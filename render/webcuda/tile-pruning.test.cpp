// Compile as ordinary C++ for a CPU reference, or with nvcc -x cu for real
// CUDA execution. Both compare optimized tile lists with all-triangle lists
// through the unchanged production material rasterizer.
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>

#ifdef __CUDACC__
#include <cuda_runtime.h>
static void checked(cudaError_t result) {
    if(result!=cudaSuccess){std::fprintf(stderr,"CUDA: %s\n",cudaGetErrorString(result));std::abort();}
}
static void sync(){checked(cudaDeviceSynchronize());}
#define RUN(kernel,count,...) do {kernel<<<((count)+63u)/64u,64>>>(__VA_ARGS__);checked(cudaGetLastError());} while(false)
#else
float __uint_as_float(unsigned int bits){float value;std::memcpy(&value,&bits,4);return value;}
unsigned int __float_as_uint(float value){unsigned int bits;std::memcpy(&bits,&value,4);return bits;}
unsigned int atomicAdd(unsigned int* p,unsigned int value){auto old=*p;*p+=value;return old;}
unsigned int atomicMax(unsigned int* p,unsigned int value){auto old=*p;*p=std::max(*p,value);return old;}
#define __global__
#define __device__
struct Dim {unsigned int x=0,y=0;} blockIdx,blockDim,threadIdx,gridDim;
static void sync(){}
#define RUN(kernel,count,...) do {for(blockIdx.x=0;blockIdx.x<(count);blockIdx.x++)kernel(__VA_ARGS__);} while(false)
#endif

#include "material.cu"
#include "raster-reference.cuh"
#include "tiles.cu"

template<class T> struct Buffer {
    T* data;size_t size;
    explicit Buffer(size_t count):size(count) {
#ifdef __CUDACC__
        checked(cudaMallocManaged(&data,count*sizeof(T)));
#else
        data=new T[count];
#endif
        std::fill_n(data,count,T{});
    }
    ~Buffer(){
#ifdef __CUDACC__
        checked(cudaFree(data));
#else
        delete[] data;
#endif
    }
    T& operator[](size_t index){assert(index<size);return data[index];}
};

