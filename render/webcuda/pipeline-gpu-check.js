// Exercise the production host and its CUDA kernels together. Fixture inputs
// and analytical readback expectations are test data, not a JS renderer.
import { MaterialPipeline } from './pipeline.js';

export async function checkPipelineGpu(runtime,kernels) {
  const pipeline=new MaterialPipeline(runtime,kernels),owned=[];
  const width=8,height=6,pixels=width*height,guard=12345,checks=[];
  const allocate=data=>{const buffer=runtime.createBuffer(data);owned.push(buffer);return buffer;};
  const initial=new Float32Array(pixels*10+4);
  for(let i=0;i<pixels;i++)initial.set([0,0,0,1,.875,0,1,0,1],i*9);
  initial.fill(9,pixels*9,pixels*10);initial.fill(guard,pixels*10);
  const target=allocate(initial);
  const scene=(draw=true)=>{
    const matrices=new Float32Array(32);
    for(const base of [0,16])for(let i=0;i<4;i++)matrices[base+i*5]=1;
    return {
      vertices:new Float32Array(draw?[
        -1,1,0,1,1,0,0,.5,0,0, 1,1,0,1,1,0,0,.5,1,0,
        1,-1,0,1,1,0,0,.5,1,1, -1,-1,0,1,1,0,0,.5,0,1]:[]),
      matrices,matrixIds:new Uint32Array(draw?4:0),
      triangles:new Uint32Array(draw?[0,1,2,0,0,2,3,0]:[]),
      materials:new Uint32Array(draw?[0,1,1,2|4|8,0,0,0,width,height,0,0,0]:[]),
      texels:new Uint32Array([0xffffffff])
    };
  };
  const options={target,colorFormat:0x8814,normalFormat:0x8814,depthFormat:0x8cad,
    normalTargetId:1,stencilBits:8,deferCompletion:true,clearMask:0};
  const render=async(input,pass={})=>{
    const result=await pipeline.render(input,width,height,null,{...options,...pass});
    const completed=await result.queryCompletion;
    if(completed.error)throw completed.error;
    await runtime.idle();pipeline.collectRetired();
    return runtime.read(target,Float32Array,initial.byteLength);
  };
  const equal=(name,actual,expected)=>{
    if(actual.length!==expected.length)throw Error(`${name}: length mismatch`);
    for(let i=0;i<expected.length;i++)if(!Number.isFinite(actual[i])||Math.abs(actual[i]-expected[i])>1e-6)
      throw Error(`${name}: word ${i}, expected ${expected[i]}, got ${actual[i]}`);
    checks.push(name);
  };
  const inViewport=(i,v)=>i%width>=v[0]&&i%width<v[0]+v[2]
    &&height-1-Math.floor(i/width)>=v[1]&&height-1-Math.floor(i/width)<v[1]+v[3];
  try {
    equal('Pipeline empty camera preserves every attachment and guards',await render(scene(false)),initial);
    for(const samples of [1,4]) {
      const sampleTarget=samples===1?null:allocate(new Float32Array(pixels*10*samples+4).fill(guard));
      for(const mask of [256,1024,16384,17664]) {
        runtime.write(target,initial);
        if(sampleTarget)pipeline.seedMultisample(target,sampleTarget,width,height,samples);
        const viewport=[2,1,4,3],expected=initial.slice();
        for(let i=0;i<pixels;i++)if(inViewport(i,viewport)) {
          if(mask&16384)for(const plane of [0,5])expected.set([.25,.5,.75,1],i*9+plane);
          if(mask&256)expected[i*9+4]=.25;
          if(mask&1024)expected[pixels*9+i]=37;
        }
        const result=await render(scene(false),{sampleCount:samples,sampleTarget,viewport,
          clearMask:mask,clearColor:[.25,.5,.75,1],clearDepth:.25,clearStencil:37});
        equal(`Pipeline ${samples}x empty-camera clear mask ${mask}, partial viewport and guards`,result,expected);
        if(sampleTarget) {
          const tail=await runtime.read(sampleTarget,Float32Array,16,pixels*10*samples*4);
          if(tail.some(value=>value!==guard))throw Error('Multisample clear overwrote trailing guards');
        }
      }
      runtime.write(target,initial);
      if(sampleTarget)pipeline.seedMultisample(target,sampleTarget,width,height,samples);
      const expected=initial.slice();
      for(let i=0;i<pixels;i++){expected.set([.5,0,0,1,.5],i*9);}
      equal(`Pipeline ${samples}x transformed, clipped and tiled quad blends once per sample`,
        await render(scene(),{sampleCount:samples,sampleTarget}),expected);
      equal(`Pipeline ${samples}x equal-depth draw preserves previous color`,
        await render(scene(),{sampleCount:samples,sampleTarget}),expected);
    }
    runtime.write(target,initial);
    const translated=scene();translated.matrices[12]=.5;
    const translatedExpected=initial.slice();
    for(let i=0;i<pixels;i++)if(i%width>=2)translatedExpected.set([.5,0,0,1,.5],i*9);
    equal('Pipeline model-view translation and right-plane clipping preserve uncovered pixels',
      await render(translated),translatedExpected);
    // Generate a Morrowind terrain mask, sample it in the rasterizer, then reuse
    // its immutable residency after overwriting the scratch atlas in another pass.
    const terrain=scene();
    for(let i=0;i<4;i++)terrain.vertices.set([1,1,1,1],i*10+4);
    terrain.materials.set([0,4,4,1|2,0,0,0,width,height,0,0,0]);
    terrain.texels=new Uint32Array(16);
    terrain.compressedBlocks=new Uint32Array([2,2,2,0,1,1,0,0,1,0,7]);
    terrain.textureDecodes=new Uint32Array([7,0,4,4,259]);
    terrain.textureResources=new Uint32Array([987,0,16]);
    const expected=initial.slice();
    for(let i=0;i<pixels;i++) {
      // Stored texture rows are sampled with top-left vertex UV=(0,0).
      const covered=(i%width>=width/2)!==(Math.floor(i/width)>=height/2);
      if(covered)expected.set([1,1,1,1],i*9);
    }
    for(let repetition=0;repetition<2;repetition++) {
      runtime.write(target,initial);
      const result=await render(terrain);
      equal(`Pipeline CUDA terrain generation and sampling ${repetition?'after residency restore':'on cache miss'}`,result,expected);
      if(repetition===0)await render(scene(false));
    }
    return checks;
  } finally {
    try {await runtime.idle();}
    finally {pipeline.dispose();for(const buffer of owned)runtime.destroyBuffer(buffer);}
  }
}
