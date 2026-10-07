// Exercise the actual host's asynchronous ownership boundaries. GPU execution
// is controlled here; actual shared-WASM uploads and gameplay are tested in browser.
import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
import {WASM_FRAME_MAGIC,WASM_FRAME_VERSION,SCENE_VIEWS,DIRECT_GPU_NAMES} from './wasm-frame.js';

const deferred=()=>{let resolve;const promise=new Promise(done=>{resolve=done;});return {promise,resolve};};
async function until(predicate,message='Host did not reach expected boundary') {
  const deadline=performance.now()+2000;
  do {if(predicate())return;await new Promise(setImmediate);} while(performance.now()<deadline);
  assert.fail(message);
}

async function fixture(t,{search=''}={}) {
  const renderGate=deferred(),idleGate=deferred(),readGate=deferred(),lost=deferred(),errors=[];
  const runtime={buffers:new Set(),stats:{dataBytesUploaded:0},idleCalls:0,renderCalls:0,renderError:null,
    readCalls:0,presentations:0,readError:null,submissions:0,renderSubmissions:0,
    fences:[],pendingFences:0,maxPendingFences:0,autoResolveFences:false,
    device:{limits:{maxTextureDimension2D:8192,maxStorageBufferBindingSize:2147483648,maxBufferSize:2147483648,maxComputeWorkgroupsPerDimension:65535},
      lost:lost.promise,addEventListener(){},removeEventListener(){},destroyCalls:0,destroy(){this.destroyCalls++;}},
    createBuffer(byteLength){const buffer={byteLength,data:new Uint8Array(byteLength)};this.buffers.add(buffer);return buffer;},
    destroyBuffer(buffer){assert(this.buffers.delete(buffer),'Buffer destroyed once');},
    batch(){return {dispatch(){return this;},copy(source,target,{sourceOffset=0,targetOffset=0,byteLength}){
      target.data.set(source.data.subarray(sourceOffset,sourceOffset+byteLength),targetOffset);return this;
    },submit(){runtime.submissions++;}};},
    async read(source,Type,bytes,offset=0){this.readCalls++;const snapshot=source.data.slice(offset,offset+bytes);
      await readGate.promise;if(this.readError)throw this.readError;return new Type(snapshot.buffer);},
    async presentBuffer(){this.presentations++;},
    fence(){
      const completion=deferred();this.fences.push(completion);this.pendingFences++;
      this.maxPendingFences=Math.max(this.maxPendingFences,this.pendingFences);
      completion.promise.then(()=>this.pendingFences--);
      if(this.autoResolveFences)completion.resolve();
      return completion.promise;
    },
    idle(){this.idleCalls++;return Promise.all([idleGate.promise,...this.fences.map(value=>value.promise)]);}};
  const scratch=new Map(),retired=new Set();
  const pipeline={kernels:{clear_target:{bind(){return {};}},pack_target:{bind(){return {};}}},prewarmCalls:0,
    prewarm(){this.prewarmCalls++;},
    async render(scene,width,height){
      runtime.renderCalls++;await renderGate.promise;if(runtime.renderError)throw runtime.renderError;
      runtime.batch().submit();runtime.renderSubmissions++;
      return {width,height,row_pixels:Math.ceil(width/64)*64,
        queryCompletion:Promise.resolve({queryResults:new Map(),diagnostic:{}})};
    },
    buffer(name,bytes){if(!scratch.has(name))scratch.set(name,runtime.createBuffer(bytes));return scratch.get(name);},
    collectRetired(){for(const resource of retired)runtime.destroyBuffer(resource);retired.clear();},
    deferRetired(completion){const resources=[...retired];retired.clear();
      Promise.resolve(completion).then(()=>{for(const resource of resources)runtime.destroyBuffer(resource);});},
    dispose(){this.collectRetired();for(const resource of scratch.values())runtime.destroyBuffer(resource);scratch.clear();},
    retireBuffer(resource){retired.add(resource);}};
  class Canvas {
    constructor(){this.dataset={};this.style={};this.parentElement={appendChild(){}};}
    setAttribute(){} remove(){} append(){} addEventListener(){}
    getContext(){return {configure(){},unconfigure(){}};}
    getBoundingClientRect(){return {left:0,top:0,width:16,height:8};}
  }
  const context=vm.createContext({console,performance,URLSearchParams,queueMicrotask,clearTimeout,
    setTimeout(callback,delay,...args){const timer=setTimeout(callback,delay,...args);if(delay>=15000)timer.unref();return timer;},
    Uint32Array,Float32Array,ArrayBuffer,Map,Set,HTMLCanvasElement:Canvas,
    ResizeObserver:class{observe(){} disconnect(){}},
    GPUTextureUsage:{COPY_DST:1,RENDER_ATTACHMENT:2},
    location:{search},document:{createElement(){return new Canvas();}},
    window:{addEventListener(){},removeEventListener(){}}});
  const synthetic=(name,values)=>new vm.SyntheticModule(Object.keys(values),function(){for(const [key,value] of Object.entries(values))this.setExport(key,value);},{context,identifier:name});
  const host=new vm.SourceTextModule(await readFile(new URL('./game-host.js',import.meta.url),'utf8'),{context});
  await host.link(async specifier=>{
    if(specifier==='./runtime.js')return synthetic(specifier,{WebGPURuntime:{create:async()=>runtime}});
    if(specifier==='./pipeline.js')return synthetic(specifier,{MaterialPipeline:{create:async()=>pipeline}});
    if(specifier==='./legacy-draw-guard.js')return synthetic(specifier,{guardLegacyRendering:()=>({attempts:0})});
    if(specifier==='./native-targets.js')return synthetic(specifier,{NativeAttachmentStore:class{
      destroy(){} dispose(){} snapshot(){return {};}
      canCamera(){return false;}
    }});
    return new vm.SourceTextModule(await readFile(new URL(specifier,import.meta.url),'utf8'),{context,identifier:specifier});
  });
  await host.evaluate();
  const Module={canvas:new Canvas()};
  const owner=await host.namespace.installWebGPU(Module,{onError:error=>errors.push(error)});
  const packet=()=>{
    const value={version:2,storage:'wasm-retained',width:16,height:8,
      scene:{vertices:new Float32Array([1]),textureDecodes:new Uint32Array()},releases:0};
    value.release=()=>{value.releases++;value.submissionsWhenReleased=runtime.renderSubmissions;};return value;
  };
  const submit=(value,targetId=1)=>{Module.webcudaPassState({targetId,clearMask:16384,clearDepth:1});Module.webcudaSubmitPass(value);};
  const cleanup=async()=>{
    runtime.autoResolveFences=true;for(const completion of runtime.fences)completion.resolve();
    renderGate.resolve();readGate.resolve();idleGate.resolve();await owner.dispose();
  };
  t.after(cleanup);
  return {Module,owner,runtime,pipeline,renderGate,idleGate,readGate,lost,errors,packet,submit,cleanup};
}

