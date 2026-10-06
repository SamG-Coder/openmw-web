import assert from 'node:assert/strict';
import {targetId,targetCommand} from './target-id.js';
for(const value of [0,1,0x3fffffff,0x40000001,0x80000007,0xffffffff]) {
  assert.equal(targetId(value),value);
  assert.equal(targetId(value|0),value);
  const targets=new Map([[targetId(value|0),'attachment']]);
  assert.equal(targets.get(new Uint32Array([value])[0]),'attachment');
  assert(targets.delete(targetId(value)));
}
for(const value of [undefined,null,'1',NaN,Infinity,-Infinity,1.1,-0x80000001,0x100000000])
  assert.throws(()=>targetId(value),RangeError);
const input={targetId:-2147483641,sourceId:-1,depthTargetId:-2147483641,normalTargetId:0x40000001,stencilTargetId:0,distortionId:2,width:8192};
const output=targetCommand(input);
assert.deepEqual(output,{...input,targetId:0x80000007,sourceId:0xffffffff,depthTargetId:0x80000007});
assert.equal(input.targetId,-2147483641);
assert.equal(targetCommand({}).sourceId,undefined);
console.log('Target ID ABI: signed/unsigned identity, lookup, retirement, command fields and invalid inputs passed');
