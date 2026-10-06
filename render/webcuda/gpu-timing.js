// Host diagnostics only. Timestamp queries measure a single compute pass;
// shader arithmetic and rendering remain in generated CUDA kernels.
export function gpuTimedBatch(runtime,enabled,label) {
  const device=runtime.device,resources=[];
  const timed=enabled&&runtime.backend!=='native-cuda-paged'&&device.features.has('timestamp-query');
  let querySet,resolve,readback,submitted=false;
  const dispose=()=>{for(const resource of resources)resource.destroy();resources.length=0;};
  try {
    if(timed) {
      querySet=device.createQuerySet({type:'timestamp',count:2});resources.push(querySet);
      resolve=device.createBuffer({size:16,usage:GPUBufferUsage.QUERY_RESOLVE|GPUBufferUsage.COPY_SRC});resources.push(resolve);
      readback=device.createBuffer({size:16,usage:GPUBufferUsage.COPY_DST|GPUBufferUsage.MAP_READ});resources.push(readback);
    }
    const batch=runtime.batch(timed?{label,timestampWrites:{querySet,beginningOfPassWriteIndex:0,endOfPassWriteIndex:1}}:{label});
    return {batch,dispose,submit() {
      if(submitted)throw Error('Timed batch already submitted');
      submitted=true;
      try {
        batch.endPass();
        if(timed) {
          batch.encoder.resolveQuerySet(querySet,0,2,resolve,0);
          batch.encoder.copyBufferToBuffer(resolve,0,readback,0,16);
        }
        batch.submit();
      } catch(error){dispose();throw error;}
      if(!timed)return Promise.resolve({gpuMs:null});
      return readback.mapAsync(GPUMapMode.READ).then(()=>{
        const values=new BigUint64Array(readback.getMappedRange());
        const elapsed=values[1]-values[0];
        readback.unmap();
        return {gpuMs:elapsed>0n?Number(elapsed)/1e6:null};
      }).catch(error=>({error})).finally(dispose);
    }};
  } catch(error){dispose();throw error;}
}
