import { boundedBatch } from './bounded-batch.js';
export async function checkBoundedBatchGpu(runtime,kernel) {
  const count=1000,source=runtime.createBuffer(4),result=runtime.createBuffer(count*4);
  try {
    const before=runtime.stats.submissions,batch=boundedBatch(runtime);
    for(let i=0;i<count;i++)batch.dispatch(kernel.bind({target:source},{pixel_count:1,depth:i}),[1,1,1])
      .copy(source,result,{sourceOffset:0,targetOffset:i*4,byteLength:4});
    batch.submit();
    const submissions=runtime.stats.submissions-before;
    const values=await runtime.read(result);
    for(let i=0;i<count;i++)if(values[i]!==i)throw Error(`Split batch order failed at ${i}: ${values[i]}`);
    if(submissions<2)throw Error('Uniform capacity split was not exercised');
    return [`${count} CUDA dispatch/copy snapshots preserved across ${submissions} submissions`];
  } finally {runtime.destroyBuffer(source);runtime.destroyBuffer(result);}
}
