// Exercise the real host scheduling path with controlled GPU completion.
// Native shader arithmetic is covered by gpu-check.mjs on an actual WebGPU device.
import test from 'node:test';
import assert from 'node:assert/strict';
import {MaterialPipeline} from './pipeline.js';
import {FrameReadbacks} from './frame-readbacks.js';
import {ImmutableBufferResidency} from './texture-residency.js';

function fixture() {
  const commands=[],reads=[],allocations=[],invocations=[];
  const runtime={uniformAlignment:256,uniformCapacity:65536,
    device:{limits:{maxTextureDimension2D:8192,maxBufferSize:64*1024*1024,maxStorageBufferBindingSize:64*1024*1024,maxComputeWorkgroupsPerDimension:65535}},
    status:0,gate:null,
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
        invocations.push(invocation);
        if(invocation.name==='resolve_camera')new Uint32Array(invocation.resources.status.data.buffer)[invocation.scalars.status_index]=runtime.status;
        return this;
      },copy(source,target,{sourceOffset=0,targetOffset=0,byteLength}){
        target.data.set(source.data.subarray(sourceOffset,sourceOffset+byteLength),targetOffset);return this;
      },endPass(){},submit(){return Promise.resolve();}
    };}};
  const kernels=new Proxy({}, {get:(_,name)=>({bind(resources,scalars){return {name,resources,scalars,kernel:{artifact:{metadata:{uniformSize:64}}}};}})});
  const rasterizer={async render(resources,params,options){
    commands.push('hardware_render');invocations.push({name:'hardware_render',resources,scalars:params,options});
    return {drawCalls:1,gpuMs:null};
  },dispose(){}};
  const pipeline=new MaterialPipeline(runtime,kernels,rasterizer);
  const readbacks=new FrameReadbacks(runtime,bytes=>pipeline.buffer('frameReadback',bytes));
  const scene=(triangles=1)=>({vertices:new Float32Array(30),matrices:new Float32Array(32),matrixIds:new Uint32Array(3),
    triangles:Uint32Array.from({length:triangles*4},(_,i)=>[0,1,2,0][i%4]),materials:new Uint32Array(12),texels:new Uint32Array(1),attributes:new Float32Array(102)});
  return {runtime,pipeline,readbacks,scene,commands,reads,allocations,invocations,
    pass:{deferCompletion:true,readback:(...args)=>readbacks.read(...args)}};
}

test('positioned WGSL preparation uses one upload before each descriptor consumer',async()=>{
  const f=fixture(),scene=f.scene(),writes=[];
  scene.fixedLighting=new Uint32Array(368);scene.fixedLighting.set([1,128,0,1]);
  new Float32Array(scene.fixedLighting.buffer)[48+23]=180;
  scene.texgen=new Uint32Array(144);scene.texgen.set([1,5,0,9]);
  scene.positionedState=new Uint32Array(24);scene.positionedState[0]=9;
  for(let k=0;k<4;k++)new Float32Array(scene.positionedState.buffer)[8+k*5]=1;
  const write=f.runtime.write;
  f.runtime.write=(buffer,data,offset)=>{writes.push(buffer.label);write(buffer,data,offset);};
  const rendered=await f.pipeline.render(scene,32,32,null,f.pass);
  for(const [prepare,consume,buffer] of [['prepare_fixed_matrices','shade_fixed_vertices','fixedLighting'],
    ['prepare_texgen_matrices','generate_texture_coordinates','texgen']]) {
    assert(f.commands.indexOf(prepare)>=0&&f.commands.indexOf(prepare)<f.commands.indexOf(consume));
    const before=f.invocations.find(i=>i.name===prepare),after=f.invocations.find(i=>i.name===consume);
    assert.equal(before.resources.descriptors,after.resources.descriptors);
    assert.equal(before.scalars.draw_count,1);assert.equal(writes.filter(label=>label===`OpenMW ${buffer}`).length,1);
  }
  assert.equal(writes.filter(label=>label==='OpenMW positionedState').length,1);
  assert.equal(scene.fixedLighting[3],1);assert.equal(scene.positionedState[0],9);
  f.commands.length=0;
  const plain=await f.pipeline.render(f.scene(),32,32,null,f.pass);await f.readbacks.flush();await Promise.all([rendered.queryCompletion,plain.queryCompletion]);
  assert(!f.commands.some(name=>name==='prepare_fixed_matrices'||name==='prepare_texgen_matrices'));
});

