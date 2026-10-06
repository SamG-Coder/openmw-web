// Compare scoped capture with a fresh OSG merge, including state-stack changes
// and mutation boundaries in the real submission path.
#include <cassert>
#include <cstdio>
#include <stdexcept>
#include <osg/BlendFunc>
#include <osg/Depth>
#include <osg/Geometry>
#include <osg/Program>
#include <osg/Shader>
#include <osg/Texture2D>
#include <osg/Uniform>
#include <osgUtil/RenderLeaf>
#include <osgUtil/RenderStage>
#include <components/webcuda/geometrypacket.hpp>
#include <components/webcuda/materialtable.hpp>

namespace {
    osg::ref_ptr<osg::StateSet> fresh(const WebCuda::DrawContext& context) {
        osg::ref_ptr<osg::StateSet> state=new osg::StateSet;
        for(const auto* source:context.states)if(source)state->merge(*source);
        if(const auto* program=dynamic_cast<const osg::Program*>(state->getAttribute(osg::StateAttribute::PROGRAM)))
            if(!program->getNumShaders())state->removeAttribute(osg::StateAttribute::PROGRAM);
        return state;
    }
    void equivalent(const WebCuda::DrawContext& context) {
        const auto actual=WebCuda::resolveState(context);const auto expected=fresh(context);
        assert(actual->compare(*expected,true)==0);
        assert(WebCuda::encodeRasterState(*actual,64,32)==WebCuda::encodeRasterState(*expected,64,32));
    }
    void scopes() {
        using A=osg::StateAttribute;
        osg::ref_ptr<osg::StateSet> parent=new osg::StateSet,child=new osg::StateSet,replacement=new osg::StateSet;
        parent->setMode(GL_BLEND,A::ON|A::OVERRIDE);child->setMode(GL_BLEND,A::OFF);
        parent->setAttribute(new osg::Depth(osg::Depth::LESS),A::OVERRIDE);
        child->setAttribute(new osg::Depth(osg::Depth::GEQUAL),A::PROTECTED);
        parent->addUniform(new osg::Uniform("alpha",.25f),A::OVERRIDE);
        child->addUniform(new osg::Uniform("alpha",.75f));
        parent->setDefine("FEATURE","parent",A::OVERRIDE);child->setDefine("FEATURE","child",A::PROTECTED);
        parent->setTextureAttribute(0,new osg::Texture2D,A::OVERRIDE);
        child->setTextureAttribute(0,new osg::Texture2D,A::PROTECTED);
        replacement->setMode(GL_BLEND,A::OFF|A::PROTECTED);
        replacement->setAttribute(new osg::Depth(osg::Depth::ALWAYS),A::PROTECTED);
        osg::ref_ptr<osg::Program> program=new osg::Program;
        program->addShader(new osg::Shader(osg::Shader::VERTEX,"void main() {}"));
        parent->setAttribute(program,A::OVERRIDE);
        replacement->setAttribute(new osg::Program,A::PROTECTED);
        WebCuda::DrawContext context;context.states={parent,nullptr,child};
        osg::ref_ptr<const osg::StateSet> previous;
        {
            WebCuda::ResolvedStateScope capture(context);equivalent(context);
            previous=WebCuda::resolveState(context);
            for(unsigned i=0;i<4;i++)assert(WebCuda::resolveState(context)==previous);
            auto variant=context;variant.states.push_back(replacement);equivalent(variant);
            assert(!WebCuda::resolveState(variant)->getAttribute(A::PROGRAM));
            {
                WebCuda::ResolvedStateScope nested(variant);equivalent(variant);
                auto changed=variant;changed.states[0]=replacement;equivalent(changed);
                changed.states={child,parent};equivalent(changed);
                changed.states.clear();equivalent(changed);
                assert(WebCuda::resolveState(context)==previous);
            }
            variant.states.pop_back();assert(WebCuda::resolveState(variant)==previous);
            try {WebCuda::ResolvedStateScope nested(context);throw std::runtime_error("fixture");}
            catch(const std::runtime_error&) {}
            assert(WebCuda::resolveState(context)==previous);
        }
        assert(context.resolvedState==nullptr);
        // Same pointers and stack length, new structural values on the next draw.
        parent->setMode(GL_BLEND,A::OFF|A::OVERRIDE);parent->setDefine("FEATURE","changed");
        child->removeDefine("FEATURE");child->removeAttribute(A::DEPTH);
        parent->addUniform(new osg::Uniform("alpha",.125f),A::OVERRIDE);
        {
            WebCuda::ResolvedStateScope capture(context);equivalent(context);
            const auto state=WebCuda::resolveState(context);float alpha=0;state->getUniform("alpha")->get(alpha);
            assert(alpha==.125f&&!(state->getMode(GL_BLEND)&A::ON));
            assert(previous->getMode(GL_BLEND)&A::ON);
        }
        assert(context.resolvedState==nullptr);
    }
    struct Callback : osg::Drawable::DrawCallback,WebCuda::CustomDrawCallback {
        osg::ref_ptr<osg::StateSet> source;mutable unsigned calls=0;
        osg::ref_ptr<osg::StateSet> captureWebCudaState() const override {
            source->setMode(GL_BLEND,calls++%2?osg::StateAttribute::OFF:osg::StateAttribute::ON);
            return nullptr;
        }
    };
    struct Custom : osg::Drawable,WebCuda::CustomDrawable {
        osg::ref_ptr<osg::StateSet> source;osg::ref_ptr<osg::Geometry> shape;
        void submitWebCuda(WebCuda::SubmissionSink& sink,const WebCuda::DrawContext& context) const override {
            assert(context.resolvedState==nullptr);
            for(const auto mode:{osg::StateAttribute::OFF,osg::StateAttribute::ON}) {
                source->setMode(GL_BLEND,mode);sink.geometry(*shape,context);
            }
        }
    };
    struct Sink : WebCuda::SubmissionSink {
        WebCuda::MaterialTable table{64,32};WebCuda::GeometryPacket packet;
        std::vector<bool> blending;
        void beginPass(const osgUtil::RenderStage&) override {}
        void endPass(const osgUtil::RenderStage&) override {}
        void geometry(const osg::Geometry& geometry,const WebCuda::DrawContext& context) override {
            equivalent(context);
            const bool blend=(fresh(context)->getMode(GL_BLEND)&osg::StateAttribute::ON)!=0;
            const auto before=packet.triangles.size();
            WebCuda::captureGeometry(packet,geometry,context,[&](const auto& draw,const auto* texture,bool gui){
                equivalent(draw);return table.encode(draw,texture,gui);
            });
            const auto material=packet.triangles.at(before+3);
            assert(bool(table.materials()[material*12+3]&2u)==blend);blending.push_back(blend);
        }
        void gui(const osg::Array&,std::size_t,const osg::Texture2D*,const WebCuda::DrawContext&) override {assert(false);}
    };
    void submission() {
        osg::ref_ptr<osg::StateSet> source=new osg::StateSet;
        source->setAttribute(new osg::Program,osg::StateAttribute::OVERRIDE|osg::StateAttribute::PROTECTED);
        osg::ref_ptr<osg::Geometry> geometry=new osg::Geometry;
        auto* vertices=new osg::Vec3Array;
        vertices->push_back({-1,-1,0});vertices->push_back({1,-1,0});vertices->push_back({0,1,0});
        geometry->setVertexArray(vertices);geometry->addPrimitiveSet(new osg::DrawArrays(GL_TRIANGLES,0,3));
        osg::ref_ptr<Callback> callback=new Callback;callback->source=source;geometry->setDrawCallback(callback);
        osg::ref_ptr<Custom> custom=new Custom;custom->source=source;custom->shape=geometry;
        osg::ref_ptr<osgUtil::RenderStage> stage=new osgUtil::RenderStage;
        std::vector<osg::ref_ptr<osgUtil::RenderLeaf>> leaves;
        auto add=[&](osg::Drawable* drawable){
            osg::ref_ptr<osgUtil::RenderLeaf> leaf=new osgUtil::RenderLeaf(drawable,new osg::RefMatrix,new osg::RefMatrix);
            stage->getRenderLeafList().push_back(leaf);leaves.push_back(leaf);
        };
        add(geometry);add(geometry);add(geometry);add(custom);add(geometry);
        Sink sink;WebCuda::submitStage(*stage,sink,{source});
        assert((sink.blending==std::vector<bool>{true,false,true,false,true,false}));
        assert(callback->calls==4);
    }
}
int main() {
    scopes();submission();
    std::puts("Draw state: fresh OSG equivalence, scoped reuse, variants, overrides, empty programs, exceptions, later edits and custom-draw mutation boundaries passed");
}
