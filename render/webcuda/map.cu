// Generate global-map palette color and land alpha from raw 9x9 WNAM cells.
__global__ void generate_map(const unsigned int* blocks,unsigned int* pixels,unsigned int width,unsigned int height,
                            unsigned int block_offset,unsigned int pixel_offset,unsigned int alpha_only) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=width*height)return;
    unsigned int cells_x=blocks[block_offset],cell_size=blocks[block_offset+2u];
    unsigned int x=i%width,y=i/width;
    unsigned int cell=(y/cell_size)*cells_x+x/cell_size;
    unsigned int sample=((y%cell_size)*9u/cell_size)*9u+(x%cell_size)*9u/cell_size;
    unsigned int index=blocks[block_offset+1027u+cell*81u+sample];
    if(index>255u)index=255u;
    unsigned int packed=4278190080u;
    if(alpha_only!=0u)packed=16777215u|(index<128u?0u:4278190080u);
    else for(unsigned int channel=0;channel<3;channel++) {
        float value=__uint_as_float(blocks[block_offset+3u+index*4u+channel]);
        unsigned int byte=(unsigned int)(fminf(1.0f,fmaxf(0.0f,value))*255.0f);
        packed|=byte<<(channel*8u);
    }
    pixels[pixel_offset+i]=packed;
}
