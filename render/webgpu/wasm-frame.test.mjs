import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {WASM_FRAME_MAGIC,WASM_FRAME_VERSION,SCENE_VIEWS,DIRECT_GPU_NAMES,submitWasmFrame} from './wasm-frame.js';
import {importDirectPacket} from './direct-packet.js';

class Words {
  constructor(){this.values=[];}
  u32(value){this.values.push(value>>>0);return this;}
  i32(value){return this.u32(value);}
  u64(value){const n=BigInt(value);return this.u32(Number(n&0xffffffffn)).u32(Number(n>>32n));}
  f32(value){const bits=new Float32Array([value]);return this.u32(new Uint32Array(bits.buffer)[0]);}
  f64(value){const bits=new Float64Array([value]);for(const word of new Uint32Array(bits.buffer))this.u32(word);return this;}
  floats(values){for(const value of values)this.f32(value);return this;}
  command(opcode,payload){return this.u32(opcode).u32(payload.values.length+2).append(payload.values);}
  append(values){this.values.push(...values);return this;}
}
const word=value=>new Words().u32(value);
const floats=values=>new Words().floats(values);
const deferred=()=>{let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};};

function fixture({heap=new SharedArrayBuffer(65536),commandOffset=64,directBytes=0}={}) {
  const stream=new Words().u32(WASM_FRAME_MAGIC).u32(WASM_FRAME_VERSION),events=[],packets=[],released=[];
  const aliases=new Set();
  const runtime={importExternalBuffer(buffer,bytes,{offset,label}) {
    assert.equal(offset%256,0);const value={buffer,bytes,offset,label};aliases.add(value);return value;
  },releaseExternalBuffer(value){assert(aliases.delete(value));}};
  const Module={};
  for(const name of ['PassState','ResolveAttachment','RetireTarget','DepthIsolation','DebugScene','BloomScene',
    'SceneLuminance','DistortScene','AdjustScene','ResolveScene','CaptureDepth','ColorTarget','SubmitRipple','SnapshotPreviousFrame'])
    Module[`webcuda${name}`]=(...args)=>events.push([name,...args]);
  Module.webcudaSubmitPass=packet=>{importDirectPacket(runtime,packet);packets.push(packet);events.push(['Pass',packet]);return true;};
  Module.webcudaCaptureImage=(...args)=>{events.push(['CaptureImage',...args]);return Promise.resolve({pixels:'test'});};
  Module.webcudaEndFrame=commit=>{events.push(['EndFrame',commit]);if(!commit)for(const packet of packets)packet.release();};
  const gpuBuffer={size:4096,usage:128|4|8};
  const add=(opcode,payload)=>{stream.command(opcode,payload);return f;};
  const release=token=>released.push(token);
  const write=()=>{new Uint32Array(heap,commandOffset,stream.values.length).set(stream.values);};
  const submit=()=>{write();submitWasmFrame(Module,heap,commandOffset,stream.values.length,
    directBytes?gpuBuffer:null,directBytes,release);};
  const abort=()=>Module.webcudaEndFrame(false);
  const f={heap,commandOffset,stream,events,packets,released,aliases,Module,gpuBuffer,add,write,submit,abort};
  return f;
}

function scene(f,{token=11,base=8192,directRanges={},addressOverrides={},countOverrides={}}={}) {
  const payload=new Words().u32(token).u32(1).u32(320).u32(200).u64(64).u32(SCENE_VIEWS.length).u32(DIRECT_GPU_NAMES.length);
  const views=new Map();let address=base;
  for(let i=0;i<SCENE_VIEWS.length;i++) {
    const [name,type]=SCENE_VIEWS[i];
    const count=name==='matrices'?32:name==='triangles'?4:name==='materials'?12:2;
    const array=type==='f'?new Float32Array(f.heap,address,count):new Uint32Array(f.heap,address,count);
    for(let n=0;n<count;n++)array[n]=i*32+n+(type==='f'?.5:0);
    payload.u64(addressOverrides[name]??address).u64(countOverrides[name]??count);
    views.set(name,{array,address,count});address+=count*4+16;
  }
  for(const name of DIRECT_GPU_NAMES) {
    const range=directRanges[name];payload.u32(range?.offset??0).u32(range?.bytes??0);
  }
  return {payload,views};
}

