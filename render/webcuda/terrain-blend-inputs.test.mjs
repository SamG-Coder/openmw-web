import test from 'node:test';
import assert from 'node:assert/strict';
import {terrainBlendInputRange} from './terrain-blend-inputs.js';

test('categorical masks share validated raw grids across layers and upload through their descriptors',()=>{
  const heap=new Uint32Array(new SharedArrayBuffer(32*4)),blocks=heap.subarray(3,19);
  blocks.set([2,2,3,0,1,2,0,0,0,0,7,0,2,0,7]);
  const before=heap.slice(),validated=new Map();
  assert.deepEqual(terrainBlendInputRange(blocks,7,4,4,validated),{offset:0,words:11});
  assert.deepEqual(terrainBlendInputRange(blocks,11,4,4,validated),{offset:0,words:15});
  assert.equal(validated.size,1);assert.deepEqual(heap,before);
  assert.throws(()=>terrainBlendInputRange(blocks,11,8,4,validated),/Invalid terrain blend/);
  for(const [index,value] of [[0,0],[1,3],[2,0],[3,3],[7,2],[8,3],[9,1],[10,5]]) {
    const invalid=blocks.slice();invalid[index]=value;
    assert.throws(()=>terrainBlendInputRange(invalid,7,4,4),/Invalid terrain blend/);
  }
});

function quadFixture() {
  // One 1x1 output pixel reads source vertex (0,16), after two ordered layers.
  const data=[1,1,3,4,0,...Array(290).fill(295)];
  for(let v=273;v<290;v++)data[5+v]=299;
  data.push(1,0x3f000000,2,0x3e800000);
  const descriptor=data.length;data.push(1,2,0,descriptor);
  return {blocks:Uint32Array.from(data),descriptor};
}

test('terrain payloads validate at nonzero offsets after unrelated compressed data',()=>{
  for(const {blocks,descriptor} of [quadFixture(),{blocks:Uint32Array.from([1,1,2,0,0,1,0,4]),descriptor:4}]) {
    const relocated=new Uint32Array(blocks.length+7).fill(0xdeadbeef);
    relocated.set(blocks,7);relocated[descriptor+9]=7;
    assert.deepEqual(terrainBlendInputRange(relocated,descriptor+7,descriptor===4?2:1,descriptor===4?2:1),
      {offset:7,words:descriptor+4});
  }
});

test('sparse ESM4 vertex ranges reject invalid addresses, ordering, layers and opacity bits',()=>{
  const {blocks,descriptor}=quadFixture();
  assert.deepEqual(terrainBlendInputRange(blocks,descriptor,1,1),{offset:0,words:descriptor+4});
  for(const [index,value] of [[0,2],[1,2],[3,3],[3,300],[4,3],[5,294],[6,294],
    [5+273,298],[5+289,300],[295,3],[296,0x7fc00000],[298,0x7f800000],[descriptor+2,1]]) {
    const invalid=blocks.slice();invalid[index]=value;
    assert.throws(()=>terrainBlendInputRange(invalid,descriptor,1,1),/Invalid terrain blend/);
  }
  const missing=Uint32Array.from([1,1,3,0,1,0,0,4]);
  assert.deepEqual(terrainBlendInputRange(missing,4,1,1),{offset:0,words:8});
  for(const offset of [-1,.5,blocks.length-3])assert.throws(()=>terrainBlendInputRange(blocks,offset,1,1),/Invalid terrain blend/);
});
