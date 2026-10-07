// SPDX-License-Identifier: GPL-3.0-or-later
// WebGPU's graphics pipeline owns triangle coverage, homogeneous clipping,
// depth/stencil tests, color masks, and attachment blending. Compute is used
// only to bridge the existing engine attachment buffers and query ABI.
import {specializeMaterialSource} from './shader-specialization.js';

import {ExactVisibilityCounter,MAX_VISIBILITY_TRIANGLES} from './visibility-counter.js';
import {nativeCameraAttachments,attachmentBridgeKey} from './attachment-policy.js';

const PARAM_FIELDS = [
  'width','height','capacity','raster_offset','boundary_offset','point_fade_offset',
  'lighting_offset','cluster_offset','fixed_offset','falloff_offset','fixed_enabled',
  'normal_enabled','normal_channels','normal_storage','color_channels','color_storage',
  'depth_bits','stencil_enabled','sample_count','draw_material',
];
const COMPARE = ['never','less','equal','less-equal','greater','not-equal','greater-equal','always'];
const STENCIL_OP = ['keep','zero','replace','increment-clamp','decrement-clamp','invert','increment-wrap','decrement-wrap'];
const BLEND_OP = ['add','subtract','reverse-subtract','min','max'];
const BLEND_FACTOR = ['zero','one','src','one-minus-src','src-alpha','one-minus-src-alpha',
  'dst-alpha','one-minus-dst-alpha','dst','one-minus-dst','src-alpha-saturated','constant',
  'one-minus-constant','constant','one-minus-constant'];
const FULLSCREEN_VERTEX = `
@vertex fn fullscreen(@builtin(vertex_index) vertex: u32) -> @builtin(position) vec4<f32> {
  let x = f32((vertex << 1u) & 2u);
  let y = f32(vertex & 2u);
  return vec4<f32>(x * 2.0 - 1.0, y * 2.0 - 1.0, 0.0, 1.0);
}`;
const BRIDGE_PARAMS = `
struct BridgeParams { width:u32, height:u32, pixels:u32, samples:u32, compact:u32, bit:u32, colorChannels:u32, normalChannels:u32 }
@group(0) @binding(1) var<uniform> bridge: BridgeParams;
`;

function nativeBuffer(buffer) {
  const result = buffer?.gpuBuffer ?? buffer?.gpu ?? buffer?.buffer ?? buffer;
  if (!result || typeof result.destroy !== 'function' || typeof result.size !== 'number')
    throw TypeError('Hardware rasterizer requires a WebGPU buffer');
  return result;
}
function nativeBinding(buffer) {
  const gpu=nativeBuffer(buffer);
  const offset=buffer?.offset??0;
  const size=buffer?.size??buffer?.byteLength??(gpu.size-offset);
  if(!Number.isSafeInteger(offset)||!Number.isSafeInteger(size)||offset<0||size<=0||offset+size>gpu.size)
    throw RangeError('Invalid native WebGPU buffer binding range');
  return {buffer:gpu,offset,size};
}
function requireFeature(device, name, reason) {
  if (!device.features.has(name)) throw Error(`Native WebGPU rendering requires ${name} for ${reason}`);
}
function nextCapacity(size) {
  let result=256;
  while(result<size)result*=2;
  return result;
}
function normalizedChannels(channels) { return (1 << channels) - 1; }
function attachmentFormat(device, storage, label) {
  if(storage===0)return 'rgba8unorm';
  if(storage===1)return 'rgba16float';
  if(storage===2)return 'rgba32float';
  if(storage===3)return 'rgba8unorm-srgb';
  if(storage===4) { requireFeature(device,'texture-formats-tier1',`${label} with 16-bit normalized channels`);return 'rgba16unorm'; }
  if(storage===5) { requireFeature(device,'texture-formats-tier1',`${label} with signed normalized channels`);return 'rgba8snorm'; }
  if(storage===6) { requireFeature(device,'texture-formats-tier1',`${label} with 16-bit signed normalized channels`);return 'rgba16snorm'; }
  throw RangeError(`Unsupported WebGPU ${label} storage ${storage}`);
}
function depthFormat(device, bits, stencil) {
  if(stencil && bits===0) { requireFeature(device,'depth32float-stencil8','a floating-point depth/stencil attachment');return 'depth32float-stencil8'; }
  if(stencil) {
    if(bits!==24)throw RangeError('WebGPU cannot combine a 16-bit depth attachment with stencil');
    return 'depth24plus-stencil8';
  }
  if(bits===16)return 'depth16unorm';
  if(bits===24)return 'depth24plus';
  if(bits===0)return 'depth32float';
  throw RangeError(`Unsupported WebGPU depth precision ${bits}`);
}

/** Keep submission order. Ribbon material selection remains GPU-side: draw
 * both possible states and let the vertex shader reject the unused material. */
export function buildDrawRuns(scene, triangleCount) {
  if(!(scene.triangles instanceof Uint32Array)||scene.triangles.length<triangleCount*4)
    throw RangeError('Missing CPU triangle material metadata');
  const ranges=scene.ribbonRanges??new Uint32Array();
  if(!(ranges instanceof Uint32Array)||ranges.length%13)throw RangeError('Invalid ribbon material ranges');
  const ribbons=[];
  for(let i=0;i<ranges.length;i+=13) {
    const count=(ranges[i+1]-1)*2,first=ranges[i+3];
    if(count<2||first+count>triangleCount)throw RangeError('Invalid ribbon triangle interval');
    ribbons.push({first,count,materials:[...new Set([ranges[i+6],ranges[i+7]])]});
  }
  ribbons.sort((a,b)=>a.first-b.first);
  for(let i=1;i<ribbons.length;i++)if(ribbons[i].first<ribbons[i-1].first+ribbons[i-1].count)
    throw RangeError('Overlapping ribbon draw intervals');
  const result=[];
  let cursor=0,ribbon=0;
  while(cursor<triangleCount) {
    const range=ribbons[ribbon];
    if(range?.first===cursor) {
      for(const material of range.materials)result.push({first:cursor,count:range.count,material});
      cursor+=range.count;ribbon++;continue;
    }
    const material=scene.triangles[cursor*4+3],first=cursor;
    const stop=range?.first??triangleCount;
    do{cursor++;}while(cursor<stop&&scene.triangles[cursor*4+3]===material);
    result.push({first,count:cursor-first,material});
  }
  return result;
}