test('the command ABI matches the engine field order, names and opcode values',async()=>{
  assert.equal(SCENE_VIEWS.length,44);assert.equal(DIRECT_GPU_NAMES.length,31);
  assert.equal(new Set(SCENE_VIEWS.map(([name])=>name)).size,44);
  assert.equal(new Set(DIRECT_GPU_NAMES).size,31);
  const bridge=await readFile(new URL('../../openmw/components/webcuda/browserbridge.cpp',import.meta.url),'utf8');
  const descriptor=bridge.slice(bridge.indexOf('BrowserCommand command(BrowserOpcode::Pass)'),bridge.indexOf('// The JS wrapper owns release'));
  const aliases={mipGenerations:'mipGenerations'};
  const cppViews=[...descriptor.matchAll(/\.view\((?:geometry|table)\.([a-zA-Z0-9_]+)(?:\(\))?\)/g)].map(match=>aliases[match[1]]??match[1]);
  assert.deepEqual(cppViews,SCENE_VIEWS.map(([name])=>name));
  assert.match(descriptor,/\.u32\(44\)\.u32\(DirectRangeCount\)/);
  const header=await readFile(new URL('../../openmw/components/webcuda/browserframe.hpp',import.meta.url),'utf8');
  const opcodes=header.match(/enum class BrowserOpcode[^\{]*\{([^}]+)\}/)[1].replace(/\s/g,'').split(',');
  assert.deepEqual(opcodes,['PassState=1','Pass','ResolveAttachment','RetireTarget','DepthIsolation','Debug','Bloom','Luminance',
    'Distort','Adjust','Resolve','CaptureDepth','ColorTarget','Ripples','Snapshot','CaptureImage','CaptureTimings','ShaderStats']);
});

