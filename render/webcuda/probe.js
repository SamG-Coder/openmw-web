import { GpuRuntime } from '/webcuda-sdk/src/runtime/runtime.js';
import { MaterialPipeline } from './pipeline.js';
const output=document.querySelector('#results');
let packet;
try {
  await globalThis.createOpenMWProbe({locateFile:path=>`/webcuda-probe/${path}`,webcudaSubmitPass:value=>{packet=value;return true;}});
  if(!packet || packet.version!==2||packet.storage!=='wasm-retained')throw Error('WASM probe did not submit a supported packet');
  const runtime=await GpuRuntime.create({backend:'webgpu'});
  const pipeline=await MaterialPipeline.create(runtime);
  const context=document.querySelector('canvas').getContext('webgpu');
  context.configure({device:runtime.device,format:'rgba8unorm',usage:GPUTextureUsage.COPY_DST|GPUTextureUsage.RENDER_ATTACHMENT,alphaMode:'opaque'});
  const frame=await pipeline.render(packet.scene,packet.width,packet.height,context);
  const pixels=await runtime.read(frame.pixels,Uint32Array);
  if(pixels[128*frame.row_pixels+128]!==0xff0000ff || pixels[0]!==0xff000000)throw Error('OSG packet did not produce expected compressed-texture triangle/background pixels');
  output.textContent=JSON.stringify({status:'passed',path:'OSG cull → C++ geometry/material tables → wasm64 typed transport → .cu DXT/transform/clip/bin/material/present',vertices:packet.scene.vertices.length/10,triangles:packet.scene.triangles.length/4,materials:packet.scene.materials.length/12,compressedTextures:packet.scene.textureDecodes.length/5,gameIntegration:false},null,2);
}catch(error){output.textContent=JSON.stringify({status:'failed',error:String(error.stack||error)},null,2);}
finally {packet?.release?.();}
