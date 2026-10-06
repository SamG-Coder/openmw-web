// Actual OSG producers, retained draw state and independent dense references.
#include <cassert>
#include <cstdio>
#include <limits>
#include <osg/Geometry>
#include <osg/Material>
#include <osgUtil/RenderLeaf>
#include <osgUtil/RenderStage>
#include <osgParticle/ConnectedParticleSystem>
#include <components/webcuda/geometrypacket.hpp>
#include "vertex-input-reference.hpp"

namespace {
    osg::ref_ptr<osg::Geometry> geometry(unsigned int count=258,GLenum mode=GL_TRIANGLES) {
        osg::ref_ptr<osg::Geometry> result=new osg::Geometry;
        auto* positions=new osg::Vec3Array;
        for(unsigned int i=0;i<count;i++)positions->push_back({float(i%13)*.125f-.5f,float(i%7)*.25f-1.f,0.f});
        result->setVertexArray(positions);result->addPrimitiveSet(new osg::DrawArrays(mode,0,count));return result;
    }
    struct Colors {
        osg::ref_ptr<osg::Vec3ubArray> rgb=new osg::Vec3ubArray,secondary=new osg::Vec3ubArray;
        osg::ref_ptr<osg::Vec4ubArray> rgba=new osg::Vec4ubArray;
        Colors() {
            for(unsigned int i=0;i<258;i++) {
                rgb->push_back(osg::Vec3ub(i&255u,(255u-i)&255u,(i+73u)&255u));
                rgba->push_back(osg::Vec4ub((*rgb)[i][0],(*rgb)[i][1],(*rgb)[i][2],(i*37u)&255u));
                secondary->push_back(osg::Vec3ub((i+31u)&255u,(i*17u)&255u,(i+254u)&255u));
            }
        }
    };
    void arrays() {
        osg::Matrixd matrix;
        WebCuda::DrawContext context{&matrix,&matrix,{}};
        context.hasCurrentColor=true;context.currentColor[0]=1.5f;context.currentColor[3]=.375f;
        context.currentSecondaryColor[1]=.125f;
        for(unsigned int channels:{3u,4u})for(const auto binding:{osg::Array::BIND_PER_VERTEX,osg::Array::BIND_OVERALL,osg::Array::BIND_PER_PRIMITIVE_SET})
        for(const auto mode:{GL_TRIANGLES,GL_LINES,GL_POINTS}) {
            auto source=geometry(258,mode);Colors colors;
            source->setColorArray(channels==3?static_cast<osg::Array*>(colors.rgb.get()):colors.rgba.get(),binding);
            source->setSecondaryColorArray(colors.secondary,binding);
            if(binding==osg::Array::BIND_PER_PRIMITIVE_SET)source->addPrimitiveSet(new osg::DrawArrays(mode,0,258));
            WebCuda::GeometryPacket compact(true),dense;
            for(unsigned int repeat=0;repeat<2;repeat++)for(auto* packet:{&compact,&dense})WebCuda::appendGeometry(*packet,*source,context,2);
            const auto draws=compact.vertexLayouts.size()/32;
            for(unsigned int d=0;d<draws;d++) {
                const auto* layout=compact.vertexLayouts.data()+d*32;
                assert(layout[28]==channels&&layout[29]==3&&layout[30]==0);
                const auto index=binding==osg::Array::BIND_PER_PRIMITIVE_SET?d%2:0;
                assert(compact.vertexInputs[layout[10]+1]==(*colors.rgb)[index][1]);
                if(channels==3)assert(compact.vertexInputs[layout[10]+3]==1.f); // Implicit alpha is already a float.
            }
            if(binding==osg::Array::BIND_PER_VERTEX) {
                assert(compact.vertexLayouts[10]==compact.vertexLayouts[42]); // Shared immutable raw color stream.
                assert(compact.vertexLayouts[12]==compact.vertexLayouts[44]);
            }
            VertexInputReference::verify(compact,dense);
            const auto captured=compact.vertexInputs;
            (*colors.rgb)[0].set(254,73,128);(*colors.rgba)[0].set(254,73,128,191);(*colors.secondary)[0].set(127,128,129);
            WebCuda::GeometryPacket changed(true),changedDense;
            for(auto* packet:{&changed,&changedDense})WebCuda::appendGeometry(*packet,*source,context,2);
            VertexInputReference::verify(changed,changedDense);
            assert(compact.vertexInputs==captured&&changed.vertexInputs[changed.vertexLayouts[10]]==254);
            if(binding==osg::Array::BIND_PER_VERTEX) {
                assert(changed.vertexResources[0]==compact.vertexResources[0]); // Position version survives color edits.
                assert(changed.vertexResources[3]!=compact.vertexResources[3]);
            }
        }
        // A disabled byte array must not tag unrelated floating current values.
        auto source=geometry(6);Colors colors;source->setColorArray(colors.rgba,osg::Array::BIND_OFF);
        source->setSecondaryColorArray(colors.secondary,osg::Array::BIND_OFF);
        for(unsigned int channels:{0u,3u,4u}) {
            context.currentColorByteComponents=channels;context.currentSecondaryByteComponents=channels?3u:0u;
            context.currentColor[0]=channels?254.f:1.5f;context.currentColor[1]=channels?128.f:-.25f;
            context.currentColor[2]=channels?73.f:.125f;context.currentColor[3]=channels==4?191.f:.375f;
            context.currentSecondaryColor[0]=channels?254.f:-.125f;
            context.currentSecondaryColor[1]=channels?128.f:.5f;context.currentSecondaryColor[2]=channels?1.f:2.f;
            WebCuda::GeometryPacket compact(true),dense;
            for(auto* packet:{&compact,&dense})WebCuda::appendGeometry(*packet,*source,context,2);
            assert(compact.vertexLayouts[28]==channels&&compact.vertexLayouts[29]==(channels?3u:0u));
            VertexInputReference::verify(compact,dense);
        }
        // Generated line/point vertices use the retained secondary format,
        // independently of an explicit floating secondary stream.
        context.currentSecondaryByteComponents=3;
        auto* floats=new osg::Vec3Array(6);for(auto& value:*floats)value.set(.25,.5,.75);
        source->setSecondaryColorArray(floats,osg::Array::BIND_PER_VERTEX);
        for(const auto mode:{GL_LINES,GL_POINTS}) {
            source->setPrimitiveSet(0,new osg::DrawArrays(mode,0,6));
            WebCuda::GeometryPacket compact(true),dense;
            for(auto* packet:{&compact,&dense})WebCuda::appendGeometry(*packet,*source,context,2);
            assert(compact.vertexLayouts[29]==0&&compact.vertexLayouts[30]==3);
            VertexInputReference::verify(compact,dense);
        }
        for(unsigned int invalid:{1u,2u,5u})for(bool compact:{false,true}) {
            context.currentColorByteComponents=invalid;WebCuda::GeometryPacket packet(compact);bool rejected=false;
            try {WebCuda::appendGeometry(packet,*source,context,0);}catch(const std::runtime_error&){rejected=true;}
            assert(rejected&&packet.vertexCount()==0);
        }
        context.currentColorByteComponents=4;context.currentColor[0]=255.5f;
        for(bool compact:{false,true}) {
            WebCuda::GeometryPacket packet(compact);bool rejected=false;
            try {WebCuda::appendGeometry(packet,*source,context,0);}catch(const std::runtime_error&){rejected=true;}
            assert(rejected&&packet.vertexCount()==0);
        }
    }
    struct Sink : WebCuda::SubmissionSink {
        WebCuda::GeometryPacket compact{true},dense;
        std::vector<unsigned int> primaryFormats,secondaryFormats;
        void beginPass(const osgUtil::RenderStage&) override {}
        void endPass(const osgUtil::RenderStage&) override {VertexInputReference::verify(compact,dense);}
        void geometry(const osg::Geometry& source,const WebCuda::DrawContext& context) override {
            primaryFormats.push_back(context.currentColorByteComponents);secondaryFormats.push_back(context.currentSecondaryByteComponents);
            for(auto* packet:{&compact,&dense})WebCuda::appendGeometry(*packet,source,context,0);
        }
        void gui(const osg::Array&,std::size_t,const osg::Texture2D*,const WebCuda::DrawContext&) override {assert(false);}
    };
    void retained() {
        for(unsigned int channels:{3u,4u})for(const auto binding:{osg::Array::BIND_OVERALL,osg::Array::BIND_PER_PRIMITIVE_SET}) {
            Colors colors;auto first=geometry(3),next=geometry(3);
            first->setColorArray(channels==3?static_cast<osg::Array*>(colors.rgb.get()):colors.rgba.get(),binding);
            first->setSecondaryColorArray(colors.secondary,binding);
            if(binding==osg::Array::BIND_PER_PRIMITIVE_SET)first->addPrimitiveSet(new osg::DrawArrays(GL_TRIANGLES,0,3));
            osg::ref_ptr<osgUtil::RenderStage> stage=new osgUtil::RenderStage;
            osg::ref_ptr<osgUtil::RenderLeaf> a=new osgUtil::RenderLeaf(first,new osg::RefMatrix,new osg::RefMatrix);
            osg::ref_ptr<osgUtil::RenderLeaf> b=new osgUtil::RenderLeaf(next,new osg::RefMatrix,new osg::RefMatrix);
            stage->getRenderLeafList()={a.get(),b.get()};Sink sink;WebCuda::submitStage(*stage,sink,{});
            assert(sink.primaryFormats[0]==0&&sink.primaryFormats[1]==channels&&sink.secondaryFormats[1]==3);
            const auto last=binding==osg::Array::BIND_PER_PRIMITIVE_SET?1u:0u;
            assert(sink.currentAttributes.color[1]==(*colors.rgb)[last][1]);
            assert(sink.currentAttributes.secondaryColor[2]==(*colors.secondary)[last][2]);
            // Retention survives a pass/frame boundary; applying a material
            // resets primary format to float while secondary remains retained.
            stage->getRenderLeafList()={b.get()};WebCuda::submitStage(*stage,sink,{});
            assert(sink.primaryFormats.back()==channels&&sink.secondaryFormats.back()==3);
            osg::ref_ptr<osg::StateSet> state=new osg::StateSet;
            osg::ref_ptr<osg::Material> material=new osg::Material;material->setDiffuse(osg::Material::FRONT_AND_BACK,{.125,.25,.375,.5});
            state->setAttribute(material);WebCuda::submitStage(*stage,sink,{state});
            assert(sink.primaryFormats.back()==0&&sink.secondaryFormats.back()==3);
            assert(sink.currentAttributes.color[1]==.25f);
            WebCuda::submitStage(*stage,sink,{});assert(sink.primaryFormats.back()==0);
        }
    }
    void particleFallbacks() {
        osg::Matrixd matrix;WebCuda::DrawContext context{&matrix,&matrix,{}};
        context.currentSecondaryByteComponents=3;
        context.currentSecondaryColor[0]=254;context.currentSecondaryColor[1]=128;context.currentSecondaryColor[2]=1;
        osg::ref_ptr<osgParticle::ParticleSystem> ordinary=new osgParticle::ParticleSystem;
        ordinary->setUseShaders(false);ordinary->createParticle(nullptr);
        osg::ref_ptr<osgParticle::ConnectedParticleSystem> ribbon=new osgParticle::ConnectedParticleSystem;
        ribbon->createParticle(nullptr)->setPosition({-1,0,0});ribbon->createParticle(nullptr)->setPosition({1,0,0});
        WebCuda::GeometryPacket compact(true),dense;
        for(const auto* source:{ordinary.get(),static_cast<osgParticle::ParticleSystem*>(ribbon.get())}) {
            for(auto* packet:{&compact,&dense})WebCuda::appendParticles(*packet,*source,context,0);
            assert(compact.vertexLayouts[compact.vertexLayouts.size()-3]==3);
            VertexInputReference::verify(compact,dense);
        }
    }
}
int main() {
    arrays();retained();particleFallbacks();VertexInputReference::save();
    std::puts("Raw vertex colors: byte RGB/RGBA, secondary colors, all levels, bindings, cache edits, inherited state, material resets, generated tails and particle/ribbon fallback passed");
}
