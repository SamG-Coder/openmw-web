import test from 'node:test';
import assert from 'node:assert/strict';
import { allFinite, validateVertexAttributes } from './packet-validation.js';
import { MaterialPipeline } from './pipeline.js';

test('shared heap views validate only their live range without copying or changing it',()=>{
  const heap=new Float32Array(new SharedArrayBuffer(140*4));heap.fill(Infinity);
  const view=heap.subarray(2,138);view.fill(0);
  const before=heap.slice();
  assert.equal(allFinite(view),true);
  assert.deepEqual(validateVertexAttributes(view,4),{projectedParticles:false,lineParticles:false});
  assert.deepEqual(heap,before);
  view[33]=NaN;
  assert.equal(allFinite(view),false);
  assert.equal(allFinite(view,34,68),true);
  assert.equal(allFinite(new Float32Array()),true);
});

test('every attribute field retains NaN and infinity rejection',()=>{
  const attributes=new Float32Array(3*34);
  for(const invalid of [NaN,Infinity,-Infinity])for(let field=0;field<attributes.length;field++) {
    attributes[field]=invalid;
    assert.throws(()=>validateVertexAttributes(attributes,3),/Invalid world vertex attributes/);
    attributes[field]=0;
  }
  assert.throws(()=>validateVertexAttributes(new Float64Array(102),3),/Invalid world vertex attributes/);
  assert.throws(()=>validateVertexAttributes(attributes.subarray(1),3),/Invalid world vertex attributes/);
});

test('particle classification and flag bounds preserve the existing packet contract',()=>{
  for(const mode of [0,1,4,5,5.5,6,7,8,9])for(const flags of [-1,0,.5,31,32]) {
    const attributes=new Float32Array(4*34);
    attributes[3*34]=mode;attributes[3*34+25]=flags;
    const projected=mode>=5&&mode<=8;
    if(projected&&(!Number.isInteger(flags)||flags<0||flags>31))
      assert.throws(()=>validateVertexAttributes(attributes,4),/Invalid projected particle/);
    else assert.deepEqual(validateVertexAttributes(attributes,4),{projectedParticles:projected,lineParticles:mode===6});
  }
});

test('the pipeline rejects invalid inputs before any GPU allocation or upload',async()=>{
  const reachedUpload=Error('Reached GPU upload');let allocations=0;
  const runtime={device:{limits:{maxTextureDimension2D:8192,maxBufferSize:1024*1024,maxStorageBufferBindingSize:1024*1024}},
    createBuffer(){allocations++;throw reachedUpload;}};
  const pipeline=new MaterialPipeline(runtime,{});
  const scene=()=>({vertices:new Float32Array(30),matrices:new Float32Array(32),matrixIds:new Uint32Array(3),
    triangles:new Uint32Array([0,1,2,0]),materials:new Uint32Array(12),texels:new Uint32Array(1),attributes:new Float32Array(102)});
  await assert.rejects(pipeline.render(scene(),32,32),error=>error===reachedUpload);
  assert.equal(allocations,1);
  for(const [field,message] of [['vertices',/Non-finite vertex/],['matrices',/Non-finite vertex/],['attributes',/Invalid world vertex attributes/]]) {
    const invalid=scene();invalid[field][invalid[field].length-1]=Infinity;
    await assert.rejects(pipeline.render(invalid,32,32),message);
  }
  const particles=scene();particles.attributes[68]=6;particles.attributes[93]=32;
  await assert.rejects(pipeline.render(particles,32,32),/Invalid projected particle/);
  assert.equal(allocations,1);
  particles.attributes[93]=31;
  await assert.rejects(pipeline.render(particles,32,32),error=>error===reachedUpload);
  assert.equal(allocations,2);assert.equal(pipeline.busy,false);
});