function intersectScissor(materials, m, flags, width, height, viewport) {
  let x=materials[m+5],y=materials[m+6],w=materials[m+7],h=materials[m+8];
  if(flags&16777216) { x=x|0; y=height-((y|0)+h); }
  const [vx,vy,vw,vh]=(flags&4194304)?[0,0,width,height]:(viewport??[0,0,width,height]);
  const left=Math.max(0,x,vx),top=Math.max(0,y,height-vy-vh);
  const right=Math.min(width,x+w,vx+vw),bottom=Math.min(height,y+h,height-vy);
  return {x:left,y:top,width:Math.max(0,right-left),height:Math.max(0,bottom-top)};
}
function blendComponent(factors, equation, alpha) {
  if(equation>4)throw RangeError('Unsupported native blend equation');
  let source=factors&15,destination=(factors>>>4)&15;
  if(source>14||destination>14)throw RangeError('Unsupported native blend factor');
  if(alpha) { if(source===10)source=1;if(destination===10)destination=1; }
  if(equation>=3) {source=1;destination=1;}
  return {operation:BLEND_OP[equation],srcFactor:BLEND_FACTOR[source],dstFactor:BLEND_FACTOR[destination]};
}
function materialBlend(materials,m,flags,control) {
  if(!(flags&128))return {
    color:{operation:'add',srcFactor:'src-alpha',dstFactor:'one-minus-src-alpha'},
    alpha:{operation:'add',srcFactor:'one',dstFactor:'one-minus-src-alpha'},
  };
  return {color:blendComponent(materials[m+10],(control>>>8)&7,false),
    alpha:blendComponent(materials[m+10]>>>8,(control>>>11)&7,true)};
}
function stencilFace(params,base) {
  const func=params[base],fail=params[base+4],depthFail=params[base+5],pass=params[base+6];
  if(!COMPARE[func]||!STENCIL_OP[fail]||!STENCIL_OP[depthFail]||!STENCIL_OP[pass])
    throw RangeError('Unsupported native stencil state');
  return {compare:COMPARE[func],failOp:STENCIL_OP[fail],depthFailOp:STENCIL_OP[depthFail],passOp:STENCIL_OP[pass]};
}

