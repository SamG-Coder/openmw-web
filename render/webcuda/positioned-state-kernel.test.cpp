// Execute real engine-captured positioned-state fixtures on the CPU or CUDA.
// The expected matrices were composed independently by OSG in the WASM test.
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <vector>
#ifdef __CUDACC__
#include <cuda_runtime.h>
void cudaCheck(cudaError_t result){if(result!=cudaSuccess)throw std::runtime_error(cudaGetErrorString(result));}
#else
struct Dim {unsigned int x=0,y=0;};
Dim blockIdx,blockDim{64,0},threadIdx,gridDim{3,1};
float __uint_as_float(unsigned int word){float v;std::memcpy(&v,&word,4);return v;}
unsigned int __float_as_uint(float value){unsigned int w;std::memcpy(&w,&value,4);return w;}
#define __device__
#define __global__
#endif
#include "positioned-state.cu"

int main(int argc,char** argv) {
    if(argc!=2)throw std::runtime_error("Pass the WASM-captured positioned-state fixture file");
    std::ifstream stream(argv[1],std::ios::binary|std::ios::ate);if(!stream)throw std::runtime_error("Missing fixture file");
    const auto bytes=stream.tellg();if(bytes<20||bytes%4)throw std::runtime_error("Invalid fixture extent");
    std::vector<std::uint32_t> fixture(static_cast<std::size_t>(bytes)/4);stream.seekg(0);
    stream.read(reinterpret_cast<char*>(fixture.data()),bytes);
    assert(fixture[0]==0x50535431u);
    const auto draws=fixture[1],fixedWords=fixture[2],texgenWords=fixture[3],postWords=fixture[4];
    assert(fixedWords==draws*368&&texgenWords==draws*144&&fixture.size()==5+2*fixedWords+2*texgenWords+postWords);
    const auto* fixed=fixture.data()+5;const auto* texgen=fixed+fixedWords;const auto* post=texgen+texgenWords;
    const auto* expectedFixed=post+postWords;const auto* expectedTexgen=expectedFixed+fixedWords;
    constexpr unsigned int guard=0xa123bc45u;
    std::vector<std::uint32_t> actualFixed(fixedWords+2,guard),actualTexgen(texgenWords+2,guard);
    std::copy_n(fixed,fixedWords,actualFixed.data()+1);std::copy_n(texgen,texgenWords,actualTexgen.data()+1);
#ifdef __CUDACC__
    unsigned int *gpuFixed,*gpuTexgen,*gpuPost;
    cudaCheck(cudaMalloc(reinterpret_cast<void**>(&gpuFixed),actualFixed.size()*4));
    cudaCheck(cudaMalloc(reinterpret_cast<void**>(&gpuTexgen),actualTexgen.size()*4));
    cudaCheck(cudaMalloc(reinterpret_cast<void**>(&gpuPost),postWords*4));
    cudaCheck(cudaMemcpy(gpuFixed,actualFixed.data(),actualFixed.size()*4,cudaMemcpyHostToDevice));
    cudaCheck(cudaMemcpy(gpuTexgen,actualTexgen.data(),actualTexgen.size()*4,cudaMemcpyHostToDevice));
    cudaCheck(cudaMemcpy(gpuPost,post,postWords*4,cudaMemcpyHostToDevice));
    prepare_fixed_matrices<<<dim3(3,(draws*8+191)/192),64>>>(gpuFixed+1,gpuPost,draws);
    prepare_texgen_matrices<<<dim3(3,(draws*4+191)/192),64>>>(gpuTexgen+1,gpuPost,draws);
    cudaCheck(cudaGetLastError());cudaCheck(cudaDeviceSynchronize());
    cudaCheck(cudaMemcpy(actualFixed.data(),gpuFixed,actualFixed.size()*4,cudaMemcpyDeviceToHost));
    cudaCheck(cudaMemcpy(actualTexgen.data(),gpuTexgen,actualTexgen.size()*4,cudaMemcpyDeviceToHost));
    cudaCheck(cudaFree(gpuFixed));cudaCheck(cudaFree(gpuTexgen));cudaCheck(cudaFree(gpuPost));
#else
    for(unsigned int kind=0;kind<2;kind++) {
        gridDim.y=(draws*(kind?4:8)+191)/192;
        for(blockIdx.y=0;blockIdx.y<gridDim.y;blockIdx.y++)for(blockIdx.x=0;blockIdx.x<3;blockIdx.x++)
            for(threadIdx.x=0;threadIdx.x<64;threadIdx.x++) {
                if(kind)prepare_texgen_matrices(actualTexgen.data()+1,post,draws);
                else prepare_fixed_matrices(actualFixed.data()+1,post,draws);
            }
    }
#endif
    float worst=0;
    for(unsigned int kind=0;kind<2;kind++) {
        const auto& actual=kind?actualTexgen:actualFixed;
        const auto* expected=kind?expectedTexgen:expectedFixed;
        assert(actual.front()==guard&&actual.back()==guard);
        const unsigned int stride=kind?36:368,first=kind?20:72,count=kind?1:8,step=kind?0:40;
        for(std::size_t i=0;i<actual.size()-2;i++)if(actual[i+1]!=expected[i]) {
            bool matrix=false;for(unsigned int k=0;k<count;k++)matrix|=i%stride>=first+k*step&&i%stride<first+k*step+16;
            assert(matrix);
            float a,e;std::memcpy(&a,&actual[i+1],4);std::memcpy(&e,&expected[i],4);
            const float error=std::fabs(a-e)/std::max(1.f,std::fabs(e));worst=std::max(worst,error);
            if(!std::isfinite(a)||error>2e-5f)throw std::runtime_error("Positioned matrix differs from OSG reference");
        }
    }
    std::printf("Positioned matrices: %u engine-captured draws, 2D dispatch, untouched fields and guards passed; max normalized error %.9g\n",draws,worst);
}
