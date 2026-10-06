// SPDX-License-Identifier: GPL-3.0-or-later
// Native WebGPU host. The webcuda* Module callbacks preserve the existing WASM ABI.
import { WebGPURuntime } from './runtime.js';
import { MaterialPipeline } from './pipeline.js';
import { dispatchGroups } from './dispatch.js';
import { colorStorage, depthStorage } from './color-storage.js';
import { guardLegacyRendering } from './legacy-draw-guard.js';
import { targetId as canonicalTargetId, targetCommand } from './target-id.js';
import { FrameReadbacks } from './frame-readbacks.js';
import { NativeAttachmentStore } from './native-targets.js';

// A frame is accepted before culling starts, retains immutable WASM packets,
// then uploads directly from their heap views in camera order. At most one
// accepted frame owns GPU work; every completion/error path releases its views.
// SDL retains its input canvas/context; every visible game pixel comes from
// the separate WebGPU presentation canvas, which never acquires a GL context.
const moduleOwners=new WeakMap();
function releasePackets(passes) {
  for(const pass of passes??[])pass.release?.();
}

export async function installWebGPU(Module, {onError=console.error}={}) {
  return installOwnedWebGPU(Module,onError,false);
}

async function installOwnedWebGPU(Module,onError,recovering) {
  if(moduleOwners.has(Module)||Module.webcudaEnabled||(Module.webcudaRecoveryPending&&!recovering))
    throw Error('WebGPU host is already installed, initializing, disposing or recovering');
  const owner={};
  moduleOwners.set(Module,owner);
  const releaseOwnership=()=>{
    if(moduleOwners.get(Module)===owner)moduleOwners.delete(Module);
  };
  try { return await createWebGPUHost(Module,onError,releaseOwnership); }
  catch(error) { releaseOwnership();throw error; }
}