test('bounded passes queue through reused scratch and defer status mapping until frame end',async()=>{
  const f=fixture(),completions=[];
  for(let i=0;i<4;i++) {
    f.runtime.status=i===1?1:0;
    completions.push((await f.pipeline.render(f.scene(),32,32,null,f.pass)).queryCompletion);
  }
  assert.equal(f.reads.length,0);assert.equal(f.commands.filter(name=>name==='hardware_render').length,4);
  await f.readbacks.flush();const results=await Promise.all(completions);
  assert.equal(f.reads.length,1);assert.equal(results[0].diagnostic.hardwareDrawCalls,1);
  assert.match(results[1].error.message,/singular/);
  assert.equal(results[2].error,undefined);assert.equal(results[3].error,undefined);
});

test('compact input construction precedes deformation and transformation without expanded host uploads',async()=>{
  const f=fixture(),scene=f.scene(),count=scene.matrixIds.length;
  scene.vertexEncoding=1;scene.vertexLayouts=new Uint32Array(32);
  scene.vertexLayouts.set([0,count,count,0,0,0,0,count*10,count*44]);
  scene.vertexInputs=new Float32Array(count*47);
  scene.vertexInputs.set(scene.vertices);scene.vertexInputs.set(scene.attributes,count*10);
  scene.vertices=new Float32Array();scene.attributes=new Float32Array();scene.secondaryColors=new Float32Array();
  const writes=[],write=f.runtime.write;
  f.runtime.write=(resource,data,offset)=>{writes.push(resource.label);write(resource,data,offset);};
  const rendered=await f.pipeline.render(scene,32,32,null,f.pass);await f.readbacks.flush();await rendered.queryCompletion;
  assert(f.commands.indexOf('unpack_vertex_inputs')>=0);
  assert(f.commands.indexOf('unpack_vertex_inputs')<f.commands.indexOf('expand_particles'));
  assert(f.commands.indexOf('unpack_vertex_inputs')<f.commands.indexOf('transform_attributes'));
  assert(writes.includes('OpenMW vertexInputs')&&writes.includes('OpenMW vertexLayouts'));
  for(const name of ['vertices','attributes','secondaryColors'])assert(!writes.includes(`OpenMW ${name}`));
  const bad=fixture(),malformed={...scene,vertexLayouts:scene.vertexLayouts.slice()};malformed.vertexLayouts[7]=999999;
  await assert.rejects(bad.pipeline.render(malformed,32,32,null,bad.pass),/storage/);
  assert.equal(bad.allocations.length,0);
});

