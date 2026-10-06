#include <cassert>
#include <cmath>
#include <cstring>
#include <cstdio>
#include <initializer_list>
#define __global__
struct Dim { unsigned int x=0,y=0; } blockIdx,blockDim,threadIdx,gridDim;
float __uint_as_float(unsigned int n){float f;std::memcpy(&f,&n,4);return f;}
unsigned int __float_as_uint(float f){unsigned int n;std::memcpy(&n,&f,4);return n;}
#include "screen-primitives.cu"
#include "particles.cu"
int main() {
    blockDim.x=1;
    for(bool zero:{false,true})for(bool clamp:{false,true})for(float z:{-.25f,0.f,.5f,1.25f}) {
        const bool visible=clamp||(z<=1.f&&z>=(zero?0.f:-1.f));
        for(unsigned int point:{0u,1u}) {
            float vertices[60]={},attributes[6*46]={},lighting[96]={};unsigned int origins[18]={};
            vertices[0]=-.25f;vertices[2]=z;vertices[3]=1;
            vertices[10]=.25f;vertices[12]=z;vertices[13]=1;
            unsigned int record[]={0,1,2,point,__float_as_uint(2.f),0,__float_as_uint(64.f),0,__float_as_uint(1.f),0,0,
                (zero?512u:0u)|(clamp?32u:0u)};
            expand_screen_primitives(vertices,attributes,record,origins,lighting,1,64,64,0,0,1,6*34);
            for(unsigned int v=2;v<6;v++)assert((vertices[v*10+3]>0)==visible);
        }
        for(float mode:{5.f,6.f,7.f,8.f}) {
            float source[10]={-.25f,0,z,1},vertices[10]={-.25f,0,z,1},attributes[34]={},varyings[80]={};
            float matrices[32]={},lighting[16]={},endpoints[32]={};unsigned int ids[]={0};
            for(unsigned int m=0;m<2;m++)for(unsigned int k=0;k<4;k++)matrices[m*16+k*5]=1;
            attributes[0]=mode;attributes[1]=-1;attributes[2]=1;attributes[10]=.5f;attributes[15]=2;
            attributes[19]=64;attributes[25]=(zero?16.f:0.f)+(clamp?1.f:0.f);
            project_particles(source,attributes,matrices,ids,vertices,varyings,lighting,endpoints,1,64,64,0,0,0,34,1);
            assert((vertices[3]>0)==visible);
        }
    }
    // A crossing line must move its first endpoint to z=0, not just survive.
    {
        float vertices[60]={},attributes[6*46]={},lighting[96]={};unsigned int origins[18]={};
        vertices[0]=-.25f;vertices[2]=-.25f;vertices[3]=1;
        vertices[10]=.25f;vertices[12]=.25f;vertices[13]=1;
        unsigned int record[]={0,1,2,0,__float_as_uint(2.f),0,__float_as_uint(64.f),0,__float_as_uint(1.f),0,0,512u};
        expand_screen_primitives(vertices,attributes,record,origins,lighting,1,64,64,1,0,1,6*34);
        assert(vertices[23]==1 && std::fabs(vertices[22])<1e-6f);
        assert(std::fabs(__uint_as_float(origins[2*3+2])-.5f)<1e-6f);
        assert(std::fabs(vertices[42]-.25f)<1e-6f);
    }
    for(float mode:{6.f,7.f}) {
        float source[10]={-.25f,0,-.25f,1},vertices[10]={},attributes[34]={},varyings[80]={};
        float matrices[32]={},lighting[16]={},endpoints[32]={};unsigned int ids[]={0};
        for(unsigned int m=0;m<2;m++)for(unsigned int k=0;k<4;k++)matrices[m*16+k*5]=1;
        attributes[0]=mode;attributes[1]=-1;attributes[2]=1;
        attributes[10]=.5f;attributes[12]=.5f;attributes[15]=2;attributes[25]=16;
        project_particles(source,attributes,matrices,ids,vertices,varyings,lighting,endpoints,1,64,64,0,0,0,34,1);
        assert(vertices[3]==1 && std::fabs(vertices[2])<1e-6f);
        assert(std::fabs(varyings[34+4+2])<1e-6f);
        assert(std::fabs(varyings[34+8+2]-.25f)<1e-6f);
    }
    std::puts("CUDA point, line and projected particle clipping: depth conventions, crossing endpoints and depth clamp passed");
}
