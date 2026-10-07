import assert from 'node:assert/strict';
import test from 'node:test';
import {importDirectPacket} from './direct-packet.js';

function fixture() {
  const borrowed=new Set(),imports=[],released=[];
  const runtime={importExternalBuffer(buffer,bytes,options){
    if(options.offset%256)throw RangeError('Unaligned GPU range');
    const resource={buffer,bytes,...options};borrowed.add(resource);imports.push(resource);return resource;
  },releaseExternalBuffer(resource){assert(borrowed.delete(resource));released.push(resource);}};
  const buffer={size:4096},packet={scene:{matrices:new Float32Array(32),triangles:new Uint32Array(4)},releases:0};
  packet.release=()=>{assert.equal(borrowed.size,0);packet.releases++;};
  // Absolute offsets allow many camera packets to share one frame allocation.
  packet.scene.directGPU={buffer,byteLength:2048,ranges:{matrices:{offset:1024,bytes:128},triangles:{offset:1280,bytes:16}}};
  return {runtime,packet,borrowed,imports,released,buffer};
}

test('direct ranges preserve GPU identity and CPU views until the packet releases once',()=>{
  const f=fixture(),cpu=f.packet.scene.matrices;
  importDirectPacket(f.runtime,f.packet);
  assert.equal(f.borrowed.size,2);assert.equal(f.packet.scene.matrices,cpu);
  assert.equal(f.packet.scene.directGpuResources.matrices.buffer,f.buffer);
  assert.equal(f.packet.scene.directGpuResources.matrices.offset,1024);
  assert.equal(f.packet.scene.directGpuResources.triangles.offset,1280);
  f.packet.release();f.packet.release();
  assert.equal(f.borrowed.size,0);assert.equal(f.released.length,2);assert.equal(f.packet.releases,1);
});

test('a failed later range rolls back earlier imports before WASM owner cleanup',()=>{
  for(const bad of [{offset:1280,bytes:20},{offset:1024,bytes:16},{offset:2048,bytes:16},{offset:1284,bytes:16}]) {
    const f=fixture();f.packet.scene.directGPU.ranges.triangles=bad;
    assert.throws(()=>importDirectPacket(f.runtime,f.packet),/range|overlap/i);
    assert.equal(f.imports.length,1);assert.equal(f.released.length,1);assert.equal(f.borrowed.size,0);
    assert.equal(f.packet.scene.directGpuResources,undefined);
    f.packet.release();assert.equal(f.packet.releases,1);
  }
});

test('direct packets reject missing ownership extent and unknown scene arrays',()=>{
  const missing=fixture();delete missing.packet.scene.directGPU.byteLength;
  assert.throws(()=>importDirectPacket(missing.runtime,missing.packet),/packet/);
  const unknown=fixture();unknown.packet.scene.directGPU.ranges.other={offset:1536,bytes:4};
  unknown.packet.scene.other=new Uint32Array(1);
  assert.throws(()=>importDirectPacket(unknown.runtime,unknown.packet),/other/);
  assert.equal(unknown.borrowed.size,0);
});
