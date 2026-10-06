import { GpuRuntime } from '/webcuda-sdk/src/runtime/runtime.js';
import { kernelManifest } from './kernel-manifest.js';
import { checkRasterGpu } from './raster-gpu-check.js';
import { checkDepthImageGpu } from './depth-image-gpu-check.js';
import { checkCompactDepthGpu } from './compact-depth-gpu-check.js';
import { NativeRendererRuntime } from './native-runtime.js';
import { checkNativeStorageGpu } from './native-storage-gpu-check.js';
import { checkPipelineGpu } from './pipeline-gpu-check.js';
import { checkPooledTextureResidencyGpu } from './texture-residency-gpu-check.js';
import { checkPositionedStateGpu } from './positioned-state-gpu-check.js';

const run=document.querySelector('#run'),save=document.querySelector('#save');
const availability=document.querySelector('#availability'),status=document.querySelector('#status');
const results=document.querySelector('#results'),scope=document.querySelector('#scope');
const storage=document.querySelector('#storage');
let report=null;
async function inspectAvailability() {
  try {
    const supported=await GpuRuntime.SupportsNativeCuda();
    availability.textContent=supported
      ?'Native CUDA is available in this browser. Ready to request access and test.'
      :'Native CUDA is unavailable here. Open this page in ChromiumRTXCuda alpha.6 on the NVIDIA GPU.';
    run.disabled=!supported;
  } catch(error) { availability.textContent=`Availability check failed: ${error.message}`;run.disabled=true; }
}
await inspectAvailability();

run.addEventListener('click',async()=>{
  run.disabled=true;scope.disabled=true;storage.disabled=true;save.disabled=true;results.textContent='';
  report={schema:1,startedAt:new Date().toISOString(),backend:'native-cuda',
    scope:scope.value,storage:storage.value,userAgent:navigator.userAgent,kernels:[],checks:[],status:'running',
    limits:'Kernel and controlled pipeline checks; no full-game correctness or frame-rate claim.'};
  let runtime,stage='Requesting native CUDA permission',stageStarted=performance.now();
  const setStage=value=>{stage=value;stageStarted=performance.now();status.textContent=stage;};
  const log=value=>{results.textContent+=value+'\n';};
  const timer=setInterval(()=>{status.textContent=`${stage} (${((performance.now()-stageStarted)/1000).toFixed(1)} s)`;},500);
  const checks=async(fn,kernel)=>{
    for(const name of await fn(runtime,kernel)){report.checks.push(name);log(`PASS: ${name}`);}
  };
  try {
    // Call before any await in this click handler so the browser receives the
    // actual user gesture. Availability alone never grants GPU execution.
    const permission=await GpuRuntime.requestPermission();
    if(permission!=='granted') {
      report.status='permission not granted';setStage('Native GPU access was not granted');return;
    }
    setStage('Opening native CUDA session');
    if(storage.value==='paged') {
      const base=await GpuRuntime.create({backend:'webgpu',useAdapterBufferLimits:true});
      try {runtime=await NativeRendererRuntime.create(base);} catch(error){await base.dispose();throw error;}
    } else runtime=await GpuRuntime.create({backend:'native'});
    report.backend=runtime.backend;
    if(!['native-cuda','native-cuda-paged'].includes(runtime.backend))throw Error('Expected native CUDA; refusing a backend substitution');
    report.runtime=runtime.describe();
    const entries=kernelManifest.filter(item=>item.runtime&&(scope.value==='all'||item.entry==='raster_material'));
    entries.sort((a,b)=>Number(b.entry==='raster_material')-Number(a.entry==='raster_material'));
    const kernels={};
    for(const {entry} of entries) {
      setStage(`${entry}: fetching original CUDA`);
      const response=await fetch(`generated/${entry}${runtime.artifactSuffix??'.native.json'}`);
      if(!response.ok)throw Error(`${entry}: HTTP ${response.status}; regenerate native artifacts`);
      const artifact=await response.json();
      if(artifact.native?.entry!==entry)throw Error(`${entry}: mismatched artifact entry`);
      const bytes=new TextEncoder().encode(artifact.native.source);
      const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),n=>n.toString(16).padStart(2,'0')).join('');
      setStage(`${entry}: NVRTC compilation and module load`);
      const started=performance.now();
      const kernel=await runtime.kernel(artifact);
      kernels[entry]=kernel;
      const elapsedMs=performance.now()-started;
      report.kernels.push({entry,sourceSha256:hash,sourceBytes:bytes.length,compileAndLoadMs:elapsedMs});
      log(`${entry}: native CUDA ready in ${(elapsedMs/1000).toFixed(3)} s; source SHA-256 ${hash}`);
      if(entry==='prepare_fixed_matrices'||entry==='prepare_texgen_matrices') {
        setStage('Native positioned state checks');await checks((runtime,kernel)=>checkPositionedStateGpu(runtime,kernel,entry),kernel);
      }
      if(entry==='raster_material'){setStage('Native raster output checks');await checks(checkRasterGpu,kernel);}
      if(entry==='decode_float_image'){setStage('Native depth image checks');await checks(checkDepthImageGpu,kernel);}
      if(entry==='compact_depth_to_texture'){setStage('Native depth layout checks');await checks(checkCompactDepthGpu,kernel);}
    }
    if(storage.value==='paged'){setStage('Native large-buffer and presentation checks');await checks(checkNativeStorageGpu);}
    if(storage.value==='paged'&&scope.value==='all') {
      setStage('Native production pipeline GPU checks');
      await checks((runtime)=>checkPipelineGpu(runtime,kernels));
      await checks(checkPooledTextureResidencyGpu);
    }
    await runtime.idle();
    report.status='passed';report.stats={...runtime.stats};
    setStage(`PASS: ${report.kernels.length} native kernels, ${report.checks.length} GPU checks`);
  } catch(error) {
    report.status='failed';report.error=String(error?.stack??error);setStage('Native CUDA check failed');log(report.error);
  } finally {
    clearInterval(timer);
    try {await runtime?.dispose();} catch(error) {report.status='failed';report.cleanupError=String(error);status.textContent='Native session cleanup failed';log(report.cleanupError);}
    report.finishedAt=new Date().toISOString();save.disabled=false;scope.disabled=false;storage.disabled=false;run.disabled=false;
    // Read-only DOM evidence for both manual inspection and browser automation.
    results.dataset.nativeReport=JSON.stringify(report);
  }
});
save.addEventListener('click',()=>{
  if(!report)return;
  const url=URL.createObjectURL(new Blob([JSON.stringify(report,null,2)+'\n'],{type:'application/json'}));
  const link=document.createElement('a');link.href=url;link.download='openmw-native-cuda-report.json';link.click();
  setTimeout(()=>URL.revokeObjectURL(url),0);
});
