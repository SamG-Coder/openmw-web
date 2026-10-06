export const NATIVE_PAGE_BYTES=64*1024*1024;
export const NATIVE_ALLOCATION_ALIGNMENT=64*1024;

export function pageRanges(size,offset=0,byteLength=size-offset) {
  if([size,offset,byteLength].some(n=>!Number.isSafeInteger(n)||n<0||n%4)||offset+byteLength>size)
    throw RangeError('Invalid native page range');
  const result=[];
  for(let cursor=offset,end=offset+byteLength;cursor<end;) {
    const page=Math.floor(cursor/NATIVE_PAGE_BYTES),pageOffset=cursor%NATIVE_PAGE_BYTES;
    const bytes=Math.min(end-cursor,NATIVE_PAGE_BYTES-pageOffset);
    result.push({page,pageOffset,offset:cursor-offset,byteLength:bytes});cursor+=bytes;
  }
  return result;
}

// RGBA8 copy layout, including the uncommon case where a page splits a row.
// Only GPU transfer coordinates are calculated here, never pixel values.
export function canvasPageCopies(size,width,height,rowPixels) {
  if(![width,height,rowPixels].every(n=>Number.isSafeInteger(n)&&n>0)||rowPixels<width||rowPixels%64)
    throw RangeError('Invalid native canvas copy layout');
  const rowBytes=rowPixels*4;
  if(!Number.isSafeInteger(rowBytes*height)||rowBytes*height>size)throw RangeError('Canvas pixels exceed native buffer');
  const copies=[];
  for(let y=0;y<height;) {
    const absolute=y*rowBytes,page=Math.floor(absolute/NATIVE_PAGE_BYTES),offset=absolute%NATIVE_PAGE_BYTES;
    const available=Math.min(NATIVE_PAGE_BYTES-offset,size-absolute);
    const rows=Math.min(height-y,Math.floor(available/rowBytes));
    if(rows) {copies.push({page,offset,x:0,y,width,height:rows,bytesPerRow:rowBytes});y+=rows;continue;}
    for(let x=0;x<width;) {
      const cursor=absolute+x*4,p=Math.floor(cursor/NATIVE_PAGE_BYTES),o=cursor%NATIVE_PAGE_BYTES;
      const pixels=Math.min(width-x,(NATIVE_PAGE_BYTES-o)/4);
      copies.push({page:p,offset:o,x,y,width:pixels,height:1});x+=pixels;
    }
    y++;
  }
  return copies;
}
