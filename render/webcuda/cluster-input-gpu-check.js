// Test-only scene construction and independent CPU references.
import {MaterialPipeline} from './pipeline.js';
import {lightInputScene,canonicalLightInput} from './light-input-gpu-check.js';

export function clusterInputScene({count=8,rotated=false,fade=0,camera='perspective'}={}) {
  const scene=canonicalLightInput(lightInputScene({count:0}));scene.texels[scene.materials[0]+4]=16777216;
  for(let vertex=0;vertex<4;vertex++)scene.vertices[vertex*10+2]=-.5;
  const projection=new Float32Array([1,0,0,0,0,1,0,0,0,0,-1.020202,-1,0,0,-.2020202,0]);
  if(camera!=='perspective')projection.set([.5,0,0,0,0,.25,0,0,0,0,-2/9.9,0,.25,-.5,-10.1/9.9,1]);
  if(camera==='orthographicReverse'){projection[10]=1/9.9;projection[14]=10/9.9;}
  const inputs=new Float32Array(20+count*5);
  inputs.set(rotated?[0,1,0,0,-1,0,0,0,0,0,1,0,.375,-.25,.5,1]:[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]);inputs[16]=1.5;
  const lights=new Float32Array((count+2)*20);lights.fill(12345,0,40);
  for(let i=0;i<count;i++) {
    lights.set([i*.015625-.5,.25,1,1,.0005,.00075,.001,.625,.0001,.0002,.0003,1,.00025,.0005,.00075,.875,.75,.125,.0125,64],40+i*20);
    inputs.set([fade===1?1:fade===2?7:16,0,0,4,fade===0?0:12],20+i*5);
  }
  const records=new Uint32Array([2,count,2,2,2,0,0,0x80000001,0,0]),values=new Float32Array(records.buffer);
  values[5]=.1;values[6]=10;values[8]=values[9]=16;
  const projections=new Float32Array(16+Math.ceil((16+inputs.length)/16)*16);projections.set(projection,16);projections.set(inputs,32);
  return {...scene,clusterRecords:records,clusterMaterials:new Uint32Array([0,0]),clusterLights:lights,clusterProjections:projections};
}

export function canonicalClusterInput(scene) {
  const records=scene.clusterRecords.slice(),lights=scene.clusterLights.slice();
  const first=records[0],count=records[1],start=(records[7]&0x7fffffff)*16+16,raw=scene.clusterProjections;
  for(let i=0;i<count;i++) {
    const from=(first+i)*20,position=lights.slice(from,from+4),fade=start+20+i*5;
    for(let row=0;row<4;row++)lights[from+row]=position.reduce((sum,value,col)=>sum+value*raw[start+col*4+row],0);
    const amount=raw[fade+4]===0?1:1-Math.min(1,Math.max(0,(Math.hypot(...raw.subarray(fade,fade+3))-raw[fade+3])/(raw[fade+4]-raw[fade+3])));
    for(const offset of [4,12])for(let k=0;k<4;k++)lights[from+offset+k]*=amount;
    lights[from+19]*=raw[start+16];
  }
  records[7]&=0x7fffffff;return {...scene,clusterRecords:records,clusterLights:lights};
}

export async function checkClusterInputGpu(runtime,kernels) {
  const pipeline=new MaterialPipeline(runtime,kernels),initial=new Float32Array(256*10+4),checks=[];
  for(let p=0;p<256;p++)initial[p*9+4]=1;initial.fill(12345,256*10);
  const target=runtime.createBuffer(initial);
  const render=async scene=>{
    runtime.write(target,initial);
    const result=await pipeline.render(scene,16,16,null,{target,colorFormat:0x8814,depthFormat:0x8cad,stencilBits:8,clearMask:0,deferCompletion:true});
    const completion=await result.queryCompletion;if(completion.error)throw completion.error;
    await runtime.idle();pipeline.collectRetired();return runtime.read(target,Float32Array,initial.byteLength);
  };
  try {
    const withoutLights=await render(canonicalClusterInput(clusterInputScene({count:0})));
    for(const camera of ['perspective','orthographic','orthographicReverse'])
    for(const count of [0,8,65,130])for(const rotated of [false,true])for(let fade=0;fade<4;fade++) {
      const scene=clusterInputScene({count,rotated,fade,camera}),reference=canonicalClusterInput(scene),before=scene.clusterLights.slice();
      const resources=(await pipeline.prepareClusterSnapshots(scene)).get(0);
      if(camera!=='perspective') {
        const bounds=await runtime.read(resources.clusters,Float32Array,resources.clusterCount*32),projection=scene.clusterProjections.subarray(16,32);
        for(let tile=0;tile<resources.clusterCount;tile++)for(let side=0;side<2;side++)for(let axis=0;axis<2;axis++) {
          const cell=axis?Math.floor(tile/2)%2:tile%2;
          const ndc=bounds[tile*8+side*4+axis]*projection[axis*5]+projection[12+axis];
          if(Math.abs(ndc-(cell+side-1))>0.00002)throw Error(`${camera}: cluster ${tile} has incorrect XY bounds`);
        }
      }
      if(count) {
        const prepared=await runtime.read(resources.lights,Float32Array,count*80);
        const expected=reference.clusterLights.subarray(40);
        for(let i=0;i<prepared.length;i++)if(!Number.isFinite(prepared[i])||Math.abs(prepared[i]-expected[i])>0.00002)
          throw Error(`Prepared clustered light ${count}/${rotated}/${fade}, word ${i}: ${prepared[i]} != ${expected[i]}`);
      }
      if(count>64&&resources.capacity!==count)throw Error('Cluster overflow did not grow the complete list');
      const expected=await render(reference),actual=await render(scene);
      for(let i=0;i<actual.length;i++)if(!Number.isFinite(actual[i])||Math.abs(actual[i]-expected[i])>0.00002)
        throw Error(`Clustered raster ${count}/${rotated}/${fade}, word ${i}: ${actual[i]} != ${expected[i]}`);
      if(count&&fade!==3&&!actual.some((v,i)=>i<256*9&&i%9<3&&Math.abs(v-withoutLights[i])>0.00001))throw Error('Clustered point lights made no rendered contribution');
      for(let i=256*10;i<actual.length;i++)if(actual[i]!==12345)throw Error('Cluster target guard changed');
      if(!scene.clusterLights.every((v,i)=>v===before[i]))throw Error('Cluster source snapshot changed');
      checks.push(`CUDA clustered lights: ${count} lights, ${camera}/${rotated?'rotated':'identity'} camera, fade ${fade}, preparation/culling/raster/guards`);
    }
    return checks;
  } finally {try{await runtime.idle();}finally{pipeline.dispose();runtime.destroyBuffer(target);}}
}