test('all frame commands preserve camera values, effect order, signed integers and doubles',async()=>{
  const f=fixture(),debug=Array.from({length:19},(_,i)=>i+.5),bloom=Array.from({length:11},(_,i)=>i+1);
  const state=new Words().u32(16640).floats([.25,.5,.75,1]).f32(.5).u32(7).u32(0x80000005).u32(0x40000009)
    .u32(0x8058).u32(0x81a6).i32(-17).u32(8).u32(13).u32(15).i32(-5).i32(-7).u32(320).u32(200).u32(4).u32(0x881a);
  f.add(1,state);const pass=scene(f);f.add(2,pass.payload);
  f.add(3,new Words().u32(7).u32(8).u32(2).u32(0x8058).u32(320).u32(200).i32(-2).i32(-3).u32(300).u32(180));
  f.add(4,word(0xc0000021));f.add(5,new Words().u32(1).f32(.25));
  f.add(6,new Words().u32(9).u32(10).u32(3).floats(debug));
  f.add(7,new Words().u32(9).u32(1).floats(bloom));
  f.add(8,new Words().u32(8).u32(160).u32(100).f32(.5).f32(.25).f32(2).u32(1).f64(123456.125).u32(320).u32(200));
  f.add(9,word(0xa0000011));f.add(10,floats([2.25,1.5]));
  f.add(11,new Words().u32(8).u32(9).u32(0x8058).u32(0x881a).floats([.5,.25]));
  f.add(12,new Words().u32(0x80000003).u32(320).u32(200));
  f.add(13,new Words().u32(1).u32(17).u32(0x8058).u32(0x81a6));
  f.add(14,new Words().u32(19).u32(32).u32(16).u32(2).floats([2.5,3.5,4.5]).u32(1).floats([1,2,3,4,5,6]));
  f.add(15,new Words().u32(21).u32(320).u32(200));
  f.add(16,new Words().u32(22).u32(160).u32(100).u32(1));
  const times=new Words();for(let i=0;i<8;i++)times.f64(i+.125);f.add(17,times);
  f.add(18,new Words().f64(4294967297).f64(23).f64(31));f.submit();
  assert.deepEqual(f.events.map(event=>event[0]),['PassState','Pass','ResolveAttachment','RetireTarget','DepthIsolation','DebugScene','BloomScene',
    'SceneLuminance','DistortScene','AdjustScene','ResolveScene','CaptureDepth','ColorTarget','SubmitRipple','SnapshotPreviousFrame','CaptureImage','EndFrame']);
  assert.deepEqual(f.events[0][1],{clearMask:16640,clearColor:[.25,.5,.75,1],clearDepth:.5,targetId:7,depthTargetId:0x80000005,
    normalTargetId:0x40000009,colorFormat:0x8058,depthFormat:0x81a6,clearStencil:-17,stencilBits:8,stencilTargetId:13,
    clearColorMask:15,viewport:[-5,-7,320,200],sampleCount:4,normalFormat:0x881a});
  assert.deepEqual(f.events[2][1],{sourceId:7,targetId:8,plane:2,format:0x8058,width:320,height:200,viewport:[-2,-3,300,180]});
  assert.deepEqual(f.events[3],['RetireTarget',0xc0000021]);assert.deepEqual(f.events[4],['DepthIsolation',true,.25]);
  assert.deepEqual(f.events[5],['DebugScene',9,10,3,new Float32Array(debug)]);
  assert.deepEqual(f.events[6],['BloomScene',9,new Float32Array(bloom),true]);
  assert.deepEqual(f.events[7][1],{sourceId:8,width:160,height:100,sx:.5,sy:.25,speed:2,reset:true,time:123456.125,viewportWidth:320,viewportHeight:200});
  assert.deepEqual(f.events[8],['DistortScene',0xa0000011]);assert.deepEqual(f.events[9],['AdjustScene',2.25,1.5]);
  assert.deepEqual(f.events[10],['ResolveScene',8,9,0x8058,0x881a,.5,.25]);
  assert.deepEqual(f.events[11],['CaptureDepth',0x80000003,320,200]);
  assert.deepEqual(f.events[12],['ColorTarget',true,17,0x8058,0x81a6]);
  assert.deepEqual(f.events[13][1],{kind:'ripples',targetId:19,width:32,height:16,ox:2.5,oy:3.5,time:4.5,simulate:true,positions:new Float32Array([1,2,3,4,5,6])});
  assert.deepEqual(f.events[14],['SnapshotPreviousFrame',21,320,200]);assert.deepEqual(f.events[15],['CaptureImage',160,100,true]);
  assert.deepEqual(Object.values(f.Module.webcudaCaptureTimings),Array.from({length:8},(_,i)=>i+.125));
  assert.deepEqual(f.Module.webcudaShaderAnalysisStats,{hits:4294967297,misses:23,bypasses:31});
  assert.equal(f.Module.webcudaTransportStats.lastFrameCommands,18);assert.equal(f.Module.webcudaTransportStats.frameSubmissions,1);
  await Promise.resolve();assert.deepEqual(f.Module.webcudaImageResults.get(22),{image:{pixels:'test'}});
  f.packets[0].release();assert.deepEqual(f.released,[11]);
});

