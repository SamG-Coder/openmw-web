// Exercise the real host scheduling path with controlled GPU completion.
// Kernel arithmetic is covered by the CUDA numerical and GPU fixtures.
import test from 'node:test';
import assert from 'node:assert/strict';
import {MaterialPipeline} from './pipeline.js';
import {FrameReadbacks} from './frame-readbacks.js';

function fixture() {
  const commands=[],reads=[],allocations=[];
  const runtime={uniformAlignment:256,uniformCapacity:65536,
    device:{limits:{maxTextureDimension2D:8192,maxBufferSize:64*1024*1024,maxStorageBufferBindingSize:64*1024*1024,maxComputeWorkgroupsPerDimension:65535}},
    status:0,references:1,gate:null,
    createBuffer(byteLength,{label}={}){const resource={byteLength,label,data:new Uint8Array(byteLength)};allocations.push(resource);return resource;},
    write(resource,data,offset=0){resource.data.set(new Uint8Array(data.buffer,data.byteOffset,data.byteLength),offset);},
    destroyBuffer(){},async idle(){},
    async read(resource,Type,byteLength,offset=0){
      reads.push(resource.label);const result=new Type(resource.data.slice(offset,offset+byteLength).buffer);
      if(this.gate)await this.gate;return result;
    },
    batch(){return {
      dispatch(invocation){
        commands.push(invocation.name);
        if(invocation.name==='bin_triangle_bounds'&&!invocation.scalars.scatter)runtime.references=invocation.scalars.triangle_count?1:0;
        if(invocation.name==='prefix_tile_block_totals')new Uint32Array(invocation.resources.summary.data.buffer).set([invocation.scalars.tile_count+1+runtime.references,runtime.status]);
        return this;
      },copy(source,target,{sourceOffset=0,targetOffset=0,byteLength}){
        target.data.set(source.data.subarray(sourceOffset,sourceOffset+byteLength),targetOffset);return this;
      },endPass(){},submit(){return Promise.resolve();}
    };}};
  const kernels=new Proxy({}, {get:(_,name)=>({bind(resources,scalars){return {name,resources,scalars,kernel:{artifact:{metadata:{uniformSize:64}}}};}})});
  const pipeline=new MaterialPipeline(runtime,kernels);
  const readbacks=new FrameReadbacks(runtime,bytes=>pipeline.buffer('frameReadback',bytes));
  const scene=(triangles=1)=>({vertices:new Float32Array(30),matrices:new Float32Array(32),matrixIds:new Uint32Array(3),
    triangles:Uint32Array.from({length:triangles*4},(_,i)=>[0,1,2,0][i%4]),materials:new Uint32Array(12),texels:new Uint32Array(1),attributes:new Float32Array(102)});
  return {runtime,pipeline,readbacks,scene,commands,reads,allocations,
    pass:{deferCompletion:true,readback:(...args)=>readbacks.read(...args)}};
}

test('bounded passes queue through reused scratch and defer status mapping until frame end',async()=>{
  const f=fixture(),completions=[];
  for(let i=0;i<4;i++) {
    f.runtime.status=i===1?1:0;
    completions.push((await f.pipeline.render(f.scene(),32,32,null,f.pass)).queryCompletion);
  }
  assert.equal(f.reads.length,0);assert.equal(f.commands.filter(name=>name==='raster_material').length,4);
  await f.readbacks.flush();const results=await Promise.all(completions);
  assert.equal(f.reads.length,1);assert.equal(results[0].diagnostic.tileReferences,1);
  assert.match(results[1].error.message,/singular/);
  assert.equal(results[2].error,undefined);assert.equal(results[3].error,undefined);
});

test('an unproven large pass still waits for exact sizing before scatter or raster',async()=>{
  const f=fixture();let release;
  f.runtime.gate=new Promise(resolve=>{release=resolve;});
  const pending=f.pipeline.render(f.scene(150),512,512,null,f.pass);
  for(let i=0;i<10&&!f.reads.length;i++)await new Promise(setImmediate);
  assert.deepEqual(f.reads,['OpenMW tileSummary']);
  assert(!f.commands.includes('copy_tile_offsets'));assert(!f.commands.includes('raster_material'));
  release();const rendered=await pending;await f.readbacks.flush();
  assert(f.commands.includes('raster_material'));assert.equal((await rendered.queryCompletion).error,undefined);
});

test('retained storage skips inline sizing only when it covers the full proven bound',async()=>{
  const f=fixture();f.pipeline.buffer('candidates',5*1024*1024);
  const before=f.allocations.length;
  const rendered=await f.pipeline.render(f.scene(150),512,512,null,f.pass);
  assert.equal(f.reads.length,0);assert(f.commands.includes('raster_material'));
  assert(!f.allocations.slice(before).some(resource=>resource.label==='OpenMW candidates'));
  await f.readbacks.flush();assert.equal((await rendered.queryCompletion).error,undefined);
});

test('a large-pass allocation error stops before any scatter or raster',async()=>{
  const f=fixture();f.runtime.status=2;
  await assert.rejects(f.pipeline.render(f.scene(150),512,512,null,f.pass),/buffer capacity/);
  assert(!f.commands.includes('copy_tile_offsets'));assert(!f.commands.includes('raster_material'));
  f.readbacks.cancel(Error('frame failed'));assert.equal(f.pipeline.busy,false);
});

test('empty cameras retain clear and completion semantics without no-op framebuffer dispatches',async()=>{
  for(const [triangles,clearMask] of [[0,0],[0,17664],[1,0],[1,17664]]) {
    const f=fixture(),rendered=await f.pipeline.render(f.scene(triangles),32,32,null,{...f.pass,clearMask});
    assert.equal(f.commands.includes('clear_attachment'),clearMask!==0);
    assert.equal(f.commands.includes('raster_material'),triangles!==0);
    assert.equal(f.reads.length,0,'Empty cameras still defer status validation');
    await f.readbacks.flush();
    const result=await rendered.queryCompletion;
    assert.equal(result.error,undefined);assert.equal(result.diagnostic.triangleCount,triangles);
    assert.equal(result.diagnostic.tileReferences,triangles?1:0);
  }
});

test('terrain masks and their mip chains generate once, then restore from immutable texture residency',async()=>{
  const f=fixture(),scene=f.scene();
  scene.texels=new Uint32Array(5);
  scene.compressedBlocks=new Uint32Array([1,1,2,0,0,0,0,4]);
  scene.textureDecodes=new Uint32Array([4,0,2,2,259]);
  scene.textureResources=new Uint32Array([234,0,5]);
  scene.mipGenerations=new Uint32Array([0,4,2,2]);
  for(let frame=0;frame<2;frame++) {
    const readbacks=new FrameReadbacks(f.runtime,bytes=>f.pipeline.buffer('frameReadback',bytes));
    const rendered=await f.pipeline.render(scene,32,32,null,{deferCompletion:true,readback:(...args)=>readbacks.read(...args)});
    await readbacks.flush();assert.equal((await rendered.queryCompletion).error,undefined);
  }
  assert.equal(f.commands.filter(name=>name==='generate_terrain_blendmap').length,1);
  assert.equal(f.commands.filter(name=>name==='generate_mip').length,1);
  assert.equal(f.commands.filter(name=>name==='raster_material').length,2);
});
