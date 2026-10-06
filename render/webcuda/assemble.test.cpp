#include <cassert>
#include <cmath>
#include <cstdio>
#define __global__
struct Dim { unsigned int x = 0, y = 0; } blockIdx, blockDim, threadIdx, gridDim;
#include "clip.cu"
#include "assemble.cu"
int main() {
    blockDim.x=1;
    float source[]={-.5f,-.5f,-2,1, 1,0,0,1,0,0, .5f,-.5f,0,1, 0,1,0,1,1,0, 0,.5f,0,1, 0,0,1,1,.5f,1};
    float matrices[]={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1,1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};
    unsigned int ids[]={0,0,0},triangles[]={0,1,2,5},valid[7]={},output[28]={};
    float transformed[30]={},positions[84]={},weights[84]={},vertices[210]={};
    for(blockIdx.x=0;blockIdx.x<3;blockIdx.x++) transform_material(source,matrices,ids,transformed,3);
    for(int i=0;i<30;i++) assert(source[i]==transformed[i]);
    unsigned int materials[72]={},edges[]={7},flatColors[]={0xffffffffu};
    blockIdx.x=0;
    clip_triangles(transformed,triangles,materials,edges,positions,weights,valid,1,10,4);
    assert(valid[0]==1 && valid[1]==1);
    for(blockIdx.x=0;blockIdx.x<7;blockIdx.x++) assemble_material(source,triangles,positions,weights,valid,vertices,output,flatColors,7);
    for(int slot=0;slot<7;slot++) {
        assert(output[slot*4+3]==5);
        for(int v=0;v<3;v++) {
            int dst=(slot*3+v)*10;
            if(!valid[slot]) { assert(vertices[dst+3]==0); continue; }
            float red=vertices[dst+4],green=vertices[dst+5],blue=vertices[dst+6];
            assert(std::fabs(red+green+blue-1)<1e-6);
            assert(std::fabs(vertices[dst+8]-(green+.5f*blue))<1e-6);
            assert(std::fabs(vertices[dst+9]-blue)<1e-6);
            assert(vertices[dst+2]>=-vertices[dst+3]);
        }
    }
    std::puts("WebCuda assembly: packed transform, clipped colors/UVs, material identity and invalid slots passed");
}
