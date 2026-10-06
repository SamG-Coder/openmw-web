// Test-only canonicalization of raw GL state. Production JS only transports
// and validates these records; the CUDA binner/rasterizer owns the calculations.
import {MaterialPipeline} from './pipeline.js';

export async function checkRasterStateGpu(runtime,kernels) {
  const pipeline=new MaterialPipeline(runtime,kernels),width=35,height=19,pixels=width*height,checks=[];
  const matrices=new Float32Array(32);for(const base of [0,16])for(let k=0;k<4;k++)matrices[base+k*5]=1;
  const make=()=>{
    const params=new Float32Array(50);params[3]=1;params[24]=1;params[26]=65535;params[27]=1;
    params[37]=params[38]=1;params.set([0,64,1,1,0,0],43);
    for(const face of [8,15])params.set([7,0,255,255,2,5,2],face);
    return {vertices:new Float32Array([-1,1,.25,1,.2,.4,.6,.5,0,0,1,1,.25,1,.2,.4,.6,.5,1,0,
      1,-1,.25,1,.2,.4,.6,.5,1,1,-1,-1,.25,1,.2,.4,.6,.5,0,1]),
      matrices:matrices.slice(),matrixIds:new Uint32Array(4),triangles:new Uint32Array([0,1,2,0,0,2,3,0]),
      materials:new Uint32Array([0,1,1,128|4|8,0,0,0,width,height,7|(7<<4),0,0]),
      texels:new Uint32Array([0xffffffff]),rasterParams:params};
  };
  const unit=value=>Math.min(1,Math.max(0,value));
  const canonical=source=>{
    const result=Object.fromEntries(Object.entries(source).map(([key,value])=>[key,value.slice()]));
    const material=result.materials,params=result.rasterParams,texels=result.texels,floats=new Float32Array(texels.buffer);
    if(material[3]&16777216) {
      const x=material[5]|0,y=material[6]|0;
      const x0=Math.max(0,Math.min(width,x)),x1=Math.max(0,Math.min(width,x+material[7]));
      const y0=Math.max(0,Math.min(height,y)),y1=Math.max(0,Math.min(height,y+material[8]));
      material.set([x0,height-y1,x1-x0,y1-y0],5);material[3]&=~16777216;
    }
    const mf=new Float32Array(material.buffer);mf[4]=unit(mf[4]);
    for(let k=2;k<8;k++)params[k]=unit(params[k]);params[24]=unit(params[24]);
    for(const k of [9,16])params[k]=Math.min(255,Math.max(0,params[k]));
    if(material[3]&32768){const offset=new Uint32Array(params.buffer)[23];for(let k=4;k<8;k++)floats[offset+k]=unit(floats[offset+k]);}
    if(material[3]&16384)for(let d=material[0];d;d=texels[d+3])for(let k=4;k<8;k++)floats[d+k]=unit(floats[d+k]);
    return result;
  };
  const initial=new Float32Array(pixels*10+4);
  for(let pixel=0;pixel<pixels;pixel++)initial.set([.125,.25,.375,1,.875,.1,.2,.3,1],pixel*9);
  initial.fill(127,pixels*9,pixels*10);initial.fill(12345,pixels*10);
  const target=runtime.createBuffer(initial),sampleTarget=runtime.createBuffer(new Float32Array(pixels*10*4+4).fill(12345));
  const render=async(source,sampleCount)=>{
    runtime.write(target,initial);
    if(sampleCount>1)pipeline.seedMultisample(target,sampleTarget,width,height,sampleCount);
    const result=await pipeline.render(source,width,height,null,{target,sampleCount,sampleTarget:sampleCount>1?sampleTarget:null,
      colorFormat:0x8814,normalFormat:0x8814,normalTargetId:1,depthFormat:0x8cad,stencilBits:8,clearMask:0,deferCompletion:true});
    const completion=await result.queryCompletion;if(completion.error)throw completion.error;
    await runtime.idle();pipeline.collectRetired();
    return [await runtime.read(target,Float32Array,initial.byteLength),
      ...(sampleCount>1?[await runtime.read(sampleTarget)]:[])];
  };
  const verify=async(label,source,samples=1)=>{
    const expected=await render(canonical(source),samples),actual=await render(source,samples);
    for(let plane=0;plane<actual.length;plane++)for(let word=0;word<actual[plane].length;word++)
      if(!Number.isFinite(actual[plane][word])||Math.abs(actual[plane][word]-expected[plane][word])>1e-6)
        throw Error(`${label}: plane ${plane}, word ${word}, ${actual[plane][word]} != ${expected[plane][word]}`);
    for(let word=pixels*10;word<initial.length;word++)if(actual[0][word]!==12345)throw Error(`${label}: target guard changed`);
    checks.push(label);
  };
  try {
    for(const rect of [[-2,1,6,4],[-1,-1,2147483647,2147483647],[-2147483648,-2147483648,2147483647,2147483647],
      [2147483642,2147483644,2147483647,2147483647],[15,15,2,2],[0,18,35,1],[0,0,0,19],[-2147483642,-2147483644,2147483647,2147483647]]) {
      const source=make();source.materials[3]|=16777216;source.materials.set(rect,5);
      await verify(`Raw GL scissor ${rect.join(',')} clips and bins in CUDA`,source);
    }
    for(const value of [-4,4,-Infinity,Infinity])for(const alpha of [0,1]) {
      const source=make();source.materials[9]=7|(2<<4);new Float32Array(source.materials.buffer)[4]=value;
      for(let v=0;v<4;v++)source.vertices[v*10+7]=alpha;
      await verify(`Raw alpha reference ${value} with alpha ${alpha}`,source);
    }
    for(const range of [[-4,3],[.8,-.25],[-Infinity,Infinity],[Infinity,-Infinity]]) {
      const source=make();source.rasterParams.set(range,2);await verify(`Raw depth range ${range.join(',')}`,source);
    }
    for(const factor of [11,12,13,14]) {
      const source=make();source.materials[3]|=2;source.materials[10]=factor|(5<<4)|(factor<<8)|(5<<12);
      source.rasterParams.set([-Infinity,Infinity,.375,2],4);await verify(`Raw blend constant factor ${factor}`,source);
    }
    for(const reference of [-2147483648,-1,256,2147483648]) {
      const source=make();source.materials[3]|=8192;source.rasterParams[9]=reference;source.rasterParams[16]=-reference;
      await verify(`Raw stencil reference ${reference}`,source);
    }
    for(const coverage of [-4,.375,4])for(const invert of [0,1]) {
      const source=make();source.rasterParams[24]=coverage;source.rasterParams[25]=invert;
      await verify(`Raw ${coverage} sample coverage, invert ${invert}, all 4 sample planes`,source,4);
    }
    for(const mode of [0,1,2]) {
      const source=make();source.materials[3]|=32768;source.texels=new Uint32Array(10);source.texels[1]=mode;
      new Uint32Array(source.rasterParams.buffer)[23]=1;new Float32Array(source.texels.buffer).set([.5,0,2,-4,.375,3,2],2);
      await verify(`Raw fog color with mode ${mode}`,source);
    }
    for(const combine of [false,true]) {
      const source=make();source.materials[3]|=1|512|16384;source.materials[0]=1;source.texels=new Uint32Array(45);source.texels[0]=0x8073bf40;
      source.texels[2]=combine?5:3;source.texels[25]=source.texels[26]=1;
      for(let k=0;k<4;k++)new Float32Array(source.texels.buffer)[29+k*5]=1;
      new Float32Array(source.texels.buffer).set(combine?[-4,.375,3,2]:[-Infinity,Infinity,.375,2],5);
      if(combine){source.texels[9]=4;source.texels[11]=source.texels[12]=1;source.texels.set([2,1,0],13);source.texels.fill(2,19,25);}
      await verify(`Raw texture ${combine?'combine':'blend'} constant colors`,source);
    }
    return checks;
  } finally {
    try {await runtime.idle();}finally {pipeline.dispose();runtime.destroyBuffer(target);runtime.destroyBuffer(sampleTarget);}
  }
}