test('scene descriptors borrow the exact shared heap ranges and two camera passes share one direct upload',()=>{
  const f=fixture({directBytes:2048});
  const first=scene(f,{token:31,directRanges:{matrices:{offset:256,bytes:128},triangles:{offset:512,bytes:16}}});
  const second=scene(f,{token:32,base:16384,directRanges:{matrices:{offset:1024,bytes:128},triangles:{offset:1280,bytes:16}}});
  f.add(2,first.payload).add(2,second.payload);f.submit();
  for(const [index,captured] of [first,second].entries())for(const [name,type] of SCENE_VIEWS) {
    const view=f.packets[index].scene[name],expected=captured.views.get(name);
    assert(view instanceof (type==='f'?Float32Array:Uint32Array));assert.equal(view.buffer,f.heap);
    assert.equal(view.byteOffset,expected.address);assert.equal(view.length,expected.count);
    assert.deepEqual(view,expected.array);
  }
  assert.equal(f.packets[0].scene.directGpuResources.matrices.offset,256);
  assert.equal(f.packets[1].scene.directGpuResources.matrices.offset,1024);
  assert.equal(f.packets[0].scene.directGPU.buffer,f.packets[1].scene.directGPU.buffer);
  const stats=f.Module.webcudaTransportStats;
  assert.equal(stats.directGpuUploads,1);assert.equal(stats.directGpuBytes,2048);assert.equal(stats.directGpuPasses,2);
  assert.equal(stats.copiedSceneBytes,0);assert.equal(stats.retainedPasses,2);
  const retained=f.packets[0].scene.matrices.slice();
  new Uint32Array(f.heap,f.commandOffset,f.stream.values.length).fill(0);
  assert.deepEqual(f.packets[0].scene.matrices,retained,'Reusing command storage does not change retained scene arrays');
  f.packets[0].release();f.packets[0].release();assert.equal(stats.retainedPasses,1);assert.equal(f.aliases.size,2);
  f.packets[1].release();assert.deepEqual(f.released,[31,32]);assert.equal(f.aliases.size,0);
  assert.equal(stats.retainedPasses,0);assert.equal(stats.retainedViewBytes,0);assert.equal(stats.releasedPasses,2);
});

test('inline effect arrays own their data across later WASM command-buffer reuse',()=>{
  const f=fixture();
  f.add(6,new Words().u32(1).u32(2).u32(3).floats(Array.from({length:19},(_,i)=>i)));
  f.add(7,new Words().u32(1).u32(0).floats(Array.from({length:11},(_,i)=>i+32)));
  f.add(14,new Words().u32(3).u32(16).u32(8).u32(1).floats([0,0,1]).u32(0).floats([4,5,6]));
  f.submit();
  const arrays=[f.events[0][4],f.events[1][2],f.events[2][1].positions];
  const snapshots=arrays.map(array=>array.slice());
  new Uint32Array(f.heap,f.commandOffset,f.stream.values.length).fill(0xffffffff);
  for(let i=0;i<arrays.length;i++){assert.notEqual(arrays[i].buffer,f.heap);assert.deepEqual(arrays[i],snapshots[i]);}
});

test('capturing the next frame can reuse command memory while earlier scene storage remains retained',()=>{
  const f=fixture();f.add(2,scene(f,{token:61,base:8192}).payload);f.submit();
  const earlier=f.packets[0],before=earlier.scene.matrices.slice();
  f.stream.values=[WASM_FRAME_MAGIC,WASM_FRAME_VERSION];
  const next=scene(f,{token:62,base:16384});next.views.get('matrices').array.fill(99);
  f.add(2,next.payload);f.submit();
  assert.equal(f.Module.webcudaTransportStats.frameSubmissions,2);assert.equal(f.Module.webcudaTransportStats.retainedPasses,2);
  assert.deepEqual(earlier.scene.matrices,before);assert(f.packets[1].scene.matrices.every(value=>value===99));
  assert.notEqual(earlier.scene.matrices.byteOffset,f.packets[1].scene.matrices.byteOffset);
  f.packets[1].release();assert.deepEqual(f.released,[62]);assert.deepEqual(earlier.scene.matrices,before);
  earlier.release();assert.deepEqual(f.released,[62,61]);assert.equal(f.Module.webcudaTransportStats.retainedViewBytes,0);
});

test('MEMORY64 addresses and counts above 4 GiB are rejected without wrapping into valid low heap ranges',()=>{
  for(const overrides of [
    {addressOverrides:{matrices:4294967296n+8192n}},
    {countOverrides:{matrices:4294967296n+32n}},
    {addressOverrides:{matrices:9007199254740992n}},
    {countOverrides:{matrices:9007199254740992n}},
    {addressOverrides:{matrices:8193n}},
  ]) {
    const f=fixture();f.add(2,scene(f,overrides).payload);
    assert.throws(f.submit,/Invalid WASM matrices view|exact integer range/);assert.equal(f.packets.length,0);
    assert(!f.events.some(event=>event[0]==='EndFrame'&&event[1]));
  }
});

