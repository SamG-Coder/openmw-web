// Host transfer planning only. Attachment pixels are produced and copied by
// WGSL kernels before sampling; uploading their reserved CPU atlas bytes first
// would transfer the same (potentially 8192x8192) storage just to overwrite it.
export function atlasUploadRanges(wordCount,copies=new Uint32Array(),gpuWordCount=wordCount,residentRanges=[]) {
  if(!Number.isSafeInteger(wordCount)||wordCount<0||!Number.isSafeInteger(gpuWordCount)||gpuWordCount<wordCount
    ||!(copies instanceof Uint32Array)||copies.length%4)
    throw RangeError('Invalid atlas upload layout');
  const generated=[];
  for(const [start,end] of residentRanges) {
    if(!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start<0||end<start||end>wordCount)
      throw RangeError('Resident image exceeds CPU atlas prefix');
    generated.push([start,end]);
  }
  for(let i=0;i<copies.length;i+=4) {
    const [id,offset,width,height]=copies.subarray(i,i+4);
    const words=width*height*((id&0x20000000)?4:1),end=offset+words;
    if(!id||!width||!height||!Number.isSafeInteger(end)||end>gpuWordCount)
      throw RangeError('Attachment copy exceeds atlas upload layout');
    // New engine packets reserve these pixels only on the GPU, after the
    // compact CPU prefix. Older packets can still contain the reserved holes.
    if(offset<wordCount)generated.push([offset,Math.min(end,wordCount)]);
  }
  generated.sort((a,b)=>a[0]-b[0]);
  const ranges=[];let cursor=0;
  for(const [start,end] of generated) {
    if(start>cursor)ranges.push([cursor,start]);
    cursor=Math.max(cursor,end);
  }
  if(cursor<wordCount)ranges.push([cursor,wordCount]);
  return ranges;
}
