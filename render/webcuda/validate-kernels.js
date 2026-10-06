import { GpuRuntime } from '/webcuda-sdk/src/runtime/runtime.js';
import { kernelManifest } from './kernel-manifest.js';
import { checkRasterGpu } from './raster-gpu-check.js';
import { checkDepthImageGpu } from './depth-image-gpu-check.js';
import { checkCompactDepthGpu, checkFullSizeDepthGpu } from './compact-depth-gpu-check.js';
import { checkBoundedBatchGpu } from './bounded-batch-gpu-check.js';
import { checkPipelineGpu } from './pipeline-gpu-check.js';
import { checkPooledTextureResidencyGpu } from './texture-residency-gpu-check.js';
import { checkPositionedStateGpu } from './positioned-state-gpu-check.js';
import { checkParticleInputsGpu } from './particle-input-gpu-check.js';
const button=document.querySelector('#run'),status=document.querySelector('#status'),results=document.querySelector('#results');
button.addEventListener('click',async()=>{
  button.disabled=true;results.textContent='';
  let runtime,stage='Requesting WebGPU device',started=performance.now();
  const setStage=value=>{stage=value;started=performance.now();status.textContent=value;};
  const timer=setInterval(()=>{status.textContent=`${stage} (${((performance.now()-started)/1000).toFixed(1)} s)`;},1000);
  const report=value=>{results.textContent+=value+'\n';};
  try {
    runtime=await GpuRuntime.create({backend:'webgpu',useAdapterBufferLimits:true});
    const adapter=runtime.adapter?.info;
    report(`Adapter: ${adapter?.vendor??'unknown'} ${adapter?.architecture??''} ${adapter?.description??''}`);
    report(`Device buffer limits: storage ${runtime.device.limits.maxStorageBufferBindingSize}, buffer ${runtime.device.limits.maxBufferSize} bytes`);
    // The main rasterizer is the observed slow stage; examine it before the
    // smaller kernels so its validation and driver compilation are distinct.
    const only=new URLSearchParams(location.search).get('kernel');
    const entries=kernelManifest.filter(entry=>entry.runtime&&(!only||entry.entry===only));
    if(!entries.length)throw Error(`Unknown runtime kernel: ${only}`);
    entries.sort((a,b)=>(b.entry==='raster_material')-(a.entry==='raster_material'));
    const kernels={};
    for(const {entry} of entries){
      setStage(`${entry}: fetching artifact`);
      const response=await fetch(`generated/${entry}.json`);
      if(!response.ok)throw Error(`${entry}: HTTP ${response.status}`);
      const artifact=await response.json();
      const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(artifact.wgsl));
      const hash=Array.from(new Uint8Array(digest),byte=>byte.toString(16).padStart(2,'0')).join('');
      report(`${entry}: WGSL SHA-256 ${hash}`);
      setStage(`${entry}: WGSL validation`);
      const module=runtime.device.createShaderModule({label:entry,code:artifact.wgsl});
      const info=await module.getCompilationInfo();
      const errors=info.messages.filter(message=>message.type==='error');
      for(const message of info.messages)report(`${entry}: ${message.type} ${message.lineNum}:${message.linePos} ${message.message}`);
      if(errors.length)throw Error(`${entry}: WGSL validation failed`);
      report(`${entry}: WGSL accepted in ${((performance.now()-started)/1000).toFixed(2)} s`);
      setStage(`${entry}: runtime pipeline creation`);
      // Exercise the same explicit layouts, feature checks and error scopes as
      // the game. This includes runtime WGSL validation again, not only driver time.
      const kernel=await runtime.kernel(artifact);
      kernels[entry]=kernel;
      report(`${entry}: runtime pipeline created in ${((performance.now()-started)/1000).toFixed(2)} s`);
      if(entry==='unpack_vertex_inputs') {
        setStage(`${entry}: GPU particle input checks`);
        for(const check of await checkParticleInputsGpu(runtime,kernel))report(`PASS: ${check}`);
      }
      if(entry==='prepare_fixed_matrices'||entry==='prepare_texgen_matrices') {
        setStage(`${entry}: GPU output checks`);
        for(const check of await checkPositionedStateGpu(runtime,kernel,entry))report(`PASS: ${check}`);
      }
      if(entry==='raster_material'){
        setStage(`${entry}: GPU output checks`);
        for(const check of await checkRasterGpu(runtime,kernel))report(`PASS: ${check}`);
      }
      if(entry==='decode_float_image'){
        setStage(`${entry}: GPU output checks`);
        for(const check of await checkDepthImageGpu(runtime,kernel))report(`PASS: ${check}`);
      }
      if(entry==='compact_depth_to_texture'){
        setStage(`${entry}: GPU output checks`);
        for(const check of await checkCompactDepthGpu(runtime,kernel))report(`PASS: ${check}`);
      }
      if(entry==='clear_compact_depth'){
        setStage(`${entry}: full-size GPU allocation check`);
        for(const check of await checkFullSizeDepthGpu(runtime,kernel))report(`PASS: ${check}`);
        for(const check of await checkBoundedBatchGpu(runtime,kernel))report(`PASS: ${check}`);
      }
    }
    if(!only) {
      setStage('Production pipeline GPU checks');
      for(const check of await checkPipelineGpu(runtime,kernels))report(`PASS: ${check}`);
      for(const check of await checkPooledTextureResidencyGpu(runtime))report(`PASS: ${check}`);
    }
    setStage(`PASS: ${entries.length} runtime kernels validated and compiled`);
  }catch(error){setStage('FAIL');report(String(error?.stack??error));}
  finally{clearInterval(timer);runtime?.dispose();button.disabled=false;}
});
