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

function particles() {
  const scene=streams();scene.matrixIds=new Uint32Array(24);scene.vertexLayouts.fill(0);
  scene.vertexLayouts.set([0,24,6,2,0,0,23,0]);scene.vertexInputs=new Float32Array(23+6*17);
  scene.vertexInputs.set([1,0,0,0,1,0,3,8,4,1,0,0,1,64,1,0,31]);
  for(const [i,mode] of [2,3,4,5,6,8].entries())scene.vertexInputs[23+i*17+16]=mode;
  return scene;
}

test('raw particle descriptors classify projected and line modes without CPU expansion',()=>{
  const scene=particles();assert.deepEqual(validateVertexInputs(scene),{projectedParticles:true,lineParticles:true});
  scene.vertexInputs[23+4*17+16]=4;
  assert.deepEqual(validateVertexInputs(scene),{projectedParticles:true,lineParticles:false});
  scene.vertexInputs[23+3*17+16]=3;scene.vertexInputs[23+5*17+16]=2;
  assert.deepEqual(validateVertexInputs(scene),{projectedParticles:false,lineParticles:false});
  assert.equal(scene.vertices.length,0);assert.equal(scene.attributes.length,0);
});

test('raw particle validation bounds every source, mode, size, flag and reserved field',()=>{
  const invalid=[s=>s.vertexLayouts[2]=5,s=>s.vertexLayouts[4]=1,s=>s.vertexLayouts[5]=1,
    s=>s.vertexLayouts[6]++,s=>s.vertexLayouts[7]=s.vertexInputs.length-22,s=>s.vertexLayouts[8]=1,
    s=>s.vertexLayouts[31]=1,s=>s.vertexInputs[6]=0,s=>s.vertexInputs[6]=1.5,s=>s.vertexInputs[16]=32,
    s=>s.vertexInputs[16]=-.5,s=>s.vertexInputs[23+16]=7,s=>s.vertexInputs[23+16]=2.5,
    s=>s.vertexInputs[7]=0,s=>s.vertexInputs[8]=-1,s=>s.vertexInputs[12]=-1,
    s=>s.vertexInputs[13]=0,s=>s.vertexInputs[14]=-1,s=>s.vertexInputs[30]=NaN,s=>s.matrixIds[23]=1];
  for(const mutate of invalid){const scene=particles();mutate(scene);assert.throws(()=>validateVertexInputs(scene),RangeError);}
  const scene=particles();scene.vertexLayouts[1]=scene.vertexLayouts[2]=0;scene.matrixIds=new Uint32Array();
  scene.vertexInputs=scene.vertexInputs.slice(0,23);
  assert.deepEqual(validateVertexInputs(scene),{projectedParticles:false,lineParticles:false});
});

function gui() {
  const scene=streams();scene.matrixIds=new Uint32Array(6);scene.vertexLayouts.fill(0);
  scene.vertexLayouts.set([0,6,6,3,0,0,3,0]);scene.vertexInputs=new Float32Array(3+6*9);
  scene.vertexInputs.set([.125,.25,.375]);
  for(let i=0;i<6;i++)scene.vertexInputs.set([i*.125,-1,0,0,255,73,128,-.25,1.25],3+i*9);
  return scene;
}

test('raw GUI inputs preserve byte-valued colors and empty batches without host expansion',()=>{
  const scene=gui();assert.deepEqual(validateVertexInputs(scene),{projectedParticles:false,lineParticles:false});
  scene.vertexInputs[6]=255;scene.vertexInputs[0]=-.5;
  assert.deepEqual(validateVertexInputs(scene),{projectedParticles:false,lineParticles:false});
  assert.equal(scene.vertices.length,0);assert.equal(scene.attributes.length,0);
  scene.vertexLayouts[1]=scene.vertexLayouts[2]=0;scene.matrixIds=new Uint32Array();
  scene.vertexInputs=scene.vertexInputs.slice(0,3);
  assert.deepEqual(validateVertexInputs(scene),{projectedParticles:false,lineParticles:false});
});

