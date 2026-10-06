// The WASM build captures real ESMTerrain/MaterialTable packets and compares
// the CUDA source as a CPU reference with the engine's original painted maps.
// The NVCC build consumes those exact packets and checks GPU output separately.
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>

#ifdef __CUDACC__
#include <cuda_runtime.h>
static void checked(cudaError_t result) {
    if(result!=cudaSuccess){std::fprintf(stderr,"CUDA: %s\n",cudaGetErrorString(result));std::abort();}
}
#else
float __uint_as_float(unsigned bits){float value;std::memcpy(&value,&bits,4);return value;}
#define __global__
struct Dim {unsigned x=0,y=0;} blockIdx,blockDim,threadIdx,gridDim;
#endif
#include "terrain-blend.cu"

static void transfer(FILE* file,void* data,size_t words,bool write) {
    auto count=write?std::fwrite(data,4,words,file):std::fread(data,4,words,file);
    if(count!=words){std::puts("Fixture file transfer failed");std::abort();}
}
struct Fixture {
    unsigned width,height,descriptor;
    std::vector<unsigned> blocks,expected;
    void relocate() {
        const auto source=blocks[descriptor+2];
        blocks.insert(blocks.begin(),7,0xdeadbeefu);descriptor+=7;
        blocks[descriptor+2]=source+7; // Quad/vertex addresses stay source-relative.
    }
    void io(FILE* file,bool write) {
        unsigned header[]{width,height,descriptor,static_cast<unsigned>(blocks.size())};
        transfer(file,header,4,write);
        if(!write){width=header[0];height=header[1];descriptor=header[2];
            assert(width&&height&&width<1024&&height<1024&&header[3]<1024*1024);
            blocks.resize(header[3]);expected.resize(width*height);}
        transfer(file,blocks.data(),blocks.size(),write);transfer(file,expected.data(),expected.size(),write);
    }
    void check() {
        constexpr unsigned prefix=7,tail=16,guard=0xdeadbeefu;
        std::vector<unsigned> result(prefix+expected.size()+tail,guard);
#ifdef __CUDACC__
        unsigned *source,*target;checked(cudaMalloc(&source,blocks.size()*4));checked(cudaMalloc(&target,result.size()*4));
        checked(cudaMemcpy(source,blocks.data(),blocks.size()*4,cudaMemcpyHostToDevice));
        checked(cudaMemcpy(target,result.data(),result.size()*4,cudaMemcpyHostToDevice));
        generate_terrain_blendmap<<<(width*height+63)/64,64>>>(source,target,width,height,descriptor,prefix);
        checked(cudaGetLastError());checked(cudaDeviceSynchronize());
        checked(cudaMemcpy(result.data(),target,result.size()*4,cudaMemcpyDeviceToHost));
        checked(cudaFree(target));checked(cudaFree(source));
#else
        blockDim.x=1;gridDim.x=1;
        for(blockIdx.x=0;blockIdx.x<width*height+31;blockIdx.x++)
            generate_terrain_blendmap(blocks.data(),result.data(),width,height,descriptor,prefix);
#endif
        for(unsigned i=0;i<prefix;i++)assert(result[i]==guard);
        for(size_t i=prefix+expected.size();i<result.size();i++)assert(result[i]==guard);
        for(size_t i=0;i<expected.size();i++)if(result[prefix+i]!=expected[i]) {
            std::fprintf(stderr,"Terrain mismatch %ux%u at %zu: %08x expected %08x\n",width,height,i,result[prefix+i],expected[i]);
            std::abort();
        }
    }
};

#ifdef __EMSCRIPTEN__
#include <components/esmterrain/storage.hpp>
#include <components/esm3/loadland.hpp>
#include <components/esm4/loadltex.hpp>
#include <components/vfs/manager.hpp>
#include <components/webcuda/materialtable.hpp>
#include <components/webcuda/terrainblendimage.hpp>
#include <components/esm/util.hpp>
#include <array>
#include <map>

