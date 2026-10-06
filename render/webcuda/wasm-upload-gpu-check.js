// Verify the browser accepts a shared WASM heap directly as an upload source.
// This tests transport and lifetime, not engine integration or shader rendering.
export async function checkWasmUploadGpu(runtime) {
  const memory=new WebAssembly.Memory({initial:1,maximum:2,shared:true});
  const target=runtime.createBuffer(16,{label:'direct WASM upload check'});
  const checks=[];
  let originalView;
  try {
    for(const offset of [128,65536]) {
      if(offset>=memory.buffer.byteLength)memory.grow(1);
      const view=new Uint32Array(memory.buffer,offset,4);
      if(offset===128)originalView=view;
      for(let i=0;i<4;i++)view[i]=offset+i+1;
      // No .slice(), copied typed array or private JS staging allocation.
      runtime.device.queue.writeBuffer(target.gpuBuffer,0,memory.buffer,offset,16);
      // writeBuffer snapshots the input before returning. Reusing the heap
      // immediately must not alter the already queued upload.
      view.fill(0);
      const result=await runtime.read(target,Uint32Array);
      for(let i=0;i<4;i++)if(result[i]!==offset+i+1)throw Error('Direct WASM upload lost its snapshot');
      checks.push(offset===128?'shared WASM heap uploads directly; immediate source reuse is safe':'direct shared WASM upload works after heap growth');
    }
    // Deferred engine passes can retain an older SharedArrayBuffer object
    // while later native allocations grow the same WebAssembly memory.
    originalView.fill(0xffffffff);
    runtime.write(target,originalView);
    const retained=await runtime.read(target,Uint32Array);
    if(retained.some(value=>value!==0xffffffff))throw Error('Pre-growth heap view lost its backing storage or bits');
    checks.push('retained pre-growth WASM view uploads correctly, preserving all 32 bits');
    return checks;
  } finally {runtime.destroyBuffer(target);}
}
