// Capture original OSG matrix pairs, then compare CUDA preparation with OSG's
// preceding double-precision composition. Float GPU inputs use a bounded error.
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#include <emscripten.h>
#include <osg/Geometry>
#include <osg/Light>
#include <osg/TexGen>
#include <osgUtil/RenderLeaf>
#include <osgUtil/RenderStage>
#include <osgUtil/StateGraph>
#include <components/webcuda/geometrypacket.hpp>

namespace Reference {
    struct Dim {unsigned int x=0,y=0;};
    Dim blockIdx,blockDim{1,0},threadIdx,gridDim{1,0};
    float __uint_as_float(unsigned int word){float v;std::memcpy(&v,&word,4);return v;}
    unsigned int __float_as_uint(float value){unsigned int w;std::memcpy(&w,&value,4);return w;}
#define __device__
#define __global__
#include "positioned-state.cu"
#undef __device__
#undef __global__
}
namespace {
    struct Sink : WebCuda::SubmissionSink {
        WebCuda::GeometryPacket packet;
        std::vector<std::uint32_t> expectedFixed,expectedTexgen;
        unsigned int leaves=0;
        osg::Matrixd application,post,replacement;
        bool checkLeaves=false;
        void beginPass(const osgUtil::RenderStage&) override {}
        void endPass(const osgUtil::RenderStage&) override {}
        void gui(const osg::Array&,std::size_t,const osg::Texture2D*,const WebCuda::DrawContext&) override {assert(false);}
        void geometry(const osg::Geometry& g,const WebCuda::DrawContext& c) override {
            if(checkLeaves) {
                const bool inherited=leaves<2;
                assert(*c.lightModelView[0]==(inherited?application:replacement));
                assert(*c.texgenModelView[0]==(inherited?application:replacement));
                assert(bool(c.lightModelViewPost[0])==inherited&&bool(c.texgenModelViewPost[0])==inherited);
                if(inherited)assert(*c.lightModelViewPost[0]==post&&*c.texgenModelViewPost[0]==post);
                leaves++;
            }
            const auto fixed=packet.fixedLighting.size(),texgen=packet.texgen.size();
            WebCuda::appendGeometry(packet,g,c,0);
            expectedFixed.insert(expectedFixed.end(),packet.fixedLighting.begin()+fixed,packet.fixedLighting.end());
            expectedTexgen.insert(expectedTexgen.end(),packet.texgen.begin()+texgen,packet.texgen.end());
            auto store=[](auto& destination,std::size_t offset,const osg::Matrixd& a,const osg::Matrixd& b){
                const osg::Matrixd composed=a*b;
                for(unsigned int k=0;k<16;k++)destination[offset+k]=Reference::__float_as_uint(static_cast<float>(composed.ptr()[k]));
            };
            for(unsigned int light=0;light<8;light++)if(c.lightModelViewPost[light])
                store(expectedFixed,fixed+48+light*40+24,*c.lightModelView[light],*c.lightModelViewPost[light]);
            for(unsigned int unit=0;unit<4;unit++)if(c.texgenModelViewPost[unit])
                store(expectedTexgen,texgen+unit*36+20,*c.texgenModelView[unit],*c.texgenModelViewPost[unit]);
        }
    };
    void compare(const auto& actual,const auto& expected,unsigned int stride,unsigned int first,unsigned int matrices,unsigned int step) {
        assert(actual.size()==expected.size());
        for(std::size_t i=0;i<actual.size();i++)if(actual[i]!=expected[i]) {
            bool matrix=false;for(unsigned int k=0;k<matrices;k++)matrix|=i%stride>=first+k*step&&i%stride<first+k*step+16;
            assert(matrix); // Headers, colors, planes and padding must be bit-exact.
            const auto a=Reference::__uint_as_float(actual[i]),e=Reference::__uint_as_float(expected[i]);
            assert(std::isfinite(a)&&std::fabs(a-e)<=2e-5f*std::max(1.f,std::fabs(e)));
        }
    }
}
int main() {
    osg::ref_ptr<osg::Geometry> geometry=new osg::Geometry;
    osg::ref_ptr<osg::Vec3Array> vertices=new osg::Vec3Array(3);
    geometry->setVertexArray(vertices);geometry->addPrimitiveSet(new osg::DrawArrays(GL_TRIANGLES,0,3));
    osg::ref_ptr<osg::StateSet> state=new osg::StateSet;
    state->setMode(GL_LIGHTING,osg::StateAttribute::ON);state->setMode(GL_LIGHT0,osg::StateAttribute::ON);
    state->setTextureMode(0,GL_TEXTURE_GEN_S,osg::StateAttribute::ON);
    osg::ref_ptr<osg::Light> light=new osg::Light(0);
    osg::ref_ptr<osg::TexGen> texgen=new osg::TexGen;texgen->setMode(osg::TexGen::EYE_LINEAR);
    osg::ref_ptr<osgUtil::RenderStage> stage=new osgUtil::RenderStage;
    osg::ref_ptr<osgUtil::PositionalStateContainer> inherited=new osgUtil::PositionalStateContainer;
    Sink sink;sink.checkLeaves=true;
    sink.application=osg::Matrixd::scale(2,3,4)*osg::Matrixd::translate(11,-7,5);
    sink.post=osg::Matrixd::rotate(.4,osg::Vec3d(1,2,3))*osg::Matrixd::translate(-3,6,2);
    sink.replacement=osg::Matrixd::translate(1,2,3);
    inherited->addPositionedAttribute(new osg::RefMatrix(sink.application),light);
    inherited->addPositionedTextureAttribute(0,new osg::RefMatrix(sink.application),texgen);
    stage->setInheritedPositionalStateContainer(inherited);stage->setInheritedPositionalStateContainerMatrix(sink.post);
    osg::ref_ptr<osg::StateSet> replaced=new osg::StateSet;
    replaced->setAttribute(new osg::Light(0));
    osg::ref_ptr<osg::TexGen> replacementTexgen=new osg::TexGen;replacementTexgen->setMode(osg::TexGen::EYE_LINEAR);
    replaced->setTextureAttribute(0,replacementTexgen);
    osg::ref_ptr<osgUtil::StateGraph> graph=new osgUtil::StateGraph(nullptr,replaced);
    std::vector<osg::ref_ptr<osgUtil::RenderLeaf>> leaves;
    for(unsigned int i=0;i<4;i++) {
        auto matrix=i==2?sink.replacement:osg::Matrixd::translate(i*31,0,0);
        osg::ref_ptr<osgUtil::RenderLeaf> leaf=new osgUtil::RenderLeaf(geometry,new osg::RefMatrix,new osg::RefMatrix(matrix));
        if(i>=2)leaf->_parent=graph;
        stage->getRenderLeafList().push_back(leaf);leaves.push_back(leaf);
    }
    WebCuda::submitStage(*stage,sink,{state});assert(sink.leaves==4);
    // Additional draws exercise every light/unit, offsets after earlier draws,
    // identity, non-affine matrices and repeated changes at the same addresses.
    sink.checkLeaves=false;
    osg::Matrixd identity,application,post;
    WebCuda::DrawContext context;context.modelView=&identity;context.projection=&identity;context.states={state};
    for(unsigned int i=0;i<8;i++) {
        state->setAttribute(new osg::Light(i));state->setMode(GL_LIGHT0+i,osg::StateAttribute::ON);
        context.lightModelView[i]=&application;context.lightModelViewPost[i]=&post;
    }
    for(unsigned int unit=0;unit<4;unit++) {
        state->setTextureAttribute(unit,texgen);state->setTextureMode(unit,GL_TEXTURE_GEN_S,osg::StateAttribute::ON);
        context.texgenModelView[unit]=&application;context.texgenModelViewPost[unit]=&post;
    }
    std::mt19937 random(74021);std::uniform_real_distribution<double> values(-4,4);
    for(unsigned int draw=0;draw<128;draw++) {
        for(unsigned int k=0;k<16;k++){application.ptr()[k]=values(random);post.ptr()[k]=draw?values(random):(k%5==0?1:0);}
        sink.geometry(*geometry,context);
    }
    const auto draws=static_cast<unsigned int>(sink.packet.matrices.size()/32);
    auto fixed=sink.packet.fixedLighting,generated=sink.packet.texgen;
    for(Reference::blockIdx.x=0;Reference::blockIdx.x<draws*8+17;Reference::blockIdx.x++)
        Reference::prepare_fixed_matrices(fixed.data(),sink.packet.positionedState.data(),draws);
    for(Reference::blockIdx.x=0;Reference::blockIdx.x<draws*4+17;Reference::blockIdx.x++)
        Reference::prepare_texgen_matrices(generated.data(),sink.packet.positionedState.data(),draws);
    compare(fixed,sink.expectedFixed,368,72,8,40);compare(generated,sink.expectedTexgen,36,20,1,0);
    // Export captured input and independent OSG results for direct native GPU checks.
    std::vector<std::uint32_t> fixture{0x50535431u,draws,static_cast<unsigned int>(fixed.size()),
        static_cast<unsigned int>(generated.size()),static_cast<unsigned int>(sink.packet.positionedState.size())};
    for(const auto* words:{&sink.packet.fixedLighting,&sink.packet.texgen,&sink.packet.positionedState,&sink.expectedFixed,&sink.expectedTexgen})
        fixture.insert(fixture.end(),words->begin(),words->end());
    EM_ASM({if(process.env.WEBCUDA_POSITIONED_FIXTURES)
        require('fs').writeFileSync(process.env.WEBCUDA_POSITIONED_FIXTURES,HEAPU8.subarray(Number($0),Number($0)+Number($1)));},fixture.data(),fixture.size()*4);
    std::printf("Positioned CUDA state: %u captured draws, inherited matrix order, identity persistence, replacement reset and all light/TexGen slots passed\n",draws);
}
