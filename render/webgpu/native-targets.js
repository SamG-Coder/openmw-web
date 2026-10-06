// SPDX-License-Identifier: GPL-3.0-or-later
// Persistent logical WebGPU render targets for OpenMW. Camera attachments stay
// native from rasterization through post-processing and presentation.

import {colorStorage,depthStorage} from './color-storage.js';

const FULLSCREEN=`
@vertex fn fullscreen(@builtin(vertex_index) i:u32)->@builtin(position) vec4<f32>{
  let x=f32((i<<1u)&2u), y=f32(i&2u);
  return vec4<f32>(x*2.0-1.0,y*2.0-1.0,0.0,1.0);
}`;

function requireFeature(device,name,reason){
  if(!device.features.has(name))throw Error(`Native WebGPU target requires ${name} for ${reason}`);
}
function colorFormat(device,format,label='color'){
  const {storage}=colorStorage(format);
  if(storage===0)return 'rgba8unorm';
  if(storage===1)return 'rgba16float';
  if(storage===2)return 'rgba32float';
  if(storage===3)return 'rgba8unorm-srgb';
  if(storage===4){requireFeature(device,'texture-formats-tier1',`${label} rgba16unorm`);return 'rgba16unorm';}
  if(storage===5){requireFeature(device,'texture-formats-tier1',`${label} rgba8snorm`);return 'rgba8snorm';}
  if(storage===6){requireFeature(device,'texture-formats-tier1',`${label} rgba16snorm`);return 'rgba16snorm';}
  throw RangeError('Unsupported native color storage');
}
function depthFormatFor(device,format,stencil){
  const bits=depthStorage(format);
  if(stencil&&bits===0){requireFeature(device,'depth32float-stencil8','float depth/stencil');return 'depth32float-stencil8';}
  if(stencil){if(bits!==24)throw Error('16-bit depth cannot carry stencil in WebGPU');return 'depth24plus-stencil8';}
  if(bits===16)return 'depth16unorm';
  if(bits===24)return 'depth24plus';
  return 'depth32float';
}
function destroyPlane(plane){
  if(!plane)return;
  plane.renderTexture?.destroy();
  if(plane.sampleTexture&&plane.sampleTexture!==plane.renderTexture)plane.sampleTexture.destroy();
}
function textureUsage(copy=true){
  let usage=GPUTextureUsage.RENDER_ATTACHMENT|GPUTextureUsage.TEXTURE_BINDING;
  if(copy)usage|=GPUTextureUsage.COPY_SRC|GPUTextureUsage.COPY_DST;
  return usage;
}
function makeColorPlane(device,width,height,samples,format,label){
  const renderUsage=samples===1?textureUsage(true):(GPUTextureUsage.RENDER_ATTACHMENT|GPUTextureUsage.TEXTURE_BINDING);
  const renderTexture=device.createTexture({label,size:[width,height],sampleCount:samples,format,usage:renderUsage});
  const renderView=renderTexture.createView();
  if(samples===1)return {renderTexture,renderView,sampleTexture:renderTexture,sampleView:renderView,format,samples,width,height};
  const sampleTexture=device.createTexture({label:`${label} resolve`,size:[width,height],sampleCount:1,format,usage:textureUsage(true)});
  return {renderTexture,renderView,sampleTexture,sampleView:sampleTexture.createView(),format,samples,width,height};
}
function makeDepthPlane(device,width,height,samples,format,label){
  // Depth24Plus/Depth32Float are render/sampling resources; depth preservation is
  // performed with a native depth-copy render pass instead of buffer copies.
  const renderTexture=device.createTexture({label,size:[width,height],sampleCount:samples,format,
    usage:GPUTextureUsage.RENDER_ATTACHMENT|GPUTextureUsage.TEXTURE_BINDING});
  const renderView=renderTexture.createView();
  return {renderTexture,renderView,sampleTexture:renderTexture,sampleView:renderTexture.createView({aspect:'depth-only'}),
    format,samples,width,height};
}

