#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <cuda_runtime.h>
#include "cluster-lighting.cu"
static void checked(cudaError_t code){if(code!=cudaSuccess){std::fprintf(stderr,"CUDA: %s\n",cudaGetErrorString(code));std::abort();}}
template<class T> struct Buffer {
    T* data;std::size_t count;
    explicit Buffer(std::size_t n):count(n){checked(cudaMallocManaged(&data,(n+4)*sizeof(T)));std::fill_n(data,n+4,T{});}
    ~Buffer(){checked(cudaFree(data));}
};
static float floating(unsigned int word){float result;std::memcpy(&result,&word,4);return result;}
static void sync(){checked(cudaGetLastError());checked(cudaDeviceSynchronize());}
static void closeFloat(float actual,float expected,unsigned int fixture,std::size_t word) {
    if(!std::isfinite(actual)||std::abs(actual-expected)>0.00001f+std::abs(expected)*0.000003f) {
        std::fprintf(stderr,"cluster fixture %u word %zu: %.9g != %.9g\n",fixture,word,actual,expected);std::abort();
    }
}
int main(int argc,char** argv) {
    assert(argc==2);auto* file=std::fopen(argv[1],"rb");assert(file);
    unsigned int header[2];assert(std::fread(header,4,2,file)==2&&header[0]==0x434c4131u);
    std::size_t words=0,gridWords=0,overflowRuns=0,orthographicBounds=0;
    for(unsigned int fixture=0;fixture<header[1];fixture++) {
        unsigned int sizes[7];assert(std::fread(sizes,4,7,file)==7);
        std::vector<std::vector<unsigned int>> packet(7);
        for(unsigned int i=0;i<7;i++){packet[i].resize(sizes[i]);assert(std::fread(packet[i].data(),4,sizes[i],file)==sizes[i]);}
        Buffer<float> actual(sizes[5]),reference(sizes[5]),projection(sizes[6]);
        std::memcpy(actual.data,packet[5].data(),sizes[5]*4);std::memcpy(projection.data,packet[6].data(),sizes[6]*4);
        assert(std::fread(reference.data,4,sizes[5],file)==sizes[5]);
        for(auto* buffer:{&actual,&reference})std::fill_n(buffer->data+sizes[5],4,12345.f);
        const auto& record=packet[3];assert(record.size()==10&&record[0]==0);
        const unsigned int count=record[1],p=(record[7]&0x7fffffffu)*16,clusters=record[2]*record[3]*record[4];
        if((record[7]&0x80000000u)&&count) {prepare_cluster_lights<<<(count+63)/64,64>>>(actual.data,projection.data+p+16,count);sync();}
        for(std::size_t i=0;i<sizes[5]+4;i++) {
            const unsigned int component=i%20;
            if(i<sizes[5]&&(component<8||(component>=12&&component<16)||component==19))closeFloat(actual.data[i],reference.data[i],fixture,i);
            else assert(std::memcmp(actual.data+i,reference.data+i,4)==0);
            words++;
        }
        Buffer<float> bounds(clusters*8);
        build_light_clusters<<<(clusters+63)/64,64>>>(projection.data+p,bounds.data,record[2],record[3],record[4],floating(record[5]),floating(record[6]));sync();
        if(projection.data[p+15]>.5f) {
            // Forward-project both corners back to their grid boundaries.
            // Perspective widening of an orthographic box fails this check.
            for(unsigned int tile=0;tile<clusters;tile++)for(unsigned int side=0;side<2;side++) {
                for(unsigned int axis=0;axis<2;axis++) {
                    const unsigned int cell=axis?tile/record[2]%record[3]:tile%record[2];
                    const float ndc=bounds.data[tile*8+side*4+axis]*projection.data[p+axis*5]+projection.data[p+12+axis];
                    closeFloat(ndc,2.f*(cell+side)/record[2+axis]-1.f,fixture,tile*8+side*4+axis);
                    orthographicBounds++;
                }
                assert(bounds.data[tile*8+side*4+3]==0.f);
            }
        }
        Buffer<unsigned int> grid(clusters*2),refGrid(clusters*2),indices(clusters*std::max(1u,count)),refIndices(indices.count),overflow(clusters),refOverflow(clusters);
        unsigned int capacity=std::max(1u,std::min(count,64u));
        for(;;) {
            for(auto* buffer:{&grid,&refGrid,&indices,&refIndices,&overflow,&refOverflow})std::fill_n(buffer->data,buffer->count+4,0x12345678u);
            cull_cluster_lights<<<(clusters+63)/64,64>>>(bounds.data,actual.data,grid.data,indices.data,overflow.data,clusters,count,capacity);
            cull_cluster_lights<<<(clusters+63)/64,64>>>(bounds.data,reference.data,refGrid.data,refIndices.data,refOverflow.data,clusters,count,capacity);sync();
            for(const auto& pair:{std::pair{&grid,&refGrid},{&indices,&refIndices},{&overflow,&refOverflow}})
                for(std::size_t i=0;i<pair.first->count+4;i++){assert(pair.first->data[i]==pair.second->data[i]);gridWords++;}
            for(auto* buffer:{&grid,&indices,&overflow})for(std::size_t i=buffer->count;i<buffer->count+4;i++)assert(buffer->data[i]==0x12345678u);
            unsigned int required=0;for(unsigned int i=0;i<clusters;i++)required=std::max(required,overflow.data[i]);
            if(!required)break;assert(required>capacity&&required<=count);capacity=required;overflowRuns++;
        }
        Buffer<unsigned int> packed(count*16),refPacked(count*16);
        for(auto* buffer:{&packed,&refPacked})std::fill_n(buffer->data,buffer->count+4,0x12345678u);
        if(count) {
            pack_cluster_lights<<<(count+63)/64,64>>>(actual.data,packed.data,count,0);
            pack_cluster_lights<<<(count+63)/64,64>>>(reference.data,refPacked.data,count,0);sync();
        }
        for(unsigned int i=0;i<count*16;i++){closeFloat(floating(packed.data[i]),floating(refPacked.data[i]),fixture,i);words++;}
        for(unsigned int i=count*16;i<count*16+4;i++)assert(packed.data[i]==0x12345678u&&refPacked.data[i]==0x12345678u);
    }
    assert(std::fgetc(file)==EOF&&overflowRuns);std::fclose(file);
    std::printf("Cluster light CUDA: %u producer fixtures, %zu prepared/packed words, %zu exact culling/list words, %zu overflow retries, %zu orthographic boundary checks and guards passed\n",header[1],words,gridWords,overflowRuns,orthographicBounds);
}
