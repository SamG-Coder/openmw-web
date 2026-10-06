// Inputs/readback only; all layout conversion is authored in compact-depth.cu.
import { dispatchGroups } from './dispatch.js';
export async function checkFullSizeDepthGpu(runtime,kernel) {
  const count=8192*8192,bytes=count*4;
  const target=runtime.createBuffer(bytes+16,{label:'8192x8192 compact depth with guard'});
  try {
    runtime.write(target,new Float32Array([91,92,93,94]),bytes);
    runtime.batch().dispatch(kernel.bind({target},{pixel_count:count,depth:.375}),dispatchGroups(count,runtime.device.limits)).submit();
    for(const index of [0,8191,8192,count/2,count-1]) {
      const value=await runtime.read(target,Float32Array,4,index*4);
      if(value[0]!==.375)throw Error(`8192 depth clear failed at ${index}: ${value[0]}`);
    }
    const guards=await runtime.read(target,Float32Array,16,bytes);
    if(guards.some((v,i)=>v!==91+i))throw Error('8192 depth clear overwrote guard');
    return ['8192x8192 compact allocation, CUDA clear, first/row/middle/last samples and trailing guards'];
  } finally {runtime.destroyBuffer(target);}
}
export async function checkCompactDepthGpu(runtime,exportKernel) {
  const kernels={compact_depth_to_texture:exportKernel};
  for(const name of ['clear_compact_depth','copy_depth_layout','copy_resolved_attachment']) {
    const response=await fetch(`generated/${name}${runtime.artifactSuffix??'.json'}`);
    if(!response.ok)throw Error(`Missing ${name}`);
    kernels[name]=await runtime.kernel(await response.json());
  }
  const initial=new Float32Array([.125,.25,.5,.75,99,99]);
  const compact=runtime.createBuffer(initial);
  const fullInitial=new Float32Array(42);fullInitial.fill(99);
  const full=runtime.createBuffer(fullInitial);
  const texels=runtime.createBuffer(new Uint32Array([123,0,0,0,0,456]));
  const equal=(actual,expected,label)=>{
    if(actual.length!==expected.length||actual.some((v,i)=>v!==expected[i]))throw Error(`${label}: ${actual}`);
  };
  try {
    runtime.batch().dispatch(kernels.copy_depth_layout.bind({source:compact,target:full},
      {pixel_count:4,source_compact:1,target_compact:0}),[1,1,1]).submit();
    const expanded=await runtime.read(full);
    const expected=fullInitial.slice();for(let i=0;i<4;i++)expected[i*9+4]=initial[i];
    equal(expanded,expected,'compact to full, including untouched planes and guards');
    runtime.write(compact,new Float32Array([0,0,0,0,99,99]));
    runtime.batch().dispatch(kernels.copy_depth_layout.bind({source:full,target:compact},
      {pixel_count:4,source_compact:0,target_compact:1}),[1,1,1])
      .dispatch(exportKernel.bind({target:compact,texels},{width:2,height:2,offset:1}),[1,1,1]).submit();
    equal(await runtime.read(compact),initial,'full to compact with guards');
    const bits=new Uint32Array(initial.buffer);
    equal(await runtime.read(texels,Uint32Array),new Uint32Array([123,bits[2],bits[3],bits[0],bits[1],456]),'texture flip, offset and guards');
    runtime.batch().dispatch(kernels.clear_compact_depth.bind({target:compact},{pixel_count:4,depth:.625}),[1,1,1]).submit();
    equal(await runtime.read(compact),new Float32Array([.625,.625,.625,.625,99,99]),'scalar depth clear with guards');
    runtime.batch().dispatch(kernels.copy_resolved_attachment.bind({source:full,target:compact},
      {width:2,height:2,plane:1,color_channels:4,color_storage:0,depth_bits:16,
       viewport_x:0,viewport_y:0,viewport_width:1,viewport_height:1,source_compact:0,target_compact:1}),[1,1,1]).submit();
    equal(await runtime.read(compact),new Float32Array([.625,.625,32768/65535,.625,99,99]),'partial compact resolve and depth quantization');
    return ['compact/full depth transfers preserve other planes','depth texture vertical orientation and offset','compact clear and buffer guards','partial depth resolve preserves outside pixels and quantizes depth16'];
  } finally {for(const buffer of [compact,full,texels])runtime.destroyBuffer(buffer);}
}