test('pass rejection and host abort release decoded packets exactly once',()=>{
  for(const mode of ['false','throw']) {
    const f=fixture();let rejected;
    f.Module.webcudaSubmitPass=packet=>{rejected=packet;if(mode==='throw')throw Error('deliberate rejection');return false;};
    f.add(2,scene(f,{token:41}).payload);
    assert.throws(f.submit,/rejected|deliberate/);rejected.release();
    assert.deepEqual(f.released,[41]);assert.equal(f.Module.webcudaTransportStats.retainedPasses,0);
    assert.equal(f.Module.webcudaTransportStats.retainedViewBytes,0);
  }
  const f=fixture();f.add(2,scene(f,{token:42}).payload).add(99,new Words());
  assert.throws(f.submit,/opcode/);assert.equal(f.packets.length,1);
  // The host owns accepted packets. Its abort precedes C++'s registry cleanup.
  f.abort();f.abort();assert.deepEqual(f.released,[42]);assert.equal(f.Module.webcudaTransportStats.retainedPasses,0);
});

test('malformed headers, command extents, view counts and duplicate tokens cannot commit a frame',()=>{
  for(const mutate of [
    f=>{f.stream.values[0]=0;},f=>{f.stream.values[1]=2;},
    f=>{f.stream.u32(1);},f=>{f.stream.command(4,new Words());},
    f=>{f.stream.command(4,word(2));f.stream.values[3]=999999;},
    f=>{const pass=scene(f);pass.payload.values[6]=43;f.add(2,pass.payload);},
    f=>{const pass=scene(f);pass.payload.values[7]=30;f.add(2,pass.payload);},
    f=>{f.add(2,scene(f).payload).add(2,scene(f,{base:16384}).payload);},
    f=>{f.add(14,new Words().u32(1).u32(2).u32(3).u32(101).floats([0,0,0]).u32(1));},
  ]) {
    const f=fixture();mutate(f);assert.throws(f.submit,/WASM/);f.abort();
    assert(!f.events.some(event=>event[0]==='EndFrame'&&event[1]));
    assert.equal(new Set(f.released).size,f.released.length);
  }
  const f=fixture();f.write();
  for(const [offset,count] of [[-4,2],[2,2],[0,1],[65536,2],[4294967296,2],[0,9007199254740991]])
    assert.throws(()=>submitWasmFrame(f.Module,f.heap,offset,count,null,0,()=>{}),/command range/);
});

test('invalid GPU ranges fail before a pass can be consumed and partial imports roll back',()=>{
  for(const directRanges of [
    {matrices:{offset:1024,bytes:128},triangles:{offset:2048,bytes:16}},
    {matrices:{offset:1024,bytes:128},triangles:{offset:1280,bytes:20}},
    {matrices:{offset:1024,bytes:128},triangles:{offset:1024,bytes:16}},
  ]) {
    const f=fixture({directBytes:2048});f.add(2,scene(f,{directRanges}).payload);
    assert.throws(f.submit,/range|overlap/);assert.equal(f.packets.length,0);assert.equal(f.aliases.size,0);
    f.abort();assert.equal(f.Module.webcudaTransportStats.retainedPasses,0);
  }
});

test('image completion cannot resurrect canceled results and reports synchronous or asynchronous failure',async()=>{
  for(const mode of ['cancel','reject','throw']) {
    const f=fixture(),result=deferred();
    f.Module.webcudaCaptureImage=()=>{if(mode==='throw')throw Error('capture failed');return result.promise;};
    f.add(16,new Words().u32(51).u32(8).u32(8).u32(0));f.submit();
    if(mode==='cancel'){f.Module.webcudaImageResults.delete(51);result.resolve({pixels:'late'});}
    if(mode==='reject')result.reject(Error('capture failed'));
    await Promise.resolve();
    if(mode==='cancel')assert.equal(f.Module.webcudaImageResults.has(51),false);
    else assert.match(f.Module.webcudaImageResults.get(51).error,/capture failed/);
  }
});
