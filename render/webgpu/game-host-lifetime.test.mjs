// Exercise the actual host's asynchronous ownership boundaries. GPU execution
// is controlled here; actual shared-WASM uploads and gameplay are tested in browser.
import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
const deferred=()=>{let resolve;const promise=new Promise(done=>{resolve=done;});return {promise,resolve};};
async function until(predicate) {
  for(let i=0;i<100;i++){if(predicate())return;await new Promise(setImmediate);}
  assert.fail('Host did not reach expected boundary');
}
async function fixture() {
  const renderGate=deferred(),idleGate=deferred(),readGate=deferred(),lost=deferred(),errors=[];
  const runtime={buffers:new Set(),stats:{dataBytesUploaded:0},idleCalls:0,renderCalls:0,renderError:null,
    readCalls:0,presentations:0,readError:null,
    device:{limits:{maxTextureDimension2D:8192,maxStorageBufferBindingSize:2147483648,maxBufferSize:2147483648,maxComputeWorkgroupsPerDimension:65535},
      lost:lost.promise,addEventListener(){},removeEventListener(){},destroy(){}},
    createBuffer(byteLength){const buffer={byteLength,data:new Uint8Array(byteLength)};this.buffers.add(buffer);return buffer;},
    destroyBuffer(buffer){assert(this.buffers.delete(buffer),'Buffer destroyed once');},
    batch(){return {dispatch(){return this;},copy(source,target,{sourceOffset=0,targetOffset=0,byteLength}){
      target.data.set(source.data.subarray(sourceOffset,sourceOffset+byteLength),targetOffset);return this;
    },submit(){}};},
    async read(source,Type,bytes,offset=0){this.readCalls++;const snapshot=source.data.slice(offset,offset+bytes);
      await readGate.promise;if(this.readError)throw this.readError;return new Type(snapshot.buffer);},
    async presentBuffer(){this.presentations++;},
    idle(){this.idleCalls++;return idleGate.promise;}};
  const scratch=new Map(),retired=new Set();
  const pipeline={kernels:{clear_target:{bind(){return {};}},pack_target:{bind(){return {};}}},
    async render(){runtime.renderCalls++;await renderGate.promise;if(runtime.renderError)throw runtime.renderError;
      return {queryCompletion:Promise.resolve({queryResults:new Map(),diagnostic:{}})};},
    buffer(name,bytes){if(!scratch.has(name))scratch.set(name,runtime.createBuffer(bytes));return scratch.get(name);},
    collectRetired(){for(const resource of retired)runtime.destroyBuffer(resource);retired.clear();},
    dispose(){this.collectRetired();for(const resource of scratch.values())runtime.destroyBuffer(resource);scratch.clear();},
    retireBuffer(resource){retired.add(resource);}};
  class Canvas {
    constructor(){this.dataset={};this.style={};this.parentElement={appendChild(){}};}
    setAttribute(){} remove(){} getContext(){return {configure(){},unconfigure(){}};}
    getBoundingClientRect(){return {left:0,top:0,width:16,height:8};}
  }
  const context=vm.createContext({console,performance,URLSearchParams,setTimeout,clearTimeout,
    Uint32Array,Float32Array,ArrayBuffer,Map,Set,HTMLCanvasElement:Canvas,
    ResizeObserver:class{observe(){} disconnect(){}},
    GPUTextureUsage:{COPY_DST:1,RENDER_ATTACHMENT:2},
    location:{search:''},document:{createElement(){return new Canvas();}},
    window:{addEventListener(){},removeEventListener(){}}});
  const synthetic=(name,values)=>new vm.SyntheticModule(Object.keys(values),function(){for(const [key,value] of Object.entries(values))this.setExport(key,value);},{context,identifier:name});
  const host=new vm.SourceTextModule(await readFile(new URL('./game-host.js',import.meta.url),'utf8'),{context});
  await host.link(async specifier=>{
    if(specifier==='./runtime.js')return synthetic(specifier,{WebGPURuntime:{create:async()=>runtime}});
    if(specifier==='./pipeline.js')return synthetic(specifier,{MaterialPipeline:{create:async()=>pipeline}});
    if(specifier==='./legacy-draw-guard.js')return synthetic(specifier,{guardLegacyRendering:()=>({attempts:0})});
    if(specifier==='./native-targets.js')return synthetic(specifier,{NativeAttachmentStore:class{
      constructor(){ }
      destroy(){} dispose(){}
      canCamera(){return false;}
    }});
    return new vm.SourceTextModule(await readFile(new URL(specifier,import.meta.url),'utf8'),{context,identifier:specifier});
  });
  await host.evaluate();
  const Module={canvas:new Canvas()};
  const owner=await host.namespace.installWebGPU(Module,{onError:error=>errors.push(error)});
  const packet=()=>{
    const value={version:2,storage:'wasm-retained',width:16,height:8,scene:{vertices:new Float32Array([1])},releases:0};
    value.release=()=>{value.releases++;};return value;
  };
  const submit=(value,targetId=1)=>{Module.webcudaPassState({targetId,clearMask:16384,clearDepth:1});Module.webcudaSubmitPass(value);};
  return {Module,owner,runtime,pipeline,renderGate,idleGate,readGate,lost,errors,packet,submit};
}

