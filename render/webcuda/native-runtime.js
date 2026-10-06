import { dispatchGroups } from './dispatch.js';
import { NATIVE_PAGE_BYTES, NATIVE_ALLOCATION_ALIGNMENT, pageRanges, canvasPageCopies } from './native-layout.js';

const aligned=n=>Math.ceil(n/NATIVE_ALLOCATION_ALIGNMENT)*NATIVE_ALLOCATION_ALIGNMENT;
const scalarChecks={u32:n=>Number.isInteger(n)&&n>=0&&n<=0xffffffff,
  i32:n=>Number.isInteger(n)&&n>=-2147483648&&n<=2147483647,
  f32:n=>typeof n==='number'&&Number.isFinite(n)&&Number.isFinite(Math.fround(n))};

// Host transport and lifetime management only. Every compute operation uses
// authored CUDA. Large logical buffers consist of browser-owned shared pages;
// their address tables are CUDA-owned and never read back to JavaScript.
export class NativeRendererRuntime {
  static async create(base,{onError=()=>{}}={}) {
    const native=await base.enableNativeInterop({requirements:{sharedBuffers:true,nativeOwnedBuffers:true,
      gpuBufferToTexture:true,maxResourceBytes:NATIVE_PAGE_BYTES}});
    if(!native)throw Error(`Native rendering unavailable: ${base.nativeInteropStatus?.reason??'resource requirements not met'}`);
    const kernels={};
    for(const name of ['omw_set_page','omw_copy_pages']) {
      const response=await fetch(new URL(`generated/${name}.native.json`,import.meta.url));
      if(!response.ok)throw Error(`Missing native storage kernel ${name}`);
      kernels[name]=await native.kernel(await response.json());
    }
    return new NativeRendererRuntime(base,native,kernels,onError);
  }
  constructor(base,native,kernels,onError) {
    Object.assign(this,{base,native,kernels,onError,device:base.device,adapter:base.adapter});
    this.backend='native-cuda-paged';this.artifactSuffix='.native-paged.json';
    this.uniformAlignment=256;this.uniformCapacity=65536;
    this.buffers=new Set();this.tail=Promise.resolve();this.pendingOperations=null;this.failure=null;this.disposed=false;this.closing=false;
    this.reservedSharedBytes=0;this.reservedPages=0;this.reservedTables=0;this.reservedTableBytes=0;
    this.kernelCache=new Map();
    this.stats={pipelineCompiles:0,pipelineCacheHits:0,submissions:0,dispatches:0,dataBytesUploaded:0,
      bufferGrowths:0,reusedGrowthBytes:0,recordedBatches:0,coalescedBatches:0,
      borrowedUploadBytes:0,copiedUploadBytes:0,readbackBytes:0,pageBindingDispatches:0,peakSharedBytes:0,peakSharedPages:0};
  }
  assertAlive() {this.base.assertAlive();if(this.disposed||this.closing)throw Error('Native renderer is disposed');if(this.failure)throw this.failure;}
  checkResource(resource) {
    this.assertAlive();if(!resource||resource.runtime!==this||resource.destroyed)throw Error('Native buffer is destroyed or belongs to another runtime');
  }
  enqueue(work,{cleanup=false}={}) {
    // Uploads, readbacks, allocation, presentation and destruction terminate
    // the current compute group. Never move native work across a host/GPU
    // transfer or an ownership change.
    this.pendingOperations=null;
    const result=this.tail.then(()=>{
      // Closing rejects new public calls, but work already accepted before
      // dispose() must still reach its native ownership handoff.
      if(!cleanup){this.base.assertAlive();if(this.disposed)throw Error('Native renderer is disposed');if(this.failure)throw this.failure;}
      return work();
    });
    this.tail=result.catch(error=>{if(!this.failure){this.failure=error;this.onError(error);}});
    return result;
  }
  createBuffer(dataOrBytes,{label='OpenMW native buffer',usage=0}={}) {
    this.assertAlive();if(usage)throw Error('Native renderer buffers do not support WebGPU-specific usage flags');
    const data=ArrayBuffer.isView(dataOrBytes)?dataOrBytes:null,byteLength=data?data.byteLength:dataOrBytes;
    const resource=this.allocateBuffer(byteLength,label);
    if(data)this.write(resource,data);
    return resource;
  }
  // Scratch growth aliases complete existing pages, just as reuse without
  // growth aliases the old contents. The caller must submit all old users
  // before writing the replacement. Each version retains its own address table
  // and page references until retirement; queued commands never see a changed
  // page list. Only the partial tail needs replacement and a preserving copy.
  growBuffer(previous,byteLength,{label=previous?.label}={}) {
    this.checkResource(previous);
    if(byteLength<=previous.byteLength)throw RangeError('Native buffer growth must increase its size');
    return this.allocateBuffer(byteLength,label,previous);
  }
  allocateBuffer(byteLength,label,previous=null) {
    const limit=Math.min(this.device.limits.maxBufferSize,this.device.limits.maxStorageBufferBindingSize);
    if(!Number.isSafeInteger(byteLength)||byteLength<0||byteLength%4||byteLength>limit)throw RangeError('Invalid native renderer buffer size');
    const size=Math.max(4,byteLength),ranges=pageRanges(size);
    const allocations=ranges.map(range=>{
      const old=previous?.allocations[range.page];
      return old&&old.byteLength>=range.byteLength?old:
        {byteLength:range.byteLength,sharedBytes:aligned(range.byteLength),references:0,handle:null};
    });
    const fresh=allocations.filter(page=>page.references===0),sharedBytes=fresh.reduce((n,page)=>n+page.sharedBytes,0);
    const tableBytes=ranges.length*8,caps=this.native.capabilities;
    if(this.reservedPages+fresh.length>caps.maxResources||this.reservedSharedBytes+sharedBytes>caps.maxSharedBytes
      ||this.reservedTables+1>256||this.reservedTableBytes+tableBytes>caps.maxNativeOwnedBytes)
      throw RangeError(`Native renderer allocation budget exceeded for ${label} (${size} bytes): `+
        `shared ${this.reservedSharedBytes+sharedBytes}/${caps.maxSharedBytes} bytes, `+
        `pages ${this.reservedPages+fresh.length}/${caps.maxResources}, tables ${this.reservedTables+1}/256`);
    for(const page of allocations)page.references++;
    this.reservedPages+=fresh.length;this.reservedSharedBytes+=sharedBytes;this.reservedTables++;this.reservedTableBytes+=tableBytes;
    this.stats.peakSharedBytes=Math.max(this.stats.peakSharedBytes,this.reservedSharedBytes);
    this.stats.peakSharedPages=Math.max(this.stats.peakSharedPages,this.reservedPages);
    const resource={runtime:this,byteLength,size,label,destroyed:false,pages:[],table:null,allocations,tableBytes,pageCount:ranges.length,released:false};
    this.buffers.add(resource);
    resource.ready=this.enqueue(async()=>{
      try {
        resource.table=await this.native.createDeviceBuffer(tableBytes,{label:`${label} page table`});
        for(let slot=0;slot<allocations.length;slot++) {
          const page=allocations[slot];
          page.handle??=await this.native.createBuffer(page.byteLength,{label:`${label} page ${slot}`});
          resource.pages.push(page.handle);
        }
        if(previous) {
          // Shared prefix pages already retain their bytes. Copy only a tail
          // whose allocation grew, before any new uploads or dispatches.
          for(let slot=0;slot<previous.allocations.length;slot++)if(allocations[slot]!==previous.allocations[slot]) {
            const offset=slot*NATIVE_PAGE_BYTES,bytes=Math.min(previous.size-offset,previous.allocations[slot].byteLength);
            await this.submitOperations([{kernel:this.kernels.omw_copy_pages,
              resources:{source_pages:previous,target_pages:resource},
              scalars:{source_offset:offset/4,target_offset:offset/4,word_count:bytes/4},
              groups:dispatchGroups(bytes/4,this.device.limits)}]);
          }
        }
      } catch(error) {await this.releasePhysical(resource);throw error;}
    });
    if(previous){this.stats.bufferGrowths++;this.stats.reusedGrowthBytes+=allocations.filter(page=>!fresh.includes(page)).reduce((n,page)=>n+page.sharedBytes,0);}
    return resource;
  }
  async releasePhysical(resource) {
    if(resource.released)return;
    resource.released=true;
    // Page destruction and table destruction are ordered in NativeInterop.
    // Await the latter before returning the freed capacity to the budget.
    const released=resource.allocations.filter(page=>--page.references===0);
    for(const page of released)if(page.handle&&!page.handle.destroyed)this.base.destroyBuffer(page.handle);
    resource.pages=[];
    if(resource.table&&!resource.table.destroyed)await this.native.destroyDeviceBuffer(resource.table);
    else if(released.some(page=>page.handle))await this.native.idle();
    resource.table=null;
    this.reservedPages-=released.length;this.reservedSharedBytes-=released.reduce((n,page)=>n+page.sharedBytes,0);
    this.reservedTables--;this.reservedTableBytes-=resource.tableBytes;
  }
  destroyBuffer(resource) {
    this.checkResource(resource);resource.destroyed=true;this.buffers.delete(resource);
    this.enqueue(()=>this.releasePhysical(resource),{cleanup:true});
  }
  write(resource,data,offset=0) {return this.upload(resource,data,offset,false);}
  // The engine owns these immutable WASM packets until the accepted frame's
  // idle() completes. Explicit borrowing preserves direct heap-view uploads.
  writeBorrowed(resource,data,offset=0) {return this.upload(resource,data,offset,true);}
  upload(resource,data,offset,borrowed) {
    this.checkResource(resource);
    if(!ArrayBuffer.isView(data))throw TypeError('Expected an upload view');
    const ranges=pageRanges(resource.size,offset,data.byteLength);
    const view=new Uint8Array(data.buffer,data.byteOffset,data.byteLength);
    const bytes=borrowed?view:view.slice();
    this.stats.dataBytesUploaded+=bytes.byteLength;
    this.stats[borrowed?'borrowedUploadBytes':'copiedUploadBytes']+=bytes.byteLength;
    this.enqueue(()=>{
      for(const range of ranges)this.base.write(resource.pages[range.page],bytes.subarray(range.offset,range.offset+range.byteLength),range.pageOffset);
    });
  }
  async read(resource,Type=Float32Array,byteLength=resource.byteLength,offset=0) {
    this.checkResource(resource);
    if(![Float32Array,Uint32Array,Int32Array].includes(Type))throw TypeError('Readback supports 32-bit arrays');
    const ranges=pageRanges(resource.size,offset,byteLength);
    let reads;
    await this.enqueue(()=>{
      // Queue the WebGPU copies now. Do not block subsequent native submissions
      // on CPU mapping; fences preserve the source version of each readback.
      reads=ranges.map(range=>this.base.read(resource.pages[range.page],Type,range.byteLength,range.pageOffset));
      for(const read of reads)read.catch(()=>{});
    });
    const result=new Type(byteLength/4),parts=await Promise.all(reads);
    for(let i=0;i<parts.length;i++)result.set(parts[i],ranges[i].offset/4);
    this.stats.readbackBytes+=byteLength;return result;
  }
  async kernel(artifact) {
    this.assertAlive();
    if(artifact.native?.storage!=='openmw-paged-64m-v1'||!artifact.metadata)throw Error('Expected an OpenMW native paged artifact');
    const key=JSON.stringify(artifact.native);
    if(this.kernelCache.has(key)){this.stats.pipelineCacheHits++;return this.kernelCache.get(key);}
    const native=await this.native.kernel(artifact);
    const runtime=this,parameters=artifact.native.parameters,defaults=artifact.native.defaults??{};
    const checkScalars=values=>{
      for(const [name,value] of Object.entries(values)) {
        const param=parameters.find(p=>p.name===name&&p.type!=='buffer');
        if(!param||!scalarChecks[param.type]?.(value))throw RangeError(`Invalid native scalar ${name}`);
      }
    };
    const kernel={runtime,native,artifact,bind(resources,scalars={}) {
      const values={...defaults,...scalars};checkScalars(values);
      for(const key of Object.keys(resources))if(!parameters.some(p=>p.name===key&&p.type==='buffer'))throw Error(`Unknown buffer ${key}`);
      for(const param of parameters) {
        if(param.type==='buffer')runtime.checkResource(resources[param.name]);
        else if(!Object.hasOwn(values,param.name))throw Error(`Missing scalar ${param.name}`);
      }
      return {kernel,resources:{...resources},scalars:values,setScalars(updates){checkScalars(updates);Object.assign(this.scalars,updates);return this;}};
    }};
    this.stats.pipelineCompiles++;this.kernelCache.set(key,kernel);return kernel;
  }
  batch() {this.assertAlive();return new NativeBatch(this);}
  enqueueOperations(operations) {
    this.assertAlive();this.stats.recordedBatches++;
    if(this.pendingOperations) {
      for(const operation of operations)this.pendingOperations.operations.push(operation);
      this.stats.coalescedBatches++;
      return this.pendingOperations.promise;
    }
    // Each logical submit still owns captured resources/scalars and returns a
    // completion promise. Consecutive submits can share one native fence cycle
    // until execution starts or a non-compute enqueue closes the group.
    const group={operations,promise:null};
    group.promise=this.enqueue(()=>{
      if(this.pendingOperations===group)this.pendingOperations=null;
      return this.submitOperations(group.operations);
    });
    this.pendingOperations=group;
    return group.promise;
  }
  async submitOperations(operations) {
    let batch=this.native.batch(),bound=new Set(),jobs=0;
    const flush=async()=>{if(jobs){await batch.submit();this.stats.submissions++;}batch=this.native.batch();bound=new Set();jobs=0;};
    for(const operation of operations) {
      const resources=[...new Set(Object.values(operation.resources))];
      const cost=1+resources.filter(r=>!bound.has(r)).reduce((n,r)=>n+r.pages.length,0);
      if(jobs+cost>256)await flush();
      const needed=1+resources.filter(r=>!bound.has(r)).reduce((n,r)=>n+r.pages.length,0);
      if(needed>256)throw RangeError('A native dispatch exceeds the shared page binding budget');
      for(const resource of resources)if(!bound.has(resource)) {
        for(let slot=0;slot<resource.pages.length;slot++) {
          batch.dispatch(this.kernels.omw_set_page.bind({table:resource.table,page:resource.pages[slot]},{slot}),[1,1,1]);
          jobs++;this.stats.pageBindingDispatches++;
        }
        bound.add(resource);
      }
      const tables=Object.fromEntries(Object.entries(operation.resources).map(([name,r])=>[name,r.table]));
      batch.dispatch(operation.kernel.bind(tables,operation.scalars),operation.groups);jobs++;this.stats.dispatches++;
    }
    await flush();
  }
  async presentBuffer(resource,context,width,height,rowPixels) {
    this.checkResource(resource);const copies=canvasPageCopies(resource.size,width,height,rowPixels);
    await this.enqueue(()=>{
      const encoder=this.device.createCommandEncoder(),texture=context.getCurrentTexture();
      for(const copy of copies) {
        const source={buffer:resource.pages[copy.page].gpuBuffer,offset:copy.offset};
        if(copy.bytesPerRow)source.bytesPerRow=copy.bytesPerRow;
        encoder.copyBufferToTexture(source,{texture,origin:{x:copy.x,y:copy.y}},[copy.width,copy.height,1]);
      }
      this.device.queue.submit([encoder.finish()]);
    });
  }
  async idle() {await this.tail;this.assertAlive();await this.base.idle();}
  async flushRetired() {await this.tail;this.assertAlive();}
  snapshot() {return {backend:this.backend,storageRevision:2,submissionRevision:1,sharedBytes:this.reservedSharedBytes,sharedPages:this.reservedPages,
    tables:this.reservedTables,tableBytes:this.reservedTableBytes,...this.stats,
    largestBuffers:[...this.buffers].sort((a,b)=>b.byteLength-a.byteLength).slice(0,8).map(b=>({label:b.label,bytes:b.byteLength,pages:b.pageCount}))};}
  describe() {return {...this.base.describe(),backend:this.backend,native:this.native.capabilities};}
  dispose() {
    if(this.disposal)return this.disposal;
    this.closing=true;
    this.disposal=(async()=>{
      // Let already-recorded work reach its ownership handoff before closing.
      await this.tail;
      try {await this.base.dispose();} finally {
        this.disposed=true;for(const buffer of this.buffers)buffer.destroyed=true;this.buffers.clear();this.kernelCache.clear();
        this.reservedSharedBytes=0;this.reservedPages=0;this.reservedTables=0;this.reservedTableBytes=0;
      }
    })();return this.disposal;
  }
}

