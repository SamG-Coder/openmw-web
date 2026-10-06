// Numerical fixtures for raw source color formats. Production JS never
// normalizes these values or constructs expanded vertex records.
export async function checkColorInputsGpu(runtime,kernel) {
  const owned=[],checks=[],allocate=data=>{const buffer=runtime.createBuffer(data);owned.push(buffer);return buffer;};
  const inputs=[-7,-8],layouts=new Uint32Array(128),ids=[],vertices=[],attributes=[],secondary=[];
  for(let draw=0;draw<4;draw++) {
    const rgb=draw===0,bytes=draw!==2,constant=draw===3,sourceCount=258,count=262;
    const channels=bytes?(rgb?3:4):0,fallback=bytes?[254,128,1]:[-.125,.25,1.5];
    layouts.set([ids.length,count,sourceCount,1,0,inputs.length],draw*32);inputs.push(...fallback);
    layouts.set([channels,bytes?3:0,bytes?3:0],draw*32+28);
    const colors=[],secondaries=[],positions=[],uv=[];
    for(let i=0;i<sourceCount;i++) {
      positions.push(i*.125,-.5,.25,1);uv.push(i*.0625,.5,0,1);
      colors.push(...(bytes?[i&255,(255-i)&255,(i+73)&255,rgb?.375:(i*37)&255]:[1.5,-.25,.5,.375]));
      secondaries.push(...(bytes?[(i+31)&255,(i*17)&255,(i+254)&255]:[.25,-.5,1.5]));
    }
    const streams=[positions,constant?colors.slice(0,4):colors,constant?secondaries.slice(0,3):secondaries,
      [0,0,1],[1,0,0,-1],[.25],uv,[0,0,0,1],[0,0,0,1],[0,0,0,1]];
    for(const [index,stream] of streams.entries()) {
      const stride=index===0||index===6?4:index===1&&!constant?4:index===2&&!constant?3:0;
      layouts.set([inputs.length,stride],draw*32+8+index*2);inputs.push(...stream);
    }
    for(let i=0;i<count;i++) {
      ids.push(draw);const attribute=new Array(34).fill(0);
      if(i<sourceCount) {
        const color=colors.slice((constant?0:i)*4,(constant?0:i)*4+4).map((value,k)=>k<channels?value/255:value);
        const extra=secondaries.slice((constant?0:i)*3,(constant?0:i)*3+3).map(value=>bytes?value/255:value);
        vertices.push(...positions.slice(i*4,i*4+4),...color,...uv.slice(i*4,i*4+2));secondary.push(...extra);
        attribute[5]=1;attribute[6]=1;attribute[9]=-1;attribute[16]=uv[i*4];attribute[17]=.5;
        for(let unit=0;unit<4;unit++)attribute[27+unit*2]=1;
      } else {vertices.push(...new Array(10).fill(0));secondary.push(...fallback.map(value=>bytes?value/255:value));}
      attributes.push(...attribute);
    }
  }
  const expected=[Float32Array.from(vertices),Float32Array.from(attributes),Float32Array.from(secondary)],guard=12345;
  const source=allocate(Float32Array.from(inputs)),descriptors=allocate(layouts),matrixIds=allocate(Uint32Array.from(ids));
  const outputs=expected.map(values=>allocate(new Float32Array(values.length+4).fill(guard)));
  const verify=async label=>{
    runtime.batch().dispatch(kernel.bind({inputs:source,layouts:descriptors,matrix_ids:matrixIds,
      vertices:outputs[0],attributes:outputs[1],secondary_colors:outputs[2]},{vertex_count:ids.length}),[3,6,1]).submit();
    for(let k=0;k<3;k++) {
      const actual=await runtime.read(outputs[k]);
      for(let i=0;i<expected[k].length;i++)if(actual[i]!==expected[k][i])throw Error(`${label}: output ${k} word ${i}: ${actual[i]} != ${expected[k][i]}`);
      for(let i=expected[k].length;i<actual.length;i++)if(actual[i]!==guard)throw Error(`${label}: trailing guard changed`);
    }
    checks.push(label);
  };
  try {
    await verify('CUDA byte colors: RGB/RGBA and float streams, constant bindings, inherited generated tails, all byte levels and guards');
    inputs[layouts[10]]=254;expected[0][4]=Math.fround(254/255);
    inputs[layouts[12]]=128;expected[2][0]=Math.fround(128/255);
    inputs[layouts[5]]=73;for(let i=258;i<262;i++)expected[2][i*3]=Math.fround(73/255);
    runtime.write(source,Float32Array.from(inputs));
    await verify('CUDA byte colors observe changed primary, secondary and fallback source values');
    return checks;
  } finally {for(const buffer of owned)runtime.destroyBuffer(buffer);}
}
