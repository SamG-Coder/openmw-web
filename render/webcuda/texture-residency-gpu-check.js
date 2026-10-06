import {TextureResidency} from './texture-residency.js';
import {atlasUploadRanges} from './atlas-upload.js';

export async function checkTextureResidencyGpu(runtime) {
  const cache=new TextureResidency(runtime,{budgetBytes:168}),resources=[];
  const buffer=data=>{const result=runtime.createBuffer(data);resources.push(result);return result;};
  try {
    const [decode,mip]=await Promise.all(['decode_dxt','generate_mip'].map(async name=>
      runtime.kernel(await (await fetch(`./generated/${name}.json`)).json())));
    const atlas=buffer(new Uint32Array(40)),blocks=buffer(new Uint32Array(2));let decodes=0;
    async function frame(id,offset,encoded) {
      const cpu=new Uint32Array(40).fill(0xcafebabe),plan=cache.plan(new Uint32Array([id,offset,21]),40);
      cpu.fill(0,offset,offset+21);
      const before=runtime.stats.dataBytesUploaded;
      for(const [first,last] of atlasUploadRanges(cpu.length,new Uint32Array(),cpu.length,plan.hitRanges))
        runtime.write(atlas,cpu.subarray(first,last),first*4);
      cache.restore(plan,atlas);
      if(!plan.isResident(offset,21)) {
        runtime.write(blocks,new Uint32Array(encoded));decodes++;
        runtime.batch().dispatch(decode.bind({blocks,pixels:atlas},{width:4,height:4,format:1,block_offset:0,pixel_offset:offset}),[1,1,1])
          .dispatch(mip.bind({texels:atlas},{source:offset,destination:offset+16,width:4,height:4}),[1,1,1])
          .dispatch(mip.bind({texels:atlas},{source:offset+16,destination:offset+20,width:2,height:2}),[1,1,1]).submit();
      }
      cache.capture(plan,atlas);
      const uploaded=runtime.stats.dataBytesUploaded-before,pixels=await runtime.read(atlas,Uint32Array);
      for(let i=0;i<pixels.length;i++)if((i<offset||i>=offset+21)&&pixels[i]!==cpu[i])throw Error('Resident restore overwrote neighboring atlas metadata');
      return {pixels:pixels.slice(offset,offset+21),uploaded};
    }
    const cold=await frame(1,2,[0x001ff800,0]);
    // Poisoned source data must not be read when immutable version 1 is resident.
    const warm=await frame(1,9,[0,0]);
    if(cold.pixels.some((value,i)=>value!==warm.pixels[i])||warm.pixels.some(value=>value!==0xff0000ff))throw Error('Resident DXT/mip chain changed after atlas relocation');
    const dirty=await frame(2,9,[0x001f07e0,0]);
    if(dirty.pixels.some(value=>value!==0xff00ff00)||decodes!==2)throw Error('Dirty image version did not decode anew');
    if(cold.uploaded!==168||warm.uploaded!==76)throw Error('Warm texture upload included resident image data');
    return `resident CUDA DXT/mips preserved across atlas relocation; dirty version updated (${cold.uploaded} cold versus ${warm.uploaded} warm bytes)`;
  } finally {await runtime.idle();cache.dispose();for(const resource of resources)runtime.destroyBuffer(resource);}
}
