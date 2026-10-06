// SPDX-License-Identifier: GPL-3.0-or-later
// Run: node --experimental-vm-modules --test render/webgpu/attachment-policy.test.mjs
import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
import {canUseNativeCamera, nativeCameraAttachments, attachmentBridgeKey} from './attachment-policy.js';

const C=0x4000,D=0x100,S=0x400;
const basePass={width:32,height:16,clearMask:C|D,clearColor:[.2,.4,.6,.8],clearDepth:0,clearStencil:23};
const params={width:32,height:16,color_channels:4,color_storage:0,normal_channels:4,normal_storage:0,
  normal_enabled:1,depth_bits:24,stencil_enabled:1,sample_count:1};
const plainConfig={width:32,height:16,samples:1,compact:false,normal:true,stencil:true,
  colorFormat:'rgba8unorm',normalFormat:'rgba8unorm',depthFormat:'depth24plus-stencil8'};
const defaultAttachments=()=>({colorAttachments:[{view:{},loadOp:'load',storeOp:'store'},{view:{},loadOp:'load',storeOp:'store'}],
  depthStencilAttachment:{view:{},depthLoadOp:'load',depthStoreOp:'store',stencilLoadOp:'load',stencilStoreOp:'store'}});

for(let selection=0;selection<8;selection++) {
  const mask=(selection&1?C:0)|(selection&2?D:0)|(selection&4?S:0);
  test(`full viewport clear mask ${mask} clears only selected planes`,()=>{
    assert(canUseNativeCamera({...basePass,clearMask:mask,depthFormat:0x88f0}));
    const original=defaultAttachments();
    const result=nativeCameraAttachments(original,plainConfig,params,{...basePass,clearMask:mask});
    for(const color of result.colorAttachments){assert.equal(color.loadOp,mask&C?'clear':'load');assert.equal(color.storeOp,'store');}
    assert.equal(result.depthStencilAttachment.depthLoadOp,mask&D?'clear':'load');
    assert.equal(result.depthStencilAttachment.stencilLoadOp,mask&S?'clear':'load');
    assert.equal(result.depthStencilAttachment.depthClearValue,0,'Reverse-Z zero is retained');
    assert.equal(result.depthStencilAttachment.stencilClearValue,23);
    assert.equal(original.colorAttachments[0].loadOp,'load','Never mutate a reusable descriptor');
    assert.equal(original.depthStencilAttachment.depthLoadOp,'load');
  });
}

test('scissored/channel-masked clears remain on compatibility path; preserved draws remain native',()=>{
  assert.equal(canUseNativeCamera({...basePass,viewport:[1,0,31,16]}),false);
  assert.equal(canUseNativeCamera({...basePass,clearColorMask:7}),false);
  assert(canUseNativeCamera({...basePass,clearMask:D,clearColorMask:0}),'Color mask does not affect a depth-only clear');
  assert(canUseNativeCamera({...basePass,clearMask:0,viewport:[1,2,20,10],clearColorMask:0}));
  assert.equal(canUseNativeCamera({...basePass,sampleCount:2}),false);
  assert.equal(canUseNativeCamera({...basePass,depthTargetId:9,stencilTargetId:10}),false);
  for(const mask of [-1,1,NaN,1.5,0x100000000])assert.equal(canUseNativeCamera({...basePass,clearMask:mask}),false);
});

test('compact depth, MSAA resolves and RGB/normal default channels are retained',()=>{
  assert(canUseNativeCamera({...basePass,clearMask:D},true));
  const a=defaultAttachments();a.colorAttachments[0].resolveTarget={resolve:true};
  const descriptor=nativeCameraAttachments(a,{...plainConfig,samples:4},{...params,color_channels:3,normal_channels:2},basePass);
  assert.equal(descriptor.colorAttachments[0].resolveTarget,a.colorAttachments[0].resolveTarget);
  assert.deepEqual(descriptor.colorAttachments[0].clearValue,[.2,.4,.6,1]);
  assert.deepEqual(descriptor.colorAttachments[1].clearValue,[.2,.4,0,1]);
  const depth=nativeCameraAttachments({...a,colorAttachments:[]},{...plainConfig,compact:true,normal:false,stencil:false},params,{...basePass,clearMask:D});
  assert.equal(depth.colorAttachments.length,0);assert.equal(depth.depthStencilAttachment.depthLoadOp,'clear');
});

test('bridge compile identity ignores extent, but retains every format/sample/plane property',()=>{
  const key=attachmentBridgeKey(plainConfig);
  assert.equal(key,attachmentBridgeKey({...plainConfig,width:4096,height:2048,key:'another target'}));
  for(const change of [{samples:4},{compact:true},{normal:false},{stencil:false},{colorFormat:'rgba16float'},
    {normalFormat:'rgba32float'},{depthFormat:'depth32float'}])assert.notEqual(key,attachmentBridgeKey({...plainConfig,...change}));
});

