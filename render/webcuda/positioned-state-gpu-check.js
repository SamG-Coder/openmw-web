// Fixture inputs and independent reference multiplication for GPU validation.
// The production host never performs matrix composition.
import {dispatchGroups} from './dispatch.js';
export async function checkPositionedStateGpu(runtime,kernel,entry) {
  const fixed=entry==='prepare_fixed_matrices',stride=fixed?368:144,draws=19;
  const data=new Uint32Array(stride*draws+4),original=data.slice(),post=new Uint32Array(8+32);
  const floats=new Float32Array(data.buffer),postFloats=new Float32Array(post.buffer);
  post[0]=9;post[7]=25;
  const a=[2,0,0,0, 0,3,0,0, 0,0,4,0, 11,-7,5,1];
  const b=[0,1,0,0, -1,0,0,0, 0,0,1,0, -3,6,2,1];
  postFloats.set(b,8);postFloats.set(a,24);
  const matrices=[];
  for(let draw=0;draw<draws;draw++) {
    if(fixed) {
      data.set([129,128,0,draw%3===0?0:1],draw*368);
      for(let light=0;light<8;light++) {
        const matrix=draw*368+72+light*40;floats.set(a,matrix);
        if(draw%3!==0&&(light===0||light===7))matrices.push([matrix,light===0?b:a]);
      }
    } else for(let unit=0;unit<4;unit++) {
      const d=draw*144+unit*36,enabled=draw%3!==0&&unit%2===0;
      data.set([15,5,0,enabled?(unit===0?9:25):0],d);floats.set(a,d+20);
      if(enabled)matrices.push([d+20,unit===0?b:a]);
    }
  }
  data.fill(0xa123bc45,stride*draws);original.set(data);
  const expected=data.slice(),expectedFloats=new Float32Array(expected.buffer),changed=new Set();
  for(const [offset,parent] of matrices)for(let col=0;col<4;col++)for(let row=0;row<4;row++) {
    let value=0;for(let k=0;k<4;k++)value+=parent[k*4+row]*a[col*4+k];
    expectedFloats[offset+col*4+row]=value;changed.add(offset+col*4+row);
  }
  const descriptors=runtime.createBuffer(data),positioned=runtime.createBuffer(post);
  try {
    runtime.batch().dispatch(kernel.bind({descriptors,positioned},{draw_count:draws}),dispatchGroups(draws*(fixed?8:4),runtime.device.limits)).submit();
    const result=await runtime.read(descriptors,Uint32Array,data.byteLength),values=new Float32Array(result.buffer,result.byteOffset,result.length);
    for(let i=0;i<data.length;i++) {
      if(changed.has(i)) {
        if(!Number.isFinite(values[i])||Math.abs(values[i]-expectedFloats[i])>1e-5)throw Error(`${entry}: matrix word ${i} differs`);
      } else if(result[i]!==original[i])throw Error(`${entry}: untouched descriptor or guard ${i} changed`);
    }
    // A new capture overwrites the raw descriptor before preparation; repeat to
    // catch accidental dependence on a previous GPU-composed matrix.
    runtime.write(descriptors,original);
    runtime.batch().dispatch(kernel.bind({descriptors,positioned},{draw_count:draws}),dispatchGroups(draws*(fixed?8:4),runtime.device.limits)).submit();
    const again=await runtime.read(descriptors,Uint32Array,data.byteLength);
    if(again.some((word,i)=>word!==result[i]))throw Error(`${entry}: recaptured input did not reproduce its matrix`);
    return [`${entry}: inherited matrix order, offsets, inactive descriptors, guards and repeated capture`];
  } finally {runtime.destroyBuffer(descriptors);runtime.destroyBuffer(positioned);}
}
