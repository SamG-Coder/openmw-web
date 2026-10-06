import {allFinite,validateVertexAttributes} from './packet-validation.js';

// Validate the transport before allocating or dispatching. The GPU owns the
// construction of expanded vertex/attribute records; JS never expands them.
export function validateVertexInputs(scene) {
  const {vertexInputs:inputs,vertexLayouts:layouts,matrixIds,matrices}=scene;
  if(scene.vertexEncoding!==1||!(inputs instanceof Float32Array)||!(layouts instanceof Uint32Array)
    ||layouts.length!==matrices.length||!allFinite(inputs)||inputs.length>0xffffffff)
    throw RangeError('Invalid compact vertex inputs');
  if(scene.vertices.length||scene.attributes?.length||scene.secondaryColors?.length)
    throw RangeError('Compact vertex inputs cannot also carry expanded records');
  const widths=[4,4,3,3,4,1,4,4,4,4];let end=0,projectedParticles=false,lineParticles=false;
  const range=(offset,words)=>{
    if(offset+words>inputs.length)throw RangeError('Compact vertex stream exceeds input storage');
  };
  for(let d=0;d<layouts.length;d+=32) {
    const [first,count,source,kind,mode,fallback]=layouts.subarray(d,d+6);
    if(first!==end||first+count>matrixIds.length||source>count||kind>1||mode>2)
      throw RangeError('Invalid compact vertex draw range');
    end=first+count;
    for(let i=first;i<end;i++)if(matrixIds[i]!==d/32)throw RangeError('Compact vertex draw does not match matrix IDs');
    if(kind===0) {
      if(source!==count||mode||fallback)throw RangeError('Invalid dense vertex input descriptor');
      range(layouts[d+6],count*10);range(layouts[d+7],count*34);range(layouts[d+8],count*3);
      const flags=validateVertexAttributes(inputs.subarray(layouts[d+7],layouts[d+7]+count*34),count);
      projectedParticles||=flags.projectedParticles;lineParticles||=flags.lineParticles;
      for(let k=9;k<32;k++)if(layouts[d+k])throw RangeError('Invalid dense vertex input reserved word');
    } else {
      range(fallback,3);
      if(layouts[d+6]||layouts[d+7])throw RangeError('Invalid vertex input reserved word');
      for(let stream=0;stream<10;stream++) {
        const offset=layouts[d+8+stream*2],stride=layouts[d+9+stream*2],width=widths[stream];
        if(stride!==0&&stride!==width)throw RangeError('Invalid compact vertex stream stride');
        range(offset,source?width+(source-1)*stride:(stride?0:width));
      }
      for(let k=28;k<32;k++)if(layouts[d+k])throw RangeError('Invalid vertex input reserved word');
    }
  }
  if(end!==matrixIds.length)throw RangeError('Incomplete compact vertex draw coverage');
  return {projectedParticles,lineParticles};
}
