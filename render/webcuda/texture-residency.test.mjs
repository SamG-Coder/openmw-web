import assert from 'node:assert/strict';
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
assert.equal(plan.hits.length,0);cache.capture(plan,atlas);assert.equal(cache.snapshot().allocatedBytes,16);
plan=cache.plan(new Uint32Array([1,6,2,3,2,2]),10);
assert.deepEqual(plan.hitRanges,[[6,8]]);assert.equal(plan.isResident(6,2),true);
assert.throws(()=>plan.isResident(5,2),RangeError);
cache.restore(plan,atlas);assert.deepEqual([...atlas.data.subarray(6,8)],[11,12]);
cache.capture(plan,atlas);assert.equal(cache.snapshot().allocatedBytes,24);
// Dirty versions miss even when they reuse an old image's atlas address.
plan=cache.plan(new Uint32Array([4,6,2]),10);
assert.equal(plan.hits.length,0);cache.capture(plan,atlas);
assert.equal(cache.snapshot().allocatedBytes,24);assert.equal(cache.snapshot().retiredBytes,8);
assert.equal([...resources].filter(resource=>resource!==atlas).length,3);
cache.collectRetired();assert.equal(cache.snapshot().allocatedBytes,16);
plan=cache.plan(new Uint32Array([4,6,2]),10);cache.capture(plan,atlas);
assert.equal(cache.snapshot().allocatedBytes,24);assert.equal(cache.plan(new Uint32Array([4,0,2]),10).hits.length,1);
for(const records of [[0,0,1],[1,0,0],[1,9,2],[1,0,2,1,4,2],[1,0,2,5,1,2],[4,0,3]])
  assert.throws(()=>cache.plan(new Uint32Array(records),10),RangeError);
cache.dispose();assert.equal(cache.snapshot().allocatedBytes,0);assert.equal(resources.size,1);
// Copy-submission failure retains buffers for caller-driven queue completion.
plan=cache.plan(new Uint32Array([5,0,2]),10);failSubmit=true;
assert.throws(()=>cache.capture(plan,atlas),/deliberate submit/);failSubmit=false;
assert.equal(cache.snapshot().entries,0);assert.equal(cache.snapshot().retiredBytes,8);
cache.collectRetired();assert.equal(cache.snapshot().allocatedBytes,0);
const disabled=new TextureResidency(runtime,{budgetBytes:0});
disabled.capture(disabled.plan(new Uint32Array([7,0,2]),10),atlas);
assert.equal(disabled.snapshot().allocatedBytes,0);
assert.deepEqual(mergeWordRanges([[8,12],[2,6],[4,9],[15,15]],20),[[2,12]]);
assert.throws(()=>mergeWordRanges([[1,21]],20),RangeError);
runtime.destroyBuffer(atlas);assert.equal(resources.size,0);
console.log('Texture residency: immutable versions, relocated reuse, dirty misses, hard budget, delayed eviction, failure cleanup and upload ranges passed');
