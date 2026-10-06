// Dispatch the authored raster kernel using fixtures shared with material.test.cpp.
// JavaScript supplies inputs and checks readback; it performs no rendering.
export async function checkRasterGpu(runtime, kernel) {
  const boundary_offset=136,point_fade_offset=140,raster_offset=188;
  const vertices=new Float32Array([
    -1,1,0,1,1,0,0,.5,0,0, 1,1,0,1,1,0,0,.5,1,0,
    1,-1,0,1,1,0,0,.5,1,1, -1,-1,0,1,1,0,0,.5,0,1,
  ]);
  const triangles=new Uint32Array([0,1,2,0,0,2,3,0]);
  const materials=new Uint32Array([0,2,2,2,0,0,0,4,4,0,0,0]);
  const attributes=new Float32Array(raster_offset+50);
  attributes[raster_offset+3]=1;
  for(let v=0;v<4;v++){attributes[boundary_offset+v]=1;attributes[point_fade_offset+v*12]=1;}
  const inputs={vertices,triangles,materials,attributes,counts:new Uint32Array([2]),
    candidates:new Uint32Array([0,1]),texels:new Uint32Array([0xff0000ff,0xff00ff00,0xffff0000,0xffffffff])};
  const buffers={};
  const initial=new Float32Array(164);
  for(let p=0;p<16;p++){initial[p*9+3]=1;initial[p*9+4]=1;}
  initial.fill(12345,160);
  const scalars={width:4,height:4,capacity:2,raster_offset,boundary_offset,point_fade_offset,
    lighting_offset:0,cluster_offset:0,fixed_offset:0,falloff_offset:0,fixed_enabled:0,
    normal_enabled:0,normal_channels:4,normal_storage:2,color_channels:4,color_storage:2,
    depth_bits:0,stencil_enabled:0,sample_count:1};
  const checks=[];
  const close=(value,expected,label)=>{
    if(!Number.isFinite(value)||Math.abs(value-expected)>1e-5)throw Error(`${label}: expected ${expected}, got ${value}`);
  };
  async function run(label, expected){
    for(const name of ['vertices','triangles','materials'])runtime.write(buffers[name],inputs[name]);
    runtime.write(buffers.target,initial);
    runtime.batch().dispatch(kernel.bind(buffers,scalars),[1,1,1]).submit();
    const output=await runtime.read(buffers.target);
    for(let p=0;p<16;p++)expected(output,p);
    for(let i=160;i<164;i++)close(output[i],12345,`${label} guard ${i}`);
    checks.push(label);
  }
  try {
    for(const [name,data] of Object.entries(inputs))buffers[name]=runtime.createBuffer(data,{label:`raster fixture ${name}`});
    buffers.target=runtime.createBuffer(initial,{label:'raster fixture target with guard'});
    for(let winding=0;winding<2;winding++){
      await run(`quad winding ${winding}`,(out,p)=>{close(out[p*9],.5,'red');close(out[p*9+4],1,'depth');});
      [triangles[1],triangles[2]]=[triangles[2],triangles[1]];
      [triangles[5],triangles[6]]=[triangles[6],triangles[5]];
    }
    materials[3]=2|4|8;materials[4]=200;
    await run('alpha discard before depth',(out,p)=>{close(out[p*9],0,'discard color');close(out[p*9+4],1,'discard depth');});
    materials[4]=0;materials[5]=1;materials[6]=1;materials[7]=2;materials[8]=2;
    await run('scissor before depth',(out,p)=>{
      const inside=p%4>=1&&p%4<3&&Math.floor(p/4)>=1&&Math.floor(p/4)<3;
      close(out[p*9],inside?.5:0,'scissor color');close(out[p*9+4],inside?.5:1,'scissor depth');
    });
    materials[3]=1;materials[5]=0;materials[6]=0;materials[7]=4;materials[8]=4;
    for(let v=0;v<4;v++)vertices.fill(1,v*10+4,v*10+8);
    await run('textured quad quadrants',(out,p)=>{
      const right=p%4>=2,bottom=Math.floor(p/4)>=2;
      const rgb=bottom?(right?[1,1,1]:[0,0,1]):(right?[0,1,0]:[1,0,0]);
      for(let c=0;c<3;c++)close(out[p*9+c],rgb[c],`texture pixel ${p} channel ${c}`);
    });
    const fullTarget=buffers.target;
    const compactInitial=new Float32Array(20);compactInitial.fill(1,0,16);compactInitial.fill(12345,16);
    const compactTarget=runtime.createBuffer(compactInitial,{label:'compact depth with guards'});
    try {
      buffers.target=compactTarget;scalars.color_channels=0;
      materials[3]=2|4|8;materials[5]=0;materials[6]=0;materials[7]=4;materials[8]=4;
      for(const threshold of [0,255]) {
        materials[4]=threshold;
        for(let v=0;v<4;v++)vertices[v*10+7]=.5;
        runtime.write(buffers.materials,materials);runtime.write(buffers.vertices,vertices);runtime.write(compactTarget,compactInitial);
        runtime.batch().dispatch(kernel.bind(buffers,scalars),[1,1,1]).submit();
        const out=await runtime.read(compactTarget);
        for(let p=0;p<16;p++)close(out[p],threshold===0?.5:1,'compact depth alpha test');
        for(let p=16;p<20;p++)close(out[p],12345,'compact depth guard');
        checks.push(`compact scalar depth with alpha threshold ${threshold}`);
      }
    } finally {buffers.target=fullTarget;scalars.color_channels=4;runtime.destroyBuffer(compactTarget);}
    materials[3]=8388608|128|4|8;materials[9]=6|(7<<4);materials[4]=0;
    for(let p=0;p<16;p++)initial[p*9+4]=0;
    for(let v=0;v<4;v++){vertices[v*10+2]=.25;vertices[v*10+4]=1;}
    await run('reverse Z zero-to-one against zero clear',(out,p)=>{
      close(out[p*9],1,'reverse Z color');close(out[p*9+4],.25,'reverse Z depth');
    });
    for(let v=0;v<4;v++)vertices[v*10+2]=-.1;
    await run('zero-to-one rejects negative clip depth',(out,p)=>{
      close(out[p*9],0,'negative clip color');close(out[p*9+4],0,'negative clip depth');
    });
    return checks;
  } finally {for(const buffer of Object.values(buffers))runtime.destroyBuffer(buffer);}
}
