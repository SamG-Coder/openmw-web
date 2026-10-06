import {GpuRuntime} from '/webcuda-sdk/src/runtime/runtime.js';
import {gpuTimedBatch} from './gpu-timing.js';
import {checkWasmUploadGpu} from './wasm-upload-gpu-check.js';
import {checkAtlasUploadGpu} from './atlas-upload-gpu-check.js';
import {checkTextureResidencyGpu} from './texture-residency-gpu-check.js';
const button=document.querySelector('#run'),result=document.querySelector('#result');
button.addEventListener('click',async()=>{
  button.disabled=true;result.textContent='Running';let runtime,target;
  try {
    runtime=await GpuRuntime.create({backend:'webgpu'});
    const kernel=await runtime.kernel(await (await fetch('./generated/clear_compact_depth.json')).json());
    target=runtime.createBuffer(1024*1024*4,{label:'timing check'});
    const lines=(await checkWasmUploadGpu(runtime)).map(check=>`PASS: ${check}`);
    lines.push(`PASS: ${await checkAtlasUploadGpu(runtime)}`);
    lines.push(`PASS: ${await checkTextureResidencyGpu(runtime)}`);
    for(const enabled of [false,true]) {
      const timer=gpuTimedBatch(runtime,enabled,'CUDA clear timing check');
      const invocation=kernel.bind({target},{pixel_count:1024*1024,depth:.25});
      // Long enough to exceed browser timestamp privacy quantization.
      for(let i=0;i<(enabled?128:1);i++)timer.batch.dispatch(invocation,[16384,1,1]);
      const timing=await timer.submit();
      if(timing.error)throw timing.error;
      const data=await runtime.read(target,Float32Array,4);
      if(data[0]!==.25)throw Error('Timed CUDA dispatch did not write its output');
      if(!enabled&&timing.gpuMs!==null)throw Error('Disabled profiling returned a timestamp');
      if(enabled&&runtime.device.features.has('timestamp-query')&&!(timing.gpuMs>0))throw Error('No positive GPU interval');
      let rejected=false;try{timer.submit();}catch{rejected=true;}
      if(!rejected)throw Error('Duplicate submission accepted');
      lines.push(`PASS: enabled=${enabled}, GPU milliseconds=${timing.gpuMs}, output=${data[0]}, duplicate rejected`);
    }
    result.textContent=lines.join('\n');
  } catch(error){result.textContent=`FAIL: ${error.stack??error}`;}
  finally {if(target)runtime.destroyBuffer(target);if(runtime)await runtime.dispose();button.disabled=false;}
});