// Exercise the actual rasterizer module, replacing only shader compilation and
// the visibility reducer. No generated WGSL or GPU timing claims in this test.
async function loadRasterizer(path=new URL('./rasterizer.js',import.meta.url)) {
  const context=vm.createContext({console,performance,Uint32Array,Float32Array,ArrayBuffer,Map,Set,Promise,
    GPUBufferUsage:{UNIFORM:64,COPY_DST:8},GPUShaderStage:{VERTEX:1,FRAGMENT:2},GPUColorWrite:{RED:1},
    GPUTextureUsage:{RENDER_ATTACHMENT:16,TEXTURE_BINDING:4},setTimeout});
  const shader=new vm.SyntheticModule(['specializeMaterialSource'],function(){this.setExport('specializeMaterialSource',source=>source);},{context});
  const visibility=new vm.SyntheticModule(['ExactVisibilityCounter','MAX_VISIBILITY_TRIANGLES'],function(){
    this.setExport('ExactVisibilityCounter',class{static async create(){throw Error('Queries use the explicit test reducer');}});
    this.setExport('MAX_VISIBILITY_TRIANGLES',1024);
  },{context});
  const policy=new vm.SyntheticModule(['nativeCameraAttachments','attachmentBridgeKey'],function(){
    this.setExport('nativeCameraAttachments',nativeCameraAttachments);this.setExport('attachmentBridgeKey',attachmentBridgeKey);
  },{context});
  const module=new vm.SourceTextModule(await readFile(path,'utf8'),{context,identifier:String(path)});
  await module.link(name=>{
    if(name==='./shader-specialization.js')return shader;
    if(name==='./visibility-counter.js')return visibility;
    if(name==='./attachment-policy.js')return policy;
    throw Error(name);
  });await module.evaluate();return module.namespace.HardwareRasterizer;
}
const Rasterizer=await loadRasterizer();

function fixture(Class=Rasterizer) {
  const commands=[],uploads=[],allocated=[],queryOffsets=[],compiles=[];
  const pipeline=descriptor=>({descriptor,getBindGroupLayout:()=>({})});
  const device={limits:{minUniformBufferOffsetAlignment:256,maxBufferSize:16*1024*1024,maxTextureDimension2D:8192},
    features:new Set(['depth-clip-control','float32-blendable']),
    createShaderModule:descriptor=>({...descriptor,getCompilationInfo:async()=>({messages:[]})}),
    createRenderPipelineAsync:async descriptor=>{compiles.push(descriptor);return pipeline(descriptor);},
    createComputePipelineAsync:async descriptor=>{compiles.push(descriptor);return pipeline(descriptor);},
    createBindGroup:descriptor=>descriptor,
    createBuffer:descriptor=>{const b={...descriptor,bytes:new Uint8Array(descriptor.size),destroy(){this.destroyed=true;}};allocated.push(b);return b;},
    createCommandEncoder(){const passes=[];return {
      beginRenderPass(descriptor){
        const record={descriptor,draws:[]};passes.push(record);let group,offset=0,statePipeline,scissor,stencil;
        return {setPipeline(p){statePipeline=p;},setBindGroup(_,g,offsets=[]){group=g;offset=offsets[0]??0;},
          setScissorRect(...v){scissor=v;},setBlendConstant(){},setStencilReference(v){stencil=v;},
          draw(count,instances,first=0){
            const uniform=group?.entries?.find(e=>e.binding===5)?.resource.buffer;
            const material=uniform?new Uint32Array(uniform.bytes.buffer,offset,20)[19]:null;
            record.draws.push({count,first,instances,material,offset,stencil,scissor,pipeline:statePipeline});
          },end(){}};
      },clearBuffer(){},finish(){return passes;}
    };},
    queue:{writeBuffer(buffer,offset,data,start=0,size){
      const view=ArrayBuffer.isView(data)?new Uint8Array(data.buffer,data.byteOffset,data.byteLength):new Uint8Array(data);
      const selected=view.subarray(start,start+(size??view.byteLength-start));buffer.bytes.set(selected,offset);
      uploads.push({label:buffer.label,bytes:selected.byteLength,data:[...new Uint32Array(selected.slice().buffer)]});
    },submit(lists){commands.push(...lists.flat());}}
  };
  const r=new Class({device,assertAlive(){},flush(){}});r.materialSource='test';r.materialModule={};r.materialLayout={};r.pipelineLayout={};
  r.visibilityCounter={target:()=>({view:{}}),encode(_,__,value){queryOffsets.push(value.uniformOffset);},dispose(){}};
  const buffers={};for(const name of ['vertices','triangles','materials','texels','attributes','counts'])buffers[name]=device.createBuffer({size:4096});
  function scene(order,queries=[]) {
    const count=Math.max(0,...order)+1,materials=new Uint32Array(count*12),rasterParams=new Float32Array(count*50),texels=new Uint32Array(count*10+10);
    for(let m=0;m<count;m++) {
      materials[m*12]=m*10;materials[m*12+7]=32;materials[m*12+8]=16;rasterParams[m*50+27]=1;
      if(queries.includes(m)){materials[m*12+3]=1024;texels[m*10+8]=5;}
    }
    const triangles=new Uint32Array(order.length*4);order.forEach((m,i)=>triangles.set([0,1,2,m],i*4));
    return {materials,rasterParams,texels,triangles};
  }
  function camera(p={...params,normal_enabled:0,stencil_enabled:0}) {
    const config=r.config(p),color={value:[.9,.8,.7,.6]},normal={value:[.1,.2,.3,.4]},depth={depth:.75,stencil:97};
    const target={color:{renderView:color},normal:config.normal?{renderView:normal}:null,depth:{renderView:depth},config:{...config}};
    target.config.key=JSON.stringify([config.width,config.height,config.samples,config.compact,config.normal,config.stencil,
      config.colorFormat,config.normalFormat,config.depthFormat]);
    return {p,target,color,normal,depth};
  }
  return {r,device,commands,uploads,allocated,queryOffsets,compiles,buffers,scene,camera};
}