class TestTerrain final:public ESMTerrain::Storage {
public:
    std::map<std::pair<int,int>,osg::ref_ptr<const ESMTerrain::LandObject>> lands;
    std::array<VFS::Path::Normalized,3> textures{VFS::Path::Normalized("grass.dds"),VFS::Path::Normalized("rock.dds"),VFS::Path::Normalized("grass.dds")};
    std::array<ESM4::LandTexture,4> esm4Textures{};
    TestTerrain(VFS::Manager& vfs,bool gpu):ESMTerrain::Storage(&vfs,{},{},false,{},false,gpu) {
        for(unsigned i=0;i<esm4Textures.size();i++)esm4Textures[i].mTextureFile="layer"+std::to_string(i)+".dds";
    }
    osg::ref_ptr<const ESMTerrain::LandObject> getLand(ESM::ExteriorCellLocation cell) override {
        auto found=lands.find({cell.mX,cell.mY});return found==lands.end()?nullptr:found->second;
    }
    const VFS::Path::Normalized* getLandTexture(std::uint16_t index,int) override{return &textures.at(index);}
    const ESM4::LandTexture* getEsm4LandTexture(ESM::RefId id) const override {
        const auto* form=id.getIf<ESM::FormId>();
        return form&&form->mIndex&&form->mIndex<=esm4Textures.size()?&esm4Textures[form->mIndex-1]:nullptr;
    }
    void getBounds(float& minX,float& maxX,float& minY,float& maxY,ESM::RefId) override {minX=minY=-2;maxX=maxY=3;}
};

