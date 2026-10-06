// WASM64 material-capture benchmark. Run the same fixture with the preceding
// and current materialtable.cpp, then compare all packet checksums before times.
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <osg/Program>
#include <osg/Shader>
#include <osg/Material>
#include <osg/ValueObject>
#include <components/webcuda/materialtable.hpp>

template<class T> void hashPacket(std::uint64_t& result,const std::vector<T>& values) {
    for(const auto value:values) {
        std::uint32_t bits;static_assert(sizeof(value)==4);std::memcpy(&bits,&value,4);
        result^=bits;result*=1099511628211ull;
    }
}
int main(int argc,char** argv) {
    const char* names[]={"objects","objects","terrain","terrain_composite","groundcover","bs/nolighting","bs/default","water","shadowcasting","depthclipped"};
    const unsigned scenario=argc>1?std::strtoul(argv[1],nullptr,10):0;
    if(scenario>=10)return 1;
    osg::Matrixd identity;
    WebCuda::DrawContext context;context.view=&identity;context.modelView=&identity;
    std::vector<osg::ref_ptr<osg::StateSet>> states;
    for(unsigned layer=0;layer<6;layer++) {
        osg::ref_ptr<osg::StateSet> state=new osg::StateSet;
        for(unsigned i=0;i<8;i++)state->addUniform(new osg::Uniform(("input"+std::to_string(layer*8+i)).c_str(),float(i)));
        states.push_back(state);context.states.push_back(state);
    }
    osg::ref_ptr<osg::Image> image=new osg::Image;image->allocateImage(2,2,1,GL_RGBA,GL_UNSIGNED_BYTE);
    for(unsigned k=0;k<16;k++)image->data()[k]=k*15;
    osg::ref_ptr<osg::Texture2D> texture=new osg::Texture2D(image);
    texture->setFilter(osg::Texture::MIN_FILTER,osg::Texture::LINEAR);
    states[0]->setTextureAttributeAndModes(0,texture);states[0]->setAttribute(new osg::Material);
    states[0]->addUniform(new osg::Uniform("nodePosition",osg::Vec3()));
    states[0]->addUniform(new osg::Uniform("playerPos",osg::Vec3()));
    for(const char* sampler:{"normalMap","reflectionMap","rippleMap"})states[0]->addUniform(new osg::Uniform(sampler,0));
    osg::ref_ptr<osg::Uniform> alpha=new osg::Uniform("alphaRef",0.f);states[1]->addUniform(alpha);
    std::vector<osg::ref_ptr<osg::Program>> programs;
    for(unsigned variant=0;variant<16;variant++) {
        osg::ref_ptr<osg::Program> program=new osg::Program;
        osg::ref_ptr<osg::Shader> vertex=new osg::Shader(osg::Shader::VERTEX),fragment=new osg::Shader(osg::Shader::FRAGMENT);
        vertex->setName(std::string(names[scenario])+".vert");fragment->setName(std::string(names[scenario])+".frag");
        program->addShader(vertex);program->addShader(fragment);
        std::string metadata;
        for(const char* name:{"normalMap","darkMap","detailMap","decalMap","emissiveMap","specularMap","envMap","bumpMap","glossMap","blendMap",
            "parallax","diffuseParallax","adjustCoverage","forcePPL","softParticles","particleOcclusion","skyBlending","simpleLighting",
            "particle","preLightEnv","additiveBlending","lightingMethodClustered","shadows_enabled","reverseZ","writeNormals","disableNormals",
            "classicFalloff","clamp","radialFog","exponentialFog","alphaToCoverage","particlePointLighting","reconstructNormalZ","useGPUShader4",
            "waterRefraction","sunlightScattering","wobblyShores","reflectionBlurEnabled","perspectiveShadowMaps","useShadowDebugOverlay",
            "limitShadowMapDistance","disableNormalOffsetShadows","reflectionBlur","rainRippleDetail","diffuseMapUV","normalMapUV","specularMapUV"})
            metadata+=std::string(name)+"=0\n";
        metadata+="diffuseMap=1\ngroundcoverFadeStart=0\ngroundcoverFadeEnd=2048\nbenchmarkVariant="+std::to_string(variant)+"\n";
        if(scenario==1||scenario==2||scenario==4||scenario==5||scenario==6)
            metadata+="normalMap=1\ndetailMap=1\nemissiveMap=1\nspecularMap=1\n";
        if(scenario==8||scenario==9)metadata+="alphaToCoverage=1\nalphaFunc=516\n";
        fragment->setUserValue("webcuda.defines",metadata);programs.push_back(program);
    }
    std::vector<double> samples;std::uint64_t expected=0;
    for(unsigned run=0;run<11;run++) {
        WebCuda::MaterialTable table(1280,720);
        const auto start=std::chrono::steady_clock::now();
        for(unsigned draw=0;draw<640;draw++) {
            states[0]->setAttribute(programs[draw%programs.size()]);alpha->set(float(draw%32)/32);
            table.encode(context);
        }
        const auto ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
        if(run>=2)samples.push_back(ms);
        std::uint64_t checksum=1469598103934665603ull;
        hashPacket(checksum,table.materials());hashPacket(checksum,table.texels());hashPacket(checksum,table.rasterParams());
        hashPacket(checksum,table.compressedBlocks());hashPacket(checksum,table.textureDecodes());hashPacket(checksum,table.textureResources());
        hashPacket(checksum,table.mipGenerations());hashPacket(checksum,table.textureCopies());hashPacket(checksum,table.depthMipSources());
        hashPacket(checksum,table.clusterRecords());hashPacket(checksum,table.clusterMaterials());hashPacket(checksum,table.clusterLights());hashPacket(checksum,table.clusterProjections());
        if(run&&expected!=checksum)return 2;expected=checksum;
    }
    auto sorted=samples;std::sort(sorted.begin(),sorted.end());
    std::printf("{\"scenario\":%u,\"material\":\"%s\",\"draws\":640,\"variants\":16,\"stateLayers\":6,\"warmups\":2,\"medianMs\":%.6f,\"checksum\":\"%016llx\",\"samplesMs\":[",
        scenario,names[scenario],sorted[4],(unsigned long long)expected);
    for(unsigned k=0;k<samples.size();k++)std::printf("%s%.6f",k?",":"",samples[k]);
    std::puts("]}");
}
