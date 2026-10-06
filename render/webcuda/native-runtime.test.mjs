import assert from 'node:assert/strict';
import test from 'node:test';
import {NativeRendererRuntime} from './native-runtime.js';
import {MaterialPipeline} from './pipeline.js';
import {FrameReadbacks} from './frame-readbacks.js';
import {TextureResidency,ImmutableBufferResidency} from './texture-residency.js';
import {NATIVE_PAGE_BYTES as page,pageRanges,canvasPageCopies} from './native-layout.js';

const deferred=()=>{let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};};
const settle=()=>new Promise(setImmediate);
function fixture() {
  const events=[],writes=[],submissions=[],errors=[];let identifier=0;
  const native={capabilities:{maxResources:256,maxSharedBytes:2**31,maxNativeOwnedBytes:64*1024*1024},
    allocationGate:null,submissionGate:null,
    async createBuffer(byteLength){if(this.allocationGate)await this.allocationGate.promise;return {id:++identifier,byteLength,destroyed:false};},
    async createDeviceBuffer(byteLength){return {id:++identifier,byteLength,table:true,destroyed:false};},
    async destroyDeviceBuffer(buffer){events.push(['destroyTable',buffer.id]);buffer.destroyed=true;},
    async kernel(artifact){return shader(artifact.native.entry);},
    batch(){const jobs=[];return {
      dispatch(invocation,groups){
        for(const resource of Object.values(invocation.resources))assert(!resource.destroyed,'No destroyed native allocation submitted');
        jobs.push({...invocation,groups});return this;
      },async submit(){submissions.push(jobs);events.push(['submit',jobs.length]);if(native.submissionGate)await native.submissionGate.promise;events.push(['handoff']);},
    };},
  };
  const base={device:{limits:{maxBufferSize:2**31,maxStorageBufferBindingSize:2**31-4,maxComputeWorkgroupsPerDimension:65535}},
    assertAlive(){},write(buffer,data,offset){assert(!buffer.destroyed);writes.push({buffer,data,offset});events.push(['write',buffer.id]);},
    async read(buffer,Type,bytes,offset){events.push(['read',buffer.id,offset]);return new Type(bytes/4);},
    destroyBuffer(buffer){events.push(['destroyPage',buffer.id]);buffer.destroyed=true;},
    async idle(){events.push(['idle']);},async dispose(){events.push(['dispose']);},describe(){return {};},
  };
  function shader(name){return {name,bind(resources,scalars){return {name,resources,scalars};}};}
  const runtime=new NativeRendererRuntime(base,native,{omw_set_page:shader('set_page'),omw_copy_pages:shader('copy')},e=>errors.push(e));
  return {runtime,base,native,events,writes,submissions,errors};
}
const artifact={metadata:{uniformSize:4},native:{storage:'openmw-paged-64m-v1',entry:'test',parameters:[{name:'target',type:'buffer'},{name:'value',type:'u32'}]}};

for(const [kind,Cache] of [['images',TextureResidency],['vertex streams',ImmutableBufferResidency]])
test(`hundreds of resident ${kind} use one shared arena and keep native page/table counts bounded`,async()=>{
  const f=fixture(),count=700,atlas=f.runtime.createBuffer(count*4);
  f.native.capabilities.maxResources=8;
  const cache=new Cache(f.runtime,{budgetBytes:count*4,kind});
  const records=Uint32Array.from({length:count*3},(_,i)=>[Math.floor(i/3)+1,Math.floor(i/3),1][i%3]);
  cache.capture(cache.plan(records,count),atlas);
  await f.runtime.idle();
  assert.equal(cache.snapshot().entries,count);
  assert.equal(f.runtime.reservedPages,2);assert.equal(f.runtime.reservedTables,2);
  const relocated=records.slice();
  for(let i=0;i<count;i++)relocated[i*3+1]=count-1-i;
  cache.restore(cache.plan(relocated,count),atlas);await f.runtime.idle();
  const copies=f.submissions.flat().filter(job=>job.name==='copy');
  assert.equal(copies.length,count*2);
  assert(f.submissions.every(jobs=>jobs.length<=256));
  for(let i=0;i<count;i++) {
    assert.equal(copies[i].scalars.source_offset,i);assert.equal(copies[i].scalars.target_offset,i);
    assert.equal(copies[count+i].scalars.source_offset,count-1-i);assert.equal(copies[count+i].scalars.target_offset,i);
  }
  cache.dispose();f.runtime.destroyBuffer(atlas);await f.runtime.idle();
  assert.equal(f.runtime.reservedPages,0);assert.equal(f.runtime.reservedTables,0);
  await f.runtime.dispose();
});

