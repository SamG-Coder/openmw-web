import test from 'node:test';
import assert from 'node:assert/strict';
import {MaterialPipeline} from './pipeline.js';
import {lightInputScene,canonicalLightInput} from './light-input-gpu-check.js';
const reached=Error('Reached GPU allocation');
function pipeline(){return new MaterialPipeline({device:{limits:{maxTextureDimension2D:8192,maxBufferSize:1048576,maxStorageBufferBindingSize:1048576}},createBuffer(){throw reached;}},{});}
test('raw light snapshots and canonical views pass host validation without mutation',async()=>{
  for(const count of [0,1,8,32])for(const vertex of [false,true])for(const rotated of [false,true]) {
    const raw=lightInputScene({count,vertex,rotated,fade:2});
    for(const scene of [raw,canonicalLightInput(raw)]) {
      const before=scene.texels.slice();await assert.rejects(pipeline().render(scene,16,16),error=>error===reached);assert.deepEqual(scene.texels,before);
    }
  }
});
test('raw light host validation rejects invalid headers, fade intervals, values and ranges',async()=>{
  for(const mutate of [
    (a,f,d)=>a[d+7]--,(a,f,d)=>a[d+352]=0,(a,f,d)=>a[d+352]=4,
    (a,f,d)=>f[d+353]=-1,(a,f,d)=>f[d+354]=Infinity,(a,f,d)=>f[d+24]=NaN,
    (a,f,d)=>f[d+392]=4,(a,f,d)=>f[d+390]=NaN,
    (a,f,d)=>f[d+a[d+7]+15]=-1,(a,f,d)=>f[d+a[d+7]+8]=Infinity,
  ]) {
    const scene=lightInputScene({fade:2});mutate(scene.texels,new Float32Array(scene.texels.buffer),scene.materials[0]);
    await assert.rejects(pipeline().render(scene,16,16),/Invalid (object lighting payload|raw light|raw sunlight|raw point light)/);
  }
  const truncated=lightInputScene();truncated.texels=truncated.texels.slice(0,-1);
  await assert.rejects(pipeline().render(truncated,16,16),/Invalid object lighting payload/);
});