test('submitted frames release packets before GPU completion while capture and GPU queues each stay bounded to two',async t=>{
  const f=await fixture(t),packets=Array.from({length:4},()=>f.packet());
  const capture=packet=>{assert(f.Module.webcudaBeginFrame());f.submit(packet);f.Module.webcudaEndFrame(true);};
  capture(packets[0]);await until(()=>f.runtime.renderCalls===1);
  capture(packets[1]);assert.equal(f.Module.webcudaBeginFrame(),false);
  assert(packets.every(packet=>packet.releases===0));

  f.renderGate.resolve();await until(()=>packets[0].releases===1&&packets[1].releases===1);
  assert.equal(f.runtime.fences.length,2);assert.equal(f.runtime.pendingFences,2);
  assert.equal(f.runtime.idleCalls,0);
  assert.equal(packets[0].submissionsWhenReleased,1);assert.equal(packets[1].submissionsWhenReleased,2);

  // CPU capture may queue another two frames while both GPU fences are pending.
  capture(packets[2]);capture(packets[3]);assert.equal(f.Module.webcudaBeginFrame(),false);
  assert.equal(f.runtime.renderCalls,2);assert.equal(packets[2].releases,0);assert.equal(packets[3].releases,0);
  f.runtime.fences[0].resolve();await until(()=>packets[2].releases===1);
  assert.equal(f.runtime.renderCalls,3);assert.equal(packets[3].releases,0);
  f.runtime.fences[1].resolve();await until(()=>packets[3].releases===1);
  assert.equal(f.runtime.renderCalls,4);assert.equal(f.runtime.maxPendingFences,2);
  assert.equal(f.pipeline.prewarmCalls,4);assert.equal(f.errors.length,0);
  await f.cleanup();assert(packets.every(packet=>packet.releases===1));assert.equal(f.runtime.buffers.size,0);
});

