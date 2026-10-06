// Replay real OSG packets against authored CUDA. Compare raw-state rendering
// and pruned bins with independently canonicalized state and exhaustive bins.
// Build with nvcc -x cu for GPU execution, or ordinary C++ for a CPU reference.
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#ifdef __CUDACC__
#include <cuda_runtime.h>
static void checked(cudaError_t error) {
    if(error!=cudaSuccess){std::fprintf(stderr,"CUDA: %s\n",cudaGetErrorString(error));std::abort();}
}
static void sync(){checked(cudaDeviceSynchronize());}
#define RUN(kernel,count,...) do {kernel<<<((count)+63u)/64u,64>>>(__VA_ARGS__);checked(cudaGetLastError());} while(false)
#else
float __uint_as_float(unsigned int value){float result;std::memcpy(&result,&value,4);return result;}
unsigned int __float_as_uint(float value){unsigned int result;std::memcpy(&result,&value,4);return result;}
unsigned int atomicAdd(unsigned int* p,unsigned int value){auto old=*p;*p+=value;return old;}
unsigned int atomicMax(unsigned int* p,unsigned int value){auto old=*p;*p=std::max(*p,value);return old;}
#define __global__
#define __device__
struct Dim {unsigned int x=0,y=0;} blockIdx,threadIdx,blockDim{1,0},gridDim{1,0};
static void sync(){}
#define RUN(kernel,count,...) do {for(blockIdx.x=0;blockIdx.x<(count);blockIdx.x++)kernel(__VA_ARGS__);} while(false)
#endif
#include "material.cu"
#include "tiles.cu"

