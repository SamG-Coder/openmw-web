import test from 'node:test';
import assert from 'node:assert/strict';
import {MaterialPipeline} from './pipeline.js';

function scene() {
  const params=new Float32Array(50);params[3]=1;params[24]=1;params[26]=65535;params[27]=1;
  params[37]=params[38]=1;params.set([0,64,1,1,0,0],43);
  for(const face of [8,15])params.set([7,0,255,255,0,0,0],face);
  return {vertices:new Float32Array(30),matrices:new Float32Array(32),matrixIds:new Uint32Array(3),
    triangles:new Uint32Array([0,1,2,0]),materials:new Uint32Array([0,1,1,128,0,0,0,35,19,7|(7<<4),0,0]),
    texels:new Uint32Array([0xffffffff]),attributes:new Float32Array(102),rasterParams:params};
}
function harness() {
  const reached=Error('Reached GPU allocation');let allocations=0;
  const runtime={device:{limits:{maxTextureDimension2D:8192,maxBufferSize:1024*1024,maxStorageBufferBindingSize:1024*1024}},
    createBuffer(){allocations++;throw reached;}};
  const pipeline=new MaterialPipeline(runtime,{});
  return {
    async accept(input) {
      const before=[input.materials.slice(),input.rasterParams.slice(),input.texels.slice()];
      await assert.rejects(pipeline.render(input,35,19),error=>error===reached);
      for(const [i,name] of ['materials','rasterParams','texels'].entries())assert.deepEqual(input[name],before[i]);
    },
    async reject(input,pattern) {
      const before=allocations;await assert.rejects(pipeline.render(input,35,19),pattern);assert.equal(allocations,before);
    }
  };
}
test('raw raster values reach GPU allocation without host normalization',async()=>{
  const check=harness();
  for(const value of [-4,.375,4,-Infinity,Infinity]) {
    const input=scene();input.rasterParams.fill(value,2,8);
    new Float32Array(input.materials.buffer)[4]=value;
    input.rasterParams[24]=Number.isFinite(value)?value:1;
    await check.accept(input);
  }
  for(const value of [-2147483648,-1,0,255,256,2147483648]) {
    const input=scene();input.materials[3]|=8192;input.rasterParams[9]=input.rasterParams[16]=value;
    await check.accept(input);
  }
});
test('raw raster validation keeps NaN, opcode, mask and non-normalizable infinity rejection',async()=>{
  const check=harness();
  for(let field=0;field<50;field++)if(field!==23) {
    const input=scene();input.rasterParams[field]=NaN;await check.reject(input,/Invalid raster parameters/);
    if(field<2||field>7)for(const value of [-Infinity,Infinity]) {
      const infinite=scene();infinite.rasterParams[field]=value;await check.reject(infinite,/Invalid raster parameters/);
    }
  }
  const alpha=scene();new Float32Array(alpha.materials.buffer)[4]=NaN;await check.reject(alpha,/alpha reference/);
  for(const [field,value] of [[9,.5],[9,4294967296],[16,-4294967296],[8,8],[10,-1],[11,256],[12,8],[15,-1],[17,256]]) {
    const input=scene();input.materials[3]|=8192;input.rasterParams[field]=value;await check.reject(input,/stencil material/);
  }
  for(const field of [25,27]){const input=scene();input.rasterParams[field]=.5;await check.reject(input,/coverage|multisample/);}
});
test('raw GL scissor transports signed origins but rejects negative extents and missing format flags',async()=>{
  const check=harness();
  for(const origin of [0,0x7fffffff,0x80000000,0xffffffff]) {
    const input=scene();input.materials[3]|=16777216;input.materials.set([origin,origin,0x7fffffff,0x7fffffff],5);await check.accept(input);
  }
  for(const mutate of [m=>m[3]&=~128,m=>m[7]=0x80000000,m=>m[8]=0xffffffff]) {
    const input=scene();input.materials[3]|=16777216;mutate(input.materials);await check.reject(input,/raw GL scissor/);
  }
});
test('raw fog and texture constants retain source-specific finite rules and untouched descriptors',async()=>{
  const check=harness(),fog=scene();fog.materials[3]|=32768;fog.texels=new Uint32Array(10);
  new Uint32Array(fog.rasterParams.buffer)[23]=1;new Float32Array(fog.texels.buffer).set([.5,0,2,-4,.375,3,2],2);
  await check.accept(fog);
  new Float32Array(fog.texels.buffer)[5]=Infinity;await check.reject(fog,/fog parameters/);
  for(const combine of [false,true]) {
    const input=scene();input.materials[3]|=1|512|16384;input.materials[0]=1;input.texels=new Uint32Array(45);input.texels[0]=0xffffffff;
    input.texels[2]=combine?5:3;input.texels[25]=input.texels[26]=1;
    for(let k=0;k<4;k++)new Float32Array(input.texels.buffer)[29+k*5]=1;
    new Float32Array(input.texels.buffer).set([-4,.375,3,2],5);
    if(combine){input.texels[11]=input.texels[12]=1;input.texels.fill(2,22,25);}
    await check.accept(input);
    new Float32Array(input.texels.buffer)[5]=Infinity;
    if(combine)await check.reject(input,/environment color/);else await check.accept(input);
    new Float32Array(input.texels.buffer)[5]=NaN;await check.reject(input,/environment color/);
  }
});
