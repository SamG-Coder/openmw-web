import test from 'node:test';
import assert from 'node:assert/strict';
import {validatePositionedState} from './positioned-state.js';

const fixture=()=>{
  const positionedState=new Uint32Array(40),fixedLighting=new Uint32Array(368),texgen=new Uint32Array(144);
  positionedState[0]=9;positionedState[7]=25;
  const values=new Float32Array(positionedState.buffer);
  for(const base of [8,24])for(let i=0;i<4;i++)values[base+i*5]=1;
  fixedLighting.set([129,128,0,1]);texgen.set([15,5,0,25]);
  return {positionedState,fixedLighting,texgen};
};
test('positioned matrices accept offset tables, shared references and empty legacy packets',()=>{
  const scene=fixture(),before=structuredClone(scene);
  assert.deepEqual(validatePositionedState(scene),{fixed:true,texgen:true});assert.deepEqual(scene,before);
  scene.fixedLighting[3]=0;scene.texgen[3]=0;scene.positionedState=new Uint32Array();
  assert.deepEqual(validatePositionedState(scene),{fixed:false,texgen:false});
});
test('positioned transforms reject invalid table/matrix extents and non-finite inputs',()=>{
  for(const corrupt of [s=>s.positionedState=new Float32Array(40),s=>s.fixedLighting[3]=34,
    s=>s.fixedLighting[3]=0xffffffff,s=>s.positionedState[0]=26,s=>s.texgen[3]=0xffffffff,
    s=>new Float32Array(s.positionedState.buffer)[39]=Infinity,s=>new Float32Array(s.positionedState.buffer)[10]=NaN]) {
    const scene=fixture();corrupt(scene);assert.throws(()=>validatePositionedState(scene),RangeError);
  }
});
test('positioned transforms require an active fixed light or eye-linear generator',()=>{
  for(const corrupt of [s=>s.fixedLighting[1]=0,s=>s.fixedLighting[0]=1,s=>s.texgen[1]=1,s=>s.texgen[0]=0]) {
    const scene=fixture();corrupt(scene);assert.throws(()=>validatePositionedState(scene),RangeError);
  }
});
