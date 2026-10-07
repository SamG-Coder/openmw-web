import {allFinite,validateVertexAttributes} from './packet-validation.js';

// Validate the transport before allocating or dispatching. The GPU owns the
// construction of expanded vertex/attribute records; JS never expands them.
export function validateVertexInputs(scene,{deep=true}={}) {
  const {vertexInputs:inputs,vertexLayouts:layouts,matrixIds,matrices}=scene;
  if(scene.vertexEncoding!==1||!(inputs instanceof Float32Array)||!(layouts instanceof Uint32Array)
    ||layouts.length!==matrices.length||(deep&&!allFinite(inputs))||inputs.length>0xffffffff)
    throw RangeError('Invalid compact vertex inputs');
  if(scene.vertices.length||scene.attributes?.length||scene.secondaryColors?.length)
    throw RangeError('Compact vertex inputs cannot also carry expanded records');
  const widths=[4,4,3,3,4,1,4,4,4,4];let end=0,projectedParticles=false,lineParticles=false;
  const range=(offset,words)=>{
    if(offset+words>inputs.length)throw RangeError('Compact vertex stream exceeds input storage');
  };
  const byteColors=(offset,count,stride,channels)=>{
    if(!deep)return;
    for(let i=0;i<(stride?count:1);i++)for(let k=0;k<channels;k++) {
      const value=inputs[offset+i*stride+k];
      if(!Number.isInteger(value)||value<0||value>255)throw RangeError('Invalid vertex color byte');
    }
  };
  for(let d=0;d<layouts.length;d+=32) {
    const [first,count,source,kind,mode,fallback]=layouts.subarray(d,d+6);
    const colorBytes=layouts[d+28],secondaryBytes=layouts[d+29],fallbackBytes=layouts[d+30];
    if(first!==end||first+count>matrixIds.length||source>count||kind>3||mode>2)
      throw RangeError('Invalid compact vertex draw range');
    if(![0,3,4].includes(colorBytes)||![0,3].includes(secondaryBytes)||![0,3].includes(fallbackBytes)
      ||(kind!==1&&(colorBytes||fallbackBytes))||(kind===3&&secondaryBytes)||layouts[d+31])
      throw RangeError('Invalid compact vertex color format');
    end=first+count;
    for(let i=first;i<end;i++)if(matrixIds[i]!==d/32)throw RangeError('Compact vertex draw does not match matrix IDs');
    if(kind===0) {
      if(source!==count||mode||fallback)throw RangeError('Invalid dense vertex input descriptor');
      range(layouts[d+6],count*10);range(layouts[d+7],count*34);range(layouts[d+8],count*3);
      const flags=validateVertexAttributes(inputs.subarray(layouts[d+7],layouts[d+7]+count*34),count,deep);
      projectedParticles||=flags.projectedParticles;lineParticles||=flags.lineParticles;
      for(let k=9;k<28;k++)if(layouts[d+k])throw RangeError('Invalid dense vertex input reserved word');
      if(secondaryBytes)byteColors(layouts[d+8],count,3,secondaryBytes);
    } else if(kind===3) {
      if(source!==count||count%3||mode||fallback)throw RangeError('Invalid GUI input descriptor');
      const vertices=layouts[d+6],shared=layouts[d+7];
      range(vertices,count*9);range(shared,3);
      for(let k=8;k<32;k++)if(layouts[d+k])throw RangeError('Invalid GUI input reserved word');
      for(let p=vertices;p<vertices+count*9;p+=9)for(let k=3;k<7;k++) {
        const color=inputs[p+k];
        if(!Number.isInteger(color)||color<0||color>255)throw RangeError('Invalid GUI color byte');
      }
    } else if(kind===2) {
      if(source*4!==count||mode||fallback)throw RangeError('Invalid particle input descriptor');
      const particles=layouts[d+6],shared=layouts[d+7];
      range(particles,source*17);range(shared,23);
      for(let k=8;k<28;k++)if(layouts[d+k])throw RangeError('Invalid particle input reserved word');
      if(secondaryBytes)byteColors(shared+20,1,0,secondaryBytes);
      const detail=inputs[shared+6],flags=inputs[shared+16];
      if(!Number.isInteger(detail)||detail<=0||!Number.isInteger(flags)||flags<0||flags>31)
        throw RangeError('Invalid particle detail or flags');
      for(let p=particles;p<particles+source*17;p+=17) {
        const particleMode=inputs[p+16];
        if(![2,3,4,5,6,8].includes(particleMode))throw RangeError('Invalid particle input mode');
        if(particleMode>=5) {
          const size=inputs[shared+(particleMode===6?8:7)],minimum=inputs[shared+12],maximum=inputs[shared+13],fade=inputs[shared+14];
          if(size<=0||minimum<0||maximum<minimum||fade<0)throw RangeError('Invalid particle raster size');
          projectedParticles=true;lineParticles||=particleMode===6;
        }
      }
    } else {
      range(fallback,3);
      if(layouts[d+6]||layouts[d+7])throw RangeError('Invalid vertex input reserved word');
      for(let stream=0;stream<10;stream++) {
        const offset=layouts[d+8+stream*2],stride=layouts[d+9+stream*2],width=widths[stream];
        if(stride!==0&&stride!==width)throw RangeError('Invalid compact vertex stream stride');
        range(offset,source?width+(source-1)*stride:(stride?0:width));
      }
      if(colorBytes)byteColors(layouts[d+10],source,layouts[d+11],colorBytes);
      if(secondaryBytes)byteColors(layouts[d+12],source,layouts[d+13],secondaryBytes);
      if(fallbackBytes)byteColors(fallback,1,0,fallbackBytes);
    }
  }
  if(end!==matrixIds.length)throw RangeError('Incomplete compact vertex draw coverage');
  return {projectedParticles,lineParticles};
}