for(const mask of [C,D,S,C|D|S,0])test(`rasterizer integrates clear mask ${mask} without compatibility shaders or an extra pass`,async()=>{
  const f=fixture(),c=f.camera(params),scene=f.scene([0,1,0]);
  const result=await f.r.render(f.buffers,c.p,{scene,triangleCount:3,pass:{...basePass,clearMask:mask,nativeTarget:c.target}});
  assert.equal(result.drawCalls,3);assert.equal(f.commands.length,1);
  const a=f.commands[0].descriptor;
  assert.equal(a.colorAttachments[0].loadOp,mask&C?'clear':'load');
  assert.equal(a.depthStencilAttachment.depthLoadOp,mask&D?'clear':'load');
  assert.equal(a.depthStencilAttachment.stencilLoadOp,mask&S?'clear':'load');
  assert.equal(f.r.bridgePipelines.size,0);assert.equal(f.r.snapshot().performance.compatibilityCameraPasses,0);
  f.r.dispose();
});

test('empty native camera still clears and never needs a material shader pipeline',async()=>{
  const f=fixture(),c=f.camera();
  await f.r.render(f.buffers,c.p,{scene:f.scene([]),triangleCount:0,pass:{...basePass,clearMask:D,nativeTarget:c.target}});
  assert.equal(f.commands.length,1);assert.equal(f.commands[0].draws.length,0);assert.equal(f.compiles.length,0);
  assert.equal(f.commands[0].descriptor.colorAttachments[0].loadOp,'load');f.r.dispose();
});

test('a query before the first draw clears once; subsequent passes preserve the attachments',async()=>{
  const f=fixture(),c=f.camera();
  await f.r.render(f.buffers,c.p,{scene:f.scene([1,0,1]),triangleCount:3,pass:{...basePass,nativeTarget:c.target}});
  // Explicit queries force an upfront clear before their coverage-only target.
  f.commands.length=0;
  await f.r.render(f.buffers,c.p,{scene:f.scene([1,0,1],[1]),triangleCount:3,pass:{...basePass,nativeTarget:c.target}});
  assert.equal(f.commands[0].descriptor.label,'OpenMW native attachment clear');
  assert.equal(f.commands.filter(p=>p.descriptor.depthStencilAttachment.depthLoadOp==='clear').length,1);
  assert.deepEqual(f.commands.flatMap(p=>p.draws).map(d=>d.material),[1,0,1]);
  assert.deepEqual(f.queryOffsets,[0,0],'Repeated query material shares its correct uniform slot');f.r.dispose();
});

