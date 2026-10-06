// Host resource ownership and GPU copies only. Image decoding and mip generation
// remain authored CUDA kernels. A version ID names immutable image contents.
export function mergeWordRanges(ranges,wordCount) {
  if(!Number.isSafeInteger(wordCount)||wordCount<0)throw RangeError('Invalid upload extent');
  const sorted=ranges.map(([start,end])=>{
    if(!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start<0||end<start||end>wordCount)
      throw RangeError('Invalid upload range');
    return [start,end];
  }).sort((a,b)=>a[0]-b[0]);
  const result=[];
  for(const [start,end] of sorted) {
    if(start===end)continue;
    const previous=result.at(-1);
    if(previous&&start<=previous[1])previous[1]=Math.max(previous[1],end);
    else result.push([start,end]);
  }
  return result;
}

export class TextureResidency {
  constructor(runtime,{budgetBytes=64*1024*1024}={}) {
    if(!Number.isSafeInteger(budgetBytes)||budgetBytes<0||budgetBytes%4)throw RangeError('Invalid texture cache budget');
    this.runtime=runtime;this.budgetBytes=budgetBytes;this.entries=new Map();this.retired=[];this.liveBytes=0;
    this.hits=0;this.misses=0;this.evictions=0;this.stored=0;this.restoredBytes=0;this.bypassed=0;
  }
  plan(records,cpuWords) {
    if(!(records instanceof Uint32Array)||records.length%3||!Number.isSafeInteger(cpuWords)||cpuWords<0)
      throw RangeError('Invalid texture residency records');
    const regions=[],wanted=new Set();
    for(let i=0;i<records.length;i+=3) {
      const [id,offset,words]=records.subarray(i,i+3),end=offset+words;
      if(!id||!words||end>cpuWords||wanted.has(id))throw RangeError('Invalid immutable texture range or duplicate version');
      wanted.add(id);regions.push({id,offset,words,end,entry:null});
    }
    regions.sort((a,b)=>a.offset-b.offset);
    for(let i=1;i<regions.length;i++)if(regions[i].offset<regions[i-1].end)
      throw RangeError('Overlapping immutable texture ranges');
    // Validate before changing LRU state or recording hits.
    for(const region of regions) {
      const entry=this.entries.get(region.id);
      if(entry&&entry.words!==region.words)throw RangeError('Image version changed its immutable extent');
      region.entry=entry??null;
    }
    const hits=[],misses=[];
    for(const region of regions) {
      if(region.entry) {
        hits.push(region);this.hits++;
        this.entries.delete(region.id);this.entries.set(region.id,region.entry);
      } else {misses.push(region);this.misses++;}
    }
    return {wanted,hits,misses,hitRanges:hits.map(region=>[region.offset,region.end]),
      isResident(offset,words) {
        const end=offset+words;
        if(!Number.isSafeInteger(offset)||!Number.isSafeInteger(words)||offset<0||words<=0||!Number.isSafeInteger(end))
          throw RangeError('Invalid texture operation range');
        let low=0,high=regions.length;
        while(low<high){const middle=(low+high)>>>1;if(regions[middle].end<=offset)low=middle+1;else high=middle;}
        const region=regions[low];
        if(!region||region.offset>=end)return false;
        if(offset<region.offset||end>region.end)throw RangeError('Texture operation crosses immutable image boundary');
        return region.entry!==null;
      }};
  }
  restore(plan,atlas) {
    if(!plan.hits.length)return;
    const batch=this.runtime.batch();
    for(const region of plan.hits) {
      batch.copy(region.entry.buffer,atlas,{targetOffset:region.offset*4,byteLength:region.words*4});
      this.restoredBytes+=region.words*4;
    }
    batch.submit();
  }
  capture(plan,atlas) {
    const pending=[];let batch=null;
    try {
      for(const region of plan.misses) {
        const bytes=region.words*4;
        if(bytes>this.budgetBytes){this.bypassed++;continue;}
        if(this.liveBytes+bytes>this.budgetBytes) {
          // Retired buffers still count against the hard budget until the
          // frame completes. Never destroy a buffer referenced by queued work.
          let reclaimable=this.retired.reduce((sum,entry)=>sum+entry.words*4,0);
          for(const [id,entry] of this.entries) {
            if(this.liveBytes-reclaimable+bytes<=this.budgetBytes)break;
            if(plan.wanted.has(id))continue;
            this.entries.delete(id);this.retired.push(entry);this.evictions++;
            reclaimable+=entry.words*4;
          }
          this.bypassed++;continue;
        }
        const entry={words:region.words,buffer:this.runtime.createBuffer(bytes,{label:`OpenMW resident image ${region.id}`})};
        this.liveBytes+=bytes;pending.push({id:region.id,entry});
        batch??=this.runtime.batch();
        batch.copy(atlas,entry.buffer,{sourceOffset:region.offset*4,byteLength:bytes});
      }
      if(batch)batch.submit();
      for(const {id,entry} of pending){this.entries.set(id,entry);this.stored++;}
    } catch(error) {
      for(const {entry} of pending)this.retired.push(entry);
      throw error;
    }
  }
  // The caller must have completed the queue first (including failed frames).
  collectRetired() {
    for(const entry of this.retired){this.runtime.destroyBuffer(entry.buffer);this.liveBytes-=entry.words*4;}
    this.retired=[];
  }
  snapshot() {
    return {budgetBytes:this.budgetBytes,allocatedBytes:this.liveBytes,entries:this.entries.size,
      retiredBytes:this.retired.reduce((sum,entry)=>sum+entry.words*4,0),hits:this.hits,misses:this.misses,
      evictions:this.evictions,stored:this.stored,restoredBytes:this.restoredBytes,bypassed:this.bypassed};
  }
  dispose() {
    for(const entry of this.entries.values())this.retired.push(entry);
    this.entries.clear();this.collectRetired();
  }
}