int main() {
#ifndef __CUDACC__
    blockDim.x=1;gridDim.x=1;
#endif
    constexpr unsigned W=35,H=19,N=12,V=N*3,T=((W+15)/16)*((H+15)/16);
    constexpr unsigned Boundary=V*34,Point=Boundary+V,Raster=Point+V*12,MaxWords=T+1+T*N;
    Buffer<float> vertices(V*10),attributes(Raster+N*50),actual(W*H*10*16),expected(actual.size);
    Buffer<unsigned> triangles(N*4),materials(N*12),texels(1),counts(T+1+N),referenceCounts(counts.size);
    Buffer<unsigned> compact(MaxWords+1),reference(T*N),offsets(T+1),summary(2),blocks(1);
    std::mt19937 random(419);std::uniform_real_distribution<float> position(-1.4f,1.4f),unit(0.f,1.f);
    for(unsigned t=0;t<N;t++)for(unsigned c=0;c<3;c++) {
        unsigned v=t*3+c;float w=.5f+unit(random)*2;
        vertices[v*10]=position(random)*w;vertices[v*10+1]=position(random)*w;
        vertices[v*10+2]=(.8f-1.6f*float(t)/N)*w;vertices[v*10+3]=w;
        for(unsigned k=0;k<3;k++)vertices[v*10+4+k]=.2f+unit(random)*.7f;
        vertices[v*10+7]=.5f;attributes[Point+v*12]=1;attributes[Boundary+v]=1;
        triangles[t*4+c]=v;
    }
    // Two complete screen triangles ensure the oracle includes visible pixels
    // at tile boundaries, including the partial right and bottom tiles.
    const float quad[12]={-1,1,1,1,1,-1,-1,1,1,-1,-1,-1};
    for(unsigned v=0;v<6;v++){vertices[v*10]=quad[v*2];vertices[v*10+1]=quad[v*2+1];vertices[v*10+3]=1;}
    for(unsigned t=0;t<N;t++) {
        triangles[t*4+3]=t;
        unsigned r=Raster+t*50;
        attributes[r+3]=1;attributes[r+37]=2.25f;attributes[r+38]=4.5f;
        attributes[r+44]=64;attributes[r+45]=1.5f;attributes[r+46]=1;
        for(unsigned face:{8u,15u}){attributes[r+face]=7;attributes[r+face+1]=float(t+1);
            attributes[r+face+2]=255;attributes[r+face+3]=255;attributes[r+face+6]=2;}
    }
    for(unsigned tile=0;tile<T;tile++)for(unsigned t=0;t<N;t++)reference[tile*N+t]=t;
    const unsigned scissors[][4]={{0,0,W,H},{16,16,1,1},{15,15,2,2},{32,16,3,3},
        {0,H-1,W,1},{W-1,0,1,H},{1,1,0xffffffffu,0xffffffffu},
        {W,0,1,H},{0xffffffffu,0,4,H},{0,H+1,W,1},{0,0,0,H},{0,0,W,0}};
    unsigned cases=0,visibleCases=0;
    for(unsigned samples:{1u,2u,4u,8u,16u})for(unsigned mode=0;mode<3;mode++)
    for(const auto& scissor:scissors)for(unsigned state=0;state<8;state++) {
        for(unsigned t=0;t<N;t++) {
            unsigned m=t*12,r=Raster+t*50;
            materials[m+3]=2u|4u|8u|256u|8192u|(state==6?0u:128u);
            std::copy_n(scissor,4,materials.data+m+5);
            unsigned cull=state==5||state==6?3u:t%3;
            materials[m+9]=1u|(7u<<4)|(cull<<14)|((t%2)<<16)|(mode<<27)|((t%2?0u:mode)<<29);
            materials[m+10]=0x5454;
            attributes[r+24]=state==2||state==4?0.f:state==7?.4f:1.f;
            attributes[r+25]=state==3?1.f:0.f;
            attributes[r+26]=float(state==1||state==4?0u:state==7?0xaaaau:65535u);
            attributes[r+27]=state==4?0.f:1.f;
            attributes[r+49]=float(t%3==0?129u:t%3==1?66u:0u);
        }
        std::fill_n(counts.data,counts.size,0u);std::fill_n(referenceCounts.data,referenceCounts.size,0u);
        for(unsigned tile=0;tile<T;tile++)referenceCounts[tile]=N;
        std::fill_n(compact.data,compact.size,0xdeadbeefu);
        summary[0]=summary[1]=0;
        RUN(bin_triangle_bounds,N,vertices.data,triangles.data,counts.data,compact.data,offsets.data,summary.data,materials.data,attributes.data,W,H,N,0,0,Raster,samples);
        RUN(prefix_tile_blocks,1,counts.data,offsets.data,blocks.data,T,MaxWords);
        RUN(prefix_tile_block_totals,1,counts.data,blocks.data,summary.data,T,MaxWords);
        RUN(finish_tile_prefix,T+1,offsets.data,blocks.data,summary.data,T);
        RUN(copy_tile_offsets,T+1,offsets.data,compact.data,T);
        RUN(clear_tile_counts,T,counts.data,T);
        RUN(bin_triangle_bounds,N,vertices.data,triangles.data,counts.data,compact.data,offsets.data,summary.data,materials.data,attributes.data,W,H,N,0,1,Raster,samples);
        RUN(sort_tile_candidates,T,counts.data,compact.data,T,0);
        RUN(clear_attachment,W*H*samples,actual.data,W*H,17664,0,0,0,1,1,1,4,2,4,2,24,1,0,15,W,H,0,0,W,H,samples);
        RUN(clear_attachment,W*H*samples,expected.data,W*H,17664,0,0,0,1,1,1,4,2,4,2,24,1,0,15,W,H,0,0,W,H,samples);
        RUN(raster_material,W*H*samples,vertices.data,triangles.data,counts.data,compact.data,materials.data,texels.data,actual.data,attributes.data,W,H,0,Raster,Boundary,Point,0,0,0,0,0,1,4,2,4,2,24,1,samples);
        RUN(WEBCUDA_REFERENCE_ENTRY,W*H*samples,vertices.data,triangles.data,referenceCounts.data,reference.data,materials.data,texels.data,expected.data,attributes.data,W,H,N,Raster,Boundary,Point,0,0,0,0,0,1,4,2,4,2,24,1,samples);
        sync();assert(summary[1]==0&&summary[0]<=MaxWords);assert(compact[MaxWords]==0xdeadbeefu);
        if(std::memcmp(actual.data,expected.data,W*H*10*samples*sizeof(float))) {
            std::fprintf(stderr,"Mismatch: case %u samples %u mode %u state %u scissor %u %u %u %u\n",cases,samples,mode,state,scissor[0],scissor[1],scissor[2],scissor[3]);
            std::abort();
        }
        bool visible=false;for(unsigned p=0;p<W*H;p++)visible|=expected[p*9]>.0f;
        visibleCases+=visible?1u:0u;cases++;
    }
    assert(visibleCases>100);
    // Old bounding-box-only binning visits all 4096 tiles for each of these
    // two screen triangles. A one-pixel scissor needs only one tile per triangle.
    Buffer<unsigned> largeCounts(4097);
    for(unsigned t=0;t<2;t++){unsigned m=t*12;materials[m+3]=0;materials[m+9]=0;
        materials[m+5]=16;materials[m+6]=16;materials[m+7]=1;materials[m+8]=1;}
    RUN(bin_triangle_bounds,2,vertices.data,triangles.data,largeCounts.data,compact.data,offsets.data,summary.data,materials.data,attributes.data,1024,1024,2,0,0,Raster,1);
    sync();unsigned references=0;for(unsigned tile=0;tile<4096;tile++)references+=largeCounts[tile];
    assert(references==2&&largeCounts[65]==2&&largeCounts[4096]==0);
    std::printf("Tile pruning: %u exact raster comparisons (%u visible), guarded compact lists; scissor references 8192 -> %u\n",cases,visibleCases,references);
#ifdef __CUDACC__
    std::puts("Executed production CUDA kernels on the GPU; browser interop and gameplay were not exercised.");
#else
    std::puts("Executed CPU reference; GPU execution is a separate nvcc build/run.");
#endif
}
