import {atlasUploadRanges} from './atlas-upload.js';

export async function checkAtlasUploadGpu(runtime) {
  const resources=[];
  const buffer=data=>{const value=runtime.createBuffer(data);resources.push(value);return value;};
  try {
    const [depthKernel,colorKernel]=await Promise.all(['depth_to_texture','float_target_to_texture'].map(async name=>
      runtime.kernel(await (await fetch(`./generated/${name}.json`)).json())));
    const sourceValues=new Float32Array(40);
    for(let pixel=0;pixel<4;pixel++)for(let channel=0;channel<9;channel++)sourceValues[pixel*9+channel]=(pixel+1)*.1+channel*.01;
    const source=buffer(sourceValues),words=Uint32Array.from({length:64},(_,i)=>i+100);
    const full=buffer(words),sparse=buffer(new Uint32Array(64).fill(0xdeadbeef));
    const copies=new Uint32Array([0x80000001,8,2,2,0x20000002,24,2,2]);
    let uploaded=0;
    for(const [first,last] of atlasUploadRanges(words.length,copies)) {
      const view=words.subarray(first,last);runtime.write(sparse,view,first*4);uploaded+=view.byteLength;
    }
    for(const texels of [full,sparse])runtime.batch()
      .dispatch(depthKernel.bind({target:source,texels},{width:2,height:2,offset:8}),[1,1,1])
      .dispatch(colorKernel.bind({target:source,texels},{width:2,height:2,offset:24}),[1,1,1]).submit();
    const [expected,actual]=await Promise.all([runtime.read(full,Uint32Array),runtime.read(sparse,Uint32Array)]);
    if(expected.some((value,i)=>value!==actual[i]))throw Error('Sparse atlas upload changed attachment pixels or untouched metadata');
    if(uploaded!==176)throw Error('Attachment output storage was uploaded unnecessarily');
    const prefix=words.subarray(0,8),gpuWords=28,reference=new Uint32Array(gpuWords);
    reference.set(prefix);
    const fullTail=buffer(reference),compact=buffer(new Uint32Array(gpuWords).fill(0xdeadbeef));
    const tailCopies=new Uint32Array([0x80000001,8,2,2,0x20000002,12,2,2]);
    let compactUploaded=0;
    for(const [first,last] of atlasUploadRanges(prefix.length,tailCopies,gpuWords)) {
      const view=prefix.subarray(first,last);runtime.write(compact,view,first*4);compactUploaded+=view.byteLength;
    }
    for(const texels of [fullTail,compact])runtime.batch()
      .dispatch(depthKernel.bind({target:source,texels},{width:2,height:2,offset:8}),[1,1,1])
      .dispatch(colorKernel.bind({target:source,texels},{width:2,height:2,offset:12}),[1,1,1]).submit();
    const [tailExpected,tailActual]=await Promise.all([runtime.read(fullTail,Uint32Array),runtime.read(compact,Uint32Array)]);
    if(tailExpected.some((value,i)=>value!==tailActual[i]))throw Error('Compact atlas changed CPU metadata or GPU-only attachment pixels');
    if(compactUploaded!==32)throw Error('Compact atlas uploaded more than its CPU prefix');
    return `sparse and compact atlas uploads match full uploads after CUDA depth/color copies (${uploaded}/${words.byteLength} and ${compactUploaded}/${reference.byteLength} bytes)`;
  } finally {for(const resource of resources)runtime.destroyBuffer(resource);}
}
