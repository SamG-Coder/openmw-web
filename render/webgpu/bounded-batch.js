// Preserve dispatch/copy order while bounding each submission's uniform arena.
// Treat every dispatch as a new snapshot: this can split conservatively when an
// invocation is reused, but never depends on runtime snapshot-cache internals.
export function boundedBatch(runtime) {
  let batch=null,cursor=0,ended=false;
  const alignment=runtime.uniformAlignment,capacity=runtime.uniformCapacity;
  if(!Number.isSafeInteger(alignment)||alignment<=0||!Number.isSafeInteger(capacity)||capacity<=0)
    throw RangeError('Invalid runtime uniform arena');
  const open=()=>{if(ended)throw Error('Batch already submitted');};
  const ensure=()=>batch??=runtime.batch();
  const api={
    dispatch(invocation,groups,indirect=null) {
      open();
      const size=invocation.kernel.artifact.metadata.uniformSize;
      if(!Number.isSafeInteger(size)||size<0||size>capacity)throw RangeError('Invocation exceeds uniform arena capacity');
      let next=size?Math.ceil(cursor/alignment)*alignment+size:cursor;
      if(next>capacity) {batch.submit();batch=null;cursor=0;next=size;}
      ensure().dispatch(invocation,groups,indirect);cursor=next;return api;
    },
    copy(source,target,range) {open();ensure().copy(source,target,range);return api;},
    submit() {open();ended=true;if(batch)batch.submit();},
  };
  return api;
}