test('pending dispatch and GPU completion retain the packet and apply frame backpressure',async()=>{
  const f=await fixture(),packet=f.packet();
  assert(f.Module.webcudaBeginFrame());f.submit(packet);f.Module.webcudaEndFrame(true);
  assert.equal(f.runtime.renderCalls,1);assert.equal(packet.releases,0);
  assert.equal(f.Module.webcudaBeginFrame(),false);
  f.renderGate.resolve();await until(()=>f.runtime.idleCalls===1);
  assert.equal(packet.releases,0);
  f.idleGate.resolve();await until(()=>packet.releases===1);
  assert(f.Module.webcudaBeginFrame());f.Module.webcudaEndFrame(false);
  await f.owner.dispose();assert.equal(packet.releases,1);assert.equal(f.runtime.buffers.size,0);
});

test('aborted and invalid-commit frames release every captured pass without GPU submission',async()=>{
  const f=await fixture(),a=f.packet(),b=f.packet();
  assert(f.Module.webcudaBeginFrame());f.submit(a);f.submit(b);
  f.Module.webcudaPassState({targetId:1});
  assert.throws(()=>f.Module.webcudaEndFrame(true),/camera did not finish/);
  assert.equal(a.releases,0);assert.equal(b.releases,0);
  f.Module.webcudaEndFrame(false);
  assert.equal(a.releases,1);assert.equal(b.releases,1);assert.equal(f.runtime.renderCalls,0);
  f.idleGate.resolve();await f.owner.dispose();
});

test('shader/packet failure drains prior commands before releasing retained heap views',async()=>{
  const f=await fixture(),packet=f.packet();f.runtime.renderError=Error('deliberate dispatch failure');
  assert(f.Module.webcudaBeginFrame());f.submit(packet);f.Module.webcudaEndFrame(true);
  f.renderGate.resolve();await until(()=>f.runtime.idleCalls===1);
  assert.equal(packet.releases,0);assert.equal(f.errors.length,1);
  f.idleGate.resolve();await until(()=>packet.releases===1);
  assert.equal(f.Module.webcudaBeginFrame(),false);
  await f.owner.dispose();assert.equal(packet.releases,1);
});

test('disposal releases pending packets and waits for in-flight packets',async()=>{
  const pending=await fixture(),a=pending.packet();
  assert(pending.Module.webcudaBeginFrame());pending.submit(a);
  pending.idleGate.resolve();await pending.owner.dispose();assert.equal(a.releases,1);
  const running=await fixture(),b=running.packet();
  assert(running.Module.webcudaBeginFrame());running.submit(b);running.Module.webcudaEndFrame(true);
  const disposed=running.owner.dispose();assert.equal(b.releases,0);
  running.renderGate.resolve();await until(()=>running.runtime.idleCalls===1);
  assert.equal(b.releases,0);running.idleGate.resolve();await disposed;
  assert.equal(b.releases,1);assert.equal(running.runtime.buffers.size,0);
});


test('device loss retains in-flight heap views until cancelled recovery drains the old host',async()=>{
  const f=await fixture(),packet=f.packet();
  assert(f.Module.webcudaBeginFrame());f.submit(packet);f.Module.webcudaEndFrame(true);
  f.lost.resolve({message:'deliberate device loss'});
  await until(()=>f.Module.webcudaRecoveryPending===true);
  assert.equal(packet.releases,0);assert.equal(f.Module.webcudaBeginFrame(),false);
  const disposal=f.owner.dispose(); // Cancel recreation while cleanup is pending.
  f.renderGate.resolve();await until(()=>f.runtime.idleCalls===1);
  assert.equal(packet.releases,0);f.idleGate.resolve();await disposal;
  await until(()=>f.Module.webcudaRecoveryPending===false);
  assert.equal(packet.releases,1);assert.equal(f.runtime.buffers.size,0);
});

test('the frame joins collected validation before presentation and drains failures before packet release',async()=>{
  for(const failure of [null,'status','mapping']) {
    const f=await fixture(),packets=[f.packet(),f.packet()],original=f.pipeline.render.bind(f.pipeline);
    f.pipeline.render=async(scene,width,height,context,pass)=>{
      await original();
      const summary=f.pipeline.buffer('summary',8);
      new Uint32Array(summary.data.buffer).set([17,failure==='status'&&f.runtime.renderCalls===1?1:0]);
      const queryCompletion=pass.readback(summary,Uint32Array,8).then(values=>values[1]
        ?{error:Error('singular camera')}:{queryResults:new Map()},error=>({error}));
      return {width,height,row_pixels:64,queryCompletion};
    };
    assert(f.Module.webcudaBeginFrame());for(const packet of packets)f.submit(packet,0);f.Module.webcudaEndFrame(true);
    f.renderGate.resolve();await until(()=>f.runtime.readCalls===1);
    assert.equal(f.runtime.renderCalls,2);assert.equal(f.runtime.presentations,0);
    assert(packets.every(packet=>packet.releases===0));
    if(failure==='mapping')f.runtime.readError=Error('mapping failed');
    f.readGate.resolve();await until(()=>f.runtime.idleCalls===1);
    assert.equal(f.runtime.presentations,failure?0:1);assert.equal(f.errors.length,failure?1:0);
    assert(packets.every(packet=>packet.releases===0));
    f.idleGate.resolve();await until(()=>packets.every(packet=>packet.releases===1));
    await f.owner.dispose();assert.equal(f.runtime.buffers.size,0);
  }
});
