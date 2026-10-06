// SPDX-License-Identifier: GPL-3.0-or-later
// Source words retain the file's byte/float/half bits. GPU conversion and swizzle
// produce four float-bit atlas words per texel with requested storage precision.
#include "precision.cuh"
__global__ void decode_float_image(const unsigned int* blocks,unsigned int* pixels,
    unsigned int width,unsigned int height,unsigned int format,unsigned int block_offset,unsigned int pixel_offset) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=width*height)return;
    unsigned int destination_kind=(format>>8u)&15u,storage=(format>>12u)&7u,convert=format&65536u;
    unsigned int encoding=format&255u;
    unsigned int family=encoding/16u,kind=encoding%16u;
    unsigned int channels=(kind==6u||kind==13u)?4u:((kind==7u||kind==14u)?3u:((kind==8u||kind==11u)?2u:1u));
    unsigned int input[4];for(unsigned int k=0;k<4;k++)input[k]=k==3?1065353216u:0u;
    for(unsigned int k=0;k<channels;k++) {
        unsigned int index=i*channels+k;
        if(family>=8u) {
            unsigned int packed=family<14u?(blocks[block_offset+i/2u]>>((i%2u)*16u))&65535u:blocks[block_offset+i];
            unsigned int shift=0u,bits=8u;
            if(family==8u||family==9u) {
                bits=k==1u?6u:5u;
                shift=family==8u?(k==0u?11u:(k==1u?5u:0u)):(k==0u?0u:(k==1u?5u:11u));
            } else if(family==10u||family==11u) {
                bits=4u;shift=family==10u?(3u-k)*4u:k*4u;
            } else if(family==12u||family==13u) {
                bits=k==3u?1u:5u;
                shift=family==12u?(k==3u?0u:11u-k*5u):(k==3u?15u:k*5u);
            } else shift=family==14u?(3u-k)*8u:k*8u;
            unsigned int mask=(1u<<bits)-1u;
            input[k]=__float_as_uint((float)((packed>>shift)&mask)/(float)mask);
        }
        else if(family==0u)input[k]=blocks[block_offset+index];
        else if(family==1u)input[k]=expand_half((blocks[block_offset+index/2u]>>((index%2u)*16u))&65535u);
        else {
            unsigned int value;
            float decoded;
            if(family==2u||family==4u) {
                value=(blocks[block_offset+index/4u]>>((index%4u)*8u))&255u;
                decoded=family==2u?(float)value/255.0f:fmaxf(-1.0f,(float)((int)value-(value>=128u?256:0))/127.0f);
            } else if(family==3u||family==5u) {
                value=(blocks[block_offset+index/2u]>>((index%2u)*16u))&65535u;
                decoded=family==3u?(float)value/65535.0f:fmaxf(-1.0f,(float)((int)value-(value>=32768u?65536:0))/32767.0f);
            } else {
                value=blocks[block_offset+index];
                decoded=family==6u?(float)value/4294967295.0f:fmaxf(-1.0f,(float)((int)value)/2147483647.0f);
            }
            input[k]=__float_as_uint(decoded);
        }
    }
    // Depth images share the scalar float atlas ABI used by rendered depth
    // attachments. Floating depth retains its bits (including fallback +inf).
    if(convert!=0u&&destination_kind==9u) {
        pixels[pixel_offset+i]=storage==0u?input[0]:__float_as_uint(store_depth_value(__uint_as_float(input[0]),storage==1u?16u:24u));
        return;
    }
    float color[4];
    for(unsigned int k=0;k<4;k++) {
        unsigned int value=input[k];
        if(kind==10u||kind==11u)value=k==3u?(kind==11u?input[1]:1065353216u):input[0];
        if(kind==12u)value=k==3u?input[0]:0u;
        if((kind==13u||kind==14u)&&k<3u)value=input[2u-k];
        color[k]=__uint_as_float(value);
    }
    for(unsigned int k=0;k<4;k++) {
        float value=color[k];
        if(convert!=0u) {
            if(destination_kind==5u||destination_kind==6u)value=k==3u?(destination_kind==6u?color[3]:1.0f):color[0];
            if(destination_kind==7u)value=k==3u?color[3]:0.0f;
            if(destination_kind==8u)value=color[0];
            // Upload components already contain encoded sRGB values. Quantize
            // those values before decoding; mip generation starts in linear space.
            if(storage==3u) {
                value=store_color_value(value,k,destination_kind,0u);
                if(k<3u)value=srgb_to_linear(value);
            } else value=store_color_value(value,k,destination_kind>4u?4u:destination_kind,storage);
        }
        pixels[pixel_offset+i*4u+k]=__float_as_uint(value);
    }
}
