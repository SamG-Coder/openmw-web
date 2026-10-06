// Freeze the previous resolved screen on the GPU for loading-screen backgrounds.
// Resize in CUDA if the window extent changed between frames; no CPU readback.
__global__ void snapshot_frame(const float* source,float* target,unsigned int source_width,unsigned int source_height,
                               unsigned int width,unsigned int height) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=width*height)return;
    unsigned int valid=source_width>0u&&source_height>0u;
    unsigned int sx=valid!=0u?(unsigned int)(((float)(i%width)+0.5f)*(float)source_width/(float)width):0u;
    unsigned int sy=valid!=0u?(unsigned int)(((float)(i/width)+0.5f)*(float)source_height/(float)height):0u;
    if(valid!=0u){if(sx>=source_width)sx=source_width-1u;if(sy>=source_height)sy=source_height-1u;}
    for(unsigned int k=0;k<3;k++)target[i*9u+k]=valid!=0u?source[(sy*source_width+sx)*9u+k]:0.0f;
    target[i*9u+3u]=1.0f;target[i*9u+4u]=1.0f;
    for(unsigned int k=5;k<9;k++)target[i*9u+k]=0.0f;
    target[width*height*9u+i]=0.0f;
}