test('aborted and invalid-commit frames release every captured pass without GPU submission',async t=>{
  const f=await fixture(t),a=f.packet(),b=f.packet();
  assert(f.Module.webcudaBeginFrame());f.submit(a);f.submit(b);
  f.Module.webcudaPassState({targetId:1});
  assert.throws(()=>f.Module.webcudaEndFrame(true),/camera did not finish/);
  assert.equal(a.releases,0);assert.equal(b.releases,0);
  f.Module.webcudaEndFrame(false);await until(()=>a.releases===1&&b.releases===1);
  assert.equal(f.runtime.renderCalls,0);assert.equal(f.runtime.submissions,0);
  await f.cleanup();assert.equal(a.releases,1);assert.equal(b.releases,1);
});

test('shader or packet failure drains previously submitted commands before releasing retained heap views',async t=>{
  const f=await fixture(t),packet=f.packet();f.runtime.renderError=Error('deliberate dispatch failure');
  assert(f.Module.webcudaBeginFrame());f.submit(packet);f.Module.webcudaEndFrame(true);
  await until(()=>f.runtime.renderCalls===1);
  f.renderGate.resolve();await until(()=>f.runtime.idleCalls===1);
  assert.equal(packet.releases,0);assert.equal(f.errors.length,1);
  assert(f.runtime.submissions>0,'Attachment clear was submitted before the failing render');
  f.idleGate.resolve();await until(()=>packet.releases===1);
  assert.equal(f.Module.webcudaBeginFrame(),false);
  await f.cleanup();assert.equal(packet.releases,1);assert.equal(f.runtime.buffers.size,0);
});

test('disposal releases queued packets, retains active CPU inputs until submission, and waits for GPU resources',async t=>{
  const pending=await fixture(t),a=pending.packet();
  assert(pending.Module.webcudaBeginFrame());pending.submit(a);
  const pendingDisposal=pending.owner.dispose();await until(()=>a.releases===1);
  pending.idleGate.resolve();await pendingDisposal;

  const running=await fixture(t),b=running.packet(),c=running.packet();
  assert(running.Module.webcudaBeginFrame());running.submit(b);running.Module.webcudaEndFrame(true);
  await until(()=>running.runtime.renderCalls===1);
  assert(running.Module.webcudaBeginFrame());running.submit(c);running.Module.webcudaEndFrame(true);
  let finished=false;const disposal=running.owner.dispose().then(()=>{finished=true;});
  await until(()=>c.releases===1);assert.equal(b.releases,0);assert.equal(finished,false);
  running.renderGate.resolve();await until(()=>b.releases===1&&running.runtime.idleCalls===1);
  assert.equal(running.runtime.fences.length,1);assert.equal(finished,false);
  assert.equal(b.submissionsWhenReleased,1);assert(running.runtime.buffers.size>0);
  running.idleGate.resolve();await new Promise(setImmediate);assert.equal(finished,false);
  running.runtime.fences[0].resolve();await disposal;
  assert.equal(b.releases,1);assert.equal(c.releases,1);assert.equal(running.runtime.buffers.size,0);
  assert.equal(running.runtime.device.destroyCalls,1);
});

