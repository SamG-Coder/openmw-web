// Transport metadata only. All pixel conversion occurs in authored .cu.
const formats=new Map([[0x1908,[4,0]],[0x8058,[4,0]],[0x1907,[3,0]],[0x8051,[3,0]],
  [0x822a,[1,4]],[0x822c,[2,4]],[0x8054,[3,4]],[0x805b,[4,4]],
  [0x8f94,[1,5]],[0x8f95,[2,5]],[0x8f96,[3,5]],[0x8f97,[4,5]],
  [0x8f98,[1,6]],[0x8f99,[2,6]],[0x8f9a,[3,6]],[0x8f9b,[4,6]],
  [0x881a,[4,1]],[0x881b,[3,1]],[0x8814,[4,2]],[0x8815,[3,2]],
  [0x8229,[1,0]],[0x822b,[2,0]],[0x822d,[1,1]],[0x822f,[2,1]],[0x822e,[1,2]],[0x8230,[2,2]]]);
export function colorStorage(format) {
  const value=formats.get(format);if(!value)throw Error('Unsupported colour attachment format');
  return {channels:value[0],storage:value[1]};
}

export function depthStorage(format) {
  if(format===0x81a5)return 16;
  if(format===0x81a6||format===0x88f0||format===0x1902)return 24;
  if(format===0x8cac||format===0x8cad)return 0; // FLOAT32, optionally packed stencil
  throw Error('Unsupported depth attachment format');
}