test('material uniforms and state are shared within a camera without sorting draw order',async()=>{
  const f=fixture(),c=f.camera(),order=Array.from({length:40},(_,i)=>i%2),scene=f.scene(order);
  for(let frame=0;frame<100;frame++)await f.r.render(f.buffers,{...c.p,capacity:frame},{scene,triangleCount:order.length,pass:{...basePass,nativeTarget:c.target}});
  const stats=f.r.snapshot().performance;
  assert.equal(stats.materialStateBuilds,200);assert.equal(stats.materialStateReuses,3800);
  assert.equal(stats.uniformHostAllocations,1);assert.equal(stats.uniformUploadBytes,100*2*256);
  for(const pass of f.commands)assert.deepEqual(pass.draws.map(d=>d.material),order);
  const uploads=f.uploads.filter(u=>u.label==='OpenMW native material uniforms');
  assert.equal(uploads.length,100);for(let frame=0;frame<100;frame++)assert.equal(uploads[frame].data[2],frame);
  assert.equal(f.r.lastPass.drawCalls,40);assert.equal(f.r.lastPass.uniqueMaterials,2);
  console.log('100 cameras x 40 runs: state builds 4000 -> 200; uniform upload 1024000 -> 51200 bytes; CPU uniform allocations 100 -> 1 (mock workload).');
  f.r.dispose();
});

test('changed material state is reconstructed on the next camera, including scissor',async()=>{
  const f=fixture(),c=f.camera(),scene=f.scene([0,1,0]);
  await f.r.render(f.buffers,c.p,{scene,triangleCount:3,pass:{...basePass,nativeTarget:c.target}});
  scene.materials[7]=12;
  await f.r.render(f.buffers,c.p,{scene,triangleCount:3,pass:{...basePass,nativeTarget:c.target}});
  assert.equal(f.commands.at(-1).draws[0].scissor[2],12);assert.equal(f.commands[0].draws[0].scissor[2],32);f.r.dispose();
});

test('split front/back stencil faces retain triangle order, references and shared uniforms',async()=>{
  const f=fixture(),c=f.camera(params),scene=f.scene([0,0,0]);
  scene.materials[3]=8192;scene.rasterParams[8]=7;scene.rasterParams[9]=1;scene.rasterParams[10]=255;scene.rasterParams[11]=255;
  scene.rasterParams[15]=7;scene.rasterParams[16]=2;scene.rasterParams[17]=255;scene.rasterParams[18]=255;
  await f.r.render(f.buffers,c.p,{scene,triangleCount:3,pass:{...basePass,nativeTarget:c.target}});
  const draws=f.commands.flatMap(p=>p.draws);
  assert.deepEqual(draws.map(d=>[d.first,d.stencil]),[[0,1],[0,2],[3,1],[3,2],[6,1],[6,2]]);
  assert(draws.every(d=>d.offset===0));assert.equal(f.r.snapshot().performance.materialStateBuilds,3);f.r.dispose();
});

test('uniform storage grows once when needed and only live bytes upload after shrinking',async()=>{
  const f=fixture(),c=f.camera();
  for(const order of [[0,1],[0,1,2,3,4,5,6,7,8],[1,0]])await f.r.render(f.buffers,c.p,
    {scene:f.scene(order),triangleCount:order.length,pass:{...basePass,nativeTarget:c.target}});
  assert.equal(f.r.snapshot().performance.uniformHostAllocations,2);
  assert.deepEqual(f.uploads.filter(u=>u.label==='OpenMW native material uniforms').map(u=>u.bytes),[512,2304,512]);f.r.dispose();
});

test('one bridge compilation covers multiple camera extents; format changes remain separate',async()=>{
  const f=fixture(),a={...plainConfig,key:'a'},b={...plainConfig,width:4096,height:4096,key:'b'};
  const [first,second]=await Promise.all([f.r.bridge(a),f.r.bridge(b)]);assert.equal(first,second);
  assert.equal(f.r.bridgePipelines.size,1);const initial=f.compiles.length;
  await f.r.bridge({...a,normalFormat:'rgba16float'});assert.equal(f.r.bridgePipelines.size,2);assert.equal(f.compiles.length,initial*2);f.r.dispose();
});

test('failed bridge compilation can retry and cannot leave an unusable cached entry',async()=>{
  const f=fixture(),original=f.r.createBridge.bind(f.r);let fail=true;
  f.r.createBridge=async c=>{if(fail)throw Error('compile failed');return original(c);};
  await assert.rejects(f.r.bridge(plainConfig),/compile failed/);assert.equal(f.r.bridgePipelines.size,0);
  fail=false;assert(await f.r.bridge(plainConfig));assert.equal(f.r.bridgePipelines.size,1);f.r.dispose();
});

// Prototype dispatch verifies the host will use the shared eligibility policy,
// without allocating textures or depending on a physical GPU in unit tests.
test('NativeAttachmentStore delegates its live camera eligibility to the tested policy',async()=>{
  const source=await readFile(new URL('./native-targets.js',import.meta.url),'utf8');
  assert(source.includes("import {canUseNativeCamera} from './attachment-policy.js'"));
  assert(source.includes('return canUseNativeCamera(pass,compact);'));
});