test('raw GUI validation rejects malformed triangles, color bytes, offsets and unused descriptor fields',()=>{
  const invalid=[s=>s.vertexLayouts[2]=3,s=>{s.vertexLayouts[1]=s.vertexLayouts[2]=5;s.matrixIds=new Uint32Array(5);},
    s=>s.vertexLayouts[4]=1,s=>s.vertexLayouts[5]=1,s=>s.vertexLayouts[6]++,s=>s.vertexLayouts[7]=s.vertexInputs.length-2,
    s=>s.vertexLayouts[8]=1,s=>s.vertexLayouts[31]=1,s=>s.vertexInputs[6]=256,s=>s.vertexInputs[7]=-.5,
    s=>s.vertexInputs[8]=1.5,s=>s.vertexInputs[9]=Infinity,s=>s.vertexInputs[3]=NaN,s=>s.vertexInputs[10]=Infinity,
    s=>s.vertexInputs[1]=NaN,s=>s.matrixIds[5]=1,s=>s.vertexLayouts[3]=4];
  for(const mutate of invalid){const scene=gui();mutate(scene);assert.throws(()=>validateVertexInputs(scene),RangeError);}
});

function byteStreams(channels=4) {
  const scene=streams(),layout=scene.vertexLayouts;layout[28]=channels;layout[29]=layout[30]=3;
  scene.vertexInputs.set([254,128,1]);
  scene.vertexInputs.set([254,128,73,channels===4?191:.375],layout[10]);
  for(let i=0;i<9;i++)scene.vertexInputs[layout[12]+i]=(i*37)&255;
  return scene;
}

test('byte stream formats preserve RGB float alpha, constant bindings and generated-tail defaults',()=>{
  for(const channels of [3,4]) {
    const scene=byteStreams(channels),before=scene.vertexInputs.slice();
    assert.deepEqual(validateVertexInputs(scene),{projectedParticles:false,lineParticles:false});
    assert.deepEqual(scene.vertexInputs,before);
    if(channels===3)assert.equal(scene.vertexInputs[scene.vertexLayouts[10]+3],.375);
  }
  const scene=byteStreams();scene.vertexLayouts[28]=scene.vertexLayouts[29]=scene.vertexLayouts[30]=0;
  scene.vertexInputs[scene.vertexLayouts[10]]=1.25;scene.vertexInputs[scene.vertexLayouts[12]]=-.5;
  assert.doesNotThrow(()=>validateVertexInputs(scene));
});

test('color format validation rejects malformed tags and non-byte values in every normalized source',()=>{
  const invalid=[s=>s.vertexLayouts[28]=1,s=>s.vertexLayouts[28]=5,s=>s.vertexLayouts[29]=4,
    s=>s.vertexLayouts[30]=4,s=>s.vertexLayouts[31]=1,s=>s.vertexInputs[s.vertexLayouts[10]]=255.5,
    s=>s.vertexInputs[s.vertexLayouts[10]+3]=256,s=>s.vertexInputs[s.vertexLayouts[12]+8]=-1,
    s=>s.vertexInputs[1]=.125,s=>s.vertexInputs[s.vertexLayouts[12]]=NaN];
  for(const mutate of invalid){const scene=byteStreams();mutate(scene);assert.throws(()=>validateVertexInputs(scene),RangeError);}
});

test('dense ribbon and particle shared secondary formats validate their own source blocks',()=>{
  const dense=streams();dense.matrixIds=new Uint32Array(2);dense.vertexLayouts.fill(0);
  dense.vertexLayouts.set([0,2,2,0,0,0,0,20,88]);dense.vertexLayouts[29]=3;
  dense.vertexInputs=new Float32Array(94);dense.vertexInputs.set([0,128,254,255,73,191],88);
  assert.doesNotThrow(()=>validateVertexInputs(dense));
  dense.vertexInputs[93]=.5;assert.throws(()=>validateVertexInputs(dense),/color byte/);
  const particle=particles();particle.vertexLayouts[29]=3;particle.vertexInputs.set([254,128,1],20);
  assert.doesNotThrow(()=>validateVertexInputs(particle));
  particle.vertexInputs[22]=256;assert.throws(()=>validateVertexInputs(particle),/color byte/);
  for(const make of [gui,particles])for(const field of [28,30]) {
    const scene=make();scene.vertexLayouts[field]=3;assert.throws(()=>validateVertexInputs(scene),/color format/);
  }
});
