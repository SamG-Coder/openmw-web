import assert from 'node:assert/strict';
import test from 'node:test';
import {TextureResidency,mergeWordRanges} from './texture-residency.js';
const resources=new Set();let failSubmit=false;
const runtime={
  createBuffer(bytes){const resource={data:new Uint32Array(bytes/4),byteLength:bytes,destroyed:false};resources.add(resource);return resource;},
  destroyBuffer(resource){assert.equal(resource.destroyed,false);resource.destroyed=true;resources.delete(resource);},
  batch(){const copies=[];return {
    copy(source,target,{sourceOffset=0,targetOffset=0,byteLength}){copies.push({source,target,sourceOffset,targetOffset,byteLength});return this;},
    submit(){if(failSubmit)throw Error('deliberate submit failure');for(const {source,target,sourceOffset,targetOffset,byteLength} of copies){
      assert.equal(source.destroyed,false);assert.equal(target.destroyed,false);
      target.data.set(source.data.subarray(sourceOffset/4,(sourceOffset+byteLength)/4),targetOffset/4);
    }}
  };}
};
const cache=new TextureResidency(runtime,{budgetBytes:24}),atlas=runtime.createBuffer(40);
atlas.data.set([10,11,12,13,14,15,16,17,18,19]);
let plan=cache.plan(new Uint32Array([1,1,2,2,4,2]),10);
assert.equal(plan.hits.length,0);cache.capture(plan,atlas);assert.equal(cache.snapshot().occupiedBytes,16);
assert.equal(cache.snapshot().allocatedBytes,24);
plan=cache.plan(new Uint32Array([1,6,2,3,2,2]),10);
assert.deepEqual(plan.hitRanges,[[6,8]]);assert.equal(plan.isResident(6,2),true);
assert.throws(()=>plan.isResident(5,2),RangeError);
cache.restore(plan,atlas);assert.deepEqual([...atlas.data.subarray(6,8)],[11,12]);
cache.capture(plan,atlas);assert.equal(cache.snapshot().allocatedBytes,24);
// Dirty versions miss even when they reuse an old image's atlas address.
plan=cache.plan(new Uint32Array([4,6,2]),10);
assert.equal(plan.hits.length,0);cache.capture(plan,atlas);
assert.equal(cache.snapshot().allocatedBytes,24);assert.equal(cache.snapshot().retiredBytes,8);
assert.equal([...resources].filter(resource=>resource!==atlas).length,1);
cache.collectRetired();assert.equal(cache.snapshot().occupiedBytes,16);
plan=cache.plan(new Uint32Array([4,6,2]),10);cache.capture(plan,atlas);
assert.equal(cache.snapshot().allocatedBytes,24);assert.equal(cache.plan(new Uint32Array([4,0,2]),10).hits.length,1);
for(const records of [[0,0,1],[1,0,0],[1,9,2],[1,0,2,1,4,2],[1,0,2,5,1,2],[4,0,3]])
  assert.throws(()=>cache.plan(new Uint32Array(records),10),RangeError);
cache.dispose();assert.equal(cache.snapshot().allocatedBytes,0);assert.equal(resources.size,1);
// Copy-submission failure retains buffers for caller-driven queue completion.
plan=cache.plan(new Uint32Array([5,0,2]),10);failSubmit=true;
assert.throws(()=>cache.capture(plan,atlas),/deliberate submit/);failSubmit=false;
assert.equal(cache.snapshot().entries,0);assert.equal(cache.snapshot().retiredBytes,8);
cache.collectRetired();assert.equal(cache.snapshot().occupiedBytes,0);
assert.equal(cache.snapshot().allocatedBytes,24,'Empty arena remains reusable until disposal');
cache.dispose();assert.equal(cache.snapshot().allocatedBytes,0);
const disabled=new TextureResidency(runtime,{budgetBytes:0});
disabled.capture(disabled.plan(new Uint32Array([7,0,2]),10),atlas);
assert.equal(disabled.snapshot().allocatedBytes,0);
assert.deepEqual(mergeWordRanges([[8,12],[2,6],[4,9],[15,15]],20),[[2,12]]);
assert.throws(()=>mergeWordRanges([[1,21]],20),RangeError);
runtime.destroyBuffer(atlas);assert.equal(resources.size,0);
console.log('Texture residency: immutable versions, pooled ranges, relocated reuse, dirty misses, hard budget, delayed eviction, failure cleanup and upload ranges passed');

test('fragmented resident ranges cannot be reused before completion or overwrite protected neighbours',()=>{
  const cache=new TextureResidency(runtime,{budgetBytes:32}),atlas=runtime.createBuffer(128),output=runtime.createBuffer(128);
  for(let i=0;i<32;i++)atlas.data[i]=100+i;
  cache.capture(cache.plan(new Uint32Array([1,0,2,2,2,2,3,4,2,4,6,2]),32),atlas);
  const oldPlan=cache.plan(new Uint32Array([1,12,2]),32);
  const fragmented=new Uint32Array([2,2,2,4,6,2,5,16,3]);
  cache.capture(cache.plan(fragmented,32),atlas);
  assert.equal(cache.snapshot().retiredBytes,16);
  assert.equal(cache.snapshot().occupiedBytes,32);
  // Eviction changes lookup membership, not the ranges of still-queued reads.
  cache.restore(oldPlan,output);assert.deepEqual([...output.data.subarray(12,14)],[100,101]);
  cache.collectRetired();assert.throws(()=>cache.restore(oldPlan,output),/released image/);
  assert.equal(cache.snapshot().occupiedBytes,16);
  cache.capture(cache.plan(fragmented,32),atlas);
  assert.equal(cache.snapshot().entries,2,'Two nonadjacent holes do not fit three contiguous words');
  const larger=new Uint32Array([2,2,2,6,16,3]);
  cache.capture(cache.plan(larger,32),atlas);
  assert.equal(cache.snapshot().retiredBytes,8);
  cache.collectRetired();cache.capture(cache.plan(larger,32),atlas);
  cache.restore(cache.plan(new Uint32Array([2,0,2,6,8,3]),32),output);
  assert.deepEqual([...output.data.subarray(0,2)],[102,103]);
  assert.deepEqual([...output.data.subarray(8,11)],[116,117,118]);
  assert.equal(cache.snapshot().allocatedBytes,32);assert.equal(cache.snapshot().occupiedBytes,20);
  cache.dispose();runtime.destroyBuffer(atlas);runtime.destroyBuffer(output);assert.equal(resources.size,0);
});

test('arena allocation failure leaves free ranges available for a later successful capture',()=>{
  const cache=new TextureResidency(runtime,{budgetBytes:16}),atlas=runtime.createBuffer(16),allocate=runtime.createBuffer;
  atlas.data.set([1,2,3,4]);
  runtime.createBuffer=()=>{throw Error('allocation rejected');};
  try {assert.throws(()=>cache.capture(cache.plan(new Uint32Array([1,0,4]),4),atlas),/allocation rejected/);}
  finally {runtime.createBuffer=allocate;}
  assert.equal(cache.snapshot().entries,0);assert.equal(cache.snapshot().occupiedBytes,0);assert.equal(cache.snapshot().allocatedBytes,0);
  cache.capture(cache.plan(new Uint32Array([1,0,4]),4),atlas);
  atlas.data.fill(9);cache.restore(cache.plan(new Uint32Array([1,0,4]),4),atlas);
  assert.deepEqual([...atlas.data],[1,2,3,4]);
  cache.dispose();runtime.destroyBuffer(atlas);assert.equal(resources.size,0);
});
