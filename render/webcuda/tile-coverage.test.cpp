// Filled-tile rejection against all-triangle lists, through the production
// rasterizer. Build as C++17 or nvcc -x cu; the latter executes real GPU kernels.
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

#ifdef __CUDACC__
#include <cuda_runtime.h>
static void checked(cudaError_t result) {
    if(result!=cudaSuccess){std::fprintf(stderr,"CUDA: %s\n",cudaGetErrorString(result));std::abort();}
}
static void sync(){checked(cudaDeviceSynchronize());}
#define RUN(kernel,count,...) do {kernel<<<((count)+63u)/64u,64>>>(__VA_ARGS__);checked(cudaGetLastError());} while(false)
#else
float __uint_as_float(unsigned bits){float value;std::memcpy(&value,&bits,4);return value;}
unsigned __float_as_uint(float value){unsigned bits;std::memcpy(&bits,&value,4);return bits;}
unsigned atomicAdd(unsigned* p,unsigned value){auto old=*p;*p+=value;return old;}
unsigned atomicMax(unsigned* p,unsigned value){auto old=*p;*p=std::max(*p,value);return old;}
#define __global__
#define __device__
struct Dim {unsigned x=0,y=0;} blockIdx,blockDim,threadIdx,gridDim;
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

struct Scene {
    unsigned width,height,n,tiles,boundary,point,raster,maxWords;
    Buffer<float> vertices,attributes,actual,expected;
    Buffer<unsigned> triangles,materials,texels,counts,referenceCounts,candidates,reference,offsets,summary,blocks;
    Scene(unsigned w,unsigned h,unsigned count,unsigned maxSamples):
        width(w),height(h),n(count),tiles(((w+15)/16)*((h+15)/16)),boundary(n*3*34),
        point(boundary+n*3),raster(point+n*3*12),maxWords(tiles+1+tiles*n),
        vertices(n*3*10),attributes(raster+n*50),actual(w*h*10*maxSamples+1),expected(actual.size),
        triangles(n*4),materials(n*12),texels(4),counts(tiles+1),referenceCounts(tiles+1),
        candidates(maxWords+1),reference(tiles*n),offsets(tiles+1),summary(2),blocks((tiles+255)/256) {
        texels[0]=0xff804020u;texels[1]=0x8090b0d0u;texels[2]=0xa02080c0u;texels[3]=0xffffffffu;
        for(unsigned t=0;t<n;t++) {
            unsigned m=t*12,r=raster+t*50;
            triangles[t*4+3]=t;
            materials[m+1]=materials[m+2]=2;materials[m+3]=1|2|4|8|32|128|8192;
            materials[m+7]=w;materials[m+8]=h;materials[m+9]=7|(7<<4);materials[m+10]=0x5454;
            attributes[r+3]=1;attributes[r+24]=1;attributes[r+26]=65535;attributes[r+27]=1;
            // Increment on every covered sample, so later overlapping triangles
            // cannot hide missing coverage by overwriting color/depth.
            for(unsigned face:{8u,15u}){attributes[r+face]=7;attributes[r+face+2]=255;
                attributes[r+face+3]=255;attributes[r+face+6]=3;}
            for(unsigned c=0;c<3;c++) {
                unsigned v=t*3+c;triangles[t*4+c]=v;
                attributes[boundary+v]=1;attributes[point+v*12]=1;
                for(unsigned k=0;k<4;k++)vertices[v*10+4+k]=float(1+(v*7+k*11)%17)/18;
                vertices[v*10+8]=float(c%2);vertices[v*10+9]=float(c/2);
            }
        }
        for(unsigned tile=0;tile<tiles;tile++) {
            referenceCounts[tile]=n;
            for(unsigned t=0;t<n;t++)reference[tile*n+t]=t;
        }
    }
    void vertex(unsigned v,float x,float y,float w,float z=0.0f) {
        vertices[v*10]=(x/float(width)*2-1)*w;vertices[v*10+1]=(1-y/float(height)*2)*w;
        vertices[v*10+2]=z*w;vertices[v*10+3]=w;
    }
    void bin(unsigned samples) {
        std::fill_n(counts.data,counts.size,0u);std::fill_n(candidates.data,candidates.size,0xdeadbeefu);
        summary[0]=summary[1]=0;
        RUN(bin_triangle_bounds,n,vertices.data,triangles.data,counts.data,candidates.data,offsets.data,summary.data,
            materials.data,attributes.data,width,height,n,0,0,raster,samples);
        RUN(prefix_tile_blocks,blocks.size,counts.data,offsets.data,blocks.data,tiles,maxWords);
        RUN(prefix_tile_block_totals,1,counts.data,blocks.data,summary.data,tiles,maxWords);
        RUN(finish_tile_prefix,tiles+1,offsets.data,blocks.data,summary.data,tiles);
        RUN(copy_tile_offsets,tiles+1,offsets.data,candidates.data,tiles);
        RUN(clear_tile_counts,tiles,counts.data,tiles);
        RUN(bin_triangle_bounds,n,vertices.data,triangles.data,counts.data,candidates.data,offsets.data,summary.data,
            materials.data,attributes.data,width,height,n,0,1,raster,samples);
        RUN(sort_tile_candidates,tiles,counts.data,candidates.data,tiles,0);
        sync();assert(summary[1]==0&&summary[0]<=maxWords&&candidates[maxWords]==0xdeadbeefu);
    }
    void clear(float* target,unsigned samples) {
        RUN(clear_attachment,width*height*samples,target,width*height,17664,.1f,.2f,.3f,1,1,1,4,2,4,2,24,1,0,15,width,height,0,0,width,height,samples);
    }
    void render(bool optimized,unsigned samples) {
        if(optimized) {
            RUN(raster_material,width*height*samples,vertices.data,triangles.data,counts.data,candidates.data,
                materials.data,texels.data,actual.data,attributes.data,width,height,
                0,raster,boundary,point,0,0,0,0,0,1,4,2,4,2,24,1,samples);
        } else {
            RUN(WEBCUDA_REFERENCE_ENTRY,width*height*samples,vertices.data,triangles.data,
                comparePreviousRaster?counts.data:referenceCounts.data,comparePreviousRaster?candidates.data:reference.data,
                materials.data,texels.data,expected.data,attributes.data,width,height,
                comparePreviousRaster?0:n,raster,boundary,point,0,0,0,0,0,1,4,2,4,2,24,1,samples);
        }
    }
    void compare(unsigned samples,unsigned scene) {
        bin(samples);actual[actual.size-1]=expected[expected.size-1]=12345;
        clear(actual.data,samples);clear(expected.data,samples);render(true,samples);render(false,samples);sync();
        assert(actual[actual.size-1]==12345&&expected[expected.size-1]==12345);
        if(std::memcmp(actual.data,expected.data,width*height*10*samples*sizeof(float))) {
            std::fprintf(stderr,"Tile coverage mismatch: %ux%u scene %u samples %u\n",width,height,scene,samples);std::abort();
        }
    }
};