int main(int argc,char** argv) {
    assert(argc==2);std::vector<Fixture> fixtures;unsigned comparisons=0,singleLayer=0;
    VFS::Manager vfs;
    for(unsigned mode=0;mode<2;mode++)for(unsigned pattern=0;pattern<3;pattern++) {
        TestTerrain cpu(vfs,false),gpu(vfs,true);
        for(int y=-2;y<=2;y++)for(int x=-2;x<=2;x++) {
            if(pattern==1&&(x+y)%3==0)continue;
            osg::ref_ptr<const ESMTerrain::LandObject> object;
            if(mode==0) {
                ESM::Land land;land.setPlugin((x-y)&3);land.mDataTypes=ESM::Land::DATA_VTEX;
                land.mLandData=std::make_unique<ESM::LandRecordData>();land.mLandData->mDataLoaded=ESM::Land::DATA_VTEX;
                for(unsigned i=0;i<land.mLandData->mTextures.size();i++)land.mLandData->mTextures[i]=pattern==2?1:(i+x*x+y*y)%4;
                object=new ESMTerrain::LandObject(land,ESM::Land::DATA_VTEX);
            } else {
                ESM4::Land land{};land.mDataTypes=ESM4::Land::LAND_VTEX;
                for(unsigned q=0;q<4;q++) {
                    auto& texture=land.mTextures[q];texture.base.formId=pattern==2?1:1+(q+x*x+y*y)%4;
                    if(pattern==2)continue;
                    for(unsigned layer=0;layer<5;layer++) {
                        ESM4::Land::TxtLayer value{};value.texture.formId=1+layer%4;
                        for(unsigned pos=0;pos<289;pos++) {
                            float opacity=float((pos*7+q*11+layer*19)%281)/255.f-.05f;
                            value.data.push_back({static_cast<std::uint16_t>(pos),0,0,opacity});
                            if(pos%17==0)value.data.push_back({static_cast<std::uint16_t>(pos),0,0,.5f});
                        }
                        texture.layers.push_back(std::move(value));
                    }
                }
                object=new ESMTerrain::LandObject(land,ESM4::Land::LAND_VTEX);
            }
            cpu.lands[{x,y}]=object;gpu.lands[{x,y}]=object;
        }
        const auto world=mode==0?ESM::RefId(ESM::Cell::sDefaultWorldspaceId):ESM::RefId::formIdRefId({1,0});
        for(float size:{.5f,1.f,2.f})for(osg::Vec2f center:{osg::Vec2f(.5f,.5f),osg::Vec2f(0,0),osg::Vec2f(-.5f,-.5f)}) {
            std::vector<osg::ref_ptr<osg::Image>> expected,generated;std::vector<Terrain::LayerInfo> oldLayers,newLayers;
            cpu.getBlendmaps(size,center,expected,oldLayers,world);gpu.getBlendmaps(size,center,generated,newLayers,world);
            assert(expected.size()==generated.size()&&oldLayers.size()==newLayers.size());
            for(unsigned layer=0;layer<oldLayers.size();layer++)assert(oldLayers[layer].mDiffuseMap==newLayers[layer].mDiffuseMap);
            if(expected.empty()){singleLayer++;continue;}
            WebCuda::MaterialTable table(64,64);WebCuda::DrawContext context;
            std::vector<osg::ref_ptr<osg::Texture2D>> retained;
            std::shared_ptr<const std::vector<std::uint32_t>> shared;
            for(unsigned layer=0;layer<generated.size();layer++) {
                auto* input=dynamic_cast<WebCuda::TerrainBlendImage*>(generated[layer].get());
                assert(input&&input->data()==nullptr&&input->s()==expected[layer]->s()&&input->t()==expected[layer]->t());
                if(shared)assert(shared==input->inputs);else shared=input->inputs;
                osg::ref_ptr<osg::Object> clone=input->clone(osg::CopyOp::DEEP_COPY_ALL);
                auto* copied=dynamic_cast<WebCuda::TerrainBlendImage*>(clone.get());assert(copied&&copied->inputs==shared&&copied->data()==nullptr);
                osg::ref_ptr<osg::Texture2D> texture=new osg::Texture2D(input);retained.push_back(texture);
                auto first=table.encode(context,texture,true);assert(table.encode(context,texture,true)==first);
            }
            assert(table.textureDecodes().size()==generated.size()*5);
            assert(table.compressedBlocks().size()==shared->size()+generated.size()*4); // one shared source
            assert(table.textureResources().size()==generated.size()*3);
            for(unsigned layer=0;layer<generated.size();layer++) {
                const auto* record=table.textureDecodes().data()+layer*5;
                assert(record[4]==259&&record[2]==unsigned(expected[layer]->s())&&record[3]==unsigned(expected[layer]->t()));
                Fixture test{record[2],record[3],record[0],table.compressedBlocks(),{}};
                for(unsigned y=0;y<test.height;y++)for(unsigned x=0;x<test.width;x++)
                    test.expected.push_back(0x00ffffffu|(unsigned(*expected[layer]->data(x,y))<<24));
                test.check();fixtures.push_back(test);comparisons++;
                test.relocate();test.check();fixtures.push_back(std::move(test));
            }
        }
    }
    FILE* output=std::fopen(argv[1],"wb");assert(output);unsigned header[]{0x424c4e44u,static_cast<unsigned>(fixtures.size())};
    transfer(output,header,2,true);for(auto& fixture:fixtures)fixture.io(output,true);assert(std::fclose(output)==0);
    std::printf("Terrain blend: %u original-engine images, %zu exact original/relocated packet comparisons, %u single-layer elisions; real WASM capture, shared inputs, clone lifetime, mips/residency records\n",comparisons,fixtures.size(),singleLayer);
}
#elif defined(__CUDACC__)
int main(int argc,char** argv) {
    assert(argc==2);FILE* input=std::fopen(argv[1],"rb");assert(input);unsigned header[2];transfer(input,header,2,false);
    assert(header[0]==0x424c4e44u&&header[1]>0&&header[1]<10000);
    for(unsigned i=0;i<header[1];i++){Fixture fixture{};fixture.io(input,false);fixture.check();}
    assert(std::fgetc(input)==EOF);assert(std::fclose(input)==0);
    std::printf("Native CUDA terrain blend: %u exact images from real WASM engine packets, original CPU masks as oracle, output guards preserved\n",header[1]);
    std::puts("Browser interop and full-game rendering were not exercised.");
}
#endif