async function createWebGPUHost(Module,onError,releaseOwnership) {
  const input=Module.canvas;
  if(!(input instanceof HTMLCanvasElement)||!input.parentElement)throw TypeError('Missing attached SDL canvas');
  // Full-resolution shadow/RTT planes can exceed the runtime's conservative
  // 256 MiB default. Request the adapter's supported limits without reducing
  // the engine's attachment dimensions or sample count.
  const runtime=await WebGPURuntime.create({useAdapterBufferLimits:true});
  let pipeline;
  try { pipeline=await MaterialPipeline.create(runtime, ({name,completed,total})=>{
    const message=name?`Preparing renderer (${completed} of ${total}): ${name}`:'Renderer ready';
    Module.setStatus?.(message);
  }); }
  catch(error) { if(runtime.dispose)await runtime.dispose();else runtime.device.destroy();throw error; }
  const canvas=document.createElement('canvas');
  canvas.id='webgpu-canvas'; canvas.setAttribute('aria-hidden','true');
  Object.assign(canvas.style,{position:'fixed',pointerEvents:'none',zIndex:'1',display:'none'});
  let context;
  try {
    input.parentElement.appendChild(canvas);
    context=canvas.getContext('webgpu');
    if(!context)throw Error('WebGPU presentation context is unavailable');
    context.configure({device:runtime.device,format:'rgba8unorm',usage:GPUTextureUsage.COPY_DST|GPUTextureUsage.RENDER_ATTACHMENT,alphaMode:'opaque'});
  } catch(error) {
    try { context?.unconfigure(); }
    finally { canvas.remove();pipeline.dispose();if(runtime.dispose)await runtime.dispose();else runtime.device.destroy(); }
    throw error;
  }
  let frame=null, state=null, lastState=null, busy=false, failed=false, disposed=false;
  let disposalPromise=null,recoveryCancelled=false;
  const imageRequests=new Set();
  Module.webcudaImageError=null;
  const targets=new Map();
  const nativeTargets=new NativeAttachmentStore(runtime);
  const luminanceHistory=new Map();
  Module.webcudaQueryResults=new Map();
  const queryLastSeen=new Map();let queryFrame=0;
  const colorTargetStack=[];
  let presentation=null;
  const inspectPasses=new URLSearchParams(location.search).has('renderdebug');
  let diagnosticPanel=null,diagnosticLabel=null;
  if(inspectPasses) {
    diagnosticPanel=document.createElement('div');diagnosticLabel=document.createElement('span');
    const save=document.createElement('button');save.textContent='Save renderer report';
    Object.assign(diagnosticPanel.style,{position:'fixed',top:'8px',left:'8px',zIndex:'100001',
      background:'rgba(10,15,22,.88)',color:'#e5eef8',font:'12px system-ui',padding:'8px',maxWidth:'90vw'});
    Object.assign(save.style,{marginLeft:'12px',font:'inherit',cursor:'pointer'});
    save.addEventListener('click',()=>{
      const report={url:location.href,observedAt:new Date().toISOString(),stats:JSON.parse(canvas.dataset.webcudaStats??'null'),
        frames:timingSnapshot(),passes:JSON.parse(canvas.dataset.webcudaPasses??'null')};
      const url=URL.createObjectURL(new Blob([JSON.stringify(report,null,2)+'\n'],{type:'application/json'}));
      const link=document.createElement('a');link.href=url;link.download='openmw-renderer-report.json';link.click();
      setTimeout(()=>URL.revokeObjectURL(url),0);
    });
    diagnosticPanel.append(diagnosticLabel,save);input.parentElement.appendChild(diagnosticPanel);
  }
  Module.webcudaProfileCapture=inspectPasses;
  // Wall-clock observations, not GPU timestamps or physical display scanout.
  const stats={accepted:0,presented:0,skipped:0,aborted:0,passes:0,error:null,gpuFrameMs:0,lastFrame:null};
  let first3DWatchdog=null;
  const armFirst3DWatchdog=()=>{
    if(first3DWatchdog||stats.presented>0)return;
    first3DWatchdog=setTimeout(()=>{
      first3DWatchdog=null;
      if(stats.presented>0||failed||disposed)return;
      const detail='The first captured 3D WebGPU frame has not completed after 15 seconds. '
        +'Open the debug log for WebGPU diagnostics; this is a renderer stall, not game-data loading.';
      stats.error=detail;publishDiagnostics(true);onError(Error(detail));
    },15000);
  };
  // Expose completed-frame evidence on the presentation element for browser
  // diagnostics. Throttle DOM updates; these counters do not drive rendering.
  let diagnosticAt=-Infinity;
  function publishDiagnostics(force=false) {
    const now=performance.now();
    if(!force&&now-diagnosticAt<1000)return;
    diagnosticAt=now;
    canvas.dataset.webcudaStats=JSON.stringify({
      accepted:stats.accepted,presented:stats.presented,skipped:stats.skipped,
      aborted:stats.aborted,
      passes:stats.passes,frameWallMs:stats.gpuFrameMs,error:stats.error,
      frameTiming:stats.lastFrame,
      // Allocation sizes, not resident physical RAM/VRAM. Driver/compiler,
      // browser heaps, textures and diagnostic query buffers are excluded.
      runtimeBufferBytes:Array.from(runtime.buffers??[],buffer=>buffer.byteLength).reduce((sum,bytes)=>sum+bytes,0),
      backend:runtime.backend,hardwareRaster:pipeline.rasterizer?.snapshot()??null,
      textureResidency:pipeline.textureResidency?.snapshot()??null,
      vertexResidency:pipeline.vertexResidency?.snapshot()??null,
      wasmHeapCapacityBytes:Module.webcudaTransportStats?.heapCapacityBytes??Module.wasmMemory?.buffer.byteLength??null,
      transport:Module.webcudaTransportStats?{...Module.webcudaTransportStats}:null,
      legacyDrawAttempts:Module.webcudaLegacyDrawStats?.attempts??0,
      maxStorageBufferBindingSize:runtime.device.limits.maxStorageBufferBindingSize,
      maxBufferSize:runtime.device.limits.maxBufferSize,
      observedAt:now,
    });
    if(diagnosticLabel) {
      const last=stats.lastFrame,backend='WebGPU';
      diagnosticLabel.textContent=stats.error?`${backend}: ${stats.error.split('\n')[0]}`:
        `${backend} · ${stats.presented} frames · capture ${(last?.packetCaptureMs??0).toFixed(1)} ms · render ${(last?.frameWallMs??0).toFixed(1)} ms · interval ${(last?.presentationSubmitIntervalMs??0).toFixed(1)} ms`;
    }
  }
  publishDiagnostics(true);
  const frameTimings=new Array(240);let timingCursor=0,timingCount=0;
  let acceptedAt=0,lastPresentationSubmit=null;
  function timingSnapshot() {
    const result=[];
    for(let i=0;i<timingCount;i++)result.push({...frameTimings[(timingCursor-timingCount+i+frameTimings.length)%frameTimings.length]});
    return result;
  }
  // Logical attachment identities are now native GPU textures first. A legacy
  // 40-byte/pixel buffer is materialized only for the handful of compatibility
  // operations that still consume buffer pixels (screenshots, uncommon effects).
  function retireAttachment(attachment) {
    if(!attachment)return;
    if(attachment.buffer)pipeline.retireBuffer(attachment.buffer);
    if(attachment.sampleBuffer)pipeline.retireBuffer(attachment.sampleBuffer);
    nativeTargets.destroy(attachment);
  }
  function planeStorage(id,width,height,sampleCount=1,alpha=1,compactDepth) {
    let destination=targets.get(id);
    compactDepth??=destination?.compactDepth??false;
    if(compactDepth&&sampleCount!==1)throw Error('Compact depth requires single-sample storage');
    if(!destination||destination.width!==width||destination.height!==height||destination.compactDepth!==compactDepth) {
      const replacement={buffer:null,sampleBuffer:null,native:null,width,height,compactDepth,sampleCount,alpha,
        authority:'empty',colorFormat:0x8058,depthFormat:0x81a6,normalFormat:0x8058};
      if(destination) {
        for(const [key,value] of targets)if(value===destination)targets.delete(key);
        retireAttachment(destination);
      }
      destination=replacement;targets.set(id,destination);
    } else if(destination.sampleCount!==sampleCount) {
      // Native planes encode sample count in their texture allocation. Drop only
      // GPU attachment storage; compatibility bytes can be regenerated lazily.
      nativeTargets.destroy(destination);
      if(destination.sampleBuffer){pipeline.retireBuffer(destination.sampleBuffer);destination.sampleBuffer=null;}
      destination.sampleCount=sampleCount;destination.authority=destination.buffer?'compat':'empty';
    }
    return destination;
  }
  function compatibilityParams(attachment) {
    const color=colorStorage(attachment.colorFormat??0x8058);
    const normal=colorStorage(attachment.normalFormat??0x8058);
    return {width:attachment.width,height:attachment.height,sample_count:attachment.sampleCount??1,
      color_channels:attachment.compactDepth?0:color.channels,color_storage:color.storage,
      normal_enabled:attachment.native?.normal?1:0,normal_channels:normal.channels,normal_storage:normal.storage,
      depth_bits:depthStorage(attachment.depthFormat??0x81a6),stencil_enabled:0};
  }
  async function ensureCompatibility(attachment) {
    if(!attachment)throw Error('Missing attachment');
    if(!attachment.buffer) {
      const bytes=attachment.width*attachment.height*(attachment.compactDepth?4:40);
      if(!Number.isSafeInteger(bytes)||bytes>runtime.device.limits.maxStorageBufferBindingSize||bytes>runtime.device.limits.maxBufferSize)
        throw RangeError('Compatibility attachment exceeds WebGPU buffer limits');
      attachment.buffer=runtime.createBuffer(bytes,{label:'OpenMW compatibility attachment'});
      if(attachment.compactDepth)runtime.batch().dispatch(pipeline.kernels.clear_compact_depth.bind({target:attachment.buffer},
        {pixel_count:attachment.width*attachment.height,depth:1}),dispatchGroups(attachment.width*attachment.height,runtime.device.limits)).submit();
      else runtime.batch().dispatch(pipeline.kernels.clear_target.bind({target:attachment.buffer},
        {pixel_count:attachment.width*attachment.height,red:0,green:0,blue:0,alpha:attachment.alpha??1,depth:1}),
        dispatchGroups(attachment.width*attachment.height,runtime.device.limits)).submit();
    }
    if(attachment.authority==='native'&&attachment.native) {
      await pipeline.rasterizer.exportCompatibility({config:{},...attachment.native},attachment.buffer,compatibilityParams(attachment));
    }
    attachment.authority='compat';
    return attachment.buffer;
  }
  async function importCompatibility(attachment) {
    if(!attachment?.buffer||!attachment.native||attachment.authority!=='compat')return;
    await pipeline.rasterizer.importCompatibility(attachment.buffer,{config:{},...attachment.native},compatibilityParams(attachment));
    attachment.authority='native';
  }
  async function copyPlane(source,destination,kernel) {
    if(source===destination)return;
    if(kernel==='copy_depth'&&source.native?.depth&&destination.native?.depth
      &&source.native.depth.samples===1&&destination.native.depth.samples===1) {
      await nativeTargets.copyDepth(source.native,destination.native);
      destination.authority='native';return;
    }
    if(kernel==='copy_normals'&&source.native?.normal&&destination.native?.normal
      &&source.native.normal.samples===1&&destination.native.normal.samples===1) {
      await nativeTargets.resolveColor({color:source.native.normal},{color:destination.native.normal},{clear:true});
      destination.authority='native';return;
    }
    const sourceBuffer=await ensureCompatibility(source),destinationBuffer=await ensureCompatibility(destination);
    if(source.compactDepth||destination.compactDepth) {
      if(kernel!=='copy_depth')throw Error('Compact depth cannot copy color, normals or stencil');
      runtime.batch().dispatch(pipeline.kernels.copy_depth_layout.bind({source:sourceBuffer,target:destinationBuffer},
        {pixel_count:source.width*source.height,source_compact:source.compactDepth?1:0,target_compact:destination.compactDepth?1:0}),
        dispatchGroups(source.width*source.height,runtime.device.limits)).submit();
    } else {
      runtime.batch().dispatch(pipeline.kernels[kernel].bind({source:sourceBuffer,target:destinationBuffer},
        {pixel_count:source.width*source.height}),dispatchGroups(source.width*source.height,runtime.device.limits)).submit();
    }
    destination.authority='compat';
  }
  async function loadPlane(id,destination,kernel,preserve) {
    if(!id||!preserve)return;
    const source=planeStorage(id,destination.width,destination.height,destination.sampleCount??1);
    await copyPlane(source,destination,kernel);
  }
  async function storePlane(id,source,kernel) {
    if(!id)return;
    await copyPlane(source,planeStorage(id,source.width,source.height,source.sampleCount??1),kernel);
  }
  async function storeAttachments(attachment,pass,nativeDirect) {
    attachment.depthTargetId=pass.depthTargetId??0;
    attachment.colorFormat=pass.colorFormat??attachment.colorFormat;
    attachment.depthFormat=pass.depthFormat??attachment.depthFormat;
    attachment.normalFormat=pass.normalFormat??attachment.normalFormat;
    if(nativeDirect) {
      attachment.authority='native';
      if(pass.depthTargetId) {
        const depth=targets.get(pass.depthTargetId);if(depth){depth.authority='native';depth.depthFormat=pass.depthFormat??depth.depthFormat;}
      }
      if(pass.normalTargetId) {
        const normal=targets.get(pass.normalTargetId);if(normal){normal.authority='native';normal.normalFormat=pass.normalFormat??normal.normalFormat;}
      }
      if(pass.stencilTargetId) {
        const stencil=targets.get(pass.stencilTargetId);if(stencil)stencil.authority='native';
      }
      return;
    }
    await storePlane(pass.depthTargetId,attachment,'copy_depth');
    if([0x88f0,0x8cad].includes(pass.depthFormat))await storePlane(pass.depthTargetId,attachment,'copy_stencil');
    await storePlane(pass.stencilTargetId,attachment,'copy_stencil');
    await storePlane(pass.normalTargetId,attachment,'copy_normals');
  }
  function fail(error) {
    if(failed||disposed)return;
    failed=true; releasePackets(frame);frame=null; state=null;
    Module.webcudaImageError=String(error);
    for(const request of [...imageRequests])request.reject(error);
    stats.error=String(error?.stack??error);
    publishDiagnostics(true);
    onError(error);
  }
  function position() {
    const rect=input.getBoundingClientRect();
    Object.assign(canvas.style,{left:`${rect.left}px`,top:`${rect.top}px`,width:`${rect.width}px`,height:`${rect.height}px`});
  }
  const observer=new ResizeObserver(position); observer.observe(input);
  window.addEventListener('scroll',position,true);
  runtime.device.lost.then(info=>{
    if(disposed)return;
    failed=true;releasePackets(frame);frame=null;state=null;
    const error=Error(`WebGPU device lost: ${info.message}`);
    Module.webcudaRecoveryPending=true;
    Module.webcudaImageError=String(error);
    stats.error=String(error);
    publishDiagnostics(true);
    for(const request of [...imageRequests])request.reject(error);
    // Device loss gets one replacement attempt. Shader/validation failures still
    // use fail(); they must not trigger an endless recreate loop.
    void (async()=>{
      try {
        try { await disposeHost(); } catch(disposeError) { console.warn('WebGPU lost-device cleanup:',disposeError); }
        if(recoveryCancelled){Module.webcudaRecoveryPending=false;return;}
        if(Module.webcudaRecoveryAttempts>=1)throw Error('WebGPU device lost again before recovery completed');
        Module.webcudaRecoveryAttempts=(Module.webcudaRecoveryAttempts??0)+1;
        const replacement=await installOwnedWebGPU(Module,onError,true);
        if(recoveryCancelled) {
          await replacement.dispose();
          Module.webcudaRecoveryPending=false;
        }
      } catch(recoveryError) {
        if(recoveryCancelled){Module.webcudaRecoveryPending=false;return;}
        Module.webcudaRecoveryPending=false;
        Module.webcudaImageError=String(recoveryError);
        onError(recoveryError);
      }
    })();
  });
  const onGpuError=event=>fail(event.error);
  runtime.device.addEventListener('uncapturederror',onGpuError);
  Module.webcudaBeginFrame=()=>{
    if(disposed||failed||Module.webcudaRecoveryPending)return false;
    if(frame)throw Error('Nested WebGPU frame');
    if(busy){stats.skipped++;publishDiagnostics();return false;}
    frame=[]; state=null;lastState=null;colorTargetStack.length=0;acceptedAt=performance.now();stats.accepted++;armFirst3DWatchdog();return true;
  };
  Module.webcudaPassState=value=>{
    if(!frame||state)throw Error('Unexpected WebGPU camera state');
    state=targetCommand(value);
  };
  Module.webcudaRetireTarget=id=>{
    id=canonicalTargetId(id);
    if(busy||!frame||frame.length||state||!Number.isInteger(id)||id<=0||id>0xffffffff)
      throw Error('Unexpected target retirement boundary');
    const attachment=targets.get(id);
    if(attachment){retireAttachment(attachment);targets.delete(id);}
    luminanceHistory.delete(id);
    pipeline.releaseBuffer(`exposure${id}`);
  };
  Module.webcudaResolveAttachment=command=>{
    command=targetCommand(command);
    if(!frame||state||!lastState||command.sourceId!==lastState.targetId)throw Error('Unexpected attachment resolve boundary');
    frame.push({...command,kind:'attachment-resolve'});
  };
  Module.webcudaSubmitPass=packet=>{
    if(!frame||!state||packet.version!==2||packet.storage!=='wasm-retained'||typeof packet.release!=='function')
      throw Error('Unexpected WebGPU pass packet');
    frame.push({...packet,...state});lastState=state;state=null;return true;
  };
  Module.webcudaDepthIsolation=(begin,depth)=>{
    if(!frame||state||!lastState||!Number.isFinite(depth)||depth<0||depth>1)throw Error('Unexpected depth isolation boundary');
    frame.push({kind:begin?'depth-save':'depth-restore',targetId:lastState.targetId,depth});
    state={...lastState,clearMask:0};
  };
  Module.webcudaResolveScene=(scene,distortion,sourceFormat,destinationFormat,scaleX=1,scaleY=1)=>{
    scene=canonicalTargetId(scene);distortion=canonicalTargetId(distortion);
    if(!frame||state||!lastState)throw Error('Unexpected scene resolve boundary');
    if(![scaleX,scaleY].every(Number.isFinite))throw Error('Invalid scene UV scaling');
    frame.push({kind:'scene-resolve',targetId:lastState.targetId,sourceId:scene,distortionId:distortion,sourceFormat,destinationFormat,scaleX,scaleY,viewport:lastState.viewport?.slice()});
    state={...lastState,clearMask:0};
  };
  Module.webcudaDebugScene=(depthId,normalId,flags,settings)=>{
    depthId=canonicalTargetId(depthId);normalId=canonicalTargetId(normalId);
    if(!frame||!state||!(settings instanceof Float32Array)||settings.length!==19||!settings.every(Number.isFinite)
      ||!Number.isInteger(flags)||flags<0||flags>15||((flags&1)&&(!(settings[0]>0)||!(settings[1]>settings[0])||!depthId))
      ||((flags&2)&&!normalId))throw Error('Invalid debug effect command');
    frame.push({kind:'scene-debug',targetId:state.targetId,depthId,normalId,flags,settings});
  };
  Module.webcudaBloomScene=(depthId,values,reverseZ)=>{
    depthId=canonicalTargetId(depthId);
    if(!frame||!state||!(values instanceof Float32Array)||values.length!==11||values.some(v=>!Number.isFinite(v)))throw Error('Invalid bloom command');
    const [gamma,threshold,clamp,skyFactor,radius,strength,near,far,resolutionWidth,resolutionHeight,time]=values;
    if(gamma<=0||threshold<0||clamp<0||skyFactor<0||radius<0||radius>1||strength<0||near<=0||far<=near
      ||![resolutionWidth,resolutionHeight].every(v=>Number.isInteger(v)&&v>0))throw Error('Invalid bloom parameters');
    frame.push({kind:'scene-bloom',targetId:state.targetId,depthId,gamma,threshold,clamp,skyFactor,radius,strength,near,far,resolutionWidth,resolutionHeight,time,reverseZ});
  };
  Module.webcudaSceneLuminance=command=>{
    command=targetCommand(command);
    if(!frame||state||!lastState)throw Error('Unexpected luminance boundary');
    if(![command.width,command.height,command.viewportWidth,command.viewportHeight].every(v=>Number.isInteger(v)&&v>0)
      ||![command.sx,command.sy,command.speed,command.time].every(Number.isFinite)||command.speed<0)throw Error('Invalid luminance parameters');
    frame.push({...command,kind:'scene-luminance'});state={...lastState,clearMask:0};
  };
  Module.webcudaDistortScene=distortionId=>{
    distortionId=canonicalTargetId(distortionId);
    if(!frame||!state||!Number.isInteger(distortionId)||distortionId<=0)throw Error('Invalid scene distortion');
    frame.push({kind:'scene-distortion',targetId:state.targetId,distortionId});
  };
  Module.webcudaAdjustScene=(gamma,contrast)=>{
    if(!frame||!state||![gamma,contrast].every(Number.isFinite)||gamma<0||contrast<0)throw Error('Invalid scene adjustment');
    frame.push({kind:'scene-adjustments',targetId:state.targetId,gamma,contrast});
  };
  Module.webcudaCaptureDepth=(target,width,height)=>{
    target=canonicalTargetId(target);
    if(!frame||state||!lastState)throw Error('Unexpected depth capture boundary');
    frame.push({kind:'depth-capture',targetId:target,sourceId:lastState.targetId,width,height});
    state={...lastState,clearMask:0};
  };
  Module.webcudaColorTarget=(begin,target,colorFormat,depthFormat)=>{
    target=canonicalTargetId(target);
    if(!frame||state||!lastState)throw Error('Unexpected color target boundary');
    if(begin) {
      colorTargetStack.push(lastState);
      state={clearMask:(target&0x80000000)?0:16384,clearColor:[0,0,0,1],clearDepth:1,targetId:target,depthTargetId:0,normalTargetId:0,colorFormat,depthFormat};
    } else {
      const saved=colorTargetStack.pop();if(!saved||saved.targetId!==target)throw Error('Unbalanced color target boundary');
      state={...saved,clearMask:0};
    }
  };
  Module.webcudaSubmitRipple=command=>{
    command=targetCommand(command);
    if(!frame||!state||command.targetId!==state.targetId)throw Error('Unexpected ripple simulation command');
    if(!(command.positions instanceof Float32Array)||command.positions.length%3||command.positions.length>300
      ||command.positions.some(v=>!Number.isFinite(v))||![command.ox,command.oy,command.time].every(Number.isFinite))throw Error('Invalid ripple simulation data');
    frame.push(command);
  };
  // Call after flushing the desired camera/pass. Pixels are copied at this
  // command's position, before later GUI or offscreen writes can alter them.
  const fogJobs=new Set();
  Module.webcudaGenerateFogImage=(width,height,words)=> {
    const job=(async()=> {
      if(failed||disposed)throw Error('WebGPU fog capture host unavailable');
      const count=width*height;
      if(![width,height].every(v=>Number.isSafeInteger(v)&&v>0&&v<=runtime.device.limits.maxTextureDimension2D)
        ||!(words instanceof Uint32Array)||words.length!==1+count+words[0]*3
        ||Math.max(words.byteLength,count*4)>Math.min(runtime.device.limits.maxBufferSize,runtime.device.limits.maxStorageBufferBindingSize))throw RangeError('Invalid fog readback dimensions');
      const brushes=new Float32Array(words.buffer,words.byteOffset+(1+count)*4,words[0]*3);
      if(brushes.some((v,i)=>!Number.isFinite(v)||(i%3===2&&v<=0)))throw RangeError('Invalid fog readback brush');
      let blocks=null,pixels=null;
      try {
        blocks=runtime.createBuffer(words.byteLength,{label:'Fog save inputs'});
        pixels=runtime.createBuffer(count*4,{label:'Fog save pixels'});
        runtime.write(blocks,words);
        runtime.batch().dispatch(pipeline.kernels.generate_fog_map.bind({blocks,pixels},
          {width,height,block_offset:0,pixel_offset:0}),dispatchGroups(count,runtime.device.limits)).submit();
        const packed=await runtime.read(pixels,Uint32Array,count*4);
        if(failed||disposed)throw Error('WebGPU fog capture interrupted');
        return {width,height,rgba:new Uint8Array(packed.buffer,packed.byteOffset,packed.byteLength),origin:'bottom-left'};
      } finally {
        if(blocks)pipeline.retireBuffer(blocks);if(pixels)pipeline.retireBuffer(pixels);
      }
    })();
    fogJobs.add(job);job.then(()=>fogJobs.delete(job),()=>fogJobs.delete(job));
    return job;
  };
  Module.webcudaSnapshotPreviousFrame=(targetId,width,height)=> {
    targetId=canonicalTargetId(targetId);
    if(!frame||state||lastState||!Number.isSafeInteger(targetId)||targetId<=0
      ||![width,height].every(v=>Number.isSafeInteger(v)&&v>0&&v<=runtime.device.limits.maxTextureDimension2D))throw Error('Invalid previous-frame snapshot');
    frame.push({kind:'frame-snapshot',targetId,width,height});
  };
  Module.webcudaCaptureImage=(width,height,finalScreen=false)=>{
    if(!frame||state||!lastState||failed||disposed)throw Error('Image capture requires a flushed active pass');
    const bytes=width*height*4;
    if(!Number.isSafeInteger(width)||!Number.isSafeInteger(height)||width<=0||height<=0
      ||!Number.isSafeInteger(bytes)||bytes/4>0xffffffff||bytes>runtime.device.limits.maxStorageBufferBindingSize
      ||bytes>runtime.device.limits.maxBufferSize)throw RangeError('Invalid image capture size');
    let resolve,reject;
    let request;
    const completion=new Promise((accept,fail)=>{
      resolve=value=>{imageRequests.delete(request);accept(value);};
      reject=error=>{imageRequests.delete(request);fail(error);};
    });
    // Engine bridges may poll later; avoid an unhandled rejection in the interim.
    completion.catch(()=>{});
    request={kind:'image-capture',sourceId:finalScreen?0:lastState.targetId,viewport:finalScreen?null:lastState.viewport?.slice(),width,height,resolve,reject};
    imageRequests.add(request);frame.push(request);
    return completion;
  };
  function dispatchPostEffect(pass,input,destination) {
    if(input.buffer===destination.buffer)throw Error('Postprocess attachment feedback');
    const groups=dispatchGroups(destination.width*destination.height,runtime.device.limits);
    if(pass.kind==='scene-adjustments') {
      runtime.batch().dispatch(pipeline.kernels.adjust_scene.bind({source:input.buffer,target:destination.buffer},
        {width:destination.width,height:destination.height,source_width:input.width,source_height:input.height,
          gamma:pass.gamma,contrast:pass.contrast}),groups).submit();
      stats.passes++;return;
    }
    if(pass.kind==='scene-debug') {
      const depth=pass.depthId?targets.get(pass.depthId):input,normals=pass.normalId?targets.get(pass.normalId):input;
      if(!depth||!normals)throw Error('Debug effect attachment is unavailable');
      const settings=pipeline.buffer('debugSettings',76,pass.settings);
      runtime.batch().dispatch(pipeline.kernels.debug_scene.bind({source:input.buffer,depth:depth.buffer,normals:normals.buffer,settings,target:destination.buffer},
        {width:destination.width,height:destination.height,source_width:input.width,source_height:input.height,
          depth_width:depth.width,depth_height:depth.height,normal_width:normals.width,normal_height:normals.height,flags:pass.flags}),groups).submit();
      stats.passes++;return;
    }
    if(pass.kind==='scene-bloom') {
      const depth=targets.get(pass.depthId);if(!depth)throw Error('Bloom depth attachment is unavailable');
          // RenderTarget SizeProxy scales the scene texture; omw.resolution
          // independently controls the shader's blur radius and texel offsets.
          const w=Math.max(1,Math.floor(input.width/4)),h=Math.max(1,Math.floor(input.height/4));
          if(w>runtime.device.limits.maxTextureDimension2D||h>runtime.device.limits.maxTextureDimension2D)throw Error('Bloom dimensions exceed device limits');
          const extract=pipeline.buffer('bloomExtract',w*h*40),horizontal=pipeline.buffer('bloomHorizontal',w*h*40),vertical=pipeline.buffer('bloomVertical',w*h*40);
          const groups=dispatchGroups(w*h,runtime.device.limits);
          runtime.batch()
            .dispatch(pipeline.kernels.bloom_extract.bind({source:input.buffer,depth:depth.buffer,target:extract},
              {width:w,height:h,source_width:input.width,source_height:input.height,depth_width:depth.width,depth_height:depth.height,
                gamma:pass.gamma,threshold:pass.threshold,sky_factor:pass.skyFactor,near_plane:pass.near,far_plane:pass.far,reverse_z:pass.reverseZ?1:0}),groups)
            .dispatch(pipeline.kernels.bloom_blur.bind({source:extract,target:horizontal},
              {width:w,height:h,resolution_width:pass.resolutionWidth,resolution_height:pass.resolutionHeight,radius_parameter:pass.radius,vertical:0}),groups)
            .dispatch(pipeline.kernels.bloom_blur.bind({source:horizontal,target:vertical},
              {width:w,height:h,resolution_width:pass.resolutionWidth,resolution_height:pass.resolutionHeight,radius_parameter:pass.radius,vertical:1}),groups)
            .dispatch(pipeline.kernels.bloom_combine.bind({source:input.buffer,bloom:vertical,target:destination.buffer},
              {width:destination.width,height:destination.height,source_width:input.width,source_height:input.height,bloom_width:w,bloom_height:h,
                gamma:pass.gamma,clamp_value:pass.clamp,strength:pass.strength,time:pass.time}),
              dispatchGroups(destination.width*destination.height,runtime.device.limits)).submit();
      stats.passes+=4;return;
    }
    const effect=pass.distortionId?targets.get(pass.distortionId):input;
    if(!effect||effect.buffer===destination.buffer)throw Error('Invalid postprocess distortion attachment');
    runtime.batch().dispatch(pipeline.kernels.resolve_scene.bind({source:input.buffer,distortion:effect.buffer,target:destination.buffer},
      {width:destination.width,height:destination.height,source_width:input.width,source_height:input.height,
        distortion_width:effect.width,distortion_height:effect.height,use_distortion:pass.distortionId?1:0,scale_x:pass.scaleX??1,scale_y:pass.scaleY??1}),groups).submit();
    stats.passes++;
  }
  async function render(passes) {
    const start=performance.now();
    const uploadsBefore=runtime.stats.dataBytesUploaded;
    const timing={acceptedAt,packetCaptureMs:start-acceptedAt,dispatchPhaseMs:0,validationWaitMs:0,
      completionWaitMs:0,frameWallMs:0,presentationSubmitAt:null,presentationSubmitIntervalMs:null,
      skippedSincePrevious:stats.skipped-(stats.lastFrame?.skippedTotal??0),skippedTotal:stats.skipped};
    timing.engineCapture=Module.webcudaCaptureTimings?{...Module.webcudaCaptureTimings}:null;
    timing.capturedSceneBytes=passes.reduce((total,pass)=>total+Object.values(pass.scene??{})
      .reduce((bytes,value)=>bytes+(ArrayBuffer.isView(value)?value.byteLength:0),0),0);
    let queueCompleted=false,readbacks;
    try {
      readbacks=new FrameReadbacks(runtime,bytes=>pipeline.buffer('frameReadback',bytes));
      const readback=(...args)=>readbacks.read(...args);
      let result;
      const markScreenWritten=(targetId,attachment,rendered=null)=>{
        if(targetId!==0||!attachment)return;
        result=rendered??{width:attachment.width,height:attachment.height,row_pixels:Math.ceil(attachment.width/64)*64};
      };
      const depthStack=[], completedQueries=new Map(),queryCompletions=[],passDiagnostics=[];
      for(let passIndex=0;passIndex<passes.length;passIndex++) {
        const pass=passes[passIndex];
        if(pass.kind==='frame-snapshot') {
          const source=targets.get(0);
          const destination=planeStorage(pass.targetId,pass.width,pass.height,1);
          destination.colorFormat=0x1907;
          if(source?.native?.color&&source.native.color.samples===1) {
            nativeTargets.ensureColor(destination,0x1907,1,'color');
            await nativeTargets.resolveColor(source.native,destination.native,{clear:true});
            destination.authority='native';
          } else {
            const destinationBuffer=await ensureCompatibility(destination);
            let sourceBuffer=null,emptySource=null;
            if(source)sourceBuffer=await ensureCompatibility(source);
            else {emptySource=runtime.createBuffer(40,{label:'Empty previous frame'});sourceBuffer=emptySource;}
            runtime.batch().dispatch(pipeline.kernels.snapshot_frame.bind({source:sourceBuffer,target:destinationBuffer},
              {source_width:source?.width??0,source_height:source?.height??0,width:pass.width,height:pass.height}),
              dispatchGroups(pass.width*pass.height,runtime.device.limits)).submit();
            destination.authority='compat';
            if(emptySource)pipeline.retireBuffer(emptySource);
          }
          stats.passes++;continue;
        }
        if(pass.kind==='image-capture') {
          const source=targets.get(pass.sourceId);
          if(!source)throw Error('Missing image capture attachment');
          if(source.compactDepth)throw Error('Color image capture requires a color attachment');
          const region=pass.viewport??[0,0,source.width,source.height];
          if(!Array.isArray(region)||region.length!==4||!region.every(Number.isSafeInteger)
            ||region.some(value=>Math.abs(value)>0x3fffffff)||region[2]<=0||region[3]<=0
            ||region[2]>runtime.device.limits.maxTextureDimension2D||region[3]>runtime.device.limits.maxTextureDimension2D)
            throw RangeError('Invalid image capture viewport');
          const [region_x,region_y,region_width,region_height]=region;
          const sourceBuffer=await ensureCompatibility(source);
          const pixels=runtime.createBuffer(pass.width*pass.height*4,{label:'OpenMW image capture'});
          try {
            runtime.batch().dispatch(pipeline.kernels.capture_image.bind({source:sourceBuffer,pixels},
              {source_width:source.width,source_height:source.height,width:pass.width,height:pass.height,region_x,region_y,region_width,region_height}),
              dispatchGroups(pass.width*pass.height,runtime.device.limits)).submit();
            const packed=await runtime.read(pixels,Uint32Array,pass.width*pass.height*4);
            const rgba=new Uint8Array(packed.buffer,packed.byteOffset,packed.byteLength);
            pass.resolve({width:pass.width,height:pass.height,rgba,origin:'bottom-left'});
          } finally {pipeline.retireBuffer(pixels);}
          continue;
        }
        if(pass.kind==='attachment-resolve') {
          const source=targets.get(pass.sourceId);
          if(!source||source.width!==pass.width||source.height!==pass.height||pass.sourceId===pass.targetId
            ||![0,1,2,3,4].includes(pass.plane))throw Error('Invalid resolved attachment source');
          const v=pass.viewport;
          if(!Array.isArray(v)||v.length!==4||!v.every(Number.isSafeInteger)||v[2]<=0||v[3]<=0)throw Error('Invalid resolve viewport');
          const destination=planeStorage(pass.targetId,pass.width,pass.height,1,1,pass.plane===1?true:undefined);
          if((source.compactDepth||destination.compactDepth)&&pass.plane!==1)throw Error('Compact depth resolve requires the depth plane');
          const full=v[0]===0&&v[1]===0&&v[2]===pass.width&&v[3]===pass.height;
          let nativeResolved=false;
          if(full&&pass.plane===0&&source.native?.color?.samples===1) {
            destination.colorFormat=pass.format;nativeTargets.ensureColor(destination,pass.format,1,'color');
            await nativeTargets.resolveColor(source.native,destination.native,{clear:true});
            destination.authority='native';nativeResolved=true;
          } else if(full&&pass.plane===2&&source.native?.normal?.samples===1) {
            destination.normalFormat=pass.format;nativeTargets.ensureColor(destination,pass.format,1,'normal');
            await nativeTargets.resolveColor({color:source.native.normal},{color:destination.native.normal},{clear:true});
            destination.authority='native';nativeResolved=true;
          } else if(full&&(pass.plane===1||pass.plane===4)&&source.native?.depth?.samples===1) {
            destination.depthFormat=pass.format;nativeTargets.ensureDepth(destination,pass.format,1,false);
            await nativeTargets.copyDepth(source.native,destination.native);
            destination.authority='native';nativeResolved=true;
          }
          if(!nativeResolved) {
            const sourceBuffer=await ensureCompatibility(source),destinationBuffer=await ensureCompatibility(destination);
            const color=pass.plane===0||pass.plane===2?colorStorage(pass.format):{channels:4,storage:0};
            const depth=pass.plane===1||pass.plane===4?depthStorage(pass.format):24;
            if(pass.plane===0)destination.colorFormat=pass.format;
            if(pass.plane===2)destination.normalFormat=pass.format;
            runtime.batch().dispatch(pipeline.kernels.copy_resolved_attachment.bind({source:sourceBuffer,target:destinationBuffer},
              {width:pass.width,height:pass.height,plane:pass.plane,color_channels:color.channels,color_storage:color.storage,depth_bits:depth,
               viewport_x:v[0],viewport_y:v[1],viewport_width:v[2],viewport_height:v[3],source_compact:source.compactDepth?1:0,target_compact:destination.compactDepth?1:0}),
              dispatchGroups(pass.width*pass.height,runtime.device.limits)).submit();
            destination.authority='compat';
          }
          if(pass.plane===0||pass.plane===2)markScreenWritten(pass.targetId,destination);
          stats.passes++;continue;
        }
        if(pass.kind==='depth-capture') {
          const source=targets.get(pass.sourceId);
          if(!source||source.width!==pass.width||source.height!==pass.height)throw Error('Depth capture source dimensions differ');
          let destination=targets.get(pass.targetId);
          if(destination===source)throw Error('Depth capture cannot alias scene attachment');
          destination=planeStorage(pass.targetId,pass.width,pass.height,1,1,true);
          destination.depthFormat=source.depthFormat??0x81a6;
          if(source.native?.depth?.samples===1) {
            nativeTargets.ensureDepth(destination,destination.depthFormat,1,false);
            await nativeTargets.copyDepth(source.native,destination.native);destination.authority='native';
          } else await copyPlane(source,destination,'copy_depth');
          stats.passes++;continue;
        }
        if(pass.kind==='scene-luminance') {
          const source=targets.get(pass.sourceId);
          if(!source)throw Error('Luminance source is unavailable');
          let w=pass.width,h=pass.height;
          if(w>runtime.device.limits.maxTextureDimension2D||h>runtime.device.limits.maxTextureDimension2D)throw Error('Luminance dimensions exceed device limits');
          const sourceBuffer=await ensureCompatibility(source);
          let input=pipeline.buffer('luminanceLevel0',w*h*4),level=0;
          runtime.batch().dispatch(pipeline.kernels.scene_log_luminance.bind({source:sourceBuffer,output:input},
            {width:w,height:h,source_width:source.width,source_height:source.height,sx:pass.sx,sy:pass.sy,viewport_width:pass.viewportWidth,viewport_height:pass.viewportHeight}),
            dispatchGroups(w*h,runtime.device.limits)).submit();
          while(w>1||h>1) {
            const dw=Math.max(1,Math.floor(w/2)),dh=Math.max(1,Math.floor(h/2));
            const output=pipeline.buffer(`luminanceLevel${++level}`,dw*dh*4);
            runtime.batch().dispatch(pipeline.kernels.reduce_luminance.bind({source:input,output},{width:w,height:h}),
              dispatchGroups(dw*dh,runtime.device.limits)).submit();
            input=output;w=dw;h=dh;
          }
          const previous=luminanceHistory.get(pass.sourceId);
          const history=previous?.buffer??pipeline.buffer(`exposure${pass.sourceId}`,4,new Float32Array(1));
          const reset=pass.reset||!previous||pass.time<previous.time;
          const delta=previous?Math.max(0,pass.time-previous.time):0;
          runtime.batch().dispatch(pipeline.kernels.adapt_luminance.bind({source:input,history},
            {delta,speed:pass.speed,reset:reset?1:0}),[1,1,1]).submit();
          luminanceHistory.set(pass.sourceId,{buffer:history,time:pass.time});
          stats.passes++;continue;
        }
        if(pass.kind==='scene-resolve') {
          const original=targets.get(pass.sourceId),destination=targets.get(pass.targetId);
          if(!original||!destination)throw Error('Scene resolve attachment is unavailable');
          const storage=colorStorage(pass.sourceFormat),finalStorage=colorStorage(pass.destinationFormat);
          const viewport=pass.viewport??[0,0,destination.width,destination.height];
          if(!Array.isArray(viewport)||viewport.length!==4||!viewport.every(Number.isSafeInteger)
            ||viewport.some(v=>Math.abs(v)>0x7fffffff)||viewport[2]<=0||viewport[3]<=0
            ||viewport[2]>runtime.device.limits.maxTextureDimension2D||viewport[3]>runtime.device.limits.maxTextureDimension2D)
            throw Error('Invalid postprocess viewport');
          const [viewport_x,viewport_y,viewport_width,viewport_height]=viewport;
          const partial=viewport_x!==0||viewport_y!==0||viewport_width!==destination.width||viewport_height!==destination.height;
          const finalOutput=partial?{width:viewport_width,height:viewport_height,
            buffer:pipeline.buffer('postprocessViewport',viewport_width*viewport_height*40)}:destination;
          const stages=[];
          if(pass.distortionId)stages.push({kind:'scene-distortion',distortionId:pass.distortionId});
          while(passIndex+1<passes.length) {
            const next=passes[passIndex+1];
            if(next.targetId!==pass.targetId||!['scene-adjustments','scene-distortion','scene-bloom','scene-debug'].includes(next.kind))break;
            stages.push(next);passIndex++;
          }
          if(!stages.length)stages.push({kind:'scene-resolve',distortionId:0,scaleX:pass.scaleX,scaleY:pass.scaleY});
          const adjustments=stages.filter(stage=>stage.kind==='scene-adjustments');
          const distortions=stages.filter(stage=>stage.kind==='scene-distortion');
          const nativePost=!partial&&original.authority==='native'&&original.native?.color?.samples===1
            &&(destination.sampleCount??1)===1&&adjustments.length<=1&&distortions.length<=1
            &&stages.every(stage=>['scene-resolve','scene-adjustments','scene-distortion'].includes(stage.kind));
          if(nativePost) {
            destination.colorFormat=pass.destinationFormat??destination.colorFormat;
            nativeTargets.ensureColor(destination,destination.colorFormat,1,'color');
            let distortion=null;
            if(distortions.length) {
              const holder=targets.get(distortions[0].distortionId);
              if(!holder||holder.authority!=='native'||!holder.native?.color)throw Error('Native distortion target is unavailable');
              distortion=holder.native;
            }
            const adjustment=adjustments[0];
            await nativeTargets.resolveColor(original.native,destination.native,{
              scaleX:pass.scaleX??1,scaleY:pass.scaleY??1,
              gamma:adjustment?.gamma??1,contrast:adjustment?.contrast??1,adjust:Boolean(adjustment),distortion,clear:false
            });
            destination.authority='native';markScreenWritten(pass.targetId,destination);stats.passes++;continue;
          }
          await ensureCompatibility(original);await ensureCompatibility(destination);
          for(const stage of stages) {
            if(stage.kind==='scene-distortion') {
              const holder=targets.get(stage.distortionId);if(holder)await ensureCompatibility(holder);
            } else if(stage.kind==='scene-debug') {
              const depth=stage.depthId&&targets.get(stage.depthId),normal=stage.normalId&&targets.get(stage.normalId);
              if(depth)await ensureCompatibility(depth);if(normal)await ensureCompatibility(normal);
            } else if(stage.kind==='scene-bloom') {
              const depth=targets.get(stage.depthId);if(depth)await ensureCompatibility(depth);
            }
          }
          const fallbackFinal=partial?{width:viewport_width,height:viewport_height,
            buffer:pipeline.buffer('postprocessViewport',viewport_width*viewport_height*40)}:destination;
          let input=original;
          for(let stage=0;stage<stages.length;stage++) {
            const final=stage===stages.length-1;
            const output=final?fallbackFinal:{width:original.width,height:original.height,
              buffer:pipeline.buffer(`postprocessChain${stage%2}`,original.width*original.height*40)};
            dispatchPostEffect(stages[stage],input,output);
            const outputStorage=final?finalStorage:storage;
            runtime.batch().dispatch(pipeline.kernels.store_postprocess_color.bind({target:output.buffer},
              {pixel_count:output.width*output.height,channels:outputStorage.channels,storage:outputStorage.storage}),
              dispatchGroups(output.width*output.height,runtime.device.limits)).submit();
            input=output;
          }
          if(partial)runtime.batch().dispatch(pipeline.kernels.place_postprocess.bind({source:fallbackFinal.buffer,target:destination.buffer},
            {width:destination.width,height:destination.height,source_width:viewport_width,source_height:viewport_height,viewport_x,viewport_y}),
            dispatchGroups(destination.width*destination.height,runtime.device.limits)).submit();
          destination.authority='compat';
          markScreenWritten(pass.targetId,destination);
          continue;
        }
        if(['scene-adjustments','scene-distortion','scene-bloom','scene-debug'].includes(pass.kind))throw Error('Postprocess stage without scene resolve');
        if(pass.kind==='depth-save'||pass.kind==='depth-restore') {
          const attachment=targets.get(pass.targetId);
          if(!attachment)throw Error('Depth isolation target is absent');
          const count=attachment.width*attachment.height,groups=dispatchGroups(count,runtime.device.limits);
          await ensureCompatibility(attachment);
          if(pass.kind==='depth-save') {
            const savedBuffer=pipeline.buffer(`isolatedDepth${depthStack.length}`,count*(attachment.compactDepth?4:40));
            const entry={id:pass.targetId,buffer:savedBuffer,width:attachment.width,height:attachment.height,
              sampleCount:1,compactDepth:attachment.compactDepth,authority:'compat',native:null};
            depthStack.push(entry);
            await copyPlane(attachment,entry,'copy_depth');
            runtime.batch().dispatch((attachment.compactDepth?pipeline.kernels.clear_compact_depth:pipeline.kernels.clear_depth).bind(
              {target:attachment.buffer},{pixel_count:count,depth:pass.depth}),groups).submit();
            attachment.authority='compat';
          } else {
            const saved=depthStack.pop();if(!saved||saved.id!==pass.targetId)throw Error('Unbalanced depth isolation');
            await copyPlane(saved,attachment,'copy_depth');attachment.authority='compat';
          }
          continue;
        }
        if(![pass.width,pass.height].every(n=>Number.isInteger(n)&&n>0&&n<=runtime.device.limits.maxTextureDimension2D))throw Error('Invalid camera target dimensions');
        const id=pass.targetId??0;
        const compactDepth=(id&0x80000000)!==0&&(pass.sampleCount??1)===1&&!pass.normalTargetId&&!pass.stencilTargetId&&!(pass.stencilBits??0)&&![0x88f0,0x8cad].includes(pass.depthFormat);
        const attachment=planeStorage(id,pass.width,pass.height,pass.sampleCount??1,pass.kind==='ripples'?0:1,compactDepth);
        if(pass.kind==='ripples') {
          if((attachment.sampleCount??1)>1)throw Error('Ripple simulation requires a single-sample attachment');
          if(pass.simulate) {
            const scratch=pipeline.buffer('rippleScratch',pass.width*pass.height*40);
            const positions=pipeline.buffer('ripplePositions',Math.max(4,pass.positions.byteLength),pass.positions);
            const groups=dispatchGroups(pass.width*pass.height,runtime.device.limits);
            runtime.batch()
              .dispatch(pipeline.kernels.ripple_blob.bind({source:attachment.buffer,target:scratch,positions},
                {width:pass.width,height:pass.height,count:pass.positions.length/3,offset_x:pass.ox,offset_y:pass.oy,time:pass.time}),groups)
              .dispatch(pipeline.kernels.ripple_simulate.bind({source:scratch,target:attachment.buffer},
                {width:pass.width,height:pass.height}),groups).submit();
          }
          stats.passes++;continue;
        }
        const v=pass.viewport??[0,0,pass.width,pass.height];
        const partialViewport=v[0]!==0||v[1]!==0||v[2]!==pass.width||v[3]!==pass.height;
        loadPlane(pass.depthTargetId,attachment,'copy_depth',partialViewport||!(pass.clearMask&256));
        if([0x88f0,0x8cad].includes(pass.depthFormat))
          loadPlane(pass.depthTargetId,attachment,'copy_stencil',partialViewport||!(pass.clearMask&1024));
        loadPlane(pass.stencilTargetId,attachment,'copy_stencil',partialViewport||!(pass.clearMask&1024));
        loadPlane(pass.normalTargetId,attachment,'copy_normals',
          partialViewport||!(pass.clearMask&16384)||(pass.clearColorMask??15)!==15);
        attachment.colorFormat=pass.colorFormat??0x8058;
        const renderCallStart=performance.now();
        const rendered=await pipeline.render(pass.scene,pass.width,pass.height,null,{...pass,target:attachment.buffer,sampleTarget:attachment.sampleBuffer,targets,compactDepth:attachment.compactDepth,deferCompletion:true,profileGpu:inspectPasses,readback});
        // Includes host preparation and any awaited earlier GPU work. This is
        // deliberately not labelled as the duration of this pass on the GPU.
        const renderCallWallMs=performance.now()-renderCallStart;
        if(inspectPasses) {
          // Queue the sample copy now, before later cameras can reuse storage.
          const pixel=Math.floor(pass.height/2)*pass.width+Math.floor(pass.width/2);
          const sample=readback(attachment.buffer,Float32Array,attachment.compactDepth?4:36,pixel*(attachment.compactDepth?4:36));
          passDiagnostics.push(Promise.all([rendered.queryCompletion,sample]).then(([completed,values])=>({
            targetId:id,width:pass.width,height:pass.height,compactDepth:attachment.compactDepth,
            clearMask:pass.clearMask,clearDepth:pass.clearDepth,depthFormat:pass.depthFormat,
            renderCallWallMs,textureDecodeCount:pass.scene.textureDecodes.length/5,
            ...completed.diagnostic,center:Array.from(values),error:completed.error?String(completed.error):null,
          }),error=>({targetId:id,error:String(error)})));
        }
        storeAttachments(attachment,pass);
        queryCompletions.push(rendered.queryCompletion);
        markScreenWritten(id,attachment,rendered);
        stats.passes++;
      }
      if(depthStack.length)throw Error('Unclosed depth isolation');
      const validationStart=performance.now();timing.dispatchPhaseMs=validationStart-start;
      // Deferred camera/status checks must pass before acquiring a canvas texture.
      // A failed GPU preparation must never publish a partially rendered frame.
      await readbacks.flush();
      for(const completed of await Promise.all(queryCompletions)) {
        if(completed.error)throw completed.error;
        for(const [id,count] of completed.queryResults)completedQueries.set(id,(completedQueries.get(id)??0)+count);
      }
      timing.validationWaitMs=performance.now()-validationStart;
      if(inspectPasses)canvas.dataset.webcudaPasses=JSON.stringify(await Promise.all(passDiagnostics));
      if(result&&!failed&&!disposed) {
        // Subsequent off-screen passes reuse the pipeline's pack buffer. Pack
        // the screen attachment again after all cameras, before presentation.
        const screen=targets.get(0);
        const bytes=result.row_pixels*result.height*4;
        if(!presentation||presentation.byteLength<bytes) {
          const replacement=runtime.createBuffer(bytes,{label:'OpenMW presentation'});
          if(presentation)pipeline.retireBuffer(presentation);
          presentation=replacement;
        }
        runtime.batch().dispatch(pipeline.kernels.pack_target.bind({target:screen.buffer,pixels:presentation},
          {width:result.width,height:result.height,row_pixels:result.row_pixels}),
          dispatchGroups(result.width*result.height,runtime.device.limits)).submit();
        if(canvas.width!==result.width)canvas.width=result.width;
        if(canvas.height!==result.height)canvas.height=result.height;
        position();
        if(runtime.presentBuffer)await runtime.presentBuffer(presentation,context,result.width,result.height,result.row_pixels);
        else {
          const encoder=runtime.device.createCommandEncoder();
          encoder.copyBufferToTexture({buffer:presentation.gpuBuffer,bytesPerRow:result.row_pixels*4,rowsPerImage:result.height},
            {texture:context.getCurrentTexture()},[result.width,result.height,1]);
          runtime.device.queue.submit([encoder.finish()]);
        }
        timing.presentationSubmitAt=performance.now();
        timing.presentationSubmitIntervalMs=lastPresentationSubmit===null?null:timing.presentationSubmitAt-lastPresentationSubmit;
        lastPresentationSubmit=timing.presentationSubmitAt;
      }
      // Plane stores can be the last commands of an offscreen-only frame.
      // Finish them before accepting a new frame that may retire their owners.
      const completionStart=performance.now();
      await runtime.idle();
      timing.completionWaitMs=performance.now()-completionStart;
      queueCompleted=true;pipeline.collectRetired();
      if(runtime.flushRetired)await runtime.flushRetired();
      if(result&&!failed&&!disposed){canvas.style.display='block';stats.presented++;if(first3DWatchdog){clearTimeout(first3DWatchdog);first3DWatchdog=null;}}
      // Publish a complete accepted frame together, so visible/total queries
      // cannot be observed from different asynchronous pass completions.
      queryFrame++;
      for(const [id,count] of completedQueries){Module.webcudaQueryResults.set(id,count);queryLastSeen.set(id,queryFrame);}
      for(const [id,last] of queryLastSeen)if(queryFrame-last>120){queryLastSeen.delete(id);Module.webcudaQueryResults.delete(id);}
      // Only a completed GPU frame proves that the replacement is usable.
      Module.webcudaRecoveryAttempts=0;
      timing.frameWallMs=performance.now()-start;
      timing.uploadedBytesDuringFrame=runtime.stats.dataBytesUploaded-uploadsBefore;
      // Preserve the legacy property while exposing its actual wall-clock meaning.
      stats.gpuFrameMs=timing.frameWallMs;stats.lastFrame={...timing};
      publishDiagnostics();
      frameTimings[timingCursor]=timing;timingCursor=(timingCursor+1)%frameTimings.length;
      timingCount=Math.min(timingCount+1,frameTimings.length);
    }catch(error){readbacks?.cancel(error);for(const pass of passes)if(pass.kind==='image-capture')pass.reject(error);fail(error);}finally{
      // A packet or shader failure may happen after earlier passes submitted.
      // Drain those commands before exposing the host as idle or disposing it.
      if(!queueCompleted)try{await runtime.idle();pipeline.collectRetired();}catch(error){fail(error);}
      releasePackets(passes);
      timing.retainedPassesAfterFrame=Module.webcudaTransportStats?.retainedPasses??null;
      if(stats.lastFrame?.acceptedAt===timing.acceptedAt)
        stats.lastFrame.retainedPassesAfterFrame=timing.retainedPassesAfterFrame;
      busy=false;
      publishDiagnostics(failed||disposed);
    }
  }
  Module.webcudaEndFrame=commit=>{
    if(!frame)throw Error('WebGPU frame not started');
    const passes=frame;
    if(!commit){frame=null;for(const pass of passes)if(pass.kind==='image-capture')pass.reject(Error('Capture frame aborted'));releasePackets(passes);state=null;colorTargetStack.length=0;stats.aborted++;publishDiagnostics();return;}
    // Preserve the pending frame on validation failure so the engine's abort
    // handler can still release it and reject its capture requests.
    if(colorTargetStack.length)throw Error('Unclosed color target');
    if(state)throw Error('WebGPU camera did not finish');
    frame=null;busy=true;void render(passes);
  };
  Module.webcudaDeviceGeneration=((Module.webcudaDeviceGeneration??0)+1)>>>0;
  if(Module.webcudaDeviceGeneration===0)Module.webcudaDeviceGeneration=1;
  Module.webcudaSelected=true;
  Module.webcudaGuardContext=context=>{
    Module.webcudaLegacyDrawStats=guardLegacyRendering(context,onError);
  };
  Module.webgpuEnabled=true;
  Module.webcudaEnabled=true; // Selects the existing capture-only C++ viewer.
  function disposeHost() {
    if(disposalPromise)return disposalPromise;
    disposalPromise=(async()=>{
    disposed=true;Module.webgpuEnabled=false;Module.webcudaEnabled=false;
    releasePackets(frame);frame=null;state=null;
    Module.webcudaImageError='WebGPU host disposed';
    for(const request of [...imageRequests])request.reject(Error(Module.webcudaImageError));
    observer.disconnect();window.removeEventListener('scroll',position,true);
    runtime.device.removeEventListener('uncapturederror',onGpuError);
    while(busy)await new Promise(resolve=>setTimeout(resolve,0));
    await Promise.allSettled([...fogJobs]);
    // Attempt every release even when a lost device or one cleanup rejects.
    // All callers share disposalPromise and observe the same final outcome.
    const cleanupErrors=[];
    try { await runtime.idle(); } catch(error) { cleanupErrors.push(error); }
    const release=action=>{try { action(); } catch(error) { cleanupErrors.push(error); }};
    if(presentation) {
      const buffer=presentation;presentation=null;
      release(()=>pipeline.retireBuffer(buffer));
    }
    release(()=>pipeline.dispose());
    const buffers=new Set([...targets.values()].flatMap(target=>[target.buffer,...(target.sampleBuffer?[target.sampleBuffer]:[])]));
    targets.clear();
    for(const buffer of buffers)release(()=>runtime.destroyBuffer(buffer));
    release(()=>context.unconfigure());
    release(()=>canvas.remove());
    release(()=>diagnosticPanel?.remove());
    try {if(runtime.dispose)await runtime.dispose();else runtime.device.destroy();} catch(error){cleanupErrors.push(error);}
    if(cleanupErrors.length)throw new AggregateError(cleanupErrors,'WebGPU host cleanup failed');
    })().finally(releaseOwnership);
    return disposalPromise;
  }
  const host={stats,canvas,timingSnapshot,dispose(){
    recoveryCancelled=true;
    return disposeHost();
  }};
  window.__omwWebGPU=host;
  window.__omwWebCuda=host; // Existing engine diagnostics use this bridge name.
  return host;
}