const POST_WGSL=`${FULLSCREEN}
struct Params {
  sourceSize:vec2<u32>, destinationSize:vec2<u32>,
  scale:vec2<f32>, gamma:f32, contrast:f32,
  useAdjust:u32, useDistortion:u32, distortionSize:vec2<u32>,
}
@group(0) @binding(0) var sourceTex:texture_2d<f32>;
@group(0) @binding(1) var distortionTex:texture_2d<f32>;
@group(0) @binding(2) var<uniform> params:Params;

fn bilinear(tex:texture_2d<f32>,uv:vec2<f32>,size:vec2<u32>)->vec4<f32>{
  let xy=clamp(uv,vec2<f32>(0.0),vec2<f32>(1.0))*vec2<f32>(size)-vec2<f32>(0.5);
  let base=vec2<i32>(floor(xy));
  let f=fract(xy);
  let hi=vec2<i32>(size)-vec2<i32>(1);
  let p00=clamp(base,vec2<i32>(0),hi);
  let p10=clamp(base+vec2<i32>(1,0),vec2<i32>(0),hi);
  let p01=clamp(base+vec2<i32>(0,1),vec2<i32>(0),hi);
  let p11=clamp(base+vec2<i32>(1,1),vec2<i32>(0),hi);
  let top=textureLoad(tex,p00,0)*(1.0-f.x)+textureLoad(tex,p10,0)*f.x;
  let bottom=textureLoad(tex,p01,0)*(1.0-f.x)+textureLoad(tex,p11,0)*f.x;
  return top*(1.0-f.y)+bottom*f.y;
}
@fragment fn post(@builtin(position) p:vec4<f32>)->@location(0) vec4<f32>{
  var uv=p.xy/vec2<f32>(params.destinationSize);
  uv*=params.scale;
  var sampleUv=uv;
  var occlusion=1.0;
  if(params.useDistortion!=0u){
    let d=bilinear(distortionTex,uv,params.distortionSize);
    let delta=clamp(d.xy*0.14,vec2<f32>(-1.0),vec2<f32>(1.0));
    occlusion=bilinear(distortionTex,uv+delta,params.distortionSize).z;
    sampleUv=uv+delta;
  }
  var color=mix(bilinear(sourceTex,sampleUv,params.sourceSize),bilinear(sourceTex,uv,params.sourceSize),occlusion);
  if(params.useAdjust!=0u){
    color.rgb=max((color.rgb-vec3<f32>(0.5))*params.contrast+vec3<f32>(0.5),vec3<f32>(0.0));
    if(params.gamma==0.0){
      color.rgb=select(vec3<f32>(0.0),vec3<f32>(1.0),color.rgb>=vec3<f32>(1.0));
    }else{
      color.rgb=pow(color.rgb,vec3<f32>(1.0/params.gamma));
    }
  }
  return color;
}`;

const DEPTH_COPY_WGSL=`${FULLSCREEN}
@group(0) @binding(0) var sourceDepth:texture_depth_2d;
@fragment fn copy_depth(@builtin(position) p:vec4<f32>)->@builtin(frag_depth) f32 {
  return textureLoad(sourceDepth,vec2<i32>(p.xy),0);
}`;

const ATLAS_COLOR_WGSL=`
struct Params { width:u32,height:u32,offset:u32,floatOutput:u32 }
@group(0) @binding(0) var sourceTex:texture_2d<f32>;
@group(0) @binding(1) var<storage,read_write> texels:array<u32>;
@group(0) @binding(2) var<uniform> params:Params;
@compute @workgroup_size(8,8,1) fn main(@builtin(global_invocation_id) id:vec3<u32>){
  if(id.x>=params.width||id.y>=params.height){return;}
  let rgba=textureLoad(sourceTex,vec2<i32>(id.xy),0);
  let pixel=((params.height-1u-id.y)*params.width+id.x);
  if(params.floatOutput!=0u){
    let base=params.offset+pixel*4u;
    texels[base]=bitcast<u32>(rgba.x);texels[base+1u]=bitcast<u32>(rgba.y);
    texels[base+2u]=bitcast<u32>(rgba.z);texels[base+3u]=bitcast<u32>(rgba.w);
  }else{
    let c=vec4<u32>(clamp(rgba,vec4<f32>(0.0),vec4<f32>(1.0))*255.0+0.5);
    texels[params.offset+pixel]=c.x|(c.y<<8u)|(c.z<<16u)|(c.w<<24u);
  }
}`;