test('device loss retains active heap views until the interrupted render drains and cancelled recovery disposes once',async t=>{
  const f=await fixture(t),packet=f.packet();
  assert(f.Module.webcudaBeginFrame());f.submit(packet);f.Module.webcudaEndFrame(true);
  await until(()=>f.runtime.renderCalls===1);
  f.runtime.renderError=Error('device lost while encoding');
  f.lost.resolve({message:'deliberate device loss'});
  await until(()=>f.Module.webcudaRecoveryPending===true);
  assert.equal(packet.releases,0);assert.equal(f.Module.webcudaBeginFrame(),false);
  const disposal=f.owner.dispose(); // Cancel recreation while cleanup is pending.
  f.renderGate.resolve();await until(()=>f.runtime.idleCalls===1);
  assert.equal(packet.releases,0);f.idleGate.resolve();await disposal;
  await until(()=>f.Module.webcudaRecoveryPending===false);
  assert.equal(packet.releases,1);assert.equal(f.runtime.buffers.size,0);assert.equal(f.runtime.device.destroyCalls,1);
});

test('normal frames validate asynchronously while diagnostic frames wait for collected results before presentation',async t=>{
  for(const inspect of [false,true])for(const failure of [null,'status','mapping']) {
    const f=await fixture(t,{search:inspect?'?renderdebug=1':''}),packets=[f.packet(),f.packet()],original=f.pipeline.render.bind(f.pipeline);
    f.pipeline.render=async(scene,width,height,context,pass)=>{
      await original(scene,width,height);
      const summary=f.pipeline.buffer('summary',8);
      new Uint32Array(summary.data.buffer).set([17,failure==='status'&&f.runtime.renderCalls===1?1:0]);
      const queryCompletion=pass.readback(summary,Uint32Array,8).then(values=>values[1]
        ?{error:Error('singular camera')}:{queryResults:new Map([[99,values[0]]]),diagnostic:{}},error=>({error}));
      return {width,height,row_pixels:64,queryCompletion};
    };
    assert(f.Module.webcudaBeginFrame());for(const packet of packets)f.submit(packet,0);f.Module.webcudaEndFrame(true);
    f.renderGate.resolve();await until(()=>f.runtime.readCalls===1);
    assert.equal(f.runtime.renderCalls,2);assert.equal(f.Module.webcudaQueryResults.size,0);
    if(inspect) {
      assert.equal(f.runtime.presentations,0);assert.equal(f.runtime.fences.length,0);
      assert(packets.every(packet=>packet.releases===0));
    } else {
      await until(()=>packets.every(packet=>packet.releases===1));
      assert.equal(f.runtime.presentations,1);assert.equal(f.runtime.fences.length,1);
      assert.equal(f.runtime.pendingFences,1);assert.equal(f.runtime.idleCalls,0);
    }
    if(failure==='mapping')f.runtime.readError=Error('mapping failed');
    f.readGate.resolve();
    if(failure) {
      await until(()=>f.errors.length===1);assert.equal(f.Module.webcudaBeginFrame(),false);
      if(inspect) {
        await until(()=>f.runtime.idleCalls===1);
        assert(packets.every(packet=>packet.releases===0));f.idleGate.resolve();
      }
    } else await until(()=>f.Module.webcudaQueryResults.get(99)===34);
    await until(()=>packets.every(packet=>packet.releases===1));
    assert.equal(f.runtime.presentations,inspect&&failure?0:1);
    assert.equal(f.errors.length,failure?1:0);
    await f.cleanup();assert.equal(f.runtime.buffers.size,0);
  }
});

test('aborted or disposed captures cancel pending prewarm before it can read released WASM views',async t=>{
  for(const mode of ['abort','dispose']) {
    const f=await fixture(t),packet=f.packet();let reads=0;
    f.pipeline.prewarm=()=>{reads++;assert.equal(packet.releases,0);};
    assert(f.Module.webcudaBeginFrame());f.submit(packet);
    if(mode==='abort')f.Module.webcudaEndFrame(false);
    const disposal=f.owner.dispose();f.idleGate.resolve();await disposal;
    await new Promise(setImmediate);
    assert.equal(reads,0);assert.equal(packet.releases,1);
  }
});