test('page range planning preserves byte offsets and rejects misaligned or out-of-bounds transfers',()=>{
  assert.deepEqual(pageRanges(page+16,page-4,12),[
    {page:0,pageOffset:page-4,offset:0,byteLength:4},{page:1,pageOffset:0,offset:4,byteLength:8}]);
  for(const args of [[page,1,4],[page,0,3],[page,page,4],[-4,0,0]])assert.throws(()=>pageRanges(...args),/Invalid/);
});

test('canvas copies cover every visible pixel exactly once without reading padding or outside a page',()=>{
  const width=2049,height=8192,rowPixels=2112,size=rowPixels*height*4;
  const rows=Array.from({length:height},()=>[]),copies=canvasPageCopies(size,width,height,rowPixels);
  assert(copies.some(copy=>copy.x>0),'Fixture must include a split row');
  for(const copy of copies) {
    const stride=copy.bytesPerRow??copy.width*4;
    assert(copy.offset+(copy.height-1)*stride+copy.width*4<=Math.min(page,size-copy.page*page));
    for(let row=0;row<copy.height;row++) {
      const y=copy.y+row;
      assert.equal(copy.page*page+copy.offset+row*stride,y*rowPixels*4+copy.x*4);
      rows[y].push([copy.x,copy.x+copy.width]);
    }
  }
  for(const spans of rows){spans.sort((a,b)=>a[0]-b[0]);let x=0;for(const [start,end] of spans){assert.equal(start,x);x=end;}assert.equal(x,width);}
});

test('owned uploads snapshot immediately while borrowed heap uploads retain their original view',async()=>{
  const f=fixture(),gate=deferred();f.native.allocationGate=gate;
  const target=f.runtime.createBuffer(page+16),owned=new Uint32Array([1,2,3]);
  const heap=new Uint32Array(new SharedArrayBuffer(24));heap.set([7,8,9],2);
  f.runtime.write(target,owned,page-4);owned.fill(99);
  f.runtime.writeBorrowed(target,heap.subarray(2,5),page-4);
  await settle();assert.equal(f.writes.length,0);gate.resolve();await f.runtime.idle();
  assert.deepEqual(f.writes.map(item=>[item.offset,...new Uint32Array(item.data.buffer,item.data.byteOffset,item.data.byteLength/4)]),
    [[page-4,1],[0,2,3],[page-4,7],[0,8,9]]);
  assert.notEqual(f.writes[0].data.buffer,owned.buffer);assert.equal(f.writes[2].data.buffer,heap.buffer);
  assert.equal(f.runtime.stats.borrowedUploadBytes,12);assert.equal(f.runtime.stats.copiedUploadBytes,12);
  await f.runtime.dispose();
});

test('every indirect page is an explicit argument in the same batch, and scalar values are captured at dispatch',async()=>{
  const f=fixture(),buffer=f.runtime.createBuffer(page+4),kernel=await f.runtime.kernel(artifact);
  const invocation=kernel.bind({target:buffer},{value:3}),batch=f.runtime.batch();
  batch.dispatch(invocation,[1,1,1]);invocation.setScalars({value:9});batch.dispatch(invocation,[1,1,1]);batch.submit();
  await f.runtime.idle();
  const jobs=f.submissions[0];assert.deepEqual(jobs.map(job=>job.name),['set_page','set_page','test','test']);
  assert.equal(jobs[0].resources.page,buffer.pages[0]);assert.equal(jobs[1].resources.page,buffer.pages[1]);
  assert.equal(jobs[0].resources.table,buffer.table);assert.equal(jobs[2].resources.target,buffer.table);
  assert.equal(jobs[2].scalars.value,3);assert.equal(jobs[3].scalars.value,9);
  await f.runtime.dispose();
});

test('native ownership handoff precedes later WebGPU uploads and destruction',async()=>{
  const f=fixture(),buffer=f.runtime.createBuffer(16),kernel=await f.runtime.kernel(artifact),gate=deferred();
  f.native.submissionGate=gate;
  f.runtime.batch().dispatch(kernel.bind({target:buffer},{value:1}),[1,1,1]).submit();
  f.runtime.write(buffer,new Uint32Array([2]));f.runtime.destroyBuffer(buffer);
  await settle();assert(f.events.some(event=>event[0]==='submit'));assert.equal(f.writes.length,0);
  assert(!f.events.some(event=>event[0].startsWith('destroy')));
  gate.resolve();await f.runtime.idle();
  const names=f.events.map(event=>event[0]);assert(names.indexOf('handoff')<names.indexOf('write'));assert(names.indexOf('write')<names.indexOf('destroyPage'));
  assert.equal(f.runtime.reservedSharedBytes,0);await f.runtime.dispose();
});

