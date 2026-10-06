#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cmath>
#include <cstring>
#define __device__
unsigned int __float_as_uint(float value){unsigned int bits;std::memcpy(&bits,&value,4);return bits;}
float __uint_as_float(unsigned int bits){float value;std::memcpy(&value,&bits,4);return value;}
#define __global__
struct Dim { unsigned int x = 0, y = 0; } blockIdx, blockDim, threadIdx, gridDim;
#include "dxt.cu"
int main() {
    blockDim.x=1;
    unsigned int pixels[17]={};pixels[16]=0xdeadbeef;
    unsigned int dxt1[]={0x001ff800,0xe4e4e4e4}; // red,blue,2/3red,2/3blue
    decode_dxt(dxt1,pixels,4,4,1,0,0);
    assert(pixels[0]==0xff0000ff && pixels[1]==0xffff0000);
    assert(pixels[2]==0xff5500aa && pixels[3]==0xffaa0055 && pixels[16]==0xdeadbeef);
    unsigned int transparent[]={0xffff0000,0xffffffff};
    decode_dxt(transparent,pixels,4,4,1,0,0);assert(pixels[0]==0);
    decode_dxt(transparent,pixels,4,4,2,0,0);assert(pixels[0]==0xff000000);
    unsigned int dxt3[]={0x76543210,0xfedcba98,0x001ff800,0};
    decode_dxt(dxt3,pixels,4,4,3,0,0);
    for(unsigned int p=0;p<16;p++)assert(pixels[p]>>24==p*17);
    for (unsigned int reverse=0;reverse<2;reverse++) {
        unsigned int a0=reverse?10:240,a1=reverse?240:10;
        std::uint64_t bits=0;
        for(unsigned int p=0;p<16;p++)bits|=std::uint64_t(p%8)<<(p*3);
        unsigned int dxt5[]={a0|(a1<<8)|(unsigned(bits)<<16),unsigned(bits>>16),0x001ff800,0};
        decode_dxt(dxt5,pixels,4,4,5,0,0);
        const unsigned int high[]={240,10,207,174,141,108,75,42};
        const unsigned int low[]={10,240,56,102,148,194,0,255};
        for(unsigned int p=0;p<16;p++)assert(pixels[p]>>24==(reverse?low[p%8]:high[p%8]));
    }
    // Partial blocks must not write outside a non-multiple-of-four image.
    pixels[6]=0xdeadbeef;decode_dxt(dxt1,pixels,3,2,1,0,0);assert(pixels[6]==0xdeadbeef);
    unsigned int linear[65]={};linear[64]=0xdeadbeef;
    decode_dxt(dxt1,linear,4,4,1u|65536u|(4u<<8u),0,0);
    assert(__uint_as_float(linear[0])==1.f && __uint_as_float(linear[1])==0.f);
    assert(__uint_as_float(linear[3])==1.f);
    const float encoded=170.f/255.f;
    const float expected=std::pow((encoded+.055f)/1.055f,2.4f);
    assert(std::fabs(__uint_as_float(linear[8])-expected)<1e-6f);
    assert(linear[64]==0xdeadbeef);
    std::puts("WebCuda DXT: color palettes, DXT1 transparency, DXT3 alpha, both DXT5 alpha palettes and partial blocks passed");
}
