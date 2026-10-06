#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#include <algorithm>
#define __global__
#define __device__
struct Dim {unsigned int x=0,y=0;} blockIdx,blockDim,threadIdx,gridDim;
float __uint_as_float(unsigned int b){float v;std::memcpy(&v,&b,4);return v;}
unsigned int __float_as_uint(float v){unsigned int b;std::memcpy(&b,&v,4);return b;}
unsigned int atomicAdd(unsigned int* p,unsigned int v){auto old=*p;*p+=v;return old;}
#include "material.cu"
// Frozen pre-consolidation branch structure checks sampler selection and blend order.
__device__ float reference_sample_mipped(const unsigned int* texels,unsigned int base,unsigned int width,unsigned int height,
    float u,float v,float lod,unsigned int sampler,unsigned int channel) {
    if((sampler&268435456u)!=0u) {
        unsigned int selected=(sampler>>(16u+channel*3u))&7u;
        if(selected>=4u)return selected==5u?1.0f:0.0f;
        channel=selected;
    }

    if((sampler&536870912u)!=0u) {
        float minimum=__uint_as_float(texels[base+6u]),maximum=__uint_as_float(texels[base+7u]);
        float bias=fminf(16.0f,fmaxf(-16.0f,__uint_as_float(texels[base+8u])));
        lod=fminf(maximum,fmaxf(minimum,lod+bias));
    }
    unsigned int filter=(sampler>>5)&7,last=sampler&31;
    unsigned int magnification=(sampler>>8)&1;
    float crossover=magnification!=0u&&(filter==2u||filter==4u)?0.5f:0.0f;
    if(lod<=crossover)return mip_sample(texels,base,width,height,u,v,sampler,channel,0,magnification);
    if(filter<2)return mip_sample(texels,base,width,height,u,v,sampler,channel,0,filter);
    lod=fminf((float)last,fmaxf(0.0f,lod));
    unsigned int linear=filter&1;
    if(filter<4)return mip_sample(texels,base,width,height,u,v,sampler,channel,(unsigned int)floorf(lod+0.5f),linear);
    unsigned int low=(unsigned int)floorf(lod),high=low<last?low+1:low;
    float fraction=lod-(float)low;
    return mip_sample(texels,base,width,height,u,v,sampler,channel,low,linear)*(1.0f-fraction)
        +mip_sample(texels,base,width,height,u,v,sampler,channel,high,linear)*fraction;
}

int main(){
 std::mt19937 rng(2791);std::uniform_real_distribution<float> coord(-2.f,3.f),lods(-5.f,8.f),values(0.f,1.f);
 unsigned int atlas[512]={};unsigned cases=0;
 for(unsigned floating=0;floating<2;floating++){
  for(unsigned i=10;i<512;i++)atlas[i]=floating?__float_as_uint(values(rng)):rng();
  atlas[0]=10;atlas[1]=__float_as_uint(.2f);atlas[2]=__float_as_uint(.4f);atlas[3]=__float_as_uint(.6f);atlas[4]=__float_as_uint(.8f);
  atlas[5]=3;atlas[6]=__float_as_uint(-2.f);atlas[7]=__float_as_uint(3.f);atlas[8]=__float_as_uint(.375f);atlas[9]=__float_as_uint(8.f);
  for(unsigned filter=0;filter<6;filter++)for(unsigned mag=0;mag<2;mag++)for(unsigned wrap=0;wrap<4;wrap++)for(unsigned i=0;i<250;i++){
   unsigned sampler=3|(filter<<5)|(mag<<8)|(wrap<<9)|(wrap<<11)|(floating?32768:0);
   unsigned described=i%2,base=described?0:10;if(described)sampler|=536870912u;
   float u=coord(rng),v=coord(rng),lod=lods(rng);unsigned channel=i%4;
   float expected=reference_sample_mipped(atlas,base,8,8,u,v,lod,sampler,channel);
   float actual=sample_mipped(atlas,base,8,8,u,v,lod,sampler,channel);
   assert(__float_as_uint(expected)==__float_as_uint(actual));cases++;
  }
 }
 std::printf("Mip sampler: %u exact comparisons across filters, magnification, wrap, descriptors and storage passed\n",cases);
}
