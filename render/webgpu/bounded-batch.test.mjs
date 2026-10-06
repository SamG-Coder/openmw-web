import assert from 'node:assert/strict';
import {boundedBatch} from './bounded-batch.js';
const submitted=[];
const runtime={uniformAlignment:256,uniformCapacity:65536,batch(){
  let cursor=0;const commands=[];
  return {dispatch(invocation){const size=invocation.kernel.artifact.metadata.uniformSize;
    if(size)cursor=Math.ceil(cursor/256)*256+size;
    assert(cursor<=65536);commands.push(invocation.id);return this;},
    copy(source,target){commands.push(`copy ${source} ${target}`);return this;},
    submit(){submitted.push(commands);}};
}};
const invocation=(id,size=32)=>({id,kernel:{artifact:{metadata:{uniformSize:size}}}});
const batch=boundedBatch(runtime),expected=[];
for(let i=0;i<1000;i++) {
  if(i%100===0){batch.copy(i,i+1);expected.push(`copy ${i} ${i+1}`);}
  batch.dispatch(invocation(i),[1,1,1]);expected.push(i);
}
batch.submit();assert.equal(submitted.length,4);assert.deepEqual(submitted.flat(),expected);
assert.throws(()=>batch.dispatch(invocation(1001),[1]),/already submitted/);
assert.throws(()=>boundedBatch(runtime).dispatch(invocation(1,65537),[1]),RangeError);
const exact=boundedBatch(runtime);exact.dispatch(invocation('exact',65536),[1]).dispatch(invocation('zero',0),[1]).dispatch(invocation('next',16),[1]);exact.submit();
assert.deepEqual(submitted.slice(-2),[['exact','zero'],['next']]);
const before=submitted.length;boundedBatch(runtime).submit();assert.equal(submitted.length,before);
console.log('Bounded batches: 1000 ordered dispatches/copies, aligned capacity, exact boundary, zero uniforms and lifecycle passed');
