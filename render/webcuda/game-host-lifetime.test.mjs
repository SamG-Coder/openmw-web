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
  const renderGate=deferred(),idleGate=deferred(),lost=deferred(),errors=[];
  const runtime={buffers:new Set(),stats:{dataBytesUploaded:0},idleCalls:0,renderCalls:0,renderError:null,
    device:{limits:{maxTextureDimension2D:8192,maxStorageBufferBindingSize:2147483648,maxBufferSize:2147483648,maxComputeWorkgroupsPerDimension:65535},
      lost:lost.promise,addEventListener(){},removeEventListener(){},destroy(){}},
    createBuffer(byteLength){const buffer={byteLength};this.buffers.add(buffer);return buffer;},
    destroyBuffer(buffer){assert(this.buffers.delete(buffer),'Buffer destroyed once');},
    batch(){return {dispatch(){return this;},submit(){}};},
    idle(){this.idleCalls++;return idleGate.promise;}};
  const pipeline={kernels:{clear_target:{bind(){return {};}}},
    async render(){runtime.renderCalls++;await renderGate.promise;if(runtime.renderError)throw runtime.renderError;
      return {queryCompletion:Promise.resolve({queryResults:new Map(),diagnostic:{}})};},
    collectRetired(){},dispose(){},retireBuffer(){}};
  class Canvas {
    constructor(){this.dataset={};this.style={};this.parentElement={appendChild(){}};}
    setAttribute(){} remove(){} getContext(){return {configure(){},unconfigure(){}};}
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
    if(specifier.includes('/runtime/'))return synthetic(specifier,{GpuRuntime:{create:async()=>runtime}});
    if(specifier==='./pipeline.js')return synthetic(specifier,{MaterialPipeline:{create:async()=>pipeline}});
    if(specifier==='./legacy-draw-guard.js')return synthetic(specifier,{guardLegacyRendering:()=>({attempts:0})});
    return new vm.SourceTextModule(await readFile(new URL(specifier,import.meta.url),'utf8'),{context,identifier:specifier});
  });
  await host.evaluate();
  const Module={canvas:new Canvas()};
  const owner=await host.namespace.installWebCuda(Module,{onError:error=>errors.push(error)});
  const packet=()=>{
    const value={version:2,storage:'wasm-retained',width:16,height:8,scene:{vertices:new Float32Array([1])},releases:0};
    value.release=()=>{value.releases++;};return value;
  };
  const submit=value=>{Module.webcudaPassState({targetId:1,clearMask:16384,clearDepth:1});Module.webcudaSubmitPass(value);};
  return {Module,owner,runtime,renderGate,idleGate,lost,errors,packet,submit};
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
