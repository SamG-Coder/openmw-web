#include <cassert>
#include <cmath>
#include <cstdio>
#include <algorithm>
#include <cstring>
float __uint_as_float(unsigned int bits) {float value;std::memcpy(&value,&bits,4);return value;}
unsigned int __float_as_uint(float value) {unsigned int bits;std::memcpy(&bits,&value,4);return bits;}
unsigned int atomicAdd(unsigned int* p,unsigned int value){auto old=*p;*p+=value;return old;}
#define __global__
#define __device__
struct Dim { unsigned int x = 0, y = 0; } blockIdx, blockDim, threadIdx, gridDim;
#include "material.cu"
#include "compact-depth.cu"
bool near(float x, float y) { return std::fabs(x-y) < 1e-6f; }
int main() {
    blockDim.x = 1;
    float vertices[] = {
        -1,1,0,1, 1,0,0,.5f, 0,0,
        1,1,0,1, 1,0,0,.5f, 1,0,
        1,-1,0,1, 1,0,0,.5f, 1,1,
        -1,-1,0,1, 1,0,0,.5f, 0,1,
    };
    unsigned int triangles[] = {0,1,2,0, 0,2,3,0}, counts[] = {2}, candidates[] = {0,1};
    unsigned int materials[] = {0,2,2,2,0, 0,0,4,4, 0,0,0};
    unsigned int texels[] = {0xff0000ff,0xff00ff00,0xffff0000,0xffffffff};
    float target[16*10] = {};
    constexpr unsigned int boundaryOffset=4*34,pointOffset=boundaryOffset+4,rasterOffset=pointOffset+4*12;
    float attributes[rasterOffset+50]={};
    attributes[rasterOffset+3]=1.f;
    for(unsigned int v=0;v<4;v++){attributes[boundaryOffset+v]=1.f;attributes[pointOffset+v*12]=1.f;}
    auto clear = [&] { for (blockIdx.x=0; blockIdx.x<16; blockIdx.x++) clear_target(target,16,0,0,0,1,1); };
    auto render = [&] { for (blockIdx.x=0; blockIdx.x<16; blockIdx.x++) raster_material(vertices,triangles,counts,candidates,materials,texels,target,attributes,4,4,2,rasterOffset,boundaryOffset,pointOffset,0,0,0,0,0,0,4,2,4,2,0,0,1); };
    // Actual reverse-Z case: zero clear, GEQUAL and zero-to-one clip depth.
    materials[3]=8388608u|128u|4u|8u;materials[9]=6u|(7u<<4);
    for(unsigned int v=0;v<4;v++)vertices[v*10+2]=.25f;
    clear();for(unsigned int p=0;p<16;p++)target[p*9+4]=0;
    render();
    for(unsigned int p=0;p<16;p++)assert(near(target[p*9+4],.25f)&&near(target[p*9],1.f));
    // Under reverse Z, a smaller depth is farther away and must not overwrite.
    for(unsigned int v=0;v<4;v++){vertices[v*10+2]=.1f;vertices[v*10+4]=0;vertices[v*10+5]=1;}
    render();
    for(unsigned int p=0;p<16;p++)assert(near(target[p*9+4],.25f)&&near(target[p*9],1.f)&&near(target[p*9+1],0.f));
    for(unsigned int v=0;v<4;v++)vertices[v*10+2]=.75f;
    render();
    for(unsigned int p=0;p<16;p++)assert(near(target[p*9+4],.75f)&&near(target[p*9],0.f)&&near(target[p*9+1],1.f));
    for(unsigned int v=0;v<4;v++)vertices[v*10+2]=-.1f;
    render();for(unsigned int p=0;p<16;p++)assert(near(target[p*9+4],.75f));
    for(unsigned int v=0;v<4;v++){vertices[v*10+2]=0;vertices[v*10+4]=1;vertices[v*10+5]=0;}
    materials[9]=0;
    // Same rasterization, alpha/discard and depth behavior with scalar storage.
    for(unsigned int threshold:{0u,200u})for(unsigned int flags:{0u,2u|4u|8u,1u|2u|4u|8u}) {
        materials[3]=flags;materials[4]=threshold;
        float compact[18];std::fill_n(compact,18,12345.f);
        clear();
        for(blockIdx.x=0;blockIdx.x<16;blockIdx.x++)clear_compact_depth(compact+1,16,1);
        render();
        for(blockIdx.x=0;blockIdx.x<16;blockIdx.x++)raster_material(vertices,triangles,counts,candidates,materials,texels,compact+1,attributes,4,4,2,rasterOffset,boundaryOffset,pointOffset,0,0,0,0,0,0,4,2,0,2,0,0,1);
        for(unsigned p=0;p<16;p++)assert(compact[p+1]==target[p*9+4]);
        assert(compact[0]==12345.f&&compact[17]==12345.f);
        unsigned int exported[18];std::fill_n(exported,18,0xabcdef01u);
        for(blockIdx.x=0;blockIdx.x<16;blockIdx.x++)compact_depth_to_texture(compact+1,exported,4,4,1);
        for(unsigned p=0;p<16;p++)assert(exported[1+(3-p/4)*4+p%4]==__float_as_uint(compact[p+1]));
        assert(exported[0]==0xabcdef01u&&exported[17]==0xabcdef01u);
        for(blockIdx.x=0;blockIdx.x<16;blockIdx.x++)copy_depth_layout(compact+1,target,16,1,0);
        for(unsigned p=0;p<16;p++)assert(target[p*9+4]==compact[p+1]);
    }
    materials[3]=2;materials[4]=0;
    for (int winding=0; winding<2; winding++) {
        clear(); render();
        for (int p=0; p<16; p++) assert(near(target[p*9],.5f) && target[p*9+4]==1);
        std::swap(triangles[1],triangles[2]); std::swap(triangles[5],triangles[6]);
    }
    // Scissor and alpha discard must precede depth writes.
    materials[3]=2|4|8; materials[4]=200;
    clear(); render();
    for (int p=0;p<16;p++) assert(target[p*9]==0 && target[p*9+4]==1);
    materials[4]=0; materials[5]=1; materials[6]=1; materials[7]=2; materials[8]=2;
    clear(); render();
    for (int p=0;p<16;p++) {
        bool inside=(p%4>=1 && p%4<3 && p/4>=1 && p/4<3);
        assert(near(target[p*9],inside?.5f:0.f));
        assert(near(target[p*9+4],inside?.5f:1.f));
    }
    // LESS rejects equal depth; LEQUAL accepts it, with one blend per pixel.
    render(); assert(near(target[5*9],.5f));
    materials[3]|=64; render(); assert(near(target[5*9],.75f));
    assert(near(sample_channel(texels,0,2,2,.5f,.5f,32,0),.5f));
    assert(near(sample_channel(texels,0,2,2,.5f,.5f,32,1),.5f));
    assert(near(sample_channel(texels,0,2,2,-.25f,.25f,16,1),1.f));
    assert(near(sample_channel(texels,0,2,2,-1.f,0.f,0,0),1.f));
    // Textured quad maps its four quadrants to the four authored texels.
    materials[3]=1; materials[5]=0; materials[6]=0; materials[7]=4; materials[8]=4;
    for (int v=0;v<4;v++) for (int k=0;k<4;k++) vertices[v*10+4+k]=1;
    clear(); render();
    assert(target[0]==1 && target[1]==0 && target[2]==0);
    assert(target[3*9]==0 && target[3*9+1]==1);
    assert(target[12*9+2]==1 && target[12*9]==0);
    assert(target[15*9]==1 && target[15*9+1]==1 && target[15*9+2]==1);
    for(int v=0;v<4;v++) {vertices[v*10+4]=1;vertices[v*10+5]=0;vertices[v*10+6]=0;vertices[v*10+7]=.5f;}
    materials[3]=128|256|2;materials[9]=1|(7<<4);materials[10]=0x5454;
    clear();render();
    for(int p=0;p<16;p++)assert(near(target[p*9],.5f)&&near(target[p*9+3],.75f));
    materials[10]=0x5154;clear();render();assert(near(target[3],1));
    float reference=.5f;std::memcpy(&materials[4],&reference,4);materials[9]=1|(4<<4);
    clear();render();assert(target[0]==0); // GREATER rejects equality, no byte quantization
    materials[9]=1|(7<<4)|(2<<14);clear();render();assert(target[0]==0); // clockwise quad is back-facing
    materials[9]|=65536;clear();render();assert(near(target[0],.5f));
    assert(compare_value(.5f,.5f,2)==1 && compare_value(.5f,.5f,5)==0 && compare_value(.5f,.5f,6)==1);
    assert(blend_value(.2f,.8f,0,0,3)==.2f && blend_value(.2f,.8f,0,0,4)==.8f);
    assert(near(blend_value(.2f,.8f,1,1,2),.6f));
    // Compare analytic disk/pixel overlap to an independent midpoint-area
    // integration, including subpixel disks and partially covered pixels.
    for(float radius : {.1f,.5f,1.f,1.75f})for(float x : {-1.f,-.45f,0.f,.2f,1.f})
        for(float y : {-.7f,0.f,.35f}) {
            unsigned int hits=0;
            constexpr unsigned int samples=256;
            for(unsigned int sy=0;sy<samples;sy++)for(unsigned int sx=0;sx<samples;sx++) {
                const double dx=x-.5+(sx+.5)/samples,dy=y-.5+(sy+.5)/samples;
                if(dx*dx+dy*dy<=double(radius)*radius)hits++;
            }
            const float reference=float(hits)/(samples*samples);
            assert(std::fabs(point_disk_coverage(x,y,radius)-reference)<.003f);
            assert(near(point_disk_coverage(x,y,radius),point_disk_coverage(-x,-y,radius)));
        }
    assert(near(line_rectangle_coverage(-1.f,0.f,2.f,0.f,1.f),1.f));
    assert(near(line_rectangle_coverage(-1.f,0.f,2.f,0.f,.5f),.5f));
    assert(near(line_rectangle_coverage(-.25f,0.f,.5f,0.f,.5f),.25f));
    assert(line_diamond_exit(-1.f,0.f,2.f,0.f)==1u);
    assert(line_diamond_exit(-1.f,0.f,1.f,0.f)==0u);
    assert(line_diamond_exit(0.f,0.f,1.f,0.f)==1u);
    std::puts("WebCuda coverage: disk area against midpoint integration, symmetry, line area and diamond endpoints passed");
    std::puts("WebCuda material: top-left seams, winding, blending, alpha discard, depth, scissor and texture sampling passed");
}
