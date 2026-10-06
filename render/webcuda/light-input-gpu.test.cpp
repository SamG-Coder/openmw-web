#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <cuda_runtime.h>
#include "camera.cu"
static void checked(cudaError_t code){if(code!=cudaSuccess){std::fprintf(stderr,"CUDA: %s\n",cudaGetErrorString(code));std::abort();}}
static float floating(unsigned int word){float result;std::memcpy(&result,&word,4);return result;}
int main(int argc,char** argv) {
    assert(argc==2);auto* file=std::fopen(argv[1],"rb");assert(file);
    unsigned int header[2];assert(std::fread(header,4,2,file)==2&&header[0]==0x4c495431u);
    std::size_t checkedWords=0,changedWords=0;
    for(unsigned int fixture=0;fixture<header[1];fixture++) {
        unsigned int sizes[2];assert(std::fread(sizes,4,2,file)==2);
        unsigned int *materials,*actual,*status;
        checked(cudaMallocManaged(&materials,sizes[0]*12*4));checked(cudaMallocManaged(&actual,(sizes[1]+2)*4));checked(cudaMallocManaged(&status,8));
        std::vector<unsigned int> source(sizes[1]),expected(sizes[1]),tolerant(sizes[1]);
        assert(std::fread(materials,4,sizes[0]*12,file)==sizes[0]*12);
        for(auto* buffer:{&source,&expected,&tolerant})assert(std::fread(buffer->data(),4,sizes[1],file)==sizes[1]);
        std::copy(source.begin(),source.end(),actual);actual[sizes[1]]=actual[sizes[1]+1]=0x12345678;status[0]=0;status[1]=0xabcdef01;
        // Replaying a prepared atlas is also safe: the raw marker is consumed once.
        for(unsigned int repeat=0;repeat<2;repeat++) {
            resolve_camera<<<(sizes[0]+63)/64,64>>>(actual,materials,status,sizes[0],0);
            checked(cudaGetLastError());checked(cudaDeviceSynchronize());
            assert(!status[0]&&status[1]==0xabcdef01&&actual[sizes[1]]==0x12345678&&actual[sizes[1]+1]==0x12345678);
            for(unsigned int word=0;word<sizes[1];word++) {
                if(!tolerant[word])assert(actual[word]==expected[word]);
                else {
                    const float value=floating(actual[word]),reference=floating(expected[word]);
                    const float tolerance=0.00001f+std::abs(reference)*0.000003f;
                    if(!std::isfinite(value)||std::abs(value-reference)>tolerance) {
                        std::fprintf(stderr,"fixture %u word %u: %.9g != %.9g\n",fixture,word,value,reference);std::abort();
                    }
                    changedWords+=repeat==0&&source[word]!=expected[word];
                }
                checkedWords++;
            }
        }
        checked(cudaFree(materials));checked(cudaFree(actual));checked(cudaFree(status));
    }
    assert(std::fgetc(file)==EOF);std::fclose(file);
    std::printf("Light input CUDA: %u real producer fixtures, %zu words, %zu changed fields, repeat preparation and guards passed\n",header[1],checkedWords,changedWords);
}
