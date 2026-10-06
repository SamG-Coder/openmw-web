// Independent dense test data mirrors the former four-corner CPU capture.
// Production JS uploads raw particles; only the .cu kernel expands them.
export function particleInputReference(records,common) {
  const vertices=new Float32Array(records.length*40),attributes=new Float32Array(records.length*136),secondary=new Float32Array(records.length*12);
  for(let particle=0;particle<records.length;particle++)for(let corner=0;corner<4;corner++) {
    const p=Float32Array.from(records[particle]),c=Float32Array.from(common),i=particle*4+corner,v=i*10,a=i*34;
    const u=corner===1||corner===2?1:0,t=corner>=2?1:0,mode=p[16];
    let s=Math.fround(p[7]+Math.fround(u*p[9])),r=Math.fround(p[8]+Math.fround(t*p[10]));
    if(mode===5){s=.5;r=.5;}else if(mode===6){s=u;r=u;}else if(mode===8){s=u;r=1-t;}
    vertices.set([p[0],p[1],p[2],1,p[3],p[4],p[5],p[6],s,r],v);
    attributes.set([mode,u*2-1,t*2-1,...c.slice(0,6),p[11],...p.slice(13,16),p[12],c[6]],a);
    if(mode>=5) {
      attributes[a+15]=c[mode===6?8:7];
      if(mode!==6)attributes.set(c.slice(9,12),a+10);
      attributes.set(c.slice(12,15),a+18);
    }
    attributes.set([s,r],a+16);attributes.set(c.slice(17,20),a+21);
    attributes[a+24]=mode===8?c[15]:0;attributes[a+25]=c[16];
    for(let unit=0;unit<4;unit++)attributes[a+27+unit*2]=1;
    secondary.set(c.slice(20,23),i*3);
  }
  return {vertices,attributes,secondary};
}

export async function checkParticleInputsGpu(runtime,kernel) {
  const owned=[],checks=[],allocate=data=>{const b=runtime.createBuffer(data);owned.push(b);return b;};
  const layouts=new Uint32Array(64),inputs=[-9,-8,-7,-6,-5],ids=[],expected=[[],[],[]];
  for(let draw=0;draw<2;draw++) {
    const common=[1.25,.5,-.25,.125,1.5,.75,3,7,3.5,.5,.25,.125,2,48,4,12.5,31,.25,.5,.75,.125,.25,.375];
    const records=Array.from({length:36},(_,i)=>[i*.125-.5,-.75,draw-.25,.25,.5,.75,.5,.125,.375,.25,.125,.75,.625,-.25,.5,.75,[2,3,4,5,6,8][i%6]]);
    const shared=inputs.length;inputs.push(...common);const particles=inputs.length;
    for(const record of records)inputs.push(...record);
    layouts.set([ids.length,records.length*4,records.length,2,0,0,particles,shared],draw*32);
    ids.push(...new Array(records.length*4).fill(draw));
    const reference=particleInputReference(records,common);
    for(const [k,name] of ['vertices','attributes','secondary'].entries())expected[k].push(...reference[name]);
  }
  const guard=12345,source=allocate(Float32Array.from(inputs)),descriptors=allocate(layouts),matrixIds=allocate(Uint32Array.from(ids));
  const outputs=expected.map(values=>allocate(new Float32Array(values.length+4).fill(guard)));
  const verify=async label=>{
    // More than one grid row verifies the same flattened index used in-game.
    runtime.batch().dispatch(kernel.bind({inputs:source,layouts:descriptors,matrix_ids:matrixIds,
      vertices:outputs[0],attributes:outputs[1],secondary_colors:outputs[2]},{vertex_count:ids.length}),[2,3,1]).submit();
    for(let k=0;k<3;k++) {
      const actual=await runtime.read(outputs[k]);
      for(let i=0;i<expected[k].length;i++)if(actual[i]!==expected[k][i])throw Error(`${label}: output ${k} word ${i}, ${actual[i]} != ${expected[k][i]}`);
      for(let i=expected[k].length;i<actual.length;i++)if(actual[i]!==guard)throw Error(`${label}: trailing guard changed`);
    }
    checks.push(label);
  };
  try {
    await verify('CUDA particle construction: six modes, raw texture tiles, relocated draws, 2D dispatch and guards');
    const particle=layouts[6];inputs[particle+3]=.875;
    for(let corner=0;corner<4;corner++)expected[0][corner*10+4]=.875;
    runtime.write(source,Float32Array.from(inputs));
    await verify('CUDA particle construction consumes changed capture inputs without retaining old colors');
    return checks;
  } finally {for(const buffer of owned)runtime.destroyBuffer(buffer);}
}
