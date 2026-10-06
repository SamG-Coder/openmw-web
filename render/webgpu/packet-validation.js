// Validate host transport data without a callback invocation for every scalar.
// The views may point directly into the retained, immutable shared WASM heap.
export function allFinite(values, first=0, end=values.length) {
  for(let i=first;i<end;i++)if(!Number.isFinite(values[i]))return false;
  return true;
}

export function validateVertexAttributes(attributes, vertexCount) {
  if(!(attributes instanceof Float32Array)||attributes.length!==vertexCount*34)
    throw RangeError('Invalid world vertex attributes');
  let projectedParticles=false,lineParticles=false;
  for(let base=0;base<attributes.length;base+=34) {
    for(let field=0;field<34;field++)if(!Number.isFinite(attributes[base+field]))
      throw RangeError('Invalid world vertex attributes');
    const mode=attributes[base],flags=attributes[base+25];
    if(mode>=5&&mode<=8) {
      if(!Number.isInteger(flags)||flags<0||flags>31)
        throw RangeError('Invalid projected particle depth/multisample flags');
      projectedParticles=true;
    }
    lineParticles||=mode===6;
  }
  return {projectedParticles,lineParticles};
}
