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
    // One shared arena bounds native resource/table count independently of
    // image count. Ranges remain immutable until the caller completes the GPU
    // queue and collects retirement; eviction alone never makes space reusable.
    this.storage=null;this.freeRanges=budgetBytes?[[0,budgetBytes/4]]:[];
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
    for(const region of plan.hits)if(region.entry.released||!this.storage)
      throw Error('Texture residency plan references a released image');
    const batch=this.runtime.batch();
    for(const region of plan.hits) {
      batch.copy(this.storage,atlas,{sourceOffset:region.entry.offset*4,targetOffset:region.offset*4,byteLength:region.words*4});
      this.restoredBytes+=region.words*4;
    }
    batch.submit();
  }
  reserve(words) {
    const index=this.freeRanges.findIndex(([start,end])=>end-start>=words);
    if(index<0)return null;
    // Reserve the physical allocation before consuming its logical range, so
    // failure leaves the allocator unchanged and existing images still owned.
    this.storage??=this.runtime.createBuffer(this.budgetBytes,{label:'OpenMW resident image arena'});
    const [offset,end]=this.freeRanges[index];
    if(offset+words===end)this.freeRanges.splice(index,1);
    else this.freeRanges[index][0]+=words;
    this.liveBytes+=words*4;
    return {offset,words,released:false};
  }
  retireForSpace(wanted,words) {
    const ranges=[...this.freeRanges,...this.retired.map(entry=>[entry.offset,entry.offset+entry.words])];
    const fits=()=>mergeWordRanges(ranges,this.budgetBytes/4).some(([start,end])=>end-start>=words);
    // Account for fragmentation, not just the sum of free bytes. Do not evict
    // more images if already-retired neighbours will provide a contiguous fit.
    for(const [id,entry] of this.entries) {
      if(fits())break;
      if(wanted.has(id))continue;
      this.entries.delete(id);this.retired.push(entry);this.evictions++;
      ranges.push([entry.offset,entry.offset+entry.words]);
    }
  }
  capture(plan,atlas) {
    const pending=[];let batch=null;
    try {
      for(const region of plan.misses) {
        const bytes=region.words*4;
        if(bytes>this.budgetBytes){this.bypassed++;continue;}
        const entry=this.reserve(region.words);
        if(!entry) {
          this.retireForSpace(plan.wanted,region.words);
          this.bypassed++;continue;
        }
        pending.push({id:region.id,entry});
        batch??=this.runtime.batch();
        batch.copy(atlas,this.storage,{sourceOffset:region.offset*4,targetOffset:entry.offset*4,byteLength:bytes});
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
    for(const entry of this.retired){entry.released=true;this.liveBytes-=entry.words*4;}
    this.freeRanges=mergeWordRanges([...this.freeRanges,...this.retired.map(entry=>[entry.offset,entry.offset+entry.words])],this.budgetBytes/4);
    this.retired=[];
  }
  snapshot() {
    return {budgetBytes:this.budgetBytes,allocatedBytes:this.storage?.byteLength??0,occupiedBytes:this.liveBytes,entries:this.entries.size,
      retiredBytes:this.retired.reduce((sum,entry)=>sum+entry.words*4,0),hits:this.hits,misses:this.misses,
      evictions:this.evictions,stored:this.stored,restoredBytes:this.restoredBytes,bypassed:this.bypassed};
  }
  dispose() {
    for(const entry of this.entries.values())this.retired.push(entry);
    this.entries.clear();this.collectRetired();
    if(this.storage){this.runtime.destroyBuffer(this.storage);this.storage=null;}
  }
}
