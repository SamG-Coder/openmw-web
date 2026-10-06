import test from 'node:test';
import assert from 'node:assert/strict';
import {MaterialPipeline} from './pipeline.js';
import {clusterInputScene,canonicalClusterInput} from './cluster-input-gpu-check.js';
const reached=Error('Reached GPU allocation');
function pipeline(){return new MaterialPipeline({device:{limits:{maxTextureDimension2D:8192,maxBufferSize:1048576,maxStorageBufferBindingSize:1048576}},createBuffer(){throw reached;}},{});}
test('raw and canonical clustered packets validate without host light math or source mutation',async()=>{
  for(const camera of ['perspective','orthographic','orthographicReverse'])
  for(const count of [0,1,8,65,130])for(const rotated of [false,true])for(let fade=0;fade<4;fade++) {
    const raw=clusterInputScene({count,rotated,fade,camera});
    for(const scene of [raw,canonicalClusterInput(raw)]) {
      const before=[scene.clusterRecords.slice(),scene.clusterLights.slice(),scene.clusterProjections.slice()];
      await assert.rejects(pipeline().prepareClusterSnapshots(scene),error=>error===reached);
      for(const [i,name] of ['clusterRecords','clusterLights','clusterProjections'].entries())assert.deepEqual(scene[name],before[i]);
    }
  }
});
test('raw clustered transport rejects malformed metadata, ranges, mapping and finite values',async()=>{
  for(const mutate of [
    s=>s.clusterRecords[7]=0xffffffff,s=>s.clusterRecords[1]++,s=>s.clusterRecords[0]++,
    s=>s.clusterProjections=s.clusterProjections.slice(0,32),s=>s.clusterProjections[48]=-1,
    s=>s.clusterProjections[32]=NaN,s=>s.clusterProjections[49]=1,s=>s.clusterProjections[56]=4,
    s=>s.clusterLights[59]=-1,s=>s.clusterLights[40]=Infinity,s=>s.clusterMaterials[1]=1,
    s=>s.clusterProjections[27]=.5,s=>s.clusterProjections[31]=.5,
  ]) {
    const scene=clusterInputScene({fade:2});mutate(scene);
    await assert.rejects(pipeline().prepareClusterSnapshots(scene),error=>error instanceof RangeError);
  }
});