test('resident vertex streams survive scratch reuse and relocate without another host upload',async()=>{
  const f=fixture(),writes=[];
  f.pipeline.vertexResidency=new ImmutableBufferResidency(f.runtime,{budgetBytes:1024,kind:'vertex stream'});
  const write=f.runtime.write;f.runtime.write=(buffer,data,offset=0)=>{if(buffer.label==='OpenMW vertexInputs')writes.push(data.byteLength);write(buffer,data,offset);};
  const make=(version,shift=0,value=7)=>{
    const scene=f.scene(),count=scene.matrixIds.length;
    scene.vertexEncoding=1;scene.vertexLayouts=new Uint32Array(32);
    scene.vertexLayouts.set([0,count,count,0,0,0,shift,shift+count*10,shift+count*44]);
    scene.vertexInputs=new Float32Array(shift+count*47);scene.vertexInputs[shift]=value;
    scene.vertexResources=new Uint32Array(version?[version,shift,count*10]:[]);
    scene.vertices=new Float32Array();scene.attributes=new Float32Array();scene.secondaryColors=new Float32Array();return scene;
  };
  const render=async scene=>{
    const frame=new FrameReadbacks(f.runtime,bytes=>f.pipeline.buffer('frameReadback',bytes));
    const result=await f.pipeline.render(scene,32,32,null,{...f.pass,readback:(...args)=>frame.read(...args)});
    await frame.flush();await result.queryCompletion;f.pipeline.collectRetired();
  };
  await render(make(1));assert.equal(writes.reduce((a,b)=>a+b,0),3*47*4);
  await render(make(0,0,99)); // A different camera overwrites the scratch input.
  writes.length=0;await render(make(1,4));
  assert.equal(writes.reduce((a,b)=>a+b,0),(4+3*37)*4);
  const restored=new Float32Array(f.pipeline.buffers.get('vertexInputs').data.buffer);
  assert.equal(restored[4],7);assert.equal(f.pipeline.vertexResidency.snapshot().hits,1);
  writes.length=0;await render(make(2,4,17));
  assert.equal(writes.reduce((a,b)=>a+b,0),(4+3*47)*4);assert.equal(restored[4],17);
  const bad=fixture(),invalid=make(3);invalid.vertexResources[1]=999999;
  await assert.rejects(bad.pipeline.render(invalid,32,32,null,bad.pass),/range/);assert.equal(bad.allocations.length,0);
  f.pipeline.dispose();assert.equal(f.pipeline.vertexResidency.snapshot().allocatedBytes,0);
});


test('large cameras prepare one triangle slot without clipping or tile allocation readbacks',async()=>{
  const f=fixture();
  const result=await f.pipeline.render(f.scene(4096),32,32,null,f.pass);
  assert.deepEqual(f.reads,[],'GPU status is collected at the frame boundary');
  const prepared=f.invocations.find(i=>i.name==='prepare_triangles');
  const assembled=f.invocations.find(i=>i.name==='assemble_material');
  const drawn=f.invocations.find(i=>i.name==='hardware_render');
  assert.equal(prepared.scalars.triangle_count,4096);
  assert.equal(assembled.scalars.slot_count,4096);
  assert.equal(drawn.options.triangleCount,4096);
  assert(f.commands.indexOf('prepare_triangles')<f.commands.indexOf('assemble_material'));
  assert(f.commands.indexOf('assemble_material')<f.commands.indexOf('hardware_render'));
  assert(!f.commands.some(name=>/clip_triangles|prefix_clip|scatter_clip|tile|raster_material/.test(name)));
  assert(!f.allocations.some(b=>/clipSummary|tileSummary|candidates|compactValid/.test(b.label)));
  await f.readbacks.flush();
  const completed=await result.queryCompletion;
  assert.equal(completed.error,undefined);
  assert.equal(completed.diagnostic.packedTriangles,4096);
  assert.equal(completed.diagnostic.hardwareDrawCalls,1);
});

test('empty cameras retain clears and frame completion without a hardware draw',async()=>{
  const f=fixture();
  const result=await f.pipeline.render(f.scene(0),32,32,null,{...f.pass,clearMask:16640});
  assert(f.commands.includes('clear_attachment'));
  assert(!f.commands.includes('hardware_render'));
  await f.readbacks.flush();assert.equal((await result.queryCompletion).error,undefined);
});

test('singular camera status rejects frame validation after native work has been queued',async()=>{
  const f=fixture();f.runtime.status=1;
  const result=await f.pipeline.render(f.scene(),32,32,null,f.pass);
  await f.readbacks.flush();
  assert.match((await result.queryCompletion).error.message,/singular/);
  assert.equal(f.pipeline.busy,false);
});

test('WebGPU sample count support is explicit',async()=>{
  for(const count of [2,8,16]) {
    const f=fixture();
    await assert.rejects(f.pipeline.render(f.scene(),16,16,null,{...f.pass,sampleCount:count}),/sample count/);
    assert(!f.commands.includes('hardware_render'));
  }
});
