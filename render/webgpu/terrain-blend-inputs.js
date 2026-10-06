// Validate immutable source layouts before GPU reads. Pixel generation and
// opacity arithmetic are exclusively in generate_terrain_blendmap.wgsl.
export function terrainBlendInputRange(blocks,offset,width,height,validated=new Map()) {
  const fail=()=>{throw RangeError('Invalid terrain blend inputs');};
  if(!(blocks instanceof Uint32Array)||!Number.isSafeInteger(offset)||offset<0||offset+4>blocks.length
    ||!Number.isSafeInteger(width)||!Number.isSafeInteger(height)||width<=0||height<=0)fail();
  const mode=blocks[offset],layer=blocks[offset+1],source=blocks[offset+2],words=blocks[offset+3];
  if(mode>1||words<3||source+words>offset)fail();
  const columns=blocks[source],rows=blocks[source+1],layers=blocks[source+2];
  if(!columns||!rows||!layers||layer>=layers)fail();
  const signature=`${mode}:${words}:${width}:${height}`;
  if(validated.has(source)) {
    if(validated.get(source)!==signature)fail();
  } else {
    if(mode===0) {
      if(columns*2!==width||rows*2!==height||3+columns*rows!==words)fail();
      for(let i=source+3;i<source+words;i++)if(blocks[i]>=layers)fail();
    } else {
      if(columns!==Math.ceil(width/16)||rows!==1+Math.ceil((height-1)/16)||3+columns*rows>words)fail();
      const floats=new Float32Array(blocks.buffer,blocks.byteOffset,blocks.length);
      for(let q=0;q<columns*rows;q++) {
        const quad=blocks[source+3+q];if(!quad)continue;
        if(quad<3+columns*rows||quad+291>words||blocks[source+quad]>=layers)fail();
        let begin=blocks[source+quad+1];
        if(begin<quad+291||begin>words)fail();
        for(let vertex=0;vertex<289;vertex++) {
          const end=blocks[source+quad+2+vertex];
          if(end<begin||end>words||(end-begin)%2)fail();
          for(let record=begin;record<end;record+=2)
            if(blocks[source+record]>=layers||!Number.isFinite(floats[source+record+1]))fail();
          begin=end;
        }
      }
    }
    validated.set(source,signature);
  }
  // Payloads are shared by layer descriptors. Merging upload ranges includes
  // each source once, even when several generated masks require it.
  return {offset:source,words:offset+4-source};
}
