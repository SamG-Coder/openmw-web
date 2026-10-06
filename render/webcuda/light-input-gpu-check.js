// Independent test inputs/reference. Production JavaScript never evaluates light transforms or fades.
import {MaterialPipeline} from './pipeline.js';

export function lightInputScene({count=2,vertex=false,rotated=false,fade=0}={}) {
  const data=1,first=388+count*5,texels=new Uint32Array(data+first+count*16),f=new Float32Array(texels.buffer);
  texels[data+4]=0x80000000|(vertex?8388608:0);texels[data+6]=count;texels[data+7]=first;texels[data+51]=7;
  f.set([.15,.1,.2,1],data+8);f.set([.75,.5,.25,1],data+12);f.set([.125,.25,.5,1],data+16);
  f.set([1,-.5,2,0],data+24);f.set([.05,.125,.25,1],data+28);f.set([.5,.75,.3,1],data+32);f.set([.2,.3,.4,1],data+36);
  f[data+46]=8;f[data+47]=f[data+48]=1;f[data+71]=1;
  for(let k=0;k<4;k++)f[data+52+k*5]=1;
  texels[data+352]=1|(count?2:0);f[data+353]=1.5;
  for(const start of [354,370]) {
    const camera=rotated?[0,1,0,0,-1,0,0,0,0,0,1,0,.375,-.25,.5,1]:[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1];
    f.set(camera,data+start);
  }
  for(let light=0;light<count;light++) {
    f.set([fade===1?1:fade===2?7:16,0,0,4,fade===0?0:12],data+388+light*5);
    f.set([light/4-1,.5,3,.75,.1,.15,.2,.125,.75-light*.02,.5,.25,.0125,.125,.25,.5,4+light],data+first+light*16);
  }
  const matrices=new Float32Array(32);for(const start of [0,16])for(let k=0;k<4;k++)matrices[start+k*5]=1;
  const params=new Float32Array(50);params[3]=1;params[24]=1;params[26]=65535;params[27]=1;params[37]=params[38]=1;params.set([0,64,1,1,0,0],43);
  for(const face of [8,15])params.set([7,0,255,255,0,0,0],face);
  const attributes=new Float32Array(4*34);for(let vertex=0;vertex<4;vertex++){attributes[vertex*34+5]=1;attributes[vertex*34+6]=1;attributes[vertex*34+9]=1;}
  return {vertices:new Float32Array([-1,1,0,1,1,1,1,1,0,0,1,1,0,1,1,1,1,1,1,0,1,-1,0,1,1,1,1,1,1,1,-1,-1,0,1,1,1,1,1,0,1]),
    matrices,matrixIds:new Uint32Array(4),triangles:new Uint32Array([0,1,2,0,0,2,3,0]),
    materials:new Uint32Array([data,1,1,2048|128,0,0,0,16,16,7|(7<<4),0,0]),texels,rasterParams:params,attributes};
}

export function canonicalLightInput(scene) {
  const source=scene.texels,raw=new Float32Array(source.buffer),data=scene.materials[0],count=source[data+6],first=source[data+7];
  const texels=new Uint32Array(data+352+count*16);texels.set(source.subarray(0,data+352));texels.set(source.subarray(data+first),data+352);
  texels[data+4]&=~0x80000000;texels[data+7]=352;const f=new Float32Array(texels.buffer);
  const transform=(offset,position)=>[0,1,2,3].map(row=>position.reduce((sum,value,col)=>sum+raw[data+offset+col*4+row]*value,0));
  if(source[data+352]&1)f.set(transform(354,Array.from(raw.subarray(data+24,data+28))),data+24);
  if(source[data+352]&2)for(let light=0;light<count;light++) {
    const from=data+first+light*16,to=data+352+light*16,fade=data+388+light*5;
    f.set(transform(370,[...raw.subarray(from,from+3),1]).slice(0,3),to);
    const amount=raw[fade+4]===0?1:1-Math.min(1,Math.max(0,(Math.hypot(...raw.subarray(fade,fade+3))-raw[fade+3])/(raw[fade+4]-raw[fade+3])));
    for(const base of [8,12])for(let k=0;k<3;k++)f[to+base+k]=raw[from+base+k]*amount;
    f[to+15]=raw[from+15]*raw[data+353];
  }
  return {...scene,texels};
}

export async function checkLightInputGpu(runtime,kernels) {
  const pipeline=new MaterialPipeline(runtime,kernels),initial=new Float32Array(16*16*10+4),checks=[];
  for(let pixel=0;pixel<256;pixel++)initial[pixel*9+4]=1;initial.fill(12345,256*10);
  const target=runtime.createBuffer(initial);
  const render=async scene=>{
    runtime.write(target,initial);
    const result=await pipeline.render(scene,16,16,null,{target,colorFormat:0x8814,depthFormat:0x8cad,stencilBits:8,clearMask:0,deferCompletion:true});
    const completion=await result.queryCompletion;if(completion.error)throw completion.error;
    await runtime.idle();pipeline.collectRetired();return runtime.read(target,Float32Array,initial.byteLength);
  };
  try {
    for(const vertex of [false,true])for(const rotated of [false,true])for(let fade=0;fade<4;fade++) {
      const scene=lightInputScene({count:8,vertex,rotated,fade}),expected=await render(canonicalLightInput(scene)),actual=await render(scene);
      if(!expected.some((value,index)=>index<256*9&&index%9<3&&value>0))throw Error('Light reference rendered no color');
      for(let word=0;word<actual.length;word++)if(!Number.isFinite(actual[word])||Math.abs(actual[word]-expected[word])>0.00002)
        throw Error(`Light preparation ${vertex}/${rotated}/${fade}, word ${word}: ${actual[word]} != ${expected[word]}`);
      for(let word=256*10;word<initial.length;word++)if(actual[word]!==12345)throw Error('Light target guard changed');
      checks.push(`CUDA light transforms/fades: ${vertex?'vertex':'pixel'} lighting, ${rotated?'rotated':'identity'} camera, fade ${fade}`);
    }
    return checks;
  } finally {try{await runtime.idle();}finally{pipeline.dispose();runtime.destroyBuffer(target);}}
}
