// Local-map exploration mask. Inputs are saved RGBA8 pixels plus brush history.
// One thread owns one pixel; each brush applies the engine's minimum-alpha rule.
// Brush records: center X, center Y, squared exploration radius, in texel units.
__global__ void generate_fog_map(const unsigned int* blocks,unsigned int* pixels,
                                unsigned int width,unsigned int height,unsigned int block_offset,unsigned int pixel_offset) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=width*height)return;
    unsigned int brush_count=blocks[block_offset],saved=blocks[block_offset+1u+i];
    unsigned int brushes=block_offset+1u+width*height;
    unsigned int alpha=saved>>24u;
    float x=(float)(i%width),y=(float)(i/width);
    for(unsigned int b=0;b<brush_count;b++) {
        float dx=x-__uint_as_float(blocks[brushes+b*3u]),dy=y-__uint_as_float(blocks[brushes+b*3u+1u]);
        float fraction=fminf(1.0f,fmaxf(0.0f,(dx*dx+dy*dy)/__uint_as_float(blocks[brushes+b*3u+2u])));
        unsigned int candidate=(unsigned int)(fraction*255.0f);
        if(candidate<alpha)alpha=candidate;
    }
    pixels[pixel_offset+i]=brush_count==0u?saved:alpha<<24u;
}