template<class T> struct Buffer {
    T* data;std::size_t size;
    explicit Buffer(std::size_t count):size(count) {
#ifdef __CUDACC__
        checked(cudaMallocManaged(&data,std::max(std::size_t(1),count)*sizeof(T)));
#else
        data=new T[std::max(std::size_t(1),count)];
#endif
        std::fill_n(data,size,T{});
    }
    ~Buffer(){
#ifdef __CUDACC__
        checked(cudaFree(data));
#else
        delete[] data;
#endif
    }
    void read(std::FILE* file){assert(std::fread(data,4,size,file)==size);}
};
float readFloat(unsigned int word){float result;std::memcpy(&result,&word,4);return result;}
unsigned int floatBits(float value){unsigned int result;std::memcpy(&result,&value,4);return result;}
float unit(float value){return std::clamp(value,0.f,1.f);}
void canonicalize(unsigned int* material,float* params,unsigned int* texels) {
    if(material[3]&16777216u) {
        std::int32_t x,y;std::memcpy(&x,material+5,4);std::memcpy(&y,material+6,4);
        const auto x0=std::clamp<std::int64_t>(x,0,35),x1=std::clamp<std::int64_t>(std::int64_t(x)+material[7],0,35);
        const auto y0=std::clamp<std::int64_t>(y,0,19),y1=std::clamp<std::int64_t>(std::int64_t(y)+material[8],0,19);
        material[5]=x0;material[6]=19-y1;material[7]=x1-x0;material[8]=y1-y0;material[3]&=~16777216u;
    }
    if(material[3]&128u)material[4]=floatBits(unit(readFloat(material[4])));
    for(unsigned int field=2;field<8;field++)params[field]=unit(params[field]);
    params[24]=unit(params[24]);
    for(unsigned int field:{9u,16u})params[field]=std::clamp(params[field],0.f,255.f);
    if(material[3]&32768u)for(unsigned int k=0;k<4;k++) {
        const auto offset=floatBits(params[23])+4+k;texels[offset]=floatBits(unit(readFloat(texels[offset])));
    }
    if(material[3]&16384u)for(unsigned int descriptor=material[0];descriptor;descriptor=texels[descriptor+3])
        for(unsigned int k=0;k<4;k++)texels[descriptor+4+k]=floatBits(unit(readFloat(texels[descriptor+4+k])));
}
int main(int argc,char** argv) {
    assert(argc==2);auto* file=std::fopen(argv[1],"rb");assert(file);
    unsigned int header[2];assert(std::fread(header,4,2,file)==2&&header[0]==0x52535431u&&header[1]);
    constexpr unsigned int W=35,H=19,T=6,Boundary=4*34,Point=Boundary+4,Raster=Point+4*12,MaxWords=T+1+T*2;
    Buffer<float> vertices(40),attributes(Raster+50),expectedAttributes(Raster+50);
    Buffer<unsigned int> triangles(8),material(12),expectedMaterial(12),counts(T+2),referenceCounts(T+2);
    Buffer<unsigned int> candidates(MaxWords+1),reference(T*2),offsets(T+1),summary(2),blocks(1);
    const float positions[8]={-1,1,1,1,1,-1,-1,-1};
    for(unsigned int v=0;v<4;v++) {
        vertices.data[v*10]=positions[v*2];vertices.data[v*10+1]=positions[v*2+1];vertices.data[v*10+2]=.25f;vertices.data[v*10+3]=1;
        vertices.data[v*10+4]=.2f;vertices.data[v*10+5]=.4f;vertices.data[v*10+6]=.6f;
        attributes.data[v*34+2]=-1;attributes.data[Boundary+v]=1;attributes.data[Point+v*12]=1;
    }
    for(unsigned int tile=0;tile<T;tile++){referenceCounts.data[tile]=2;reference.data[tile*2]=0;reference.data[tile*2+1]=1;}
    std::size_t checkedSamples=0,changedSamples=0;
    for(unsigned int fixture=0;fixture<header[1];fixture++) {
        unsigned int sizes[3];assert(std::fread(sizes,4,3,file)==3);
        material.read(file);assert(std::fread(attributes.data+Raster,4,50,file)==50);
        Buffer<unsigned int> texels(sizes[0]),expectedTexels(sizes[0]);texels.read(file);
        std::copy_n(material.data,12,expectedMaterial.data);std::copy_n(attributes.data,attributes.size,expectedAttributes.data);
        std::copy_n(texels.data,texels.size,expectedTexels.data);
        canonicalize(expectedMaterial.data,expectedAttributes.data+Raster,expectedTexels.data);
        for(unsigned int v=0;v<4;v++)vertices.data[v*10+7]=readFloat(sizes[2]);
        const unsigned int samples=sizes[1],words=W*H*10*samples;Buffer<float> actual(words+8),expected(words+8);
        for(unsigned int winding=0;winding<2;winding++) {
            const unsigned int indices[8]={0,1,2,0,0,2,3,0};std::copy_n(indices,8,triangles.data);
            if(winding){std::swap(triangles.data[1],triangles.data[2]);std::swap(triangles.data[5],triangles.data[6]);}
            for(auto* buffer:{&actual,&expected}) {
                std::fill_n(buffer->data,buffer->size,12345.f);
                for(unsigned int sample=0;sample<samples;sample++)for(unsigned int pixel=0;pixel<W*H;pixel++) {
                    const float initial[]={.125f,.25f,.375f,1.f,.875f,.1f,.2f,.3f,1.f};
                    std::copy_n(initial,9,buffer->data+4+sample*W*H*10+pixel*9);
                    buffer->data[4+sample*W*H*10+W*H*9+pixel]=127;
                }
            }
            std::fill_n(counts.data,counts.size,0);std::fill_n(candidates.data,candidates.size,0xdeadbeefu);
            summary.data[0]=summary.data[1]=0;
            RUN(bin_triangle_bounds,2,vertices.data,triangles.data,counts.data,candidates.data,offsets.data,summary.data,material.data,attributes.data,W,H,2,0,0,Raster,samples);
            RUN(prefix_tile_blocks,1,counts.data,offsets.data,blocks.data,T,MaxWords);
            RUN(prefix_tile_block_totals,1,counts.data,blocks.data,summary.data,T,MaxWords);
            RUN(finish_tile_prefix,T+1,offsets.data,blocks.data,summary.data,T);
            RUN(copy_tile_offsets,T+1,offsets.data,candidates.data,T);
            RUN(clear_tile_counts,T,counts.data,T);
            RUN(bin_triangle_bounds,2,vertices.data,triangles.data,counts.data,candidates.data,offsets.data,summary.data,material.data,attributes.data,W,H,2,0,1,Raster,samples);
            RUN(sort_tile_candidates,T,counts.data,candidates.data,T,0);
            RUN(raster_material,W*H*samples,vertices.data,triangles.data,counts.data,candidates.data,material.data,texels.data,actual.data+4,attributes.data,W,H,0,Raster,Boundary,Point,0,0,0,0,0,1,4,2,4,2,24,1,samples);
            RUN(raster_material,W*H*samples,vertices.data,triangles.data,referenceCounts.data,reference.data,expectedMaterial.data,expectedTexels.data,expected.data+4,expectedAttributes.data,W,H,2,Raster,Boundary,Point,0,0,0,0,0,1,4,2,4,2,24,1,samples);
            sync();assert(summary.data[1]==0&&summary.data[0]<=MaxWords&&candidates.data[MaxWords]==0xdeadbeefu);
            for(std::size_t word=0;word<actual.size;word++)if(std::memcmp(actual.data+word,expected.data+word,4)) {
                std::fprintf(stderr,"Fixture %u winding %u samples %u word %zu: %.9g != %.9g\n",fixture,winding,samples,word,actual.data[word],expected.data[word]);std::abort();
            }
            for(unsigned int k=0;k<4;k++)assert(actual.data[k]==12345.f&&actual.data[words+4+k]==12345.f);
            for(unsigned int sample=0;sample<samples;sample++)for(unsigned int pixel=0;pixel<W*H;pixel++)
                changedSamples+=actual.data[4+sample*W*H*10+pixel*9]!=.125f;
            checkedSamples+=W*H*samples;
        }
    }
    assert(std::fgetc(file)==EOF&&changedSamples>0);std::fclose(file);
    std::printf("Raw raster state: %u real producer fixtures, both windings, %zu pixel samples (%zu changed), exact color/depth/normal/stencil, clipped bins and guards passed\n",header[1],checkedSamples,changedSamples);
}