test('large cache-copy batches split below 256 jobs and re-bind all pages after each split',async()=>{
  const f=fixture(),source=f.runtime.createBuffer(4),targets=Array.from({length:150},()=>f.runtime.createBuffer(4));
  const batch=f.runtime.batch();for(const target of targets)batch.copy(source,target);batch.submit();await f.runtime.idle();
  assert.equal(f.submissions.length,2);
  for(const jobs of f.submissions){assert(jobs.length<=256);assert.equal(jobs[0].name,'set_page');assert.equal(jobs[0].resources.page,source.pages[0]);}
  assert.equal(f.submissions.flat().filter(job=>job.name==='copy').length,150);await f.runtime.dispose();
});

test('consecutive native submits share fences and retain their individual scalar snapshots',async()=>{
  const f=fixture(),buffer=f.runtime.createBuffer(page+16),kernel=await f.runtime.kernel(artifact);
  const invocation=kernel.bind({target:buffer},{value:1});
  const completions=[];
  for(let value=1;value<=3;value++) {
    invocation.setScalars({value});
    completions.push(f.runtime.batch().dispatch(invocation,[1,1,1]).submit());
  }
  assert.equal(completions[0],completions[1]);
  await Promise.all(completions);await f.runtime.idle();
  assert.equal(f.submissions.length,1);
  assert.deepEqual(f.submissions[0].filter(job=>job.name==='test').map(job=>job.scalars.value),[1,2,3]);
  assert.equal(f.runtime.stats.pageBindingDispatches,2);assert.equal(f.runtime.stats.coalescedBatches,2);
  await f.runtime.dispose();
});

test('coalesced native submits split at the actual 256-job limit and rebind each new batch',async()=>{
  const f=fixture(),buffer=f.runtime.createBuffer(4),kernel=await f.runtime.kernel(artifact);
  const completions=[];
  for(let value=0;value<600;value++)completions.push(f.runtime.batch().dispatch(kernel.bind({target:buffer},{value}),[1,1,1]).submit());
  await Promise.all(completions);await f.runtime.idle();
  assert.equal(f.submissions.length,3);
  for(const jobs of f.submissions){assert(jobs.length<=256);assert.equal(jobs[0].name,'set_page');}
  assert.deepEqual(f.submissions.flat().filter(job=>job.name==='test').map(job=>job.scalars.value),Array.from({length:600},(_,i)=>i));
  assert.equal(f.runtime.stats.pageBindingDispatches,3);assert.equal(f.runtime.stats.recordedBatches,600);
  assert.equal(f.runtime.stats.coalescedBatches,599);await f.runtime.dispose();
});

test('uploads and readbacks divide coalesced groups without reordering either side',async()=>{
  const f=fixture(),buffer=f.runtime.createBuffer(4),kernel=await f.runtime.kernel(artifact);
  const submit=value=>f.runtime.batch().dispatch(kernel.bind({target:buffer},{value}),[1,1,1]).submit();
  submit(1);submit(2);f.runtime.write(buffer,new Uint32Array([9]));
  submit(3);submit(4);const read=f.runtime.read(buffer,Uint32Array,4);
  submit(5);submit(6);await f.runtime.idle();await read;
  assert.deepEqual(f.submissions.map(jobs=>jobs.filter(job=>job.name==='test').map(job=>job.scalars.value)),[[1,2],[3,4],[5,6]]);
  const events=f.events.map(event=>event[0]);
  assert.deepEqual(events.filter(name=>['submit','handoff','write','read'].includes(name)),
    ['submit','handoff','write','submit','handoff','read','submit','handoff']);
  await f.runtime.dispose();
});

