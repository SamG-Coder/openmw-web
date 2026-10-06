// SPDX-License-Identifier: GPL-3.0-or-later
#include "precision.cuh"
// Decode little-endian S3TC blocks to packed RGBA8 without OpenGL. Formats:
// 1 = DXT1 RGBA, 2 = DXT1 RGB, 3 = DXT3, 5 = DXT5. One thread per 4x4 block.
__global__ void decode_dxt(const unsigned int* blocks, unsigned int* pixels,
                          unsigned int width, unsigned int height, unsigned int format,
                          unsigned int block_offset, unsigned int pixel_offset) {
    unsigned int linear_output=format&65536u;
    unsigned int channels=(format>>8u)&7u;
    unsigned int encoding=format&255u;
    unsigned int block = (blockIdx.x + blockIdx.y * gridDim.x) * blockDim.x + threadIdx.x;
    unsigned int columns=(width+3)/4;
    if (block >= columns*((height+3)/4)) return;
    unsigned int base=block_offset+block*((encoding==1 || encoding==2)?2:4);
    unsigned int colorbase=base+((encoding==1 || encoding==2)?0:2);
    unsigned int endpoints=blocks[colorbase];
    unsigned int c0=endpoints&65535; unsigned int c1=endpoints>>16;
    unsigned int r0=(c0>>11)&31; r0=(r0<<3)|(r0>>2);
    unsigned int g0=(c0>>5)&63; g0=(g0<<2)|(g0>>4);
    unsigned int b0=c0&31; b0=(b0<<3)|(b0>>2);
    unsigned int r1=(c1>>11)&31; r1=(r1<<3)|(r1>>2);
    unsigned int g1=(c1>>5)&63; g1=(g1<<2)|(g1>>4);
    unsigned int b1=c1&31; b1=(b1<<3)|(b1>>2);
    for (unsigned int p=0;p<16;p++) {
        unsigned int x=(block%columns)*4+p%4, y=(block/columns)*4+p/4;
        if(x>=width || y>=height) continue;
        unsigned int index=(blocks[colorbase+1]>>(p*2))&3;
        unsigned int r=r0,g=g0,b=b0,a=255;
        if(index==1) {r=r1;g=g1;b=b1;}
        if(index>=2) {
            if(c0>c1 || encoding==3 || encoding==5) {
                unsigned int weight=index==2?2:1;
                r=(weight*r0+(3-weight)*r1)/3;g=(weight*g0+(3-weight)*g1)/3;b=(weight*b0+(3-weight)*b1)/3;
            } else if(index==2) {r=(r0+r1)/2;g=(g0+g1)/2;b=(b0+b1)/2;}
            else {r=0;g=0;b=0;if(encoding==1)a=0;}
        }
        if(encoding==3) a=((blocks[base+p/8]>>((p%8)*4))&15)*17;
        if(encoding==5) {
            unsigned int a0=blocks[base]&255,a1=(blocks[base]>>8)&255;
            unsigned int lo=(blocks[base]>>16)|(blocks[base+1]<<16),hi=blocks[base+1]>>16;
            unsigned int bit=p*3, ai=0;
            if(bit<32) {ai=lo>>bit;if(bit>29)ai|=hi<<(32-bit);}
            else ai=hi>>(bit-32);
            ai&=7;
            if(ai==0)a=a0;else if(ai==1)a=a1;
            else if(a0>a1)a=((8-ai)*a0+(ai-1)*a1)/7;
            else if(ai<6)a=((6-ai)*a0+(ai-1)*a1)/5;
            else a=ai==6?0:255;
        }
        if(linear_output!=0u) {
            unsigned int out=pixel_offset+(y*width+x)*4u;
            pixels[out]=__float_as_uint(srgb_to_linear((float)r/255.0f));
            pixels[out+1u]=__float_as_uint(srgb_to_linear((float)g/255.0f));
            pixels[out+2u]=__float_as_uint(srgb_to_linear((float)b/255.0f));
            pixels[out+3u]=__float_as_uint(channels==3u?1.0f:(float)a/255.0f);
        } else pixels[pixel_offset+y*width+x]=r|(g<<8)|(b<<16)|(a<<24);
    }
}
