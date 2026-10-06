// Exercise the production host and its CUDA kernels together. Fixture inputs
// and analytical readback expectations are test data, not a JS renderer.
import { MaterialPipeline } from './pipeline.js';
import { particleInputReference } from './particle-input-gpu-check.js';
import { guiInputReference } from './gui-input-gpu-check.js';

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
    // Exercise the actual upload -> preparation -> consumer path. Each fixture
    // has an analytical color and a separately specified composed matrix;
    // omitting preparation changes the rendered result.
    for(const kind of ['light','texgen']) {
      const positioned=scene(),isLight=kind==='light';
      positioned.materials.set([isLight?0:2,isLight?1:2,1,isLight?2:1|2|512|16384,0,0,0,width,height,0,0,0]);
      if(isLight)positioned.texels=new Uint32Array([0xffffffff]);
      else {
        // TexGen is consumed by the fixed texture-environment path, whose
        // descriptor keeps homogeneous coordinates and its own texture matrix.
        positioned.texels=new Uint32Array(46);positioned.texels.set([0xff0000ff,0xff00ff00]);
        positioned.texels.set([2,1,0,0],26);
        for(let axis=0;axis<4;axis++)new Float32Array(positioned.texels.buffer)[30+axis*5]=1;
      }
      positioned.attributes=new Float32Array(4*34);
      for(let vertex=0;vertex<4;vertex++) {
        positioned.vertices.set([1,1,1,1],vertex*10+4);
        positioned.attributes[vertex*34+5]=1;
        for(let unit=0;unit<4;unit++)positioned.attributes[vertex*34+27+unit*2]=1;
      }
      const descriptors=new Uint32Array(isLight?368:144),values=new Float32Array(descriptors.buffer);
      const base=isLight?[2,0,0,0,0,3,0,0,0,0,4,0,0,0,0,1]:[2,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1];
      const post=isLight?[0,0,1,0,0,1,0,0,-1,0,0,0,0,0,0,1]:[1,0,0,0,0,1,0,0,0,0,1,0,4,0,0,1];
      const composed=isLight?[0,0,2,0,0,3,0,0,-4,0,0,0,0,0,0,1]:[2,0,0,0,0,1,0,0,0,0,1,0,4,0,0,1];
      const matrixOffset=isLight?72:20;
      if(isLight) {
        positioned.fixedLighting=descriptors;descriptors.set([1,128,0,0]);
        values.set([1,1,1,1],12);values.set([1,1,1,1],29);
        values.set([1,0,0,0],48);values.set([.25,.5,.75,1],56);values[71]=180;
      } else {
        positioned.texgen=descriptors;descriptors.set([3,5,0,0]);
        values.set([.125,0,0,.5],4);values.set([0,0,0,.5],8);
      }
      values.set(composed,matrixOffset);
      const expected=initial.slice();
      for(let i=0;i<pixels;i++)expected.set(isLight?[.25,.5,.75,1]:[1,0,0,1],i*9);
      runtime.write(target,initial);
      equal(`Pipeline positioned ${kind} analytical reference`,await render(positioned),expected);
      values.set(base,matrixOffset);descriptors[3]=1;
      positioned.positionedState=new Uint32Array(isLight?24:16);
      if(isLight)positioned.positionedState[0]=9;
      new Float32Array(positioned.positionedState.buffer).set(post,isLight?8:0);
      for(let capture=0;capture<2;capture++) {
        runtime.write(target,initial);
        equal(`Pipeline positioned ${kind} CUDA preparation ${capture?'after recapture':'before shading'}`,
          await render(positioned),expected);
      }
    }
    for(const compactKind of ['dense','streams']) {
      const compact=scene();compact.vertexEncoding=1;compact.vertexLayouts=new Uint32Array(32);
      compact.matrices[12]=.5;
      if(compactKind==='dense') {
        compact.vertexLayouts.set([0,4,4,0,0,0,0,40,176]);
        compact.vertexInputs=new Float32Array(188);compact.vertexInputs.set(compact.vertices);
        for(let i=0;i<4;i++) {
          compact.vertexInputs[40+i*34+16]=compact.vertices[i*10+8];
          compact.vertexInputs[40+i*34+17]=compact.vertices[i*10+9];
          for(let unit=0;unit<4;unit++)compact.vertexInputs[40+i*34+27+unit*2]=1;
        }
      } else {
        const inputs=[0,0,0];compact.vertexLayouts.set([0,4,4,1,0,0]);
        const streams=[[-1,1,0,1,1,1,0,1,1,-1,0,1,-1,-1,0,1],[1,0,0,.5],[0,0,0],[0,0,0],
          [0,0,0,0],[0],[0,0,0,1,1,0,0,1,1,1,0,1,0,1,0,1],[0,0,0,1],[0,0,0,1],[0,0,0,1]];
        for(let stream=0;stream<streams.length;stream++) {
          compact.vertexLayouts.set([inputs.length,stream===0||stream===6?4:0],8+stream*2);inputs.push(...streams[stream]);
        }
        compact.vertexInputs=new Float32Array(inputs);
      }
      compact.vertices=new Float32Array();compact.attributes=new Float32Array();
      const version=compactKind==='dense'?1:2;
      compact.vertexResources=new Uint32Array([version,0,compact.vertexInputs.length]);
      runtime.write(target,initial);
      equal(`Pipeline CUDA ${compactKind} vertex input construction preserves transformed and clipped color`,
        await render(compact),translatedExpected);
      const changed={...compact,vertexInputs:compact.vertexInputs.slice(),vertexResources:new Uint32Array()};
      const colors=compactKind==='dense'?[4,14,24,34]:[compact.vertexLayouts[10]];
      for(const offset of colors){changed.vertexInputs[offset]=0;changed.vertexInputs[offset+1]=1;}
      const green=translatedExpected.slice();
      for(let i=0;i<pixels;i++)if(i%width>=2){green[i*9]=0;green[i*9+1]=.5;}
      runtime.write(target,initial);
      equal(`Pipeline CUDA ${compactKind} scratch overwrite changes the rendered color`,await render(changed),green);
      const relocated={...compact,vertexLayouts:compact.vertexLayouts.slice(),vertexInputs:new Float32Array(compact.vertexInputs.length+16),
        vertexResources:new Uint32Array([version,16,compact.vertexInputs.length])};
      relocated.vertexInputs.set(compact.vertexInputs,16);
      if(compactKind==='dense')for(const offset of [6,7,8])relocated.vertexLayouts[offset]+=16;
      else {relocated.vertexLayouts[5]+=16;for(let i=8;i<28;i+=2)relocated.vertexLayouts[i]+=16;}
      runtime.write(target,initial);
      equal(`Pipeline CUDA ${compactKind} resident vertex inputs restore after scratch overwrite and relocation`,
        await render(relocated),translatedExpected);
    }
    // Compare complete particle deformation/projection/clip/raster consumption
    // against independently specified dense inputs, then mutate the next draw.
    for(const mode of [2,3,4,5,6,8]) {
      const common=[1,0,0,0,1,0,1,5,2,1,0,0,1,64,1,0,0,0,0,1,0,0,0];
      const particle=[mode===6?-.75:0,0,0,1,0,0,.75,.125,.25,.5,.5,.5,mode===6?1.5:.6,mode===6?1:0,0,0,mode];
      const reference=particleInputReference([particle],common),dense=scene();
      dense.vertices=reference.vertices;dense.attributes=reference.attributes;dense.secondaryColors=reference.secondary;
      if(mode>=5)dense.materials[3]|=4194304;
      runtime.write(target,initial);const expected=await render(dense);
      if(!expected.some((value,index)=>index<pixels*9&&value!==initial[index]))throw Error(`Particle mode ${mode} reference rendered nothing`);
      const compact={...dense,vertexEncoding:1,vertices:new Float32Array(),attributes:new Float32Array(),secondaryColors:new Float32Array(),
        vertexLayouts:new Uint32Array(32),vertexInputs:new Float32Array([...common,...particle])};
      compact.vertexLayouts.set([0,4,1,2,0,0,23,0]);
      runtime.write(target,initial);
      equal(`Pipeline raw particle mode ${mode} matches dense deformation, projection and raster output`,await render(compact),expected);
      compact.vertexInputs[26]=0;compact.vertexInputs[27]=1;
      const green=expected.slice();for(let i=0;i<pixels;i++){green[i*9+1]=green[i*9];green[i*9]=0;}
      runtime.write(target,initial);
      equal(`Pipeline raw particle mode ${mode} observes the next captured color`,await render(compact),green);
    }
    // MyGUI's six source vertices must retain texture orientation, byte alpha,
    // clipping, viewport/scissor restrictions and blending in the real pipeline.
    for(const alpha of [0,73,128,255]) {
      const records=[[-1,1,0,255,191,73,alpha,0,0],[1,1,0,255,191,73,alpha,1,0],
        [-1,-1,0,255,191,73,alpha,0,1],[-1,-1,0,255,191,73,alpha,0,1],
        [1,1,0,255,191,73,alpha,1,0],[1,-1,0,255,191,73,alpha,1,1]];
      const secondary=[.125,.25,.375],reference=guiInputReference(records,secondary),dense=scene();
      dense.vertices=reference.vertices;dense.attributes=reference.attributes;dense.secondaryColors=reference.secondary;
      dense.matrixIds=new Uint32Array(6);dense.triangles=new Uint32Array([0,1,2,0,3,4,5,0]);
      dense.matrices[12]=.5;
      dense.texels=new Uint32Array([0xff0000ff,0xff00ff00,0xffff0000,0xffffffff]);
      dense.materials.set([0,2,2,1|2|4|8,0,1,1,6,4,0,0,0]);
      const pass={viewport:[1,1,6,4]};
      runtime.write(target,initial);const expected=await render(dense,pass);
      if(alpha&&!expected.some((value,index)=>index<pixels*9&&index%9<3&&value!==initial[index]))
        throw Error(`GUI alpha ${alpha} reference rendered no color`);
      const compact={...dense,vertexEncoding:1,vertices:new Float32Array(),attributes:new Float32Array(),secondaryColors:new Float32Array(),
        vertexLayouts:new Uint32Array(32),vertexInputs:new Float32Array([...secondary,...records.flat()])};
      compact.vertexLayouts.set([0,6,6,3,0,0,3,0]);
      runtime.write(target,initial);
      equal(`Pipeline raw GUI alpha ${alpha} matches textured, blended, transformed and clipped dense output`,await render(compact,pass),expected);
      // A new capture may reuse the same upload allocation without reusing old data.
      for(let i=0;i<6;i++){compact.vertexInputs[3+i*9+3]=31;compact.vertexInputs[3+i*9+4]=255;}
      for(let i=0;i<6;i++){dense.vertices[i*10+4]=31/255;dense.vertices[i*10+5]=1;}
      runtime.write(target,initial);const changed=await render(dense,pass);
      runtime.write(target,initial);
      equal(`Pipeline raw GUI alpha ${alpha} observes changed source colors`,await render(compact,pass),changed);
    }
    for(const channels of [0,3,4])for(const constant of [false,true]) {
      const dense=scene(),inputs=[0,0,0],layout=new Uint32Array(32),colors=[],secondary=[];
      dense.attributes=new Float32Array(4*34);dense.secondaryColors=new Float32Array(12);
      dense.fixedLighting=new Uint32Array(368);dense.fixedLighting[1]=32; // Unlit primary + secondary color.
      for(let i=0;i<4;i++) {
        const source=constant?0:i,raw=channels?[254-source*31,73+source*17,128,channels===4?191:1]:[1.25,-.125,.5,.625];
        const extra=[1+source*17,128-source*31,73];
        colors.push(...raw);secondary.push(...extra);
        dense.vertices.set(raw.map((value,k)=>k<channels?value/255:value),i*10+4);
        dense.secondaryColors.set(extra.map(value=>value/255),i*3);
        for(let unit=0;unit<4;unit++)dense.attributes[i*34+27+unit*2]=1;
      }
      const position=[];for(let i=0;i<4;i++)position.push(...dense.vertices.slice(i*10,i*10+4));
      const streams=[position,constant?colors.slice(0,4):colors,constant?secondary.slice(0,3):secondary,
        [0,0,0],[0,0,0,0],[0],[0,0,0,1],[0,0,0,1],[0,0,0,1],[0,0,0,1]];
      layout.set([0,4,4,1,0,0]);layout[28]=channels;layout[29]=3;
      for(const [index,stream] of streams.entries()) {
        layout.set([inputs.length,index===0?4:index===1&&!constant?4:index===2&&!constant?3:0],8+index*2);
        inputs.push(...stream);
      }
      const compact={...dense,vertexEncoding:1,vertices:new Float32Array(),attributes:new Float32Array(),secondaryColors:new Float32Array(),
        vertexLayouts:layout,vertexInputs:new Float32Array(inputs)};
      runtime.write(target,initial);const expected=await render(dense);
      const primaryOnly={...dense,fixedLighting:new Uint32Array(368)};
      runtime.write(target,initial);const withoutSecondary=await render(primaryOnly);
      if(expected.every((value,i)=>Math.abs(value-withoutSecondary[i])<1e-6))throw Error('Byte-color fixture did not exercise secondary-color addition');
      runtime.write(target,initial);
      equal(`Pipeline color format ${channels}, ${constant?'constant':'per-vertex'} binding, secondary addition and blending`,await render(compact),expected);
      layout[28]=layout[29]=0;
      for(let i=0;i<4;i++) {
        dense.vertices.set([.125,.25,.5,.5],i*10+4);dense.secondaryColors.set([.25,.125,.0625],i*3);
        compact.vertexInputs.set([.125,.25,.5,.5],layout[10]+(constant?0:i)*4);
        compact.vertexInputs.set([.25,.125,.0625],layout[12]+(constant?0:i)*3);
      }
      runtime.write(target,initial);const changed=await render(dense);
      runtime.write(target,initial);
      equal(`Pipeline color format ${channels}, ${constant?'constant':'per-vertex'} binding resets to floating source values`,await render(compact),changed);
    }
    // Trigger the production compaction threshold with mostly offscreen draws.
    // The two visible triangles straddle a prefix-block boundary; compare with
    // the identical small-camera result, including a partially clipped edge.
    for(const visible of [true,false]) {
      const compacted=scene(),count=4096;
      compacted.vertices=new Float32Array([...compacted.vertices,
        3,0,0,1,0,1,0,1,0,0, 4,0,0,1,0,1,0,1,0,0, 3,1,0,1,0,1,0,1,0,0]);
      compacted.matrixIds=new Uint32Array(7);
      compacted.triangles=Uint32Array.from({length:count*4},(_,i)=>[4,5,6,0][i%4]);
      compacted.matrices[12]=.5;
      if(visible){compacted.triangles.set([0,1,2,0],36*4);compacted.triangles.set([0,2,3,0],37*4);}
      runtime.write(target,initial);
      equal(`Pipeline stable clipping compaction with ${visible?'visible triangles across prefix blocks':'all triangles rejected'}`,
        await render(compacted),visible?translatedExpected:initial);
      const attributes=pipeline.buffers.get('clippedAttributes');
      if(attributes.byteLength>32768)throw Error('Clipping compaction retained worst-case expanded attributes');
    }
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