function seedSource(config) {
  const color=config.compact?'':'@location(0) color: vec4<f32>,';
  const normal=config.normal?'@location(1) normal: vec4<f32>,':'';
  const writeColor=config.compact?'':`for(var k=0u;k<4u;k++){out.color[k]=select(select(0.0,1.0,k==3u),source[base+k],k<bridge.colorChannels);}`;
  const writeNormal=config.normal?`for(var k=0u;k<4u;k++){out.normal[k]=select(select(0.0,1.0,k==3u),source[base+5u+k],k<bridge.normalChannels);}`:'';
  return `${FULLSCREEN_VERTEX}\n${BRIDGE_PARAMS}
@group(0) @binding(0) var<storage,read> source:array<f32>;
struct SeedOutput { ${color} ${normal} @builtin(frag_depth) depth:f32 }
@fragment fn seed(@builtin(position) position:vec4<f32>, @builtin(sample_index) sample:u32) -> SeedOutput {
  let pixel=u32(position.y)*bridge.width+u32(position.x);
  let base=sample*bridge.pixels*10u+pixel*9u;
  var out:SeedOutput;
  ${writeColor}
  ${writeNormal}
  out.depth=clamp(source[${config.compact?'pixel':'base+4u'}],0.0,1.0);
  return out;
}
@fragment fn seed_stencil(@builtin(position) position:vec4<f32>, @builtin(sample_index) sample:u32) {
  let pixel=u32(position.y)*bridge.width+u32(position.x);
  let value=u32(source[sample*bridge.pixels*10u+bridge.pixels*9u+pixel]);
  if((value & bridge.bit)==0u) { discard; }
}`;
}
function stencilExtractSource() {
  return `${FULLSCREEN_VERTEX}\n${BRIDGE_PARAMS}
@fragment fn extract(@builtin(sample_index) sample:u32) -> @location(0) vec4<f32> {
  // Native stencil comparison filters covered samples before additive blending.
  return vec4<f32>(f32(bridge.bit),0.0,0.0,0.0);
}`;
}
function exportSource(config) {
  const depthType=config.samples===1?'texture_depth_2d':'texture_depth_multisampled_2d';
  const colorType=config.samples===1?'texture_2d<f32>':'texture_multisampled_2d<f32>';
  const sample=config.samples===1?'0':'i32(index.z)';
  return `${BRIDGE_PARAMS}
@group(0) @binding(0) var<storage,read_write> destination:array<f32>;
@group(0) @binding(2) var depth:${depthType};
${config.compact?'':`@group(0) @binding(3) var color:${colorType};`}
${config.normal?`@group(0) @binding(4) var normal:${colorType};`:''}
${config.stencil?`@group(0) @binding(5) var stencil:${colorType};`:''}
@compute @workgroup_size(8,8,1) fn export_attachments(@builtin(global_invocation_id) index:vec3<u32>) {
  if(index.x>=bridge.width || index.y>=bridge.height || index.z>=bridge.samples){return;}
  let pixel=index.y*bridge.width+index.x;
  let xy=vec2<i32>(index.xy);
  let base=index.z*bridge.pixels*10u+pixel*9u;
  let z=textureLoad(depth,xy,${sample});
  ${config.compact?'destination[pixel]=z;':`let rgba=textureLoad(color,xy,${sample});
  for(var k=0u;k<4u;k++){destination[base+k]=select(select(0.0,1.0,k==3u),rgba[k],k<bridge.colorChannels);}
  destination[base+4u]=z;`}
  ${config.normal?`let encoded_normal=textureLoad(normal,xy,${sample});
  for(var k=0u;k<4u;k++){destination[base+5u+k]=select(select(0.0,1.0,k==3u),encoded_normal[k],k<bridge.normalChannels);}`:''}
  ${config.stencil?`destination[index.z*bridge.pixels*10u+bridge.pixels*9u+pixel]=textureLoad(stencil,xy,${sample}).r;`:''}
}`;
}
export class HardwareRasterizer {
  static async create(runtime, options={}) {
    const renderer=new HardwareRasterizer(runtime);
    try {
      let source=options.source??runtime.materialShaderSource;
      if(source==null) {
        const response=await (options.fetch??globalThis.fetch)(new URL('./shaders/material.wgsl',import.meta.url));
        if(!response.ok)throw Error(`Unable to load the native material shader (${response.status})`);
        source=await response.text();
      }
      renderer.materialSource=source;
      // Do not compile the complete material library here. It contains every
      // render family and makes Dawn/ANGLE spend seconds compiling code a given
      // pass cannot call. Small family modules are created lazily below.
      renderer.materialModule=null;
      const stages=GPUShaderStage.VERTEX|GPUShaderStage.FRAGMENT;
      renderer.materialLayout=renderer.device.createBindGroupLayout({label:'OpenMW native material bindings',entries:[
        ...[0,1,2,3,4].map(binding=>({binding,visibility:stages,buffer:{type:'read-only-storage'}})),
        {binding:5,visibility:stages,buffer:{type:'uniform',hasDynamicOffset:true,minBindingSize:112}},
      ]});
      renderer.pipelineLayout=renderer.device.createPipelineLayout({bindGroupLayouts:[renderer.materialLayout]});
      return renderer;
    } catch(error) { renderer.dispose();throw error; }
  }
  constructor(runtime) {
    this.runtime=runtime;this.device=runtime.device;
    if(!this.device)throw TypeError('HardwareRasterizer requires a WebGPU runtime');
    this.pipelines=new Map();this.shaderModules=new Map();this.bridgePipelines=new Map();this.targets=new Map();this.buffers=new Map();
    this.uniformStride=Math.max(256,this.device.limits.minUniformBufferOffsetAlignment);
    this.disposed=false;this.busy=false;
    this.materialUniformData=new Uint32Array();
    this.performanceStats={nativeCameraPasses:0,compatibilityCameraPasses:0,mergedNativeClears:0,
      materialStateBuilds:0,materialStateReuses:0,uniformHostAllocations:0,uniformUploadBytes:0};
    this.lastPass=null;
  }
  buffer(name,size,usage) {
    if(!Number.isSafeInteger(size)||size<0||size%4||size>this.device.limits.maxBufferSize)
      throw RangeError(`Native ${name} allocation exceeds the WebGPU buffer limit`);
    const capacity=Math.min(nextCapacity(size),this.device.limits.maxBufferSize);
    const old=this.buffers.get(name);
    if(old&&old.size>=size)return old;
    const buffer=this.device.createBuffer({label:`OpenMW native ${name}`,size:capacity,usage});
    if(old)old.destroy();
    this.buffers.set(name,buffer);return buffer;
  }
  config(params) {
    const samples=params.sample_count??1;
    if(samples!==1&&samples!==4)throw RangeError(`Native WebGPU rendering supports 1 or 4 samples; received ${samples}`);
    const compact=params.color_channels===0,normal=!compact&&Boolean(params.normal_enabled),stencil=Boolean(params.stencil_enabled);
    if(compact&&(samples!==1||stencil))throw RangeError('Compact depth targets require one sample without stencil');
    const colorFormat=compact?null:attachmentFormat(this.device,params.color_storage,'color attachment');
    const normalFormat=normal?attachmentFormat(this.device,params.normal_storage,'normal attachment'):null;
    if(samples>1&&(colorFormat==='rgba32float'||normalFormat==='rgba32float'))
      throw RangeError('WebGPU does not support multisampled rgba32float attachments');
    const config={width:params.width,height:params.height,samples,compact,normal,stencil,colorFormat,normalFormat,
      depthFormat:depthFormat(this.device,params.depth_bits,stencil)};
    if(!Number.isInteger(config.width)||!Number.isInteger(config.height)||config.width<1||config.height<1
      ||config.width>this.device.limits.maxTextureDimension2D||config.height>this.device.limits.maxTextureDimension2D)
      throw RangeError('Native render target dimensions exceed device limits');
    config.key=JSON.stringify(config);return config;
  }
  textures(config) {
    let target=this.targets.get(config.key);
    if(target) {this.targets.delete(config.key);this.targets.set(config.key,target);return target;}
    const make=(label,format)=>this.device.createTexture({label:`OpenMW native ${label}`,size:[config.width,config.height],
      sampleCount:config.samples,format,usage:GPUTextureUsage.RENDER_ATTACHMENT|GPUTextureUsage.TEXTURE_BINDING});
    target={depth:make('depth',config.depthFormat)};
    if(!config.compact)target.color=make('color',config.colorFormat);
    if(config.normal)target.normal=make('normal',config.normalFormat);
    if(config.stencil)target.stencil=make('stencil export','rgba16float');
    target.depthView=target.depth.createView();
    target.depthSampleView=target.depth.createView({aspect:'depth-only'});
    if(target.color)target.colorView=target.color.createView();
    if(target.normal)target.normalView=target.normal.createView();
    if(target.stencil)target.stencilView=target.stencil.createView();
    this.targets.set(config.key,target);
    // Every pass imports and exports its own buffer, so a small texture pool is
    // sufficient even when the game owns many logical framebuffer identities.
    if(this.targets.size>8) {
      const [key,retired]=this.targets.entries().next().value;
      this.targets.delete(key);this.destroyTextures(retired);
    }
    return target;
  }
  destroyTextures(target) { for(const key of ['color','normal','depth','stencil'])target[key]?.destroy(); }
  async bridge(config) {
    const key=attachmentBridgeKey(config);
    let pending=this.bridgePipelines.get(key);
    if(pending)return pending;
    pending=this.createBridge(config);
    this.bridgePipelines.set(key,pending);
    try{return await pending;}catch(error){if(this.bridgePipelines.get(key)===pending)this.bridgePipelines.delete(key);throw error;}
  }
  async createBridge(config) {
    const device=this.device;
    const module=device.createShaderModule({label:'OpenMW native attachment import',code:seedSource(config)});
    const targets=config.compact?[]:[{format:config.colorFormat},...(config.normal?[{format:config.normalFormat}]:[])];
    const seed=await device.createRenderPipelineAsync({label:'OpenMW native attachment import',layout:'auto',
      vertex:{module,entryPoint:'fullscreen'},fragment:{module,entryPoint:'seed',targets},
      primitive:{topology:'triangle-list'},multisample:{count:config.samples},
      depthStencil:{format:config.depthFormat,depthWriteEnabled:true,depthCompare:'always'}});
    const exportModule=device.createShaderModule({label:'OpenMW native attachment export',code:exportSource(config)});
    const exportPipeline=await device.createComputePipelineAsync({label:'OpenMW native attachment export',layout:'auto',
      compute:{module:exportModule,entryPoint:'export_attachments'}});
    const result={seed,export:exportPipeline,seedStencil:[],extractStencil:[]};
    if(config.stencil) {
      const extractModule=device.createShaderModule({label:'OpenMW native stencil export',code:stencilExtractSource()});
      for(let bit=1;bit<=128;bit*=2) {
        result.seedStencil.push(await device.createRenderPipelineAsync({label:`OpenMW import stencil bit ${bit}`,layout:'auto',
          vertex:{module,entryPoint:'fullscreen'},fragment:{module,entryPoint:'seed_stencil',targets:[]},
          primitive:{topology:'triangle-list'},multisample:{count:config.samples},
          depthStencil:{format:config.depthFormat,depthWriteEnabled:false,depthCompare:'always',
            stencilFront:{compare:'always',passOp:'replace'},stencilBack:{compare:'always',passOp:'replace'},
            stencilReadMask:255,stencilWriteMask:bit}}));
        result.extractStencil.push(await device.createRenderPipelineAsync({label:`OpenMW export stencil bit ${bit}`,layout:'auto',
          vertex:{module:extractModule,entryPoint:'fullscreen'},fragment:{module:extractModule,entryPoint:'extract',
            targets:[{format:'rgba16float',writeMask:GPUColorWrite.RED,blend:{
              color:{operation:'add',srcFactor:'one',dstFactor:'one'},alpha:{operation:'add',srcFactor:'one',dstFactor:'one'}}}]},
          primitive:{topology:'triangle-list'},multisample:{count:config.samples},
          depthStencil:{format:config.depthFormat,depthWriteEnabled:false,depthCompare:'always',
            stencilFront:{compare:'equal'},stencilBack:{compare:'equal'},stencilReadMask:bit,stencilWriteMask:0}}));
      }
    }
    return result;
  }
  state(scene, material, config, params, pass, face=null) {
    const materials=scene.materials,m=material*12,r=material*50,rp=scene.rasterParams;
    if(!Number.isInteger(material)||material<0||m+12>materials.length||r+50>rp.length)
      throw RangeError('Invalid material in native draw');
    const flags=materials[m+3],control=materials[m+9],extended=(flags&128)!==0;
    const query=(flags&1024)!==0&&scene.texels[materials[m]+8]===5;
    if(((control>>>27)&15)!==0)throw Error('Native WebGPU polygon line/point modes are not implemented');
    if(!query&&extended&&(control&33554432))throw Error('WebGPU does not expose fixed-function framebuffer logic operations');
    if(config.samples>1&&rp[r+27]===0)throw Error('Disabling multisampling inside a multisampled WebGPU render target is not supported');
    const clampDepth=(flags&262144)!==0;
    if(clampDepth)requireFeature(this.device,'depth-clip-control','GL depth clamping');
    let cull=extended?(control>>>14)&3:0;
    if(face==='front') {if(cull===1||cull===3)return null;cull=2;}
    if(face==='back') {if(cull===2||cull===3)return null;cull=1;}
    if(cull===3)return null;
    const scissor=intersectScissor(materials,m,flags,config.width,config.height,pass.viewport);
    if(scissor.width===0||scissor.height===0)return null;
    const features=(flags&2048)?(scene.texels[materials[m]+4]&0x7fff7fff)>>>0:0;
    const layers=(flags&2048)?scene.texels[materials[m]+72]:0;
    const mode=(flags&2048)?scene.texels[materials[m]+5]:0;
    const skyPass=(flags&1024)?scene.texels[materials[m]+8]:0;
    const shaderParams={flags,features,layers,mode,skyPass,
      hasShadows:(flags&2048)&&scene.texels[materials[m]+324]?1:0};
    const writeNormal=config.normal&&(flags&2048)!==0&&(features&131072)!==0&&(features&4194304)===0;
    const colorMask=query?0:normalizedChannels(params.color_channels)&(extended?(~(control>>>17))&15:15);
    const normalMask=query||!writeNormal?0:normalizedChannels(params.normal_channels)&(extended?(~rp[r+22])&15:15);
    const colorBlend=!query&&(flags&2)!==0,normalBlend=!query&&extended&&(control&67108864)!==0;
    const blend=colorBlend||normalBlend?materialBlend(materials,m,flags,control):undefined;
    if((colorBlend&&config.colorFormat==='rgba32float')||(normalBlend&&config.normalFormat==='rgba32float'))
      requireFeature(this.device,'float32-blendable','blending into a 32-bit floating-point color attachment');
    const blendConstant={r:Math.max(0,Math.min(1,rp[r+4])),g:Math.max(0,Math.min(1,rp[r+5])),
      b:Math.max(0,Math.min(1,rp[r+6])),a:Math.max(0,Math.min(1,rp[r+7]))};
    if(extended&&(colorBlend||normalBlend)&&((control>>>8)&7)<3) {
      const factors=[materials[m+10]&15,(materials[m+10]>>>4)&15];
      if(factors.some(value=>value===13||value===14)) {
        if(factors.some(value=>value===11||value===12))throw Error('WebGPU cannot use constant RGB and constant alpha as separate RGB blend factors in one draw');
        blendConstant.r=blendConstant.g=blendConstant.b=blendConstant.a;
      }
    }
    const depthCompare=(flags&4)?(extended?COMPARE[control&15]:((flags&64)?'less-equal':'less')):'always';
    if(!depthCompare)throw RangeError('Unsupported native depth comparison');
    const depthStencil={format:config.depthFormat,depthWriteEnabled:!query&&(flags&8)!==0,depthCompare};
    let stencilReference=0,splitFaces=false;
    if(config.stencil&&(flags&8192)) {
      const frontBase=r+8,backBase=(flags&4194304)?frontBase:r+15;
      const selected=face==='back'?backBase:frontBase;
      depthStencil.stencilFront=stencilFace(rp,frontBase);
      depthStencil.stencilBack=stencilFace(rp,backBase);
      depthStencil.stencilReadMask=rp[selected+2]&255;
      depthStencil.stencilWriteMask=rp[selected+3]&255;
      stencilReference=Math.max(0,Math.min(255,rp[selected+1]))|0;
      splitFaces=face==null&&[1,2,3].some(field=>rp[frontBase+field]!==rp[backBase+field]);
    }
    // Occlusion query values in WebGPU may be only boolean. Count samples with
    // additive native blending, then reduce the attachment into the engine ABI.
    const targets=query?[{format:'rgba16float',writeMask:GPUColorWrite.RED,blend:{
      color:{operation:'add',srcFactor:'one',dstFactor:'one'},alpha:{operation:'add',srcFactor:'one',dstFactor:'one'}}}]
      :config.compact?[]:[{format:config.colorFormat,writeMask:colorMask,...(colorBlend?{blend}:{})},
      ...(config.normal?[{format:config.normalFormat,writeMask:normalMask,...(normalBlend?{blend}:{})}]:[])];
    const entryPoint=query?'fragment_query':config.compact?'fragment_depth':config.normal?'fragment_normal':'fragment_color';
    const descriptor={layout:this.pipelineLayout,vertex:{entryPoint:'vertex_main'},
      fragment:{entryPoint,targets},
      primitive:{topology:'triangle-list',frontFace:(control&65536)?'cw':'ccw',cullMode:cull===1?'front':cull===2?'back':'none',
        ...(clampDepth?{unclippedDepth:true}:{})},depthStencil,multisample:{count:config.samples}};
    // Shader feature bits are dynamic uniforms, not pipeline specialization.
    // Only real fixed-function WebGPU state creates a pipeline variant.
    const key=JSON.stringify({targets,entryPoint,depthStencil,primitive:descriptor.primitive,samples:config.samples});
    return {descriptor,key,shaderParams,query,scissor,blendConstant,stencilReference,splitFaces};
  }
  async materialFamily(entryPoint) {
    let pending=this.shaderModules.get(entryPoint);
    if(!pending) {
      pending=(async()=>{
        // Prune unreachable render families, but keep material feature decisions
        // dynamic through RasterParams uniforms. This yields a handful of stable
        // modules instead of one giant module or one module per material.
        const code=specializeMaterialSource(this.materialSource,{},entryPoint);
        const module=this.device.createShaderModule({label:`OpenMW material family ${entryPoint}`,code});
        const info=await module.getCompilationInfo();
        const errors=info.messages.filter(message=>message.type==='error');
        if(errors.length)throw Error(errors.map(message=>
          `Material family ${entryPoint}:${message.lineNum}:${message.linePos} ${message.message}`).join('\n'));
        return module;
      })();
      this.shaderModules.set(entryPoint,pending);
    }
    try{return await pending;}catch(error){this.shaderModules.delete(entryPoint);throw error;}
  }
  async pipeline(state) {
    let pending=this.pipelines.get(state.key);
    if(!pending) {
      pending=(async()=>{
        const entryPoint=state.descriptor.fragment.entryPoint;
        const module=await this.materialFamily(entryPoint);
        return this.device.createRenderPipelineAsync({label:`OpenMW native material ${entryPoint}`,
          ...state.descriptor,
          vertex:{...state.descriptor.vertex,module},
          fragment:{...state.descriptor.fragment,module}});
      })();
      this.pipelines.set(state.key,pending);
    }
    try{return await pending;}catch(error){this.pipelines.delete(state.key);throw error;}
  }
  async prewarm(scene, params, pass={}, triangleCount=scene.triangles.length/4) {
    if(this.disposed)return;
    const config=this.config(params),states=new Map(),unique=new Map();
    const getState=(material,face=null)=>{
      const local=material*3+(face==='front'?1:face==='back'?2:0);
      if(states.has(local))return states.get(local);
      const state=this.state(scene,material,config,params,pass,face);
      states.set(local,state);return state;
    };
    for(const run of buildDrawRuns(scene,triangleCount)) {
      const state=getState(run.material);
      if(!state)continue;
      if(state.splitFaces) {
        for(const face of ['front','back']) {
          const split=getState(run.material,face);
          if(split&&!unique.has(split.key))unique.set(split.key,split);
        }
      } else if(!unique.has(state.key))unique.set(state.key,state);
    }
    const cold=[...unique.values()].filter(state=>!this.pipelines.has(state.key));
    if(!cold.length)return;
    this.performanceStats.prewarmRequests=(this.performanceStats.prewarmRequests??0)+cold.length;
    let cursor=0;
    await Promise.all(Array.from({length:Math.min(6,cold.length)},async()=>{
      for(;;){
        const index=cursor++;
        if(index>=cold.length)return;
        await this.pipeline(cold[index]);
      }
    }));
  }
  attachments(target, config, loadOp='load', clear={}) {
    const clearColor=clear.color??[0,0,0,0],clearDepth=clear.depth??1,clearStencil=clear.stencil??0;
    const colorView=target.color?.renderView??target.colorView;
    const colorResolve=config.samples>1?(target.color?.sampleView??null):null;
    const normalView=target.normal?.renderView??target.normalView;
    const normalResolve=config.samples>1?(target.normal?.sampleView??null):null;
    const depthView=target.depth?.renderView??target.depthView;
    const colorAttachments=config.compact?[]:[{view:colorView,loadOp,storeOp:'store',clearValue:clearColor,
      ...(colorResolve?{resolveTarget:colorResolve}:{})},
      ...(config.normal?[{view:normalView,loadOp,storeOp:'store',clearValue:clearColor,
        ...(normalResolve?{resolveTarget:normalResolve}:{})}]:[])];
    const depthStencilAttachment={view:depthView,depthLoadOp:loadOp,depthStoreOp:'store',depthClearValue:clearDepth,
      ...(config.stencil?{stencilLoadOp:loadOp,stencilStoreOp:'store',stencilClearValue:clearStencil}:{})};
    return {colorAttachments,depthStencilAttachment};
  }
  async render(buffers, params, {scene,pass={},triangleCount}) {
    if(this.disposed)throw Error('HardwareRasterizer has been disposed');
    if(this.busy)throw Error('HardwareRasterizer cannot render overlapping camera passes');
    this.runtime.assertAlive?.();
    this.busy=true;
    const passStart=performance.now();
    try {
    this.runtime.flush?.();
    const config=this.config(params),device=this.device;
    const native={};for(const [key,value] of Object.entries(buffers))if(value)native[key]=nativeBuffer(value);
    const materialCount=scene.materials.length/12;
    if(!Number.isInteger(materialCount)||!(scene.rasterParams instanceof Float32Array))throw RangeError('Invalid native material metadata');
    const runs=[],states=new Map();
    // A material may occur in many ordered runs, especially with split stencil
    // faces. Cache only within this camera: next frame's changed state is fresh.
    const getState=(material,face=null)=>{
      const key=material*3+(face==='front'?1:face==='back'?2:0);
      if(states.has(key)){this.performanceStats.materialStateReuses++;return states.get(key);}
      const state=this.state(scene,material,config,params,pass,face);
      states.set(key,state);this.performanceStats.materialStateBuilds++;return state;
    };
    for(const run of buildDrawRuns(scene,triangleCount)) {
      const state=getState(run.material);
      if(!state)continue;
      if(state.splitFaces) {
        // WebGPU has one stencil reference/read/write mask for both faces.
        // Splitting each triangle preserves order even for blending/stencil.
        for(let t=run.first;t<run.first+run.count;t++)for(const face of ['front','back']) {
          const split=getState(run.material,face);
          if(split)runs.push({first:t,count:1,material:run.material,state:split});
        }
      } else runs.push({...run,state});
    }
    const stateBuildMs=performance.now()-passStart;
    const pipelineStart=performance.now();
    const queryRuns=runs.filter(run=>run.state.query);
    if(queryRuns.length&&!native.counts)throw TypeError('Occlusion queries require the legacy query counter buffer');
    if(queryRuns.length&&!this.visibilityCounter) {
      const counter=await ExactVisibilityCounter.create(this.runtime);
      if(this.disposed) {counter.dispose();throw Error('HardwareRasterizer was disposed during visibility pipeline compilation');}
      this.visibilityCounter=counter;
    }
    const directTarget=pass.nativeTarget??null;
    if(directTarget?.config) {
      const expected=JSON.stringify([config.width,config.height,config.samples,config.compact,config.normal,config.stencil,
        config.colorFormat,config.normalFormat,config.depthFormat]);
      if(directTarget.config.key!==expected)throw Error('Native logical render target does not match camera configuration');
    }
    const bridge=directTarget?null:await this.bridge(config);
    // Compile unique material pipelines concurrently. Serial async pipeline
    // creation was a major first-world hitch because Morrowind can introduce
    // dozens of shader/state variants in the first visible cell.
    const uniqueStates=new Map();
    for(const run of runs)if(!uniqueStates.has(run.state.key))uniqueStates.set(run.state.key,run.state);
    const entries=[...uniqueStates.entries()],compiled=new Map();
    let compileCursor=0;
    const workers=Math.min(8,entries.length);
    await Promise.all(Array.from({length:workers},async()=>{
      for(;;){
        const index=compileCursor++;
        if(index>=entries.length)return;
        const [key,state]=entries[index];
        compiled.set(key,await this.pipeline(state));
      }
    }));
    for(const run of runs)run.pipeline=compiled.get(run.state.key);
    const pipelineWaitMs=performance.now()-pipelineStart;
    if(this.disposed)throw Error('HardwareRasterizer was disposed during pipeline compilation');
    this.runtime.assertAlive?.();
    const target=directTarget??this.textures(config);
    const visibilityTarget=queryRuns.length?this.visibilityCounter.target(config):null;
    this.runtime.flush?.();
    // Per-camera params are identical for repeated runs of the same material.
    // Keep their draw order, but share one uniform slot (also for query reduction).
    const uniformMaterials=new Map(),uniformStates=new Map();
    for(const run of runs) {
      let index=uniformMaterials.get(run.material);
      if(index===undefined){
        index=uniformMaterials.size;uniformMaterials.set(run.material,index);uniformStates.set(run.material,run.state);
      }
      run.uniformIndex=index;
    }
    const uniformBytes=Math.max(1,uniformMaterials.size)*this.uniformStride;
    const uniforms=this.buffer('material uniforms',uniformBytes,GPUBufferUsage.UNIFORM|GPUBufferUsage.COPY_DST);
    if(this.materialUniformData.byteLength<uniformBytes) {
      this.materialUniformData=new Uint32Array(uniforms.size/4);
      this.performanceStats.uniformHostAllocations++;
    }
    const uniformData=this.materialUniformData;
    for(const [material,index] of uniformMaterials) {
      const base=index*this.uniformStride/4,state=uniformStates.get(material);
      for(let field=0;field<PARAM_FIELDS.length;field++)
        uniformData[base+field]=field===19?material:field===18?config.samples:(params[PARAM_FIELDS[field]]??0);
      const shader=state.shaderParams;
      uniformData[base+20]=shader.flags;
      uniformData[base+21]=shader.features;
      uniformData[base+22]=shader.layers;
      uniformData[base+23]=shader.mode;
      uniformData[base+24]=shader.skyPass;
      uniformData[base+25]=shader.hasShadows;
      uniformData[base+26]=0;uniformData[base+27]=0;
    }
    device.queue.writeBuffer(uniforms,0,uniformData.buffer,0,uniformBytes);
    this.performanceStats.uniformUploadBytes+=uniformBytes;
    const bindGroup=device.createBindGroup({label:'OpenMW native material draw buffers',layout:this.materialLayout,entries:[
      ...['vertices','triangles','materials','texels','attributes'].map((key,binding)=>({binding,resource:nativeBinding(buffers[key])})),
      {binding:5,resource:{buffer:uniforms,size:112}},
    ]});
    let bridgeUniform=null,bridgeBindings=null;
    if(bridge) {
      bridgeUniform=this.buffer('attachment uniforms',this.uniformStride*9,GPUBufferUsage.UNIFORM|GPUBufferUsage.COPY_DST);
      const bridgeData=new Uint32Array(this.uniformStride*9/4);
      for(let i=0;i<9;i++)bridgeData.set([config.width,config.height,config.width*config.height,config.samples,
        config.compact?1:0,i===0?0:1<<(i-1),params.color_channels,params.normal_channels],i*this.uniformStride/4);
      device.queue.writeBuffer(bridgeUniform,0,bridgeData);
      bridgeBindings=(pipeline,index=0,source=true)=>device.createBindGroup({layout:pipeline.getBindGroupLayout(0),entries:[
        ...(source?[{binding:0,resource:nativeBinding(buffers.target)}]:[]),
        {binding:1,resource:{buffer:bridgeUniform,offset:index*this.uniformStride,size:32}},
      ]});
    }
    const encoder=device.createCommandEncoder({label:'OpenMW WebGPU hardware rendering'});
    let clearPending=Boolean(directTarget&&(pass.clearMask??16640));
    const cameraAttachments=()=>{
      const attachments=this.attachments(target,config);
      if(!clearPending)return attachments;
      clearPending=false;
      return nativeCameraAttachments(attachments,config,params,pass);
    };
    // Merge a plane clear with the first real draw pass, avoiding an extra
    // clear/store/load cycle. Queries/empty cameras need an explicit clear first.
    if(clearPending&&(!runs.length||runs[0].state.query)) {
      const clearPass=encoder.beginRenderPass({label:'OpenMW native attachment clear',...cameraAttachments()});
      clearPass.end();
    }
    if(!directTarget) {
      // Compatibility fallback: import the legacy attachment buffer only for
      // passes that cannot yet remain native.
      const seed=encoder.beginRenderPass({label:'OpenMW import engine attachments',...this.attachments(target,config,'clear')});
      seed.setPipeline(bridge.seed);seed.setBindGroup(0,bridgeBindings(bridge.seed));seed.draw(3);seed.end();
      if(config.stencil)for(let i=0;i<8;i++) {
        const depthView=target.depth?.renderView??target.depthView;
        const stencil=encoder.beginRenderPass({label:'OpenMW import stencil',colorAttachments:[],
          depthStencilAttachment:{view:depthView,depthReadOnly:true,stencilLoadOp:'load',stencilStoreOp:'store'}});
        stencil.setPipeline(bridge.seedStencil[i]);stencil.setBindGroup(0,bridgeBindings(bridge.seedStencil[i],i+1));
        stencil.setStencilReference(255);stencil.draw(3);stencil.end();
      }
    }
    const queryOffset=Math.ceil(config.width/16)*Math.ceil(config.height/16)+1;
    if(native.counts&&materialCount)encoder.clearBuffer(native.counts,queryOffset*4,materialCount*4);
    let render=null,drawCalls=0;
    const draw=(pass,run,index,first,count)=>{
      const state=run.state;
      pass.setPipeline(run.pipeline);pass.setBindGroup(0,bindGroup,[run.uniformIndex*this.uniformStride]);
      pass.setScissorRect(state.scissor.x,state.scissor.y,state.scissor.width,state.scissor.height);
      pass.setBlendConstant(state.blendConstant);pass.setStencilReference(state.stencilReference);
      pass.draw(count*3,1,first*3,0);drawCalls++;
    };
    for(let index=0;index<runs.length;index++) {
      const run=runs[index];
      if(run.state.query) {
        render?.end();render=null;
        // A binary16 component stores each integer through 2048 exactly.
        // Limiting a freshly cleared counter to 1024 triangles keeps every
        // per-sample sum exact, including overlapping query geometry.
        for(let first=run.first;first<run.first+run.count;first+=MAX_VISIBILITY_TRIANGLES) {
          const count=Math.min(MAX_VISIBILITY_TRIANGLES,run.first+run.count-first);
          const query=encoder.beginRenderPass({label:'OpenMW exact native visibility coverage',
            colorAttachments:[{view:visibilityTarget.view,loadOp:'clear',storeOp:'store',clearValue:[0,0,0,0]}],
            depthStencilAttachment:this.attachments(target,config).depthStencilAttachment});
          draw(query,run,index,first,count);query.end();
          this.visibilityCounter.encode(encoder,visibilityTarget,{counts:native.counts,uniforms,uniformOffset:run.uniformIndex*this.uniformStride});
        }
      } else {
        if(!render) {
          if(clearPending)this.performanceStats.mergedNativeClears++;
          render=encoder.beginRenderPass({label:'OpenMW native material rasterization',...cameraAttachments()});
        }
        draw(render,run,index,run.first,run.count);
      }
    }
    render?.end();
    if(!directTarget) {
      if(config.stencil)for(let i=0;i<8;i++) {
        const stencil=encoder.beginRenderPass({label:'OpenMW export stencil',
          colorAttachments:[{view:target.stencilView,loadOp:i===0?'clear':'load',storeOp:'store',clearValue:[0,0,0,0]}],
          depthStencilAttachment:{view:target.depthView,depthReadOnly:true,stencilReadOnly:true}});
        stencil.setPipeline(bridge.extractStencil[i]);stencil.setBindGroup(0,bridgeBindings(bridge.extractStencil[i],i+1,false));
        stencil.setStencilReference(255);stencil.draw(3);stencil.end();
      }
      const exportBindings=device.createBindGroup({layout:bridge.export.getBindGroupLayout(0),entries:[
        {binding:0,resource:nativeBinding(buffers.target)},{binding:1,resource:{buffer:bridgeUniform,size:32}},
        {binding:2,resource:target.depthSampleView},
        ...(config.compact?[]:[{binding:3,resource:target.colorView}]),
        ...(config.normal?[{binding:4,resource:target.normalView}]:[]),
        ...(config.stencil?[{binding:5,resource:target.stencilView}]:[]),
      ]});
      const exportPass=encoder.beginComputePass({label:'OpenMW export native attachments to engine'});
      exportPass.setPipeline(bridge.export);exportPass.setBindGroup(0,exportBindings);
      exportPass.dispatchWorkgroups(Math.ceil(config.width/8),Math.ceil(config.height/8),config.samples);exportPass.end();
    }
    device.queue.submit([encoder.finish()]);
    if(directTarget)this.performanceStats.nativeCameraPasses++;else this.performanceStats.compatibilityCameraPasses++;
    this.lastPass={wallMs:performance.now()-passStart,stateBuildMs,pipelineWaitMs,drawCalls,
      uniqueMaterials:uniformMaterials.size,uniformBytes,nativeDirect:Boolean(directTarget)};
    return {gpuMs:null,drawCalls,occlusionQueries:queryRuns.length,nativeTarget:directTarget??null};
    } finally {this.busy=false;}
  }
  async exportCompatibility(target,buffer,params) {
    if(!target?.config)throw TypeError('Native target is missing configuration');
    const base=this.config(params);
    if(base.samples!==1)throw Error('Compatibility materialization of multisampled native targets is not supported');
    // Stencil is deliberately omitted here: the remaining compatibility users
    // are color/depth/normal readers. Rasterization itself keeps stencil native.
    const config={...base,stencil:false};
    config.key=JSON.stringify(config);
    const bridge=await this.bridge(config),device=this.device;
    const uniform=this.buffer('compat export uniforms',this.uniformStride,GPUBufferUsage.UNIFORM|GPUBufferUsage.COPY_DST);
    const data=new Uint32Array(this.uniformStride/4);
    data.set([config.width,config.height,config.width*config.height,1,config.compact?1:0,0,
      params.color_channels,params.normal_channels]);
    device.queue.writeBuffer(uniform,0,data);
    const entries=[
      {binding:0,resource:nativeBinding(buffer)},{binding:1,resource:{buffer:uniform,size:32}},
      {binding:2,resource:target.depth.sampleView},
      ...(config.compact?[]:[{binding:3,resource:target.color.sampleView}]),
      ...(config.normal?[{binding:4,resource:target.normal.sampleView}]:[]),
    ];
    const bind=device.createBindGroup({layout:bridge.export.getBindGroupLayout(0),entries});
    const encoder=device.createCommandEncoder({label:'OpenMW materialize native attachment'});
    const pass=encoder.beginComputePass();pass.setPipeline(bridge.export);pass.setBindGroup(0,bind);
    pass.dispatchWorkgroups(Math.ceil(config.width/8),Math.ceil(config.height/8),1);pass.end();
    device.queue.submit([encoder.finish()]);
  }
  async importCompatibility(buffer,target,params) {
    if(!target?.config)throw TypeError('Native target is missing configuration');
    const config=this.config(params);
    if(config.samples!==1)throw Error('Compatibility import into multisampled native targets is not supported');
    const bridge=await this.bridge({...config,stencil:false,key:JSON.stringify({...config,stencil:false})});
    const uniform=this.buffer('compat import uniforms',this.uniformStride,GPUBufferUsage.UNIFORM|GPUBufferUsage.COPY_DST);
    const data=new Uint32Array(this.uniformStride/4);
    data.set([config.width,config.height,config.width*config.height,1,config.compact?1:0,0,
      params.color_channels,params.normal_channels]);
    this.device.queue.writeBuffer(uniform,0,data);
    const bind=this.device.createBindGroup({layout:bridge.seed.getBindGroupLayout(0),entries:[
      {binding:0,resource:nativeBinding(buffer)},{binding:1,resource:{buffer:uniform,size:32}}
    ]});
    const encoder=this.device.createCommandEncoder({label:'OpenMW import compatibility attachment'});
    const pass=encoder.beginRenderPass({label:'OpenMW compatibility-to-native import',
      ...this.attachments(target,config,'clear')});
    pass.setPipeline(bridge.seed);pass.setBindGroup(0,bind);pass.draw(3);pass.end();
    this.device.queue.submit([encoder.finish()]);
  }

  snapshot() {
    // Diagnostics only. Rendering is performed by native WebGPU render passes;
    // this object does not implement the old CUDA/software rasterizer.
    return {
      backend:'webgpu',
      mode:'native-render-pipeline',
      hardwareRasterization:true,
      active:!this.disposed,
      busy:this.busy,
      cachedRenderPipelines:this.pipelines.size,
      cachedShaderFamilies:this.shaderModules.size,
      cachedAttachmentBridges:this.bridgePipelines.size,
      cachedRenderTargets:this.targets.size,
      cachedBuffers:this.buffers.size,
      performance:{...this.performanceStats,lastPass:this.lastPass?{...this.lastPass}:null},
    };
  }
  dispose() {
    if(this.disposed)return;this.disposed=true;
    for(const target of this.targets.values())this.destroyTextures(target);
    for(const buffer of this.buffers.values())buffer.destroy();
    this.visibilityCounter?.dispose();
    this.materialUniformData=new Uint32Array();
    this.targets.clear();this.buffers.clear();this.pipelines.clear();this.shaderModules.clear();this.bridgePipelines.clear();
  }
}
