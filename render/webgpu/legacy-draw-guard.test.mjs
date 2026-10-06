import assert from 'node:assert/strict';
import {guardLegacyRendering} from './legacy-draw-guard.js';
let executed=0,reported=0;
const extension={drawArraysInstancedANGLE(){executed++;},vertexAttribDivisorANGLE(){return 7;}};
const context={drawElements(){executed++;},clear(){executed++;},blitFramebuffer(){executed++;},
  getParameter(){return 42;},getExtension(name){assert.equal(this,context);return name==='ANGLE_instanced_arrays'?extension:null;}};
const stats=guardLegacyRendering(context,()=>reported++);
assert.equal(guardLegacyRendering(context),stats);
assert.equal(context.getParameter(),42);
for(const name of ['drawElements','clear','blitFramebuffer'])assert.throws(()=>context[name](),/Legacy WebGL rendering is forbidden/);
assert.equal(context.getExtension('missing'),null);
const guarded=context.getExtension('ANGLE_instanced_arrays');
assert.equal(context.getExtension('ANGLE_instanced_arrays'),guarded);
assert.equal(guarded.vertexAttribDivisorANGLE(),7);
assert.throws(()=>guarded.drawArraysInstancedANGLE(),/Legacy WebGL rendering is forbidden/);
assert.equal(executed,0);assert.equal(reported,4);assert.equal(stats.attempts,4);
assert.equal(stats.lastOperation,'drawArraysInstancedANGLE');
console.log('Legacy rendering guard: draw/clear/blit/extension calls blocked; setup and idempotence preserved');
