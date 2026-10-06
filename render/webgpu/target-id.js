// Emscripten i32 scalar arguments can be signed while packet arrays are Uint32.
// Canonicalize IDs once at the host boundary; reject values outside that ABI.
export function targetId(value) {
  if(!Number.isInteger(value)||value < -0x80000000||value > 0xffffffff)
    throw RangeError('Invalid WebGPU target ID');
  return value>>>0;
}
export function targetCommand(value) {
  const result={...value};
  for(const key of ['targetId','sourceId','depthTargetId','normalTargetId','stencilTargetId','distortionId'])
    if(Object.hasOwn(result,key))result[key]=targetId(result[key]);
  return result;
}
