// Independent dense reference for test fixtures only. Production JS uploads
// raw MyGUI values; vertex-input.cu constructs all expanded shader records.
export function guiInputReference(records,secondaryColor) {
  const vertices=new Float32Array(records.length*10),attributes=new Float32Array(records.length*34),secondary=new Float32Array(records.length*3);
  for(const [i,p] of records.entries()) {
    vertices.set([...p.slice(0,3),1,...p.slice(3,7).map(value=>value/255),...p.slice(7,9)],i*10);
    attributes.set(p.slice(7,9),i*34+16);
    for(let unit=0;unit<4;unit++)attributes[i*34+27+unit*2]=1;
    secondary.set(secondaryColor,i*3);
  }
  return {vertices,attributes,secondary};
}

export async function checkGuiInputsGpu(runtime,kernel) {
  const owned=[],checks=[],allocate=data=>{const buffer=runtime.createBuffer(data);owned.push(buffer);return buffer;};
  const layouts=new Uint32Array(64),inputs=[-9,-8,-7,-6,-5],ids=[],expected=[[],[],[]];
  for(let draw=0;draw<2;draw++) {
    const common=[.125+draw,.25,.375],records=Array.from({length:258},(_,i)=>[
      i*.125-.5,-.75,draw-.25,i&255,(255-i)&255,(i+73)&255,(i*37)&255,-.25,(i%17)*.125]);
    const shared=inputs.length;inputs.push(...common);const source=inputs.length;
    for(const record of records)inputs.push(...record);
    layouts.set([ids.length,records.length,records.length,3,0,0,source,shared],draw*32);
    ids.push(...new Array(records.length).fill(draw));
    const reference=guiInputReference(records,common);
    for(const [k,name] of ['vertices','attributes','secondary'].entries())expected[k].push(...reference[name]);
  }
  const guard=12345,source=allocate(Float32Array.from(inputs)),descriptors=allocate(layouts),matrixIds=allocate(Uint32Array.from(ids));
  const outputs=expected.map(values=>allocate(new Float32Array(values.length+4).fill(guard)));
  const verify=async label=>{
    runtime.batch().dispatch(kernel.bind({inputs:source,layouts:descriptors,matrix_ids:matrixIds,
      vertices:outputs[0],attributes:outputs[1],secondary_colors:outputs[2]},{vertex_count:ids.length}),[3,3,1]).submit();
    for(let k=0;k<3;k++) {
      const actual=await runtime.read(outputs[k]);
      for(let i=0;i<expected[k].length;i++)if(actual[i]!==expected[k][i])throw Error(`${label}: output ${k} word ${i}, ${actual[i]} != ${expected[k][i]}`);
      for(let i=expected[k].length;i<actual.length;i++)if(actual[i]!==guard)throw Error(`${label}: trailing guard changed`);
    }
    checks.push(label);
  };
  try {
    await verify('CUDA GUI construction: every RGBA byte level, relocated draws, 2D dispatch and guards');
    const first=layouts[6];inputs[first]=7;inputs[first+3]=255;inputs[first+6]=128;inputs[first+7]=1.5;
    expected[0][0]=7;expected[0][4]=1;expected[0][7]=Math.fround(128/255);expected[0][8]=expected[1][16]=1.5;
    inputs[layouts[7]]=-.5;for(let i=0;i<258;i++)expected[2][i*3]=-.5;
    runtime.write(source,Float32Array.from(inputs));
    await verify('CUDA GUI construction consumes changed position, color, alpha, UV and current secondary color');
    return checks;
  } finally {for(const buffer of owned)runtime.destroyBuffer(buffer);}
}
