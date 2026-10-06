// Test the generated CUDA kernel, including scalar atlas offsets and guards.
export async function checkDepthImageGpu(runtime,kernel) {
  const input=new Float32Array([42,Infinity,.25,-1,2,43]);
  const initial=new Float32Array([123,0,0,0,0,456]);
  const blocks=runtime.createBuffer(input,{label:'depth image input with offset'});
  const pixels=runtime.createBuffer(initial,{label:'depth image scalar atlas with guards'});
  const checks=[];
  try {
    for(const storage of [0,1,2]) {
      runtime.write(pixels,initial);
      runtime.batch().dispatch(kernel.bind({blocks,pixels},{width:4,height:1,
        format:65536|(9<<8)|(storage<<12)|9,block_offset:1,pixel_offset:1}),[1,1,1]).submit();
      const output=await runtime.read(pixels);
      const expected=storage===0?[Infinity,.25,-1,2]:[1,storage===1?16384/65535:4194304/16777215,0,1];
      for(let i=0;i<4;i++) {
        if(output[i+1]!==expected[i]&&(!Number.isFinite(output[i+1])||Math.abs(output[i+1]-expected[i])>1e-7))
          throw Error(`Depth storage ${storage}, pixel ${i}: expected ${expected[i]}, got ${output[i+1]}`);
      }
      if(output[0]!==123||output[5]!==456)throw Error(`Depth storage ${storage}: atlas guard overwritten`);
      checks.push(`depth image ${storage===0?'float infinity':storage===1?'normalized16':'normalized24'} with source/destination offsets and guards`);
    }
    return checks;
  } finally {runtime.destroyBuffer(blocks);runtime.destroyBuffer(pixels);}
}
