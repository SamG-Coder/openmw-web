import test from 'node:test';
import assert from 'node:assert/strict';
import {FrameReadbacks} from './frame-readbacks.js';

function fixture(capacity=65536) {
  const commands=[],reads=[],allocations=[];
  let readError=null;
  const runtime={device:{limits:{maxBufferSize:2**30,maxStorageBufferBindingSize:2**30}},
    batch(){const operations=[];return {
      copy(source,target,{sourceOffset=0,targetOffset=0,byteLength=source.byteLength}) {
        operations.push(()=>target.data.set(source.data.subarray(sourceOffset,sourceOffset+byteLength),targetOffset));return this;
      },submit(){commands.push(...operations);}
    };},
    read(source,Type,byteLength=source.byteLength,offset=0) {
      reads.push({source,byteLength,offset});
      let resolve,reject;const result=new Promise((yes,no)=>{resolve=yes;reject=no;});
      commands.push(()=>readError?reject(readError):resolve(new Type(source.data.slice(offset,offset+byteLength).buffer)));
      return result;
    }};
  const buffer=data=>({data:new Uint8Array(data),byteLength:typeof data==='number'?data:data.byteLength});
  const collector=new FrameReadbacks(runtime,bytes=>{const value=buffer(bytes);allocations.push(value);return value;},capacity);
  return {collector,runtime,reads,allocations,buffer,
    write(target,data){commands.push(()=>target.data.set(new Uint8Array(data.buffer,data.byteOffset,data.byteLength)));},
    execute(){for(const command of commands.splice(0))command();},fail(error){readError=error;}};
}

test('64 reused pass buffers preserve GPU snapshots through one frame readback',async()=>{
  const f=fixture(),source=f.buffer(16),completions=[];
  for(let i=0;i<64;i++) {
    f.write(source,new Uint32Array([0xdeadbeef,i,i+1000,0xcafef00d]));
    completions.push(f.collector.read(source,Uint32Array,8,4));
  }
  f.write(source,new Uint32Array(4).fill(99));
  assert.equal(f.reads.length,0);assert.equal(f.allocations.length,1);
  let completed=false;completions[0].then(()=>{completed=true;});
  const flushed=f.collector.flush();assert.equal(flushed,f.collector.flush());
  assert.equal(f.reads.length,1);assert.equal(f.reads[0].byteLength,512);
  await Promise.resolve();assert.equal(completed,false);
  f.execute();await flushed;
  const results=await Promise.all(completions);
  for(let i=0;i<64;i++)assert.deepEqual([...results[i]],[i,i+1000]);
  assert.equal(new Set(results.map(result=>result.buffer)).size,1);
  assert.throws(()=>f.collector.read(source),/closed/);
});

test('mixed result types retain float bits, signed values and exact subranges',async()=>{
  const f=fixture(),source=f.buffer(16);
  f.write(source,new Float32Array([99,.5,-3.25,NaN]));
  const floats=f.collector.read(source,Float32Array,8,4);
  f.write(source,new Int32Array([99,-1,-2147483648,99]));
  const signed=f.collector.read(source,Int32Array,8,4);
  const flushed=f.collector.flush();f.execute();await flushed;
  assert.deepEqual([...await floats],[.5,-3.25]);
  assert.deepEqual([...await signed],[-1,-2147483648]);
});

test('a full staging buffer falls back to ordered reads without growing or dropping results',async()=>{
  const f=fixture(8),source=f.buffer(16);
  f.write(source,new Uint32Array([1,2,3,4]));
  const first=f.collector.read(source,Uint32Array,8);
  f.write(source,new Uint32Array([5,6,7,8]));
  const fallback=f.collector.read(source,Uint32Array,12,4);
  f.write(source,new Uint32Array(4).fill(99));
  const flushed=f.collector.flush();f.execute();await flushed;
  assert.deepEqual([...await first],[1,2]);assert.deepEqual([...await fallback],[6,7,8]);
  assert.equal(f.allocations.length,1);assert.equal(f.allocations[0].byteLength,8);
  assert.deepEqual(f.reads.map(read=>read.byteLength),[12,8]);
});

test('invalid ranges are rejected before GPU work and empty frames allocate nothing',async()=>{
  const f=fixture(),source=f.buffer(16);
  for(const [bytes,offset] of [[3,0],[4,1],[20,0],[4,16],[-4,0],[4,-4],[Infinity,0]])
    assert.throws(()=>f.collector.read(source,Uint32Array,bytes,offset),/range/);
  assert.throws(()=>f.collector.read(source,Uint8Array,4),/32-bit/);
  assert.equal((await f.collector.read(source,Float32Array,0,16)).length,0);
  await f.collector.flush();assert.equal(f.allocations.length,0);assert.equal(f.reads.length,0);
});

test('mapping failures and aborted frames reject all pending readers without destroying storage',async()=>{
  for(const abort of [false,true]) {
    const f=fixture(),source=f.buffer(8),error=Error(abort?'frame aborted':'device lost');
    const a=f.collector.read(source),b=f.collector.read(source);
    const checked=Promise.all([assert.rejects(a,error),assert.rejects(b,error)]);
    if(abort){f.collector.cancel(error);assert.throws(()=>f.collector.flush(),/closed/);}
    else {f.fail(error);const flushed=f.collector.flush();f.execute();await assert.rejects(flushed,error);}
    await checked;assert.equal(f.collector.records.length,0);
    assert.equal(f.allocations.length,1);assert.equal(f.allocations[0].byteLength,65536);
  }
});
