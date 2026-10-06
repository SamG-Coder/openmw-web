import test from 'node:test';
import assert from 'node:assert/strict';
import {validateVertexInputs} from './vertex-input.js';

function streams() {
  const scene={vertexEncoding:1,vertices:new Float32Array(),attributes:new Float32Array(),secondaryColors:new Float32Array(),
    matrices:new Float32Array(32),matrixIds:new Uint32Array(7),vertexLayouts:new Uint32Array(32)};
  const inputs=[.1,.2,.3],layout=scene.vertexLayouts;
  layout.set([0,7,3,1,2,0]);
  for(const [stream,width] of [4,4,3,3,4,1,4,4,4,4].entries()) {
    const stride=stream%2===0?width:0;
    layout.set([inputs.length,stride],8+stream*2);
    for(let i=0;i<(stride?3:1)*width;i++)inputs.push(i*.125);
  }
  scene.vertexInputs=new Float32Array(inputs);return scene;
}
test('compact streams accept constants, changing arrays, fog and a generated tail without expanding CPU records',()=>{
  const scene=streams();assert.deepEqual(validateVertexInputs(scene),{projectedParticles:false,lineParticles:false});
  scene.vertexInputs[scene.vertexLayouts[8]]=42;
  assert.deepEqual(validateVertexInputs(scene),{projectedParticles:false,lineParticles:false});
  assert.equal(scene.vertices.length,0);assert.equal(scene.attributes.length,0);
});
test('compact stream validation rejects invalid layouts, ranges, stride, mixed data and nonfinite input',()=>{
  const invalid=[s=>s.vertexEncoding=2,s=>s.vertexLayouts=new Uint32Array(31),s=>s.vertexLayouts[0]=1,
    s=>s.vertexLayouts[1]=6,s=>s.vertexLayouts[1]=8,s=>s.vertexLayouts[2]=8,s=>s.vertexLayouts[3]=2,
    s=>s.vertexLayouts[4]=3,s=>s.vertexLayouts[5]=s.vertexInputs.length-2,s=>s.vertexLayouts[6]=1,
    s=>s.vertexLayouts[8]=s.vertexInputs.length-1,s=>s.vertexLayouts[9]=3,s=>s.vertexLayouts[28]=1,
    s=>s.matrixIds[6]=1,s=>s.vertices=new Float32Array(10),s=>s.attributes=new Float32Array(1),
    s=>s.secondaryColors=new Float32Array(3),s=>s.vertexInputs[4]=Infinity];
  for(const mutate of invalid){const scene=streams();mutate(scene);assert.throws(()=>validateVertexInputs(scene),RangeError);}
});
test('dense input records preserve particle flags and reject out-of-range source blocks',()=>{
  const scene=streams();scene.matrixIds=new Uint32Array(2);scene.vertexLayouts.fill(0);
  scene.vertexLayouts.set([0,2,2,0,0,0,0,20,88]);scene.vertexInputs=new Float32Array(94);
  scene.vertexInputs[20]=6;scene.vertexInputs[45]=31;
  assert.deepEqual(validateVertexInputs(scene),{projectedParticles:true,lineParticles:true});
  scene.vertexInputs[45]=32;assert.throws(()=>validateVertexInputs(scene),/particle/);
  scene.vertexInputs[45]=0;scene.vertexLayouts[8]=89;assert.throws(()=>validateVertexInputs(scene),/storage/);
});
