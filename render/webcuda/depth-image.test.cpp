#include <cassert>
#include <cmath>
#include <cstring>
#include <cstdio>
#define __global__
#define __device__
struct Dim{unsigned x=0,y=0;}blockIdx,blockDim,threadIdx,gridDim;
float __uint_as_float(unsigned b){float v;std::memcpy(&v,&b,4);return v;}
unsigned __float_as_uint(float v){unsigned b;std::memcpy(&b,&v,4);return b;}
#include "float-image.cu"
int main(){
 blockDim.x=1;gridDim.x=4;
 unsigned input[]={0x7f800000u,__float_as_uint(.25f),__float_as_uint(-1.f),__float_as_uint(2.f)};
 unsigned output[6]={123,0,0,0,0,456};
 for(blockIdx.x=0;blockIdx.x<4;blockIdx.x++)decode_float_image(input,output,4,1,65536u|(9u<<8)|9u,0,1);
 for(unsigned i=0;i<4;i++)assert(output[i+1]==input[i]);
 assert(output[0]==123 && output[5]==456);
 for(blockIdx.x=0;blockIdx.x<4;blockIdx.x++)decode_float_image(input,output,4,1,65536u|(9u<<8)|(1u<<12)|9u,0,1);
 assert(__uint_as_float(output[1])==1.f && __uint_as_float(output[3])==0.f && __uint_as_float(output[4])==1.f);
 assert(std::fabs(__uint_as_float(output[2])-16384.f/65535.f)<1e-7f);
 assert(output[0]==123 && output[5]==456);
 std::puts("Depth image CUDA: scalar addressing, floating infinity, normalized depth16 and buffer guards passed");
}
