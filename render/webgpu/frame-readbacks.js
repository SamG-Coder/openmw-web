// Snapshot small pass results on the GPU, then map them together after the
// frame's commands have been queued. The owning pipeline retains the buffer
// until queue completion; this collector never destroys shared resources.
export class FrameReadbacks {
  constructor(runtime, acquireBuffer, capacity=64*1024) {
    const limits=runtime.device.limits;
    if(!Number.isSafeInteger(capacity)||capacity<=0||capacity%4)
      throw RangeError('Invalid frame readback capacity');
    this.capacity=Math.min(capacity,Math.floor(Math.min(limits.maxBufferSize,limits.maxStorageBufferBindingSize)/4)*4);
    this.runtime=runtime;this.acquireBuffer=acquireBuffer;
    this.buffer=null;this.bytes=0;this.records=[];this.closed=false;this.completion=null;
  }
  read(source,Type=Uint32Array,byteLength=source.byteLength,offset=0) {
    if(this.closed)throw Error('Frame readbacks are closed');
    if(![Uint32Array,Int32Array,Float32Array].includes(Type))throw TypeError('Readback supports 32-bit arrays');
    if(![byteLength,offset].every(value=>Number.isSafeInteger(value)&&value>=0&&value%4===0)
      ||offset+byteLength>source.byteLength)throw RangeError('Invalid frame readback range');
    if(!byteLength)return Promise.resolve(new Type());
    // Large query sets retain the ordinary ordered read path. No unbounded
    // staging allocation or loss of validation when the frame exceeds 64 KiB.
    if(byteLength>this.capacity-this.bytes)return this.runtime.read(source,Type,byteLength,offset);
    this.buffer??=this.acquireBuffer(this.capacity);
    const targetOffset=this.bytes;
    this.runtime.batch().copy(source,this.buffer,{sourceOffset:offset,targetOffset,byteLength}).submit();
    this.bytes+=byteLength;
    const completion=new Promise((resolve,reject)=>this.records.push({Type,byteLength,offset:targetOffset,resolve,reject}));
    // A later dispatch can fail before the caller joins pass completions.
    completion.catch(()=>{});
    return completion;
  }
  flush() {
    if(this.completion)return this.completion;
    if(this.closed)throw Error('Frame readbacks are closed');
    this.closed=true;
    if(!this.bytes)return this.completion=Promise.resolve();
    let read;
    try {read=this.runtime.read(this.buffer,Uint32Array,this.bytes);}
    catch(error){read=Promise.reject(error);}
    this.completion=Promise.resolve(read).then(values=>{
      if(values.byteLength!==this.bytes)throw Error('Incomplete frame readback');
      for(const record of this.records)record.resolve(new record.Type(values.buffer,values.byteOffset+record.offset,record.byteLength/4));
      this.records=[];
    }).catch(error=>{this.cancel(error);throw error;});
    return this.completion;
  }
  cancel(error) {
    this.closed=true;
    for(const record of this.records)record.reject(error);
    this.records=[];
  }
}