int main(int argc,char** argv) {
#ifndef __CUDACC__
    blockDim.x=1;gridDim.x=1;
#endif
    unsigned cases=0;std::mt19937 random(95241);std::uniform_real_distribution<float> unit(0,1);
    for(auto size:{std::pair<unsigned,unsigned>{1,1},{17,15},{65,49},{129,97},{8193,3},{3,8193}}) {
        Scene scene(size.first,size.second,24,16);
        unsigned layouts=std::max(size.first,size.second)>1024?4:16;
        for(unsigned layout=0;layout<layouts;layout++) {
            for(unsigned t=0;t<scene.n;t++) {
                float ax=(unit(random)*1.3f-.15f)*scene.width,ay=(unit(random)*1.3f-.15f)*scene.height;
                float bx=(unit(random)*1.3f-.15f)*scene.width,by=(unit(random)*1.3f-.15f)*scene.height;
                float cx=(unit(random)*1.3f-.15f)*scene.width,cy=(unit(random)*1.3f-.15f)*scene.height;
                if(layout%4==0) { // Near-collinear and long thin triangles, both windings.
                    ax=0;ay=0;bx=float(scene.width);by=float(scene.height);cx=bx;cy=by-float(1+(t%4))*.0625f;
                }
                if(layout%4==1) { // Edges at, and immediately either side of, tile/sample boundaries.
                    const float sampleOffsets[]={.0625f,.125f,.25f,.375f,.5f,.625f,.75f,.875f};
                    ax=16.f+sampleOffsets[(t/3)%8];ay=.0625f;bx=ax;by=float(scene.height);cx=float(scene.width);cy=by;
                    float delta=t%3==0?-1e-5f:t%3==1?0:1e-5f;ax+=delta;bx+=delta;
                }
                if(layout%4==2&&t%3==0) {cx=(ax+bx)*.5f;cy=(ay+by)*.5f;}
                if(t%2){std::swap(bx,cx);std::swap(by,cy);}
                float w=std::ldexp(.5f+unit(random),int((layout*7+t)%41)-20);
                scene.vertex(t*3,ax,ay,w,.3f);scene.vertex(t*3+1,bx,by,w*.7f,-.2f);scene.vertex(t*3+2,cx,cy,w*1.7f,.6f);
            }
            for(unsigned samples:{1u,2u,4u,8u,16u}){scene.compare(samples,layout);cases++;}
        }
    }
    std::printf("Filled-tile coverage: %u exact color/depth/stencil comparisons, guarded compact lists\n",cases);
#ifdef __CUDACC__
    if(argc>1&&std::strcmp(argv[1],"--benchmark")==0) {
        for(unsigned workload=0;workload<2;workload++) {
            Scene scene(1280,720,96,1);
            for(unsigned t=0;t<scene.n;t++)for(unsigned c=0;c<3;c++) {
                float x=unit(random)*scene.width,y=unit(random)*scene.height;
                if(workload==1){x=c==0?0:float(scene.width);y=c==0?0:float(scene.height)-(c==2?4.f:0.f);}
                scene.vertex(t*3+c,x,y,1.f);
            }
            scene.compare(1,workload);
            // Diagnostic box binner builds the old rectangular candidate set.
            // Only raster time is compared; neither binner is inside the timer.
            RUN(bin_triangles,scene.tiles,scene.vertices.data,scene.triangles.data,scene.referenceCounts.data,
                scene.reference.data,scene.width,scene.height,scene.n,scene.n,10,4);
            sync();unsigned box=0,tight=0;
            for(unsigned tile=0;tile<scene.tiles;tile++){box+=scene.referenceCounts[tile];tight+=scene.counts[tile];}
            scene.clear(scene.actual.data,1);scene.clear(scene.expected.data,1);scene.render(true,1);scene.render(false,1);sync();
            assert(std::memcmp(scene.actual.data,scene.expected.data,scene.width*scene.height*10*sizeof(float))==0);
            cudaEvent_t start,end;checked(cudaEventCreate(&start));checked(cudaEventCreate(&end));
            std::vector<float> timings[2];
            for(unsigned repeat=0;repeat<12;repeat++)for(unsigned order=0;order<2;order++) {
                bool optimized=(order^(repeat%2))!=0;
                scene.clear(optimized?scene.actual.data:scene.expected.data,1);
                checked(cudaEventRecord(start));scene.render(optimized,1);checked(cudaEventRecord(end));checked(cudaEventSynchronize(end));
                float ms;checked(cudaEventElapsedTime(&ms,start,end));if(repeat>=3)timings[optimized?1:0].push_back(ms);
            }
            for(auto& values:timings)std::sort(values.begin(),values.end());
            if(comparePreviousRaster)
                std::printf("%s: previous -> current raster, %u identical tile references; median GPU %.3f -> %.3f ms (1280x720, 96 triangles, 9 samples)\n",
                    workload==0?"Random triangles":"Long thin triangles",tight,timings[0][4],timings[1][4]);
            else
                std::printf("%s: references %u -> %u; median GPU raster %.3f -> %.3f ms (1280x720, 96 triangles, 9 samples)\n",
                    workload==0?"Random triangles":"Long thin triangles",box,tight,timings[0][4],timings[1][4]);
            checked(cudaEventDestroy(start));checked(cudaEventDestroy(end));
        }
    }
    std::puts("Executed production CUDA kernels on the GPU; browser interop and gameplay were not exercised.");
#else
    (void)argc;(void)argv;std::puts("Executed CPU reference; GPU execution is a separate nvcc build/run.");
#endif
}
