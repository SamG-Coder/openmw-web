import {allFinite} from './packet-validation.js';

// Validate every indirect range before either CUDA preparation kernel runs.
// Zero references preserve the existing, already-applied descriptor contract.
export function validatePositionedState(scene) {
  const words=scene.positionedState;
  if(!(words instanceof Uint32Array)||words.length>0xffffffff)throw RangeError('Invalid positioned state packet');
  const values=new Float32Array(words.buffer,words.byteOffset,words.length),checked=new Set();
  function matrix(reference) {
    const offset=reference-1;
    if(!reference||offset+16>words.length)throw RangeError('Positioned matrix range exceeds packet');
    if(!checked.has(reference)) {
      if(!allFinite(values,offset,offset+16))throw RangeError('Non-finite positioned matrix');
      checked.add(reference);
    }
  }
  let fixed=false,texgen=false;
  for(let d=0;d<scene.fixedLighting.length;d+=368) {
    const table=scene.fixedLighting[d+3];
    if(!table)continue;
    if(!(scene.fixedLighting[d+1]&128)||table-1+8>words.length)throw RangeError('Invalid positioned light table');
    for(let light=0;light<8;light++) {
      const post=words[table-1+light];
      if(!post)continue;
      if(!(scene.fixedLighting[d]&(1<<light)))throw RangeError('Positioned transform references a disabled light');
      matrix(post);fixed=true;
    }
  }
  for(let d=0;d<scene.texgen.length;d+=36) {
    const post=scene.texgen[d+3];
    if(!post)continue;
    if(!scene.texgen[d]||scene.texgen[d+1]!==5)throw RangeError('Positioned transform requires eye-linear texture coordinates');
    matrix(post);texgen=true;
  }
  return {fixed,texgen};
}
