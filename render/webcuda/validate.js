import { GpuRuntime } from '/webcuda-sdk/src/runtime/runtime.js';
import { MaterialPipeline } from './pipeline.js';

const output = document.querySelector('#results');
const report = { status: 'running', checks: [] };
window.webcudaValidation = report;
const assert = (condition, message) => { if (!condition) throw Error(message); report.checks.push(message); };
let runtime;
try {
  runtime = await GpuRuntime.create({ backend: 'webgpu' });
  runtime.device.addEventListener('uncapturederror', event => {
    report.status = 'failed'; report.error = event.error.message;
    output.textContent = JSON.stringify(report, null, 2);
  });
  const kernels = {};
  for (const name of ['transform_vertices', 'clip_triangles', 'raster_reference', 'pack_present', 'bin_triangles', 'raster_tiled', 'clear_target', 'raster_material', 'pack_target', 'transform_material', 'assemble_material', 'decode_dxt']) {
    const response = await fetch(`generated/${name}.json`);
    if (!response.ok) throw Error(`Missing compiled artifact: ${name}`);
    kernels[name] = await runtime.kernel(await response.json());
  }
  assert(true, 'All twelve generated WGSL kernels passed WebGPU validation');
  let alphaBits=0n;for(let p=0;p<16;p++)alphaBits|=BigInt(p%8)<<BigInt(p*3);
  const compressed=runtime.createBuffer(new Uint32Array([240|(10<<8)|(Number(alphaBits&65535n)<<16),Number(alphaBits>>16n),0x001ff800,0]));
  const decoded=runtime.createBuffer(64);
  runtime.batch().dispatch(kernels.decode_dxt.bind({blocks:compressed,pixels:decoded},{width:4,height:4,format:5,block_offset:0,pixel_offset:0}),[1,1,1]).submit();
  const decodedPixels=await runtime.read(decoded,Uint32Array);
  const alphaPalette=[240,10,207,174,141,108,75,42];
  assert(decodedPixels.every((v,p)=>(v>>>24)===alphaPalette[p%8] && (v&0xffffff)===255),
    'GPU DXT5 decoding matches color and alpha including indices crossing a 32-bit boundary');
  const source = runtime.createBuffer(new Float32Array([2,3,4]));
  const matrices = runtime.createBuffer(new Float32Array([1,0,0,0,0,1,0,0,0,0,1,0,10,20,30,1]));
  const ids = runtime.createBuffer(new Uint32Array([0]));
  const transformed = runtime.createBuffer(16);
  runtime.batch().dispatch(kernels.transform_vertices.bind({positions:source,matrices,matrix_ids:ids,clip:transformed}, {vertex_count:1}), [1,1,1]).submit();
  const transformedResult = await runtime.read(transformed);
  assert(transformedResult.every((v,i) => v === [12,23,34,1][i]), 'GPU vertex transform matches expected coordinates');

  const indices = runtime.createBuffer(new Uint32Array([0,1,2]));
  const clip = runtime.createBuffer(new Float32Array([-.8,-.8,0,1, .8,-.8,0,1, 0,.8,0,1]));
  const colors = runtime.createBuffer(new Float32Array([1,0,0,1, 0,1,0,1, 0,0,1,1]));
  const clipped = runtime.createBuffer(84*4), weights = runtime.createBuffer(84*4), valid = runtime.createBuffer(7*4);
  runtime.batch().dispatch(kernels.clip_triangles.bind({clip,indices,positions:clipped,weights,valid},{triangle_count:1,vertex_stride:4,triangle_stride:3}),[1,1,1]).submit();
  const flags = await runtime.read(valid, Uint32Array);
  assert(flags[0] === 1 && flags.slice(1).every(v => v === 0), 'GPU clipping retains one fully visible triangle');
  runtime.write(clip, new Float32Array([-.5,-.5,-2,1, .5,-.5,0,1, 0,.5,0,1]));
  runtime.batch().dispatch(kernels.clip_triangles.bind({clip,indices,positions:clipped,weights,valid},{triangle_count:1,vertex_stride:4,triangle_stride:3}),[1,1,1]).submit();
  const crossingFlags = await runtime.read(valid, Uint32Array);
  assert(crossingFlags.reduce((a,b)=>a+b,0) === 2, 'GPU near-plane clipping emits two triangles');
  const crossing = await runtime.read(clipped);
  assert([0,1].every(t => [0,1,2].every(v => { const i=t*12+v*4; return crossing[i+2]>=-crossing[i+3]-1e-6; })), 'GPU clipped vertices remain inside the near plane');
  runtime.write(clip, new Float32Array([-.8,-.8,0,1, .8,-.8,0,1, 0,.8,0,1]));
  const width=256, height=256, row_pixels=256;
  const rgba=runtime.createBuffer(width*height*16), depth=runtime.createBuffer(width*height*4);
  const pixels=runtime.createBuffer(row_pixels*height*4);
  runtime.batch()
    .dispatch(kernels.raster_reference.bind({clip,colors,indices,rgba,depth},{width,height,triangle_count:1}),[width*height/64,1,1])
    .dispatch(kernels.pack_present.bind({rgba,pixels},{width,height,row_pixels}),[width*height/64,1,1]).submit();
  const context=document.querySelector('canvas').getContext('webgpu');
  context.configure({device:runtime.device,format:'rgba8unorm',usage:GPUTextureUsage.COPY_DST|GPUTextureUsage.RENDER_ATTACHMENT,alphaMode:'opaque'});
  const encoder=runtime.device.createCommandEncoder();
  encoder.copyBufferToTexture({buffer:pixels.gpuBuffer,bytesPerRow:row_pixels*4,rowsPerImage:height}, {texture:context.getCurrentTexture()}, [width,height,1]);
  runtime.device.queue.submit([encoder.finish()]);
  const packed=await runtime.read(pixels,Uint32Array);
  assert(packed[0] === 0xff000000, 'GPU raster/present path clears background to opaque black');
  const center=packed[128*width+128];
  assert((center>>>24)===255 && (center&255)>0 && ((center>>>8)&255)>0 && ((center>>>16)&255)>0, 'GPU raster/present path produces interpolated triangle color');
  const tileCount=Math.ceil(width/16)*Math.ceil(height/16);
  const counts=runtime.createBuffer(tileCount*4), candidates=runtime.createBuffer(tileCount*4);
  runtime.batch()
    .dispatch(kernels.bin_triangles.bind({clip,indices,counts,candidates},{width,height,triangle_count:1,capacity:1,vertex_stride:4,triangle_stride:3}),[Math.ceil(tileCount/64),1,1])
    .dispatch(kernels.raster_tiled.bind({clip,colors,indices,counts,candidates,rgba,depth},{width,height,capacity:1}),[width*height/64,1,1])
    .dispatch(kernels.pack_present.bind({rgba,pixels},{width,height,row_pixels}),[width*height/64,1,1]).submit();
  const tiled=await runtime.read(pixels,Uint32Array);
  assert(tiled.every((v,i)=>v===packed[i]), 'GPU tiled raster matches reference at every pixel');
  const tileCounts=await runtime.read(counts,Uint32Array);
  assert(tileCounts.some(v=>v===0) && tileCounts.some(v=>v===1), 'GPU binning excludes empty tiles and retains covered tiles');
  runtime.batch().dispatch(kernels.bin_triangles.bind({clip,indices,counts,candidates},{width,height,triangle_count:1,capacity:0,vertex_stride:4,triangle_stride:3}),[Math.ceil(tileCount/64),1,1]).submit();
  const required=await runtime.read(counts,Uint32Array);
  assert(required.some(v=>v>0), 'GPU bin overflow reports required capacity instead of truncating counts');
  const vertices=runtime.createBuffer(new Float32Array([
    -1,1,0,1, 1,1,1,1, 0,0, 1,1,0,1, 1,1,1,1, 1,0,
    1,-1,0,1, 1,1,1,1, 1,1, -1,-1,0,1, 1,1,1,1, 0,1]));
  const triangles=runtime.createBuffer(new Uint32Array([0,1,2,0,0,2,3,0]));
  const materialCounts=runtime.createBuffer(4);
  const materialCandidates=runtime.createBuffer(8);
  const materials=runtime.createBuffer(new Uint32Array([0,2,2,1,0,0,0,4,4,0,0,0]));
  const texels=runtime.createBuffer(new Uint32Array([0xff0000ff,0xff00ff00,0xffff0000,0xffffffff]));
  const target=runtime.createBuffer(16*5*4);
  const materialBindings={vertices,triangles,counts:materialCounts,candidates:materialCandidates,materials,texels,target};
  runtime.batch()
    .dispatch(kernels.bin_triangles.bind({clip:vertices,indices:triangles,counts:materialCounts,candidates:materialCandidates},{width:4,height:4,triangle_count:2,capacity:2,vertex_stride:10,triangle_stride:4}),[1,1,1])
    .dispatch(kernels.clear_target.bind({target},{pixel_count:16,red:0,green:0,blue:0,alpha:1,depth:1}),[1,1,1])
    .dispatch(kernels.raster_material.bind(materialBindings,{width:4,height:4,capacity:2}),[1,1,1]).submit();
  const textureResult=await runtime.read(target);
  assert(textureResult[0]===1 && textureResult[1]===0 && textureResult[3*5+1]===1 && textureResult[12*5+2]===1 && textureResult[15*5]===1,
    'GPU material sampling maps all four texture quadrants');
  runtime.write(materials,new Uint32Array([0,2,2,2,0,0,0,4,4,0,0,0]));
  runtime.write(vertices,new Float32Array([
    -1,1,0,1, 1,0,0,.5, 0,0, 1,1,0,1, 1,0,0,.5, 1,0,
    1,-1,0,1, 1,0,0,.5, 1,1, -1,-1,0,1, 1,0,0,.5, 0,1]));
  runtime.batch()
    .dispatch(kernels.clear_target.bind({target},{pixel_count:16,red:0,green:0,blue:0,alpha:1,depth:1}),[1,1,1])
    .dispatch(kernels.raster_material.bind(materialBindings,{width:4,height:4,capacity:2}),[1,1,1]).submit();
  const blended=await runtime.read(target);
  assert(Array.from({length:16},(_,p)=>blended[p*5]).every(v=>Math.abs(v-.5)<1e-6),
    'GPU top-left coverage blends adjacent triangles exactly once without seams');
  runtime.write(materials,new Uint32Array([0,2,2,128|256|2,0,0,0,4,4,1|(7<<4),0x5454,0]));
  runtime.batch()
    .dispatch(kernels.clear_target.bind({target},{pixel_count:16,red:0,green:0,blue:0,alpha:1,depth:1}),[1,1,1])
    .dispatch(kernels.raster_material.bind(materialBindings,{width:4,height:4,capacity:2}),[1,1,1]).submit();
  const separate=await runtime.read(target);
  assert(Math.abs(separate[0]-.5)<1e-6 && Math.abs(separate[3]-.75)<1e-6,
    'GPU extended blend factors preserve OpenGL RGB and alpha results');
  const referenceBits=new Uint32Array(new Float32Array([.5]).buffer)[0];
  runtime.write(materials,new Uint32Array([0,2,2,128|256|2,referenceBits,0,0,4,4,1|(4<<4),0x5454,0]));
  runtime.batch()
    .dispatch(kernels.clear_target.bind({target},{pixel_count:16,red:0,green:0,blue:0,alpha:1,depth:1}),[1,1,1])
    .dispatch(kernels.raster_material.bind(materialBindings,{width:4,height:4,capacity:2}),[1,1,1]).submit();
  const discarded=await runtime.read(target);
  assert(discarded[0]===0 && discarded[3]===1,'GPU alpha GREATER rejects exact equality using the float threshold');
  const pipeline=await MaterialPipeline.create(runtime);
  const identity=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1];
  const scene={
    vertices:new Float32Array([-.8,-.8,-2,1,1,1,1,1,0,0, .8,-.8,0,1,1,1,1,1,1,0, 0,.8,0,1,1,1,1,1,.5,1]),
    matrices:new Float32Array([...identity,...identity]),matrixIds:new Uint32Array([0,0,0]),
    triangles:new Uint32Array([0,1,2,0]),materials:new Uint32Array([0,1,1,1|4|8,0,0,0,width,height,0,0,0]),
    texels:new Uint32Array([0xff00ff00])
  };
  const frame=await pipeline.render(scene,width,height,context);
  const nearPixels=await runtime.read(frame.pixels,Uint32Array);
  assert(nearPixels[128*width+128]===0xff00ff00 && nearPixels[0]===0xff000000,
    'Complete GPU pipeline transforms, clips and shades a near-plane-crossing textured triangle');
  for(let v=0;v<3;v++) scene.vertices[v*10+2]=-3;
  const rejectedFrame=await pipeline.render(scene,width,height);
  const rejectedPixels=await runtime.read(rejectedFrame.pixels,Uint32Array);
  assert(rejectedPixels.every(v=>v===0xff000000), 'Next frame rejects outside geometry without stale clipped slots');
  scene.vertices[2]=-2; scene.vertices[12]=0; scene.vertices[22]=0;
  scene.triangles=new Uint32Array(Array.from({length:80},()=>[0,1,2,0]).flat());
  const densePromise=pipeline.render(scene,4,4);
  assert(await pipeline.render(scene,4,4)===null,'In-flight submission rejects a second frame instead of growing a queue');
  const denseFrame=await densePromise;
  const densePixels=await runtime.read(denseFrame.pixels,Uint32Array);
  assert(denseFrame.capacity>64 && densePixels.some(v=>v===0xff00ff00),
    'Full pipeline grows overflowing tile lists and rerenders without dropping triangles');
  scene.triangles[0]=99;
  let invalidRejected=false;
  try { await pipeline.render(scene,width,height); } catch { invalidRejected=true; }
  assert(invalidRejected && !pipeline.busy,'Invalid packet indices are rejected and submission state recovers');
  pipeline.dispose();
  await runtime.idle();
  if (report.status === 'failed') throw Error(report.error);
  report.status='passed';
  report.backend=runtime.backend;
  report.note='Canvas was rendered with .cu compute kernels and a GPU copy. Numerical checks use readback separately. This is not an integrated Morrowind renderer.';
} catch (error) { report.status='failed'; report.error=String(error.stack || error); }
output.textContent=JSON.stringify(report,null,2);