test('frame snapshots replace 64 native readback fence boundaries with one ordered read',async()=>{
  for(const collect of [false,true]) {
    const f=fixture(),source=f.runtime.createBuffer(8),staging=f.runtime.createBuffer(65536);
    const kernel=await f.runtime.kernel(artifact),pending=[];
    const readbacks=new FrameReadbacks(f.runtime,()=>staging);
    await f.runtime.idle();
    for(let value=0;value<64;value++) {
      f.runtime.batch().dispatch(kernel.bind({target:source},{value}),[1,1,1]).submit();
      pending.push(collect?readbacks.read(source,Uint32Array,8):f.runtime.read(source,Uint32Array,8));
    }
    await readbacks.flush();await Promise.all(pending);await f.runtime.idle();
    assert.equal(f.events.filter(event=>event[0]==='read').length,collect?1:64);
    assert.equal(f.submissions.length,collect?1:64);
    const jobs=f.submissions.flat();
    assert.deepEqual(jobs.filter(job=>job.name==='test').map(job=>job.scalars.value),Array.from({length:64},(_,i)=>i));
    assert.equal(jobs.filter(job=>job.name==='copy').length,collect?64:0);
    assert.equal(f.runtime.stats.readbackBytes,512);
    if(collect)assert.deepEqual(jobs.filter(job=>job.name!=='set_page').map(job=>job.name),Array.from({length:64},()=>['test','copy']).flat());
    await f.runtime.dispose();
  }
});

test('an executing group is immutable and later submits get their own completion',async()=>{
  const f=fixture(),buffer=f.runtime.createBuffer(4),kernel=await f.runtime.kernel(artifact),gate=deferred();
  f.native.submissionGate=gate;
  const first=f.runtime.batch().dispatch(kernel.bind({target:buffer},{value:1}),[1,1,1]).submit();
  await settle();assert.equal(f.submissions.length,1);
  const second=f.runtime.batch().dispatch(kernel.bind({target:buffer},{value:2}),[1,1,1]).submit();
  assert.notEqual(first,second);assert.equal(f.submissions[0].filter(job=>job.name==='test').length,1);
  gate.resolve();await Promise.all([first,second]);assert.equal(f.submissions.length,2);
  assert.equal(f.runtime.stats.coalescedBatches,0);await f.runtime.dispose();
});

test('allocation reservations include physical alignment and retired resources until release finishes',async()=>{
  const f=fixture();f.native.capabilities.maxSharedBytes=65536;
  const buffer=f.runtime.createBuffer(4);assert.throws(()=>f.runtime.createBuffer(4),/budget/);
  await f.runtime.idle();f.runtime.destroyBuffer(buffer);assert.throws(()=>f.runtime.createBuffer(4),/budget/);
  await f.runtime.idle();f.runtime.createBuffer(4);await f.runtime.dispose();
});

test('the reported 294 MB atlas growth fits the 2 GiB budget by retaining four existing pages',async()=>{
  const f=fixture(),pipeline=new MaterialPipeline(f.runtime,{});
  const previous=pipeline.buffer('texels',281693440);
  assert.equal(previous.byteLength,285887744);
  const reportedSharedBytes=1913782272;
  const other=f.runtime.createBuffer(reportedSharedBytes-Math.ceil(previous.byteLength/65536)*65536);
  assert.equal(f.runtime.reservedSharedBytes,reportedSharedBytes);
  assert.throws(()=>f.runtime.createBuffer(294276352,{label:'OpenMW texels'}),/budget exceeded/);
  const replacement=pipeline.buffer('texels',290082048);
  assert.equal(replacement.byteLength,294276352);
  assert.equal(f.runtime.reservedSharedBytes,reportedSharedBytes+Math.ceil((294276352-4*page)/65536)*65536);
  assert(f.runtime.reservedSharedBytes<2**31);
  await f.runtime.idle();
  assert.equal(f.runtime.stats.reusedGrowthBytes,4*page);
  for(let i=0;i<4;i++)assert.equal(previous.pages[i],replacement.pages[i]);
  assert.notEqual(previous.pages[4],replacement.pages[4]);
  const shared=replacement.pages[0],oldTail=previous.pages[4];
  pipeline.collectRetired();await f.runtime.idle();
  assert(!shared.destroyed);assert(oldTail.destroyed);
  pipeline.dispose();f.runtime.destroyBuffer(other);await f.runtime.idle();
  assert.equal(f.runtime.reservedSharedBytes,0);assert.equal(f.runtime.reservedPages,0);assert.equal(f.runtime.reservedTables,0);
  await f.runtime.dispose();
});

