// Replay the real WASM/OSG producer fixtures against the production CUDA kernel.
// nvcc -x cu executes on the GPU; ordinary C++ executes the same kernel body.
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#ifdef __CUDACC__
#include <cuda_runtime.h>
static void checked(cudaError_t result) {
    if(result!=cudaSuccess){std::fprintf(stderr,"CUDA: %s\n",cudaGetErrorString(result));std::abort();}
}
#else
#define __global__
#define __device__
struct Dim {unsigned int x=0,y=0;} blockIdx,threadIdx,blockDim{1,0},gridDim{1,0};
#endif
#include "vertex-input.cu"
template<class T> struct Buffer {
    T* data;std::size_t size;
    explicit Buffer(std::size_t n):size(n) {
#ifdef __CUDACC__
        checked(cudaMallocManaged(&data,std::max(std::size_t(1),n)*4));
#else
        data=new T[std::max(std::size_t(1),n)];
#endif
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
int main(int argc,char** argv) {
    assert(argc==2);auto* file=std::fopen(argv[1],"rb");assert(file);
    unsigned int header[2];assert(std::fread(header,4,2,file)==2&&header[0]==0x56494e31u&&header[1]>0);
    std::size_t verticesChecked=0;
    for(unsigned int fixture=0;fixture<header[1];fixture++) {
        unsigned int sizes[6];assert(std::fread(sizes,4,6,file)==6);
        Buffer<unsigned int> layouts(sizes[0]),ids(sizes[2]);Buffer<float> inputs(sizes[1]);
        layouts.read(file);inputs.read(file);ids.read(file);
        std::vector<float> expected[3];
        for(unsigned int k=0;k<3;k++){expected[k].resize(sizes[k+3]);assert(std::fread(expected[k].data(),4,sizes[k+3],file)==sizes[k+3]);}
        assert(sizes[3]==sizes[2]*10&&sizes[4]==sizes[2]*34&&sizes[5]==sizes[2]*3);
        Buffer<float> vertices(sizes[3]+4),attributes(sizes[4]+4),secondary(sizes[5]+4);
        for(auto* buffer:{&vertices,&attributes,&secondary})std::fill_n(buffer->data,buffer->size,12345.f);
#ifdef __CUDACC__
        unpack_vertex_inputs<<<std::max(1u,(sizes[2]+63)/64),64>>>(inputs.data,layouts.data,ids.data,vertices.data,attributes.data,secondary.data,sizes[2]);
        checked(cudaGetLastError());checked(cudaDeviceSynchronize());
#else
        for(blockIdx.x=0;blockIdx.x<sizes[2]+1;blockIdx.x++)
            unpack_vertex_inputs(inputs.data,layouts.data,ids.data,vertices.data,attributes.data,secondary.data,sizes[2]);
#endif
        Buffer<float>* outputs[]={&vertices,&attributes,&secondary};
        for(unsigned int k=0;k<3;k++) {
            for(std::size_t word=0;word<expected[k].size();word++)if(std::memcmp(outputs[k]->data+word,expected[k].data()+word,4)) {
                std::fprintf(stderr,"Fixture %u output %u word %zu: %.9g != %.9g\n",fixture,k,word,outputs[k]->data[word],expected[k][word]);
                std::abort();
            }
            for(auto i=expected[k].size();i<outputs[k]->size;i++)assert(outputs[k]->data[i]==12345.f);
        }
        verticesChecked+=sizes[2];
    }
    assert(std::fgetc(file)==EOF);std::fclose(file);
    std::printf("Vertex inputs: %u real producer fixtures, %zu vertices, exact position/color/attribute/secondary fields and guards passed\n",header[1],verticesChecked);
}