const ATLAS_DEPTH_WGSL=`
struct Params { width:u32,height:u32,offset:u32,pad:u32 }
@group(0) @binding(0) var sourceTex:texture_depth_2d;
@group(0) @binding(1) var<storage,read_write> texels:array<u32>;
@group(0) @binding(2) var<uniform> params:Params;
@compute @workgroup_size(8,8,1) fn main(@builtin(global_invocation_id) id:vec3<u32>){
  if(id.x>=params.width||id.y>=params.height){return;}
  let z=textureLoad(sourceTex,vec2<i32>(id.xy),0);
  let pixel=((params.height-1u-id.y)*params.width+id.x);
  texels[params.offset+pixel]=bitcast<u32>(z);
}`;

const COMPAT_COLOR_WGSL=`
struct Params { width:u32,height:u32,base:u32,pad:u32 }
@group(0) @binding(0) var sourceTex:texture_2d<f32>;
@group(0) @binding(1) var<storage,read_write> target:array<f32>;
@group(0) @binding(2) var<uniform> params:Params;
@compute @workgroup_size(8,8,1) fn main(@builtin(global_invocation_id) id:vec3<u32>){
  if(id.x>=params.width||id.y>=params.height){return;}
  let pixel=id.y*params.width+id.x;
  let rgba=textureLoad(sourceTex,vec2<i32>(id.xy),0);
  let dst=pixel*9u+params.base;
  target[dst]=rgba.x;target[dst+1u]=rgba.y;target[dst+2u]=rgba.z;target[dst+3u]=rgba.w;
}`;

const COMPAT_DEPTH_WGSL=`
struct Params { width:u32,height:u32,compact:u32,pad:u32 }
@group(0) @binding(0) var sourceTex:texture_depth_2d;
@group(0) @binding(1) var<storage,read_write> target:array<f32>;
@group(0) @binding(2) var<uniform> params:Params;
@compute @workgroup_size(8,8,1) fn main(@builtin(global_invocation_id) id:vec3<u32>){
  if(id.x>=params.width||id.y>=params.height){return;}
  let pixel=id.y*params.width+id.x;
  let z=textureLoad(sourceTex,vec2<i32>(id.xy),0);
  if(params.compact!=0u){target[pixel]=z;}else{target[pixel*9u+4u]=z;}
}`;

