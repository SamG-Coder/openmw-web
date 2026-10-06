// Kernels flatten a two-dimensional CUDA block grid. This avoids the 65,535
// workgroup limit of a single WebGPU dimension at 4K and on large meshes.
export function dispatchGroups(count, limits) {
  if(!Number.isSafeInteger(count)||count<0)throw RangeError('Invalid dispatch size');
  const groups=Math.max(1,Math.ceil(count/64));
  const maximum=limits.maxComputeWorkgroupsPerDimension;
  const x=Math.min(groups,maximum),y=Math.ceil(groups/x);
  if(y>maximum)throw RangeError('Dispatch exceeds device workgroup limits');
  return [x,y,1];
}
