// SPDX-License-Identifier: GPL-3.0-or-later
import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import vm from 'node:vm';

const source=fs.readFileSync(new URL('./frame-pump.js',import.meta.url),'utf8');
function fixture({search='',durations=[5],io=false}={}) {
  const sandbox={};vm.runInNewContext(source,sandbox);
  let now=0,nextId=0,index=0,frames=new Map(),timers=new Map(),messages=[];
  const listeners=new Map(),nodes=[],downloads=[],revoked=[];
  const ioStats={hits:0,misses:0,stallMs:0,bytes:0,evictions:0};
  let ioReads=0;
  const env={
    location:{search,href:'http://localhost:8910/'+search},performance:{now:()=>now},
    MessageChannel:class {constructor(){const self=this;this.port1={};this.port2={postMessage:data=>messages.push(()=>self.port1.onmessage({data}))};}},
    requestAnimationFrame:fn=>{const id=++nextId;frames.set(id,fn);return id;},cancelAnimationFrame:id=>frames.delete(id),
    setTimeout:(fn,delay)=>{const id=++nextId;timers.set(id,{fn,delay});return id;},clearTimeout:id=>timers.delete(id),
    document:{hidden:false,addEventListener:(name,fn)=>listeners.set(name,fn),removeEventListener:(name,fn)=>{if(listeners.get(name)===fn)listeners.delete(name);},
      body:{appendChild:node=>nodes.push(node)},
      createElement:tag=>({tag,style:{},removed:false,addEventListener(name,fn){this[name]=fn;},remove(){this.removed=true;},click(){downloads.push(this);}})},
    Blob:class {constructor(parts,options){this.parts=parts;this.options=options;}},
    URL:{createObjectURL:blob=>{env.lastBlob=blob;return 'blob:report';},revokeObjectURL:url=>revoked.push(url)},
    Module:{webgpuEnabled:true,webcudaProfileCapture:false},
  };
  Object.defineProperty(env,'__streamfsStats',{get(){ioReads++;return {...ioStats};}});
  const tick=()=>{now+=durations[index++%durations.length];if(io){ioStats.stallMs+=2;ioStats.misses++;ioStats.bytes+=64;}};
  const pump=sandbox.createOpenMWFramePump(env,tick);
  const raf=()=>{assert.equal(frames.size,1);const [id,fn]=frames.entries().next().value;frames.delete(id);now+=16;fn();};
  const message=(delay=0)=>{now+=delay;assert(messages.length);messages.shift()();};
  const step=(delay=0)=>{raf();message(delay);};
  return {env,pump,raf,message,step,nodes,downloads,revoked,frames,timers,listeners,messages,get ticks(){return index;},get ioReads(){return ioReads;},setNow:v=>{now=v;}};
}
const plain=value=>JSON.parse(JSON.stringify(value));
test('engine still runs in a MessageChannel task, not inside requestAnimationFrame',()=>{
  const f=fixture();f.pump.start();f.raf();assert.equal(f.ticks,0);f.message(3);assert.equal(f.ticks,1);
  assert.equal(f.frames.size,1);f.step(3);const s=f.pump.stats();assert.equal(s.engineP95Ms,5);assert.equal(s.taskDelayP95Ms,3);
  f.pump.stop();
});
test('profiling disabled does not enable capture diagnostics, read streaming counters per tick or create UI',()=>{
  const f=fixture();f.pump.start();for(let i=0;i<5;i++)f.step();
  assert.equal(f.env.Module.webcudaProfileCapture,false);assert.equal(f.nodes.length,0);assert.equal(f.ioReads,0);
  assert.equal(f.pump.stats().streamStallP95Ms,null);f.pump.stop();
});
test('engineprofile enables only CPU capture diagnostics and restores prior state on stop',()=>{
  const f=fixture({search:'?src=hosted&engineprofile=1',io:true});f.pump.start();f.step();f.step();
  assert.equal(f.env.Module.webcudaProfileCapture,true);assert.equal(f.nodes.length,1);
  assert.equal(f.env.Module.renderdebug,undefined);assert.equal(f.pump.stats().streamStallMaxMs,2);
  const r=f.pump.report();assert.equal(r.engineFrames[0].streamMisses,1);assert.equal(r.engineFrames[0].streamBytes,64);
  f.pump.stop();assert.equal(f.env.Module.webcudaProfileCapture,false);assert(f.nodes[0].removed);assert(!f.env.__omwEnginePerformance);
});
test('preexisting render capture profiling is not disabled by pump shutdown',()=>{
  const f=fixture({search:'?engineprofile=1'});f.env.Module.webcudaProfileCapture=true;f.pump.start();f.step();f.pump.stop();
  assert.equal(f.env.Module.webcudaProfileCapture,true);
});
test('360-sample typed ring keeps chronological order and accurate outlier timing',()=>{
  const f=fixture({durations:[5]});f.pump.start();for(let i=0;i<400;i++)f.step();
  const report=f.pump.report();assert.equal(report.engineFrames.length,360);assert.equal(report.engine.visibleTicks,400);
  for(let i=1;i<360;i++)assert(report.engineFrames[i].startAt>report.engineFrames[i-1].startAt);
  assert.equal(report.engine.engineP99Ms,5);assert.equal(report.engine.engineTicksOver50Ms,0);f.pump.stop();
  const slow=fixture({durations:[60]});slow.pump.start();slow.step();slow.step();
  assert.equal(slow.pump.stats().engineMaxMs,60);assert.equal(slow.pump.stats().engineTicksOver50Ms,1);slow.pump.stop();
});
test('visibility changes discard stale messages and use the original hidden-tab timer',()=>{
  const f=fixture();f.pump.start();f.raf();f.env.document.hidden=true;f.listeners.get('visibilitychange')();
  f.message();assert.equal(f.ticks,0);assert.equal(f.timers.size,1);
  const [id,job]=f.timers.entries().next().value;assert.equal(job.delay,33);f.timers.delete(id);job.fn();f.message();
  assert.equal(f.ticks,1);assert.equal(f.pump.stats().visibleTicks,0);f.pump.stop();
});
test('reports copy engine/WebGPU counters and existing timings without requesting a GPU readback',()=>{
  const f=fixture({search:'?engineprofile=1'});let snapshots=0;
  f.env.Module.webcudaCaptureTimings={geometryEncodeMs:7};f.env.Module.webcudaShaderAnalysisStats={hits:123};
  f.env.__omwWebGPU={stats:{presented:7,lastFrame:{frameWallMs:10}},canvas:{dataset:{webcudaStats:JSON.stringify({nativeTargets:{presentations:7}})}},
    timingSnapshot(){snapshots++;return [{acceptedAt:20,packetCaptureMs:7}];}};
  f.pump.start();f.step();f.step();const report=f.pump.report();assert.equal(snapshots,1);
  assert.deepEqual(plain(report.shaderAnalysis),{hits:123});assert.equal(report.capturePhases.geometryEncodeMs,7);
  assert.equal(report.rendererCounters.nativeTargets.presentations,7);assert.equal(report.rendererFrames[0].packetCaptureMs,7);
  report.renderer.lastFrame.frameWallMs=900;assert.equal(f.env.__omwWebGPU.stats.lastFrame.frameWallMs,10);f.pump.stop();
});
test('save button emits a bounded JSON performance report',()=>{
  const f=fixture({search:'?engineprofile=1'});f.pump.start();f.step();f.step();f.nodes[0].click();
  const saved=f.downloads.at(-1);assert.equal(saved.download,'openmw-engine-webgpu-performance.json');
  const json=JSON.parse(f.env.lastBlob.parts[0]);assert.equal(json.schema,'openmw-engine-webgpu-performance-v1');assert.equal(json.engineFrames.length,1);
  f.pump.stop();
});
test('repeated start does not add a second engine driver; stop cancels scheduled work',()=>{
  const f=fixture();f.pump.start();f.pump.start();assert.equal(f.frames.size,1);f.step();f.pump.stop();assert.equal(f.frames.size,0);
  f.pump.start();f.step();assert.equal(f.ticks,2);f.pump.stop();
});