test('successive growth versions preserve queued use, copy only partial tails and release pages once',async()=>{
  const f=fixture(),gate=deferred();f.native.allocationGate=gate;
  const first=f.runtime.createBuffer(page+16);
  f.runtime.write(first,new Uint32Array([10]),page);
  const second=f.runtime.growBuffer(first,page+32);
  f.runtime.write(second,new Uint32Array([20]),page+16);
  const third=f.runtime.growBuffer(second,2*page+16);
  f.runtime.destroyBuffer(second);f.runtime.destroyBuffer(first);
  gate.resolve();await f.runtime.idle();
  const copies=f.submissions.flat().filter(job=>job.name==='copy');
  assert.deepEqual(copies.map(job=>job.scalars),[
    {source_offset:page/4,target_offset:page/4,word_count:4},
    {source_offset:page/4,target_offset:page/4,word_count:8}]);
  assert.equal(f.runtime.reservedSharedBytes,2*page+65536);assert.equal(f.runtime.reservedPages,3);
  assert(third.pages.every(p=>!p.destroyed));
  const names=f.events.map(event=>event[0]);
  assert(names.indexOf('write')<names.indexOf('submit'));
  assert(names.indexOf('handoff')<names.lastIndexOf('write'));
  f.runtime.write(third,new Uint32Array([30]));f.runtime.destroyBuffer(third);await f.runtime.idle();
  const released=f.events.filter(event=>event[0]==='destroyPage').map(event=>event[1]);
  assert.equal(released.length,5);assert.equal(new Set(released).size,5);
  assert.equal(f.runtime.reservedSharedBytes,0);await f.runtime.dispose();
});

test('growth reservation failure leaves the current pipeline buffer valid and owned',async()=>{
  const f=fixture(),pipeline=new MaterialPipeline(f.runtime,{});
  const old=pipeline.buffer('texels',4);await f.runtime.idle();
  f.native.capabilities.maxSharedBytes=65536;
  const refs=old.allocations.map(page=>page.references);
  assert.throws(()=>pipeline.buffer('texels',page),/budget exceeded/);
  assert.equal(pipeline.buffers.get('texels'),old);assert.equal(pipeline.retired.size,0);
  assert.deepEqual(old.allocations.map(page=>page.references),refs);
  f.runtime.write(old,new Uint32Array([9]));await f.runtime.idle();
  assert(!old.pages[0].destroyed);pipeline.dispose();await f.runtime.idle();await f.runtime.dispose();
});

test('shared-prefix growth copies reject physical overlap and allow disjoint ranges',async()=>{
  const f=fixture(),old=f.runtime.createBuffer(page),grown=f.runtime.growBuffer(old,page+16);
  assert.throws(()=>f.runtime.batch().copy(old,grown,{sourceOffset:0,targetOffset:4,byteLength:8}),/overlap/);
  f.runtime.batch().copy(old,grown,{sourceOffset:0,targetOffset:8,byteLength:8}).submit();
  f.runtime.destroyBuffer(old);f.runtime.destroyBuffer(grown);await f.runtime.idle();
  assert.equal(f.runtime.reservedPages,0);await f.runtime.dispose();
});

test('failed partial-tail allocation cleans only its own pages and table, preserving shared predecessors',async()=>{
  const f=fixture(),old=f.runtime.createBuffer(page+16);await f.runtime.idle();
  const shared=old.pages[0],tail=old.pages[1];
  f.native.createBuffer=async()=>{throw Error('injected allocation failure');};
  const grown=f.runtime.growBuffer(old,page+32);
  await assert.rejects(f.runtime.idle(),/injected allocation failure/);
  assert(!shared.destroyed);assert(!tail.destroyed);
  assert.equal(old.allocations[0].references,1);assert.equal(f.runtime.reservedSharedBytes,page+65536);
  assert.equal(f.runtime.reservedTables,1);assert(grown.released);
  assert.equal(f.errors.length,1);await f.runtime.dispose();
});

test('disposal rejects new work immediately but waits for accepted native submissions',async()=>{
  const f=fixture(),buffer=f.runtime.createBuffer(4),kernel=await f.runtime.kernel(artifact),gate=deferred();f.native.submissionGate=gate;
  f.runtime.batch().dispatch(kernel.bind({target:buffer},{value:1}),[1,1,1]).submit();
  const done=f.runtime.dispose();assert.throws(()=>f.runtime.createBuffer(4),/disposed/);assert.equal(f.runtime.dispose(),done);
  await settle();assert(!f.events.some(event=>event[0]==='dispose'));gate.resolve();await done;
  assert.equal(f.events.at(-1)[0],'dispose');assert.equal(f.errors.length,0);
});

test('asynchronous native failure is reported and session disposal still runs',async()=>{
  const f=fixture(),buffer=f.runtime.createBuffer(4),kernel=await f.runtime.kernel(artifact),gate=deferred();f.native.submissionGate=gate;
  f.runtime.batch().dispatch(kernel.bind({target:buffer},{value:1}),[1,1,1]).submit();
  await settle();gate.reject(Error('test device lost'));await assert.rejects(f.runtime.idle(),/test device lost/);
  assert.equal(f.errors.length,1);await f.runtime.dispose();assert.equal(f.events.at(-1)[0],'dispose');
});
