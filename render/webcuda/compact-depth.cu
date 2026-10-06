// Scalar depth planes keep full resolution without unused color/normal storage.
__global__ void clear_compact_depth(float* target,unsigned int pixel_count,float depth) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i<pixel_count)target[i]=depth;
}
__global__ void copy_depth_layout(const float* source,float* target,unsigned int pixel_count,unsigned int source_compact,unsigned int target_compact) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i<pixel_count)target[target_compact!=0u?i:i*9u+4u]=source[source_compact!=0u?i:i*9u+4u];
}
__global__ void compact_depth_to_texture(const float* target,unsigned int* texels,unsigned int width,unsigned int height,unsigned int offset) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i<width*height)texels[offset+(height-1u-i/width)*width+i%width]=__float_as_uint(target[i]);
}
