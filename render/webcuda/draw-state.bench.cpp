// Build this unchanged fixture against the preceding and current capture
// sources. Compare packet checksums before interpreting isolated CPU timings.
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <osg/Camera>
#include <osg/Geometry>
#include <osg/Material>
#include <osg/Program>
#include <osg/Shader>
#include <osg/Uniform>
#include <osgUtil/RenderLeaf>
#include <osgUtil/RenderStage>
#include <components/webcuda/geometrypacket.hpp>
#include <components/webcuda/materialtable.hpp>

template<class T> void hashPacket(std::uint64_t& result,const std::vector<T>& values) {
    for(const auto value:values) {
        std::uint32_t bits;static_assert(sizeof(value)==4);std::memcpy(&bits,&value,4);
        result^=bits;result*=1099511628211ull;
    }
}
struct Changes : osg::Drawable::DrawCallback,WebCuda::CustomDrawCallback {
    osg::ref_ptr<osg::StateSet> source;osg::ref_ptr<osg::Uniform> alpha;mutable unsigned draw=0;
    osg::ref_ptr<osg::StateSet> captureWebCudaState() const override {
        source->setMode(GL_CULL_FACE,draw%2?osg::StateAttribute::ON:osg::StateAttribute::OFF);
        alpha->set(float(draw++%32)/32.f);return nullptr;
    }
};
struct Sink : WebCuda::SubmissionSink {
    WebCuda::MaterialTable table{1280,720};WebCuda::GeometryPacket packet;
    void beginPass(const osgUtil::RenderStage&) override {}
    void endPass(const osgUtil::RenderStage&) override {}
    void geometry(const osg::Geometry& geometry,const WebCuda::DrawContext& context) override {
        WebCuda::captureGeometry(packet,geometry,context,[&](const auto& draw,const auto* texture,bool gui){return table.encode(draw,texture,gui);});
    }
    void gui(const osg::Array&,std::size_t,const osg::Texture2D*,const WebCuda::DrawContext&) override {std::abort();}
};
int main(int argc,char** argv) try {
    const unsigned scenario=argc>1?std::strtoul(argv[1],nullptr,10):0;
    if(scenario>2)return 1;
    std::vector<osg::ref_ptr<osg::StateSet>> owners;std::vector<const osg::StateSet*> states;
    for(unsigned layer=0;layer<6;layer++) {
        osg::ref_ptr<osg::StateSet> state=new osg::StateSet;
        for(unsigned i=0;i<8;i++)state->addUniform(new osg::Uniform(("input"+std::to_string(layer*8+i)).c_str(),float(i)));
        state->setDefine("LAYER"+std::to_string(layer),"1");owners.push_back(state);states.push_back(state);
    }
    osg::ref_ptr<osg::Image> image=new osg::Image;image->allocateImage(2,2,1,GL_RGBA,GL_UNSIGNED_BYTE);
    for(unsigned i=0;i<16;i++)image->data()[i]=i*15;
    osg::ref_ptr<osg::Texture2D> texture=new osg::Texture2D(image);
    texture->setFilter(osg::Texture::MIN_FILTER,osg::Texture::LINEAR);
    owners[0]->setTextureAttributeAndModes(0,texture);owners[0]->setAttribute(new osg::Material);
    osg::ref_ptr<osg::Program> program=new osg::Program;
    if(scenario==1) {
        osg::ref_ptr<osg::Shader> vertex=new osg::Shader(osg::Shader::VERTEX),fragment=new osg::Shader(osg::Shader::FRAGMENT);
        vertex->setName("objects.vert");fragment->setName("objects.frag");
        fragment->setUserValue("webcuda.defines",std::string("diffuseMap=1\nnormalMap=0\nspecularMap=0\nforcePPL=0\nreverseZ=0\n"));
        program->addShader(vertex);program->addShader(fragment);
    }
    owners[0]->setAttribute(program);
    osg::ref_ptr<Changes> changes=new Changes;changes->source=owners[1];changes->alpha=new osg::Uniform("alphaRef",0.f);
    owners[1]->addUniform(changes->alpha);
    osg::ref_ptr<osg::Geometry> geometry=new osg::Geometry;
    auto* vertices=new osg::Vec3Array;
    for(unsigned i=0;i<48;i++)vertices->push_back({float(i%3)-1.f,float(i/3%2)-.5f,0});
    geometry->setVertexArray(vertices);geometry->addPrimitiveSet(new osg::DrawArrays(GL_TRIANGLES,0,48));
    if(scenario==2) {
        geometry->addPrimitiveSet(new osg::DrawArrays(GL_LINES,0,8));
        geometry->addPrimitiveSet(new osg::DrawArrays(GL_POINTS,0,4));
    }
    geometry->setDrawCallback(changes);
    osg::ref_ptr<osgUtil::RenderStage> stage=new osgUtil::RenderStage;
    osg::ref_ptr<osg::Camera> camera=new osg::Camera;stage->setCamera(camera);
    std::vector<osg::ref_ptr<osgUtil::RenderLeaf>> leaves;
    for(unsigned draw=0;draw<640;draw++) {
        osg::ref_ptr<osgUtil::RenderLeaf> leaf=new osgUtil::RenderLeaf(geometry,new osg::RefMatrix,new osg::RefMatrix);
        stage->getRenderLeafList().push_back(leaf);leaves.push_back(leaf);
    }
    std::vector<double> samples;std::uint64_t expected=0;
    for(unsigned run=0;run<11;run++) {
        Sink sink;changes->draw=0;
        const auto start=std::chrono::steady_clock::now();WebCuda::submitStage(*stage,sink,states);
        const auto ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
        if(run>=2)samples.push_back(ms);
        std::uint64_t checksum=1469598103934665603ull;
        const auto& p=sink.packet;const auto& t=sink.table;
        hashPacket(checksum,p.vertices);hashPacket(checksum,p.attributes);hashPacket(checksum,p.triangles);
        hashPacket(checksum,p.matrices);hashPacket(checksum,p.matrixIds);hashPacket(checksum,p.uvMatrices);
        hashPacket(checksum,p.texgen);hashPacket(checksum,p.fixedLighting);hashPacket(checksum,p.positionedState);
        hashPacket(checksum,p.flatColors);hashPacket(checksum,p.polygonEdges);
        hashPacket(checksum,p.screenPrimitives);hashPacket(checksum,p.secondaryColors);
        hashPacket(checksum,t.materials());hashPacket(checksum,t.rasterParams());hashPacket(checksum,t.texels());
        hashPacket(checksum,t.textureDecodes());hashPacket(checksum,t.textureResources());hashPacket(checksum,t.compressedBlocks());
        if(run&&checksum!=expected)return 2;expected=checksum;
    }
    auto ordered=samples;std::sort(ordered.begin(),ordered.end());
    const char* name=scenario==0?"fixed-triangles":scenario==1?"object-shader":"mixed-primitives";
    std::printf("{\"scenario\":\"%s\",\"draws\":640,\"verticesPerDraw\":48,\"stateLayers\":6,\"warmups\":2,\"medianMs\":%.6f,\"checksum\":\"%016llx\",\"samplesMs\":[",name,ordered[4],(unsigned long long)expected);
    for(unsigned i=0;i<samples.size();i++)std::printf("%s%.6f",i?",":"",samples[i]);std::puts("]}");
} catch(const std::exception& error) {
    std::fprintf(stderr,"Draw state benchmark failed: %s\n",error.what());return 3;
}
