import assert from 'node:assert/strict';
import {atlasUploadRanges} from './atlas-upload.js';

assert.deepEqual(atlasUploadRanges(0),[]);
assert.deepEqual(atlasUploadRanges(13),[[0,13]]);
// Mixed scalar depth and four-word floating color targets, out of order.
assert.deepEqual(atlasUploadRanges(64,new Uint32Array([
  0x20000002,24,2,2,0x80000001,8,2,2,
])),[[0,8],[12,24],[40,64]]);
// Adjacent and overlapping outputs are omitted once. Metadata gaps survive.
assert.deepEqual(atlasUploadRanges(24,new Uint32Array([
  1,4,4,1,2,8,4,1,3,6,4,1,4,16,4,1,
])),[[0,4],[12,16],[20,24]]);
// Address calculations must not truncate byte offsets to signed i32.
const base=2**30+4;
assert.deepEqual(atlasUploadRanges(base+8,new Uint32Array([1,base,2,2])),[[0,base],[base+4,base+8]]);
assert.deepEqual(atlasUploadRanges(8192*8192+2,new Uint32Array([0x80000001,1,8192,8192])),[[0,1],[8192*8192+1,8192*8192+2]]);
// Compact engine packets have CPU metadata only; the GPU owns attachment pixels.
assert.deepEqual(atlasUploadRanges(11,new Uint32Array([0x80000001,11,8192,8192]),11+8192*8192),[[0,11]]);
assert.deepEqual(atlasUploadRanges(8,new Uint32Array([0x80000001,8,2,2,0x20000002,12,2,2]),28),[[0,8]]);
assert.deepEqual(atlasUploadRanges(8,new Uint32Array([1,4,8,1]),12),[[0,4]]);
for(const extent of [7,-1,Infinity,8.5,Number.MAX_SAFE_INTEGER+1])
  assert.throws(()=>atlasUploadRanges(8,new Uint32Array(),extent),RangeError);
assert.throws(()=>atlasUploadRanges(8,new Uint32Array([0x20000002,12,2,2]),27),RangeError);
assert.deepEqual(atlasUploadRanges(32,new Uint32Array([0x80000001,32,4,4]),48,[[2,8],[16,24]]),[[0,2],[8,16],[24,32]]);
assert.throws(()=>atlasUploadRanges(8,new Uint32Array(),8,[[4,9]]),RangeError);
for(const copies of [new Uint32Array([1]),new Uint32Array([0,0,1,1]),new Uint32Array([1,0,0,1]),
  new Uint32Array([1,31,2,1]),new Uint32Array([0x20000001,17,2,2])])
  assert.throws(()=>atlasUploadRanges(32,copies),RangeError);
// Compare against a word-level reference across overlapping random ranges.
let seed=17;const random=()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed;};
for(let trial=0;trial<500;trial++) {
  const count=1+random()%200,expected=new Uint8Array(count).fill(1),copies=[];
  for(let i=0;i<10;i++) {
    const start=random()%count,length=1+random()%(count-start);
    copies.push(i+1,start,length,1);expected.fill(0,start,start+length);
  }
  const actual=new Uint8Array(count);
  for(const [first,last] of atlasUploadRanges(count,new Uint32Array(copies)))actual.fill(1,first,last);
  assert.deepEqual(actual,expected);
}
console.log('Atlas uploads: scalar/wide attachments, preserved metadata, overlap, large offsets, bounds and 500 randomized layouts passed');