export class NativeAttachmentStore {
  constructor(runtime){
    this.runtime=runtime;this.device=runtime.device;
    this.postModule=this.device.createShaderModule({label:'OpenMW native postprocess',code:POST_WGSL});
    this.depthModule=this.device.createShaderModule({label:'OpenMW native depth copy',code:DEPTH_COPY_WGSL});
    this.atlasColorModule=this.device.createShaderModule({label:'OpenMW native target-to-atlas color',code:ATLAS_COLOR_WGSL});
    this.atlasDepthModule=this.device.createShaderModule({label:'OpenMW native target-to-atlas depth',code:ATLAS_DEPTH_WGSL});
    this.compatColorModule=this.device.createShaderModule({label:'OpenMW native compatibility color export',code:COMPAT_COLOR_WGSL});
    this.compatDepthModule=this.device.createShaderModule({label:'OpenMW native compatibility depth export',code:COMPAT_DEPTH_WGSL});
    this.postPipelines=new Map();this.depthPipelines=new Map();this.atlasPipelines=new Map();this.compatPipelines=new Map();
    this.stats={postPasses:0,presentations:0,atlasCopies:0,compatibilityMaterializations:0,depthCopies:0};
    this.uniformStride=Math.max(256,this.device.limits.minUniformBufferOffsetAlignment);
    this.postUniform=this.device.createBuffer({label:'OpenMW native postprocess uniforms',size:this.uniformStride,usage:GPUBufferUsage.UNIFORM|GPUBufferUsage.COPY_DST});
    this.atlasUniform=this.device.createBuffer({label:'OpenMW native atlas-copy uniforms',size:this.uniformStride,usage:GPUBufferUsage.UNIFORM|GPUBufferUsage.COPY_DST});
    this.compatUniform=this.device.createBuffer({label:'OpenMW native compatibility uniforms',size:this.uniformStride,usage:GPUBufferUsage.UNIFORM|GPUBufferUsage.COPY_DST});
  }
  destroy(holder){
    if(!holder?.native)return;
    for(const plane of ['color','normal','depth'])destroyPlane(holder.native[plane]);
    holder.native=null;
  }
  ensureColor(holder,format,samples=1,kind='color'){
    holder.native??={};
    const gpuFormat=colorFormat(this.device,format,kind);
    let plane=holder.native[kind];
    if(plane&&(plane.width!==holder.width||plane.height!==holder.height||plane.samples!==samples||plane.format!==gpuFormat)){
      destroyPlane(plane);plane=null;
    }
    if(!plane){
      plane=makeColorPlane(this.device,holder.width,holder.height,samples,gpuFormat,`OpenMW target ${kind}`);
      holder.native[kind]=plane;
    }
    return plane;
  }
  ensureDepth(holder,format,samples=1,stencil=false){
    holder.native??={};
    const gpuFormat=depthFormatFor(this.device,format,stencil);
    let plane=holder.native.depth;
    if(plane&&(plane.width!==holder.width||plane.height!==holder.height||plane.samples!==samples||plane.format!==gpuFormat)){
      destroyPlane(plane);plane=null;
    }
    if(!plane){
      plane=makeDepthPlane(this.device,holder.width,holder.height,samples,gpuFormat,'OpenMW target depth');
      holder.native.depth=plane;
    }
    return plane;
  }
  canCamera(pass,compact=false){
    const samples=pass.sampleCount??1;
    if(samples!==1&&samples!==4)return false;
    // Separate stencil storage cannot be represented independently from WebGPU's
    // depth-stencil attachment. Keep that rare path on the compatibility bridge.
    if(pass.stencilTargetId&&pass.depthTargetId&&pass.stencilTargetId!==pass.depthTargetId)return false;
    const v=pass.viewport??[0,0,pass.width,pass.height];
    const full=v[0]===0&&v[1]===0&&v[2]===pass.width&&v[3]===pass.height;
    const mask=pass.clearMask??16640;
    // Native load (mask=0) or a complete attachment clear is fast. Partial
    // component/depth clears still use the compatibility path.
    if(mask!==0){
      if(!full)return false;
      if(!compact&&!(mask&16384))return false;
      if(!(mask&256))return false;
      const stencilBits=pass.stencilBits??([0x88f0,0x8cad].includes(pass.depthFormat)?8:0);
      if(stencilBits&&!(mask&1024))return false;
      if(!compact&&(pass.clearColorMask??15)!==15)return false;
    }
    return true;
  }
  cameraTarget(holder,pass,targets,compact=false){
    const samples=pass.sampleCount??1;
    const stencilBits=pass.stencilBits??([0x88f0,0x8cad].includes(pass.depthFormat)?8:0);
    const color=compact?null:this.ensureColor(holder,pass.colorFormat??0x8058,samples,'color');
    const depthHolder=pass.depthTargetId?targets.get(pass.depthTargetId):holder;
    if(!depthHolder)throw Error('Missing native depth target holder');
    const depth=this.ensureDepth(depthHolder,pass.depthFormat??0x81a6,samples,stencilBits!==0);
    let normal=null;
    if(pass.normalTargetId){
      const normalHolder=targets.get(pass.normalTargetId);if(!normalHolder)throw Error('Missing native normal target holder');
      normal=this.ensureColor(normalHolder,pass.normalFormat??0x8058,samples,'normal');
      normalHolder.normalFormat=pass.normalFormat??0x8058;
    }
    return {holder,color,depth,normal,config:{
      width:holder.width,height:holder.height,samples,compact:Boolean(compact),normal:Boolean(normal),stencil:stencilBits!==0,
      colorFormat:color?.format??null,normalFormat:normal?.format??null,depthFormat:depth.format,
      key:JSON.stringify([holder.width,holder.height,samples,Boolean(compact),Boolean(normal),stencilBits!==0,color?.format??null,normal?.format??null,depth.format])
    }};
  }
  async postPipeline(format){
    let pending=this.postPipelines.get(format);if(pending)return pending;
    pending=this.device.createRenderPipelineAsync({label:`OpenMW native postprocess ${format}`,layout:'auto',
      vertex:{module:this.postModule,entryPoint:'fullscreen'},fragment:{module:this.postModule,entryPoint:'post',targets:[{format}]},
      primitive:{topology:'triangle-list'}});
    this.postPipelines.set(format,pending);return pending;
  }
  async depthPipeline(format){
    let pending=this.depthPipelines.get(format);if(pending)return pending;
    pending=this.device.createRenderPipelineAsync({label:`OpenMW native depth copy ${format}`,layout:'auto',
      vertex:{module:this.depthModule,entryPoint:'fullscreen'},fragment:{module:this.depthModule,entryPoint:'copy_depth',targets:[]},
      primitive:{topology:'triangle-list'},depthStencil:{format,depthWriteEnabled:true,depthCompare:'always'}});
    this.depthPipelines.set(format,pending);return pending;
  }
  async resolveColor(source,destination,{scaleX=1,scaleY=1,gamma=1,contrast=1,adjust=false,distortion=null,clear=false}={}){
    if(!source?.color?.sampleView||!destination?.color?.renderView)throw Error('Native color resolve requires color textures');
    if(destination.color.samples!==1)throw Error('Native postprocess destination must be single-sample');
    const pipeline=await this.postPipeline(destination.color.format);
    const params=new ArrayBuffer(48),u32=new Uint32Array(params),f32=new Float32Array(params);
    u32[0]=source.color.width;u32[1]=source.color.height;u32[2]=destination.color.width;u32[3]=destination.color.height;
    f32[4]=scaleX;f32[5]=scaleY;f32[6]=gamma;f32[7]=contrast;u32[8]=adjust?1:0;u32[9]=distortion?1:0;
    u32[10]=distortion?.color?.width??source.color.width;u32[11]=distortion?.color?.height??source.color.height;
    this.device.queue.writeBuffer(this.postUniform,0,params);
    const distortionView=distortion?.color?.sampleView??source.color.sampleView;
    const bind=this.device.createBindGroup({layout:pipeline.getBindGroupLayout(0),entries:[
      {binding:0,resource:source.color.sampleView},{binding:1,resource:distortionView},{binding:2,resource:{buffer:this.postUniform,size:48}}
    ]});
    const encoder=this.device.createCommandEncoder({label:'OpenMW native scene resolve'});
    const pass=encoder.beginRenderPass({colorAttachments:[{view:destination.color.renderView,
      loadOp:clear?'clear':'load',storeOp:'store',clearValue:[0,0,0,1]}]});
    pass.setPipeline(pipeline);pass.setBindGroup(0,bind);pass.draw(3);pass.end();
    this.device.queue.submit([encoder.finish()]);
  }
  clearDepth(holder,value=1){
    const depth=holder?.native?.depth;if(!depth)throw Error('Native depth target is unavailable');
    const encoder=this.device.createCommandEncoder({label:'OpenMW native depth clear'});
    const pass=encoder.beginRenderPass({colorAttachments:[],depthStencilAttachment:{view:depth.renderView,
      depthLoadOp:'clear',depthStoreOp:'store',depthClearValue:value,
      ...(depth.format.includes('stencil')?{stencilLoadOp:'clear',stencilStoreOp:'store',stencilClearValue:0}:{})}});
    pass.end();this.device.queue.submit([encoder.finish()]);
  }
  async copyDepth(source,destination,clearDepth=1){
    if(!source?.depth?.sampleView||!destination?.depth?.renderView)throw Error('Native depth copy requires depth textures');
    if(source.depth.samples!==1||destination.depth.samples!==1)throw Error('Native depth copy requires single-sample depth');
    const pipeline=await this.depthPipeline(destination.depth.format);
    const bind=this.device.createBindGroup({layout:pipeline.getBindGroupLayout(0),entries:[{binding:0,resource:source.depth.sampleView}]});
    const encoder=this.device.createCommandEncoder({label:'OpenMW native depth copy'});
    const pass=encoder.beginRenderPass({colorAttachments:[],depthStencilAttachment:{view:destination.depth.renderView,
      depthLoadOp:'clear',depthStoreOp:'store',depthClearValue:clearDepth,
      ...(destination.depth.format.includes('stencil')?{stencilLoadOp:'load',stencilStoreOp:'store'}:{})}});
    pass.setPipeline(pipeline);pass.setBindGroup(0,bind);pass.draw(3);pass.end();
    this.device.queue.submit([encoder.finish()]);this.stats.depthCopies++;
  }
  async present(holder,context,width,height){
    if(!holder?.native?.color)throw Error('Screen target has no native color texture');
    const source={color:holder.native.color};
    const current=context.getCurrentTexture();
    const destination={color:{renderTexture:current,renderView:current.createView(),sampleTexture:current,sampleView:null,
      format:'rgba8unorm',samples:1,width,height}};
    await this.resolveColor(source,destination,{clear:true});this.stats.presentations++;
  }
  async atlasPipeline(depth=false){
    const key=depth?'depth':'color';let pending=this.atlasPipelines.get(key);if(pending)return pending;
    const module=depth?this.atlasDepthModule:this.atlasColorModule;
    pending=this.device.createComputePipelineAsync({label:`OpenMW native ${key} target to atlas`,layout:'auto',
      compute:{module,entryPoint:'main'}});
    this.atlasPipelines.set(key,pending);return pending;
  }
  async compatPipeline(depth=false){
    const key=depth?'depth':'color';let pending=this.compatPipelines.get(key);if(pending)return pending;
    pending=this.device.createComputePipelineAsync({label:`OpenMW native compatibility ${key} export`,layout:'auto',
      compute:{module:depth?this.compatDepthModule:this.compatColorModule,entryPoint:'main'}});
    this.compatPipelines.set(key,pending);return pending;
  }
  async materializeCompatibility(holder,buffer){
    if(!holder?.native)return;
    this.stats.compatibilityMaterializations++;
    const gpuBuffer=buffer?.gpuBuffer??buffer?.gpu??buffer;
    const encoder=this.device.createCommandEncoder({label:'OpenMW native compatibility materialization'});
    const encodeColor=async(resource,base)=>{
      if(!resource||resource.samples!==1)return;
      const pipeline=await this.compatPipeline(false);
      const params=new Uint32Array([resource.width,resource.height,base,0]);
      this.device.queue.writeBuffer(this.compatUniform,0,params);
      const bind=this.device.createBindGroup({layout:pipeline.getBindGroupLayout(0),entries:[
        {binding:0,resource:resource.sampleView},{binding:1,resource:{buffer:gpuBuffer}},
        {binding:2,resource:{buffer:this.compatUniform,size:16}}
      ]});
      const pass=encoder.beginComputePass();pass.setPipeline(pipeline);pass.setBindGroup(0,bind);
      pass.dispatchWorkgroups(Math.ceil(resource.width/8),Math.ceil(resource.height/8));pass.end();
    };
    // Encode each pass with its own uniform buffer write + submission order. To
    // avoid a later write changing an earlier dispatch, submit per plane.
    const submitColor=async(resource,base)=>{
      if(!resource||resource.samples!==1)return;
      const pipeline=await this.compatPipeline(false);
      const params=new Uint32Array([resource.width,resource.height,base,0]);
      this.device.queue.writeBuffer(this.compatUniform,0,params);
      const bind=this.device.createBindGroup({layout:pipeline.getBindGroupLayout(0),entries:[
        {binding:0,resource:resource.sampleView},{binding:1,resource:{buffer:gpuBuffer}},
        {binding:2,resource:{buffer:this.compatUniform,size:16}}
      ]});
      const e=this.device.createCommandEncoder();const p=e.beginComputePass();p.setPipeline(pipeline);p.setBindGroup(0,bind);
      p.dispatchWorkgroups(Math.ceil(resource.width/8),Math.ceil(resource.height/8));p.end();this.device.queue.submit([e.finish()]);
    };
    await submitColor(holder.native.color,0);
    await submitColor(holder.native.normal,5);
    const depth=holder.native.depth;
    if(depth&&depth.samples===1){
      const pipeline=await this.compatPipeline(true);
      const params=new Uint32Array([depth.width,depth.height,holder.compactDepth?1:0,0]);
      this.device.queue.writeBuffer(this.compatUniform,0,params);
      const bind=this.device.createBindGroup({layout:pipeline.getBindGroupLayout(0),entries:[
        {binding:0,resource:depth.sampleView},{binding:1,resource:{buffer:gpuBuffer}},
        {binding:2,resource:{buffer:this.compatUniform,size:16}}
      ]});
      const e=this.device.createCommandEncoder();const p=e.beginComputePass();p.setPipeline(pipeline);p.setBindGroup(0,bind);
      p.dispatchWorkgroups(Math.ceil(depth.width/8),Math.ceil(depth.height/8));p.end();this.device.queue.submit([e.finish()]);
    }
  }

