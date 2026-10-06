import {NATIVE_PAGE_BYTES as page} from './native-layout.js';
import {checkFullSizeDepthGpu} from './compact-depth-gpu-check.js';

export async function checkNativeStorageGpu(runtime) {
  const checks=[];
  const clear=await runtime.kernel(await (await fetch('generated/clear_compact_depth.native-paged.json')).json());
  checks.push(...await checkFullSizeDepthGpu(runtime,clear));
  const source=runtime.createBuffer(page+64,{label:'Native page boundary source'});
  const target=runtime.createBuffer(page+64,{label:'Native page boundary destination'});
  try {
    const values=new Uint32Array([11,22,33,44,55,66]);
    runtime.write(source,values,page-8);values.fill(999); // ordinary write snapshots
    runtime.batch().copy(source,target,{sourceOffset:page-8,targetOffset:page-4,byteLength:24}).submit();
    const copied=await runtime.read(target,Uint32Array,24,page-4);
    if(copied.some((value,i)=>value!==(i+1)*11))throw Error('Native copy or upload failed across unequal page boundaries');
    checks.push('GPU copy across unequal 64 MiB page boundaries and upload snapshot ownership');
    if(typeof SharedArrayBuffer!=='undefined') {
      const heap=new Uint32Array(new SharedArrayBuffer(32));heap.set([71,72,73,74],2);
      const before=runtime.stats.borrowedUploadBytes;
      runtime.writeBorrowed(target,heap.subarray(2,6),page-4);
      const output=await runtime.read(target,Uint32Array,16,page-4);
      if(output.some((v,i)=>v!==71+i)||runtime.stats.borrowedUploadBytes-before!==16)throw Error('Borrowed shared heap upload failed');
      checks.push('Borrowed shared-WASM-shaped heap view across a GPU page boundary');
    }
    await runtime.idle();
  } finally {runtime.destroyBuffer(source);runtime.destroyBuffer(target);}

  // Grow a live atlas while earlier commands and reads are queued. Retiring
  // its old version must keep shared prefix pages alive for the replacement.
  const beforeGrowth=runtime.createBuffer(page+16,{label:'Native growth source'});
  let afterGrowth;
  try {
    runtime.write(beforeGrowth,new Uint32Array([17]),0);
    runtime.write(beforeGrowth,new Uint32Array([21,22,23,24,25,26]),page-8);
    const oldRead=runtime.read(beforeGrowth,Uint32Array,24,page-8);
    const sharedBefore=runtime.reservedSharedBytes;
    afterGrowth=runtime.growBuffer(beforeGrowth,page+32,{label:'Native growth replacement'});
    if(runtime.reservedSharedBytes-sharedBefore!==65536)throw Error('Native growth duplicated a full prefix page');
    runtime.write(afterGrowth,new Uint32Array([31,32,33,34]),page+16);
    runtime.destroyBuffer(beforeGrowth);
    if((await oldRead).some((word,i)=>word!==21+i))throw Error('Growth changed the version of an earlier readback');
    const grown=await runtime.read(afterGrowth,Uint32Array,40,page-8);
    const expected=[21,22,23,24,25,26,31,32,33,34];
    if(grown.some((word,i)=>word!==expected[i])||(await runtime.read(afterGrowth,Uint32Array,4))[0]!==17)
      throw Error('Native growth failed to preserve shared pages or the partial tail');
    runtime.write(afterGrowth,new Uint32Array([41,42]),page-4);
    const updated=await runtime.read(afterGrowth,Uint32Array,8,page-4);
    if(updated[0]!==41||updated[1]!==42)throw Error('Native growth replacement became unusable after old-version retirement');
    checks.push('Atlas growth reuses shared pages, preserves the partial tail, orders readbacks and survives old-version retirement');
  } finally {
    if(!beforeGrowth.destroyed)runtime.destroyBuffer(beforeGrowth);
    if(afterGrowth)runtime.destroyBuffer(afterGrowth);
  }

  // A row straddles the 64 MiB boundary at this padded stride. Exercise the
  // actual GPU buffer-to-texture copies and sample both sides of that row.
  const width=2049,height=8192,rowPixels=2112,rowBytes=rowPixels*4;
  const pixels=runtime.createBuffer(rowBytes*height,{label:'Native paged presentation check'});
  const device=runtime.device;
  const texture=device.createTexture({size:[width,height],format:'rgba8unorm',usage:GPUTextureUsage.COPY_SRC|GPUTextureUsage.COPY_DST});
  const staging=device.createBuffer({size:4*256,usage:GPUBufferUsage.COPY_DST|GPUBufferUsage.MAP_READ});
  try {
    const y=Math.floor(page/rowBytes),x=(page-y*rowBytes)/4;
    if(x<=0||x>=width)throw Error('Presentation fixture no longer straddles a visible row');
    const points=[[0,0,0xff000011],[x-1,y,0xff002200],[x,y,0xff330000],[width-1,height-1,0xff445566]];
    for(const [px,py,word] of points)runtime.write(pixels,new Uint32Array([word]),py*rowBytes+px*4);
    await runtime.presentBuffer(pixels,{getCurrentTexture:()=>texture},width,height,rowPixels);
    const encoder=device.createCommandEncoder();
    points.forEach(([px,py],i)=>encoder.copyTextureToBuffer({texture,origin:[px,py,0]},
      {buffer:staging,offset:i*256,bytesPerRow:256},[1,1,1]));
    device.queue.submit([encoder.finish()]);await staging.mapAsync(GPUMapMode.READ);
    const result=new Uint32Array(staging.getMappedRange());
    points.forEach(([, ,word],i)=>{if(result[i*64]!==word)throw Error(`Native presentation mismatch at sample ${i}`);});
    staging.unmap();checks.push('Real GPU presentation copies preserve both sides of a split row, first pixel and last pixel');
  } finally {runtime.destroyBuffer(pixels);staging.destroy();texture.destroy();}
  await runtime.idle();
  return checks;
}