test('prewarm snapshots live inputs without retaining the packet through asynchronous compilation',async t=>{
  const f=await fixture(t),packet=f.packet(),compilation=deferred();let reads=0;
  f.pipeline.prewarm=scene=>{
    assert.equal(packet.releases,0);assert.equal(scene.vertices[0],1);reads++;
    return compilation.promise;
  };
  assert(f.Module.webcudaBeginFrame());f.submit(packet);
  await until(()=>reads===1);
  f.Module.webcudaEndFrame(false);assert.equal(packet.releases,1);
  compilation.resolve();f.idleGate.resolve();await f.owner.dispose();
  assert.equal(reads,1);assert.equal(packet.releases,1);
});

test('a failed render releases queued packets while the submitted frame drains',async t=>{
  const f=await fixture(t),running=f.packet(),queued=f.packet();
  assert(f.Module.webcudaBeginFrame());f.submit(running);f.Module.webcudaEndFrame(true);
  await until(()=>f.runtime.renderCalls===1);
  assert(f.Module.webcudaBeginFrame());f.submit(queued);f.Module.webcudaEndFrame(true);
  f.runtime.renderError=Error('deliberate queued-frame failure');f.renderGate.resolve();
  await until(()=>f.errors.length===1);
  assert.equal(queued.releases,1);assert.equal(running.releases,0);
  f.idleGate.resolve();await until(()=>running.releases===1);await f.owner.dispose();
  assert.equal(f.runtime.renderCalls,1);assert.equal(queued.releases,1);
});

function batchedFrame(token,malformed=false) {
  const size=8+SCENE_VIEWS.length*4+DIRECT_GPU_NAMES.length*2;
  const pass=[2,size+2,token,0,16,8,1,0,SCENE_VIEWS.length,DIRECT_GPU_NAMES.length,
    ...new Array(SCENE_VIEWS.length*4+DIRECT_GPU_NAMES.length*2).fill(0)];
  const state=[1,23,16384,0,0,0,0x3f800000,0x3f800000,1,0,0,0x8058,0x81a6,0,0,0,15,0,0,16,8,1,0x8058];
  const words=new Uint32Array([WASM_FRAME_MAGIC,WASM_FRAME_VERSION,...state,...pass,...(malformed?[99,2]:[])]);
  const heap=new SharedArrayBuffer(words.byteLength);new Uint32Array(heap).set(words);
  return {heap,count:words.length};
}

test('one batched WASM handoff enters the real host queue and releases its token after submission',async t=>{
  const f=await fixture(t),frame=batchedFrame(71),released=[];
  assert(f.Module.webcudaBeginFrame());
  f.Module.webgpuSubmitFrame(frame.heap,0,frame.count,null,0,token=>released.push(token));
  await until(()=>f.runtime.renderCalls===1);assert.deepEqual(released,[]);
  f.renderGate.resolve();await until(()=>released.length===1);
  assert.deepEqual(released,[71]);assert.equal(f.Module.webcudaTransportStats.frameSubmissions,1);
  assert.equal(f.Module.webcudaTransportStats.lastFrameCommands,2);
  assert.equal(f.Module.webcudaTransportStats.retainedPasses,0);
  await f.cleanup();assert.deepEqual(released,[71]);
});

test('a malformed batched handoff aborts accepted packets and cancels prewarm before WASM cleanup',async t=>{
  const f=await fixture(t),frame=batchedFrame(72,true),released=[];let prewarmReads=0;
  f.pipeline.prewarm=()=>{prewarmReads++;};
  assert(f.Module.webcudaBeginFrame());
  assert.throws(()=>f.Module.webgpuSubmitFrame(frame.heap,0,frame.count,null,0,token=>released.push(token)),/opcode/);
  f.Module.webgpuAbortFrame();await new Promise(setImmediate);
  assert.deepEqual(released,[72]);assert.equal(prewarmReads,0);assert.equal(f.runtime.renderCalls,0);
  assert.equal(f.Module.webcudaTransportStats.retainedPasses,0);
  assert(f.Module.webcudaBeginFrame());f.Module.webgpuAbortFrame();await f.cleanup();
});