class NativeBatch {
  constructor(runtime){this.runtime=runtime;this.operations=[];this.ended=false;}
  open(){if(this.ended)throw Error('Native batch is closed');this.runtime.assertAlive();}
  dispatch(invocation,groups,indirect=null) {
    this.open();if(indirect)throw Error('Native renderer does not use indirect dispatch');
    if(invocation.kernel.runtime!==this.runtime)throw Error('Kernel belongs to another native renderer');
    if(!Array.isArray(groups)||groups.length!==3||groups.some(n=>!Number.isInteger(n)||n<0||n>65535))throw RangeError('Invalid native renderer grid');
    for(const resource of Object.values(invocation.resources))this.runtime.checkResource(resource);
    if(groups.some(n=>!n))return this;
    this.operations.push({kernel:invocation.kernel.native,resources:{...invocation.resources},scalars:{...invocation.scalars},groups:[...groups]});return this;
  }
  copy(source,target,range) {
    this.open();this.runtime.checkResource(source);this.runtime.checkResource(target);
    if(source===target)throw RangeError('Copy requires distinct buffers');
    if(range===undefined&&source.byteLength!==target.byteLength)throw RangeError('Whole-buffer copy requires equal sizes');
    const {sourceOffset=0,targetOffset=0,byteLength=source.byteLength}=range??{};
    const from=pageRanges(source.size,sourceOffset,byteLength),to=pageRanges(target.size,targetOffset,byteLength);
    for(const a of from)for(const b of to)if(source.allocations[a.page]===target.allocations[b.page]
      &&a.pageOffset<b.pageOffset+b.byteLength&&b.pageOffset<a.pageOffset+a.byteLength)
      throw RangeError('Copy ranges overlap shared native pages');
    if(byteLength)this.operations.push({kernel:this.runtime.kernels.omw_copy_pages,resources:{source_pages:source,target_pages:target},
      scalars:{source_offset:sourceOffset/4,target_offset:targetOffset/4,word_count:byteLength/4},groups:dispatchGroups(byteLength/4,this.runtime.device.limits)});
    return this;
  }
  endPass(){this.open();}
  submit() {
    this.open();for(const op of this.operations)for(const resource of Object.values(op.resources))this.runtime.checkResource(resource);
    this.ended=true;const operations=this.operations;this.operations=[];
    return this.runtime.enqueueOperations(operations);
  }
  discard(){this.ended=true;this.operations=[];}
}
