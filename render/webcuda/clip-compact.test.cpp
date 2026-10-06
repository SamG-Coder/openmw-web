// Compare all five production assembly kernels before/after stable clipping
// compaction. Compile with g++ or nvcc -x cu; the latter executes on the GPU.
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#ifdef __CUDACC__
#include <cuda_runtime.h>
static void checked(cudaError_t result) {
    if(result!=cudaSuccess){std::fprintf(stderr,"CUDA: %s\n",cudaGetErrorString(result));std::abort();}
}
static void sync(){checked(cudaDeviceSynchronize());}
#define RUN(kernel,count,...) do {kernel<<<std::max(1u,((count)+63u)/64u),64>>>(__VA_ARGS__);checked(cudaGetLastError());} while(false)
#else
float __uint_as_float(unsigned int bits){float value;std::memcpy(&value,&bits,4);return value;}
#define __global__
#define __device__
struct Dim {unsigned int x=0,y=0;} blockIdx,blockDim,threadIdx,gridDim;
static void sync(){}
#define RUN(kernel,count,...) do {for(blockIdx.x=0;blockIdx.x<(count);blockIdx.x++)kernel(__VA_ARGS__);} while(false)
#endif

#include "clip.cu"
#include "clip-compact.cu"
#include "assemble.cu"
#include "attributes.cu"
#include "vertex-lighting.cu"
#include "unlit-falloff.cu"
#include "fixed-lighting.cu"

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
    T& operator[](size_t i){assert(i<size);return data[i];}
};
struct Layout {
    unsigned lighting,fixed,falloff,boundary,point,words;
    explicit Layout(unsigned slots):lighting(slots*102),fixed(lighting+slots*36),
        falloff(fixed+slots*48),boundary(falloff+slots*12),point(boundary+slots*3),words(point+slots*36){}
};
int main() {
#ifndef __CUDACC__
    blockDim.x=1;gridDim.x=1;
#endif
    constexpr unsigned N=683,V=N*3,S=N*7,B=(S+255)/256,Guard=0x12345678;
    Buffer<float> source(V*10),attributes(V*46),lighting(V*12),fixed(V*16),falloff(V*4),positions(S*12),weights(S*12);
    Buffer<unsigned> triangles(N*4),materials(N*12),edges(N),flat(N),valid(S+4),offsets(S+4),blocks(B+4),summary(5),mapped(S+4);
    for(unsigned i=0;i<V;i++) {
        unsigned t=i/3,c=i%3;
        float x=c==1?.75f:-.75f,y=c==2?.75f:-.75f;
        if(t%4==1)x+=4; // fully rejected
        if(t%4==2)x*=3; // multiple output triangles
        source[i*10]=x;source[i*10+1]=y;source[i*10+2]=.1f;source[i*10+3]=1;
        for(unsigned k=4;k<10;k++)source[i*10+k]=float((i*13+k)%256)/256;
        for(unsigned k=0;k<34;k++)attributes[i*34+k]=float((i*17+k)%128)/128;
        for(unsigned k=0;k<12;k++) {
            attributes[V*34+i*12+k]=float((i*7+k)%32)/32; // point fade and line metadata
            lighting[i*12+k]=float((i*11+k)%64)/64;
        }
        for(unsigned k=0;k<16;k++)fixed[i*16+k]=float((i*5+k)%32)/16;
        for(unsigned k=0;k<4;k++)falloff[i*4+k]=float((i*3+k)%64)/64;
        triangles[t*4+c]=i;
    }
    for(unsigned t=0;t<N;t++) {
        triangles[t*4+3]=t;edges[t]=t%8;
        flat[t]=t%3==0?t*3+2:0xffffffffu;
    }
    RUN(clip_triangles,N,source.data,triangles.data,materials.data,edges.data,positions.data,weights.data,valid.data,N,10,4);
    sync();
    std::vector<unsigned> clipped(valid.data,valid.data+S);
    for(unsigned pattern=0;pattern<4;pattern++) {
        for(unsigned i=0;i<S;i++)valid[i]=pattern==0?clipped[i]:pattern==1?1:pattern==2?0:unsigned(i==0||i==255||i==256||i==S-1);
        std::fill_n(valid.data+S,4,Guard);std::fill_n(offsets.data+S,4,Guard);
        std::fill_n(blocks.data+B,4,Guard);std::fill_n(summary.data,5,Guard);std::fill_n(mapped.data,S+4,Guard);
        RUN(prefix_clip_blocks,B,valid.data,offsets.data,blocks.data,S);
        RUN(prefix_clip_totals,1,blocks.data,summary.data,B);sync();
        unsigned live=0;for(unsigned i=0;i<S;i++)live+=valid[i]!=0;
        assert(summary[0]==live);
        RUN(scatter_clip_slots,S,valid.data,offsets.data,blocks.data,mapped.data,S);sync();
        unsigned next=0;for(unsigned i=0;i<S;i++)if(valid[i])assert(mapped[next++]==(0x80000000u|i));
        for(unsigned i=live;i<S+4;i++)assert(mapped[i]==Guard);
        for(unsigned i=0;i<4;i++){assert(valid[S+i]==Guard);assert(offsets[S+i]==Guard);assert(blocks[B+i]==Guard);assert(summary[1+i]==Guard);}
        Layout fullLayout(S),compactLayout(live);
        Buffer<float> fullVertices(S*30+4),compactVertices(live*30+4),full(fullLayout.words+4),compact(compactLayout.words+4);
        Buffer<unsigned> fullTriangles(S*4+4),compactTriangles(live*4+4);
        std::fill_n(compact.data,compact.size,-999.f);std::fill_n(compactVertices.data,compactVertices.size,-999.f);
        std::fill_n(compactTriangles.data,compactTriangles.size,Guard);
        auto assemble=[&](unsigned count,unsigned* map,float* vertices,unsigned* output,float* attr,Layout layout) {
            RUN(assemble_material,count,source.data,triangles.data,positions.data,weights.data,map,vertices,output,flat.data,count);
            RUN(assemble_attributes,count,attributes.data,triangles.data,weights.data,map,attr,count,layout.boundary,layout.point,V*34);
            RUN(assemble_vertex_lighting,count,lighting.data,weights.data,map,attr,count,layout.lighting);
            RUN(assemble_fixed_lighting,count,fixed.data,triangles.data,flat.data,weights.data,map,attr,count,layout.fixed);
            RUN(assemble_unlit_falloff,count,falloff.data,weights.data,map,attr,count,layout.falloff);
        };
        assemble(S,valid.data,fullVertices.data,fullTriangles.data,full.data,fullLayout);
        assemble(live,mapped.data,compactVertices.data,compactTriangles.data,compact.data,compactLayout);sync();
        for(unsigned i=0;i<live;i++) {
            unsigned original=mapped[i]&0x7fffffffu;
            for(unsigned k=0;k<30;k++)assert(compactVertices[i*30+k]==fullVertices[original*30+k]);
            for(unsigned k=0;k<3;k++)assert(compactTriangles[i*4+k]==i*3+k);
            assert(compactTriangles[i*4+3]==fullTriangles[original*4+3]);
            const unsigned fields[][3]={{0,0,102},{fullLayout.lighting,compactLayout.lighting,36},
                {fullLayout.fixed,compactLayout.fixed,48},{fullLayout.falloff,compactLayout.falloff,12},
                {fullLayout.boundary,compactLayout.boundary,3},{fullLayout.point,compactLayout.point,36}};
            for(const auto& field:fields)for(unsigned k=0;k<field[2];k++)
                assert(compact[field[1]+i*field[2]+k]==full[field[0]+original*field[2]+k]);
        }
        for(unsigned k=0;k<4;k++){assert(compact[compactLayout.words+k]==-999);assert(compactVertices[live*30+k]==-999);assert(compactTriangles[live*4+k]==Guard);}
        std::printf("PASS: stable clipping pattern %u, %u/%u slots, all five assemblies and guards\n",pattern,live,S);
    }
}
