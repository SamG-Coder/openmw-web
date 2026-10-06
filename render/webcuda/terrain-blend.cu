// SPDX-License-Identifier: GPL-3.0-or-later
// Terrain masks from immutable land records. No CPU-generated alpha pixels.
// Descriptor: mode, destination layer, source offset, source word count.
__global__ void generate_terrain_blendmap(const unsigned int* blocks,unsigned int* pixels,
    unsigned int width,unsigned int height,unsigned int block_offset,unsigned int pixel_offset) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=width*height)return;
    unsigned int mode=blocks[block_offset],layer=blocks[block_offset+1u],source=blocks[block_offset+2u];
    unsigned int x=i%width,y=i/width,alpha=0u;
    if(mode==0u) {
        // Vanilla Morrowind doubles each source texel with nearest sampling.
        unsigned int inputWidth=blocks[source];
        alpha=blocks[source+3u+(y/2u)*inputWidth+x/2u]==layer?255u:0u;
    } else {
        // ESM4 excludes the right and bottom shared vertices. The first output
        // row comes from row 16 of the neighbouring quad; subsequent rows use
        // source rows 1..16. This preserves the engine's asymmetric borders.
        unsigned int columns=blocks[source],qx=x/16u,qy=(y+15u)/16u;
        unsigned int quad=blocks[source+3u+qy*columns+qx];
        if(quad!=0u) {
            unsigned int base=blocks[source+quad];
            alpha=base==layer?255u:0u;
            unsigned int vertex=(y==0u?16u:(y-1u)%16u+1u)*17u+x%16u;
            unsigned int begin=blocks[source+quad+1u+vertex],end=blocks[source+quad+2u+vertex];
            for(unsigned int record=begin;record<end;record+=2u) {
                unsigned int paintedLayer=blocks[source+record];
                float opacity=__uint_as_float(blocks[source+record+1u]);
                unsigned int delta=(unsigned int)fminf(255.0f,fmaxf(0.0f,opacity*255.0f));
                if(layer==base)alpha-=alpha<delta?alpha:delta;
                if(layer==paintedLayer)alpha=delta;
            }
        }
    }
    // An ALPHA texture samples white RGB, including where alpha is zero.
    pixels[pixel_offset+i]=16777215u|(alpha<<24u);
}