  async copyPlaneToAtlas(holder,plane,texels,offset,{floatOutput=false}={}){
    const resource=holder?.native?.[plane];if(!resource)throw Error(`Native ${plane} render texture is unavailable`);
    const depth=plane==='depth';
    if(depth&&resource.samples!==1)throw Error('Multisampled depth render-texture sampling requires an explicit depth resolve');
    const pipeline=await this.atlasPipeline(depth);
    const params=new Uint32Array([resource.width,resource.height,offset,floatOutput?1:0]);
    this.device.queue.writeBuffer(this.atlasUniform,0,params);
    const gpuBuffer=texels?.gpuBuffer??texels?.gpu??texels;
    const bind=this.device.createBindGroup({layout:pipeline.getBindGroupLayout(0),entries:[
      {binding:0,resource:resource.sampleView},{binding:1,resource:{buffer:gpuBuffer}},{binding:2,resource:{buffer:this.atlasUniform,size:16}}
    ]});
    const encoder=this.device.createCommandEncoder({label:'OpenMW native render texture to material atlas'});
    const pass=encoder.beginComputePass();pass.setPipeline(pipeline);pass.setBindGroup(0,bind);
    pass.dispatchWorkgroups(Math.ceil(resource.width/8),Math.ceil(resource.height/8));pass.end();
    this.device.queue.submit([encoder.finish()]);this.stats.atlasCopies++;
  }
  snapshot(){return {...this.stats,postPipelines:this.postPipelines.size,atlasPipelines:this.atlasPipelines.size,compatPipelines:this.compatPipelines.size};}
  dispose(){
    this.postUniform.destroy();this.atlasUniform.destroy();this.compatUniform.destroy();
    this.postPipelines.clear();this.depthPipelines.clear();this.atlasPipelines.clear();this.compatPipelines.clear();
  }
}
