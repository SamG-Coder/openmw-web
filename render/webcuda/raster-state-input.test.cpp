// Real OSG state producers. The saved packet stream is replayed by the native
// CUDA raster/binner test; expected normalization lives only in that test.
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <vector>
#include <emscripten.h>
#include <osg/AlphaFunc>
#include <osg/BlendColor>
#include <osg/BlendFunc>
#include <osg/Depth>
#include <osg/Fog>
#include <osg/Multisample>
#include <osg/Scissor>
#include <osg/StencilTwoSided>
#include <osg/TexEnv>
#include <osg/TexEnvCombine>
#include <components/webcuda/materialtable.hpp>

namespace {
    using State=osg::StateAttribute;
    std::vector<unsigned int> fixtures{0x52535431u,0u};
    unsigned int bits(float value){unsigned int result;std::memcpy(&result,&value,4);return result;}
    float floating(unsigned int value){float result;std::memcpy(&result,&value,4);return result;}
    void append(const void* data,std::size_t words) {
        const auto start=fixtures.size();fixtures.resize(start+words);
        if(words)std::memcpy(fixtures.data()+start,data,words*4);
    }
    void capture(osg::StateSet& state,float alpha=.5f,unsigned int samples=1) {
        WebCuda::DrawContext context;context.states={&state};
        WebCuda::MaterialTable table(35,19);
        const auto id=table.encode(context),again=table.encode(context);
        assert(id==again&&table.materials().size()==12&&table.rasterParams().size()==50);
        const auto& material=table.materials();const auto& params=table.rasterParams();
        if(const auto* scissor=dynamic_cast<const osg::Scissor*>(state.getAttribute(State::SCISSOR))) {
            assert(material[3]&16777216u);
            assert(material[5]==static_cast<unsigned int>(scissor->x())&&material[6]==static_cast<unsigned int>(scissor->y()));
            assert(material[7]==static_cast<unsigned int>(scissor->width())&&material[8]==static_cast<unsigned int>(scissor->height()));
        }
        if(const auto* func=dynamic_cast<const osg::AlphaFunc*>(state.getAttribute(State::ALPHAFUNC)))assert(material[4]==bits(func->getReferenceValue()));
        if(const auto* depth=dynamic_cast<const osg::Depth*>(state.getAttribute(State::DEPTH))) {
            assert(params[2]==static_cast<float>(depth->getZNear())&&params[3]==static_cast<float>(depth->getZFar()));
        }
        if(const auto* blend=dynamic_cast<const osg::BlendColor*>(state.getAttribute(State::BLENDCOLOR)))
            for(unsigned int k=0;k<4;k++)assert(params[4+k]==blend->getConstantColor()[k]);
        if(const auto* coverage=dynamic_cast<const osg::Multisample*>(state.getAttribute(State::MULTISAMPLE)))assert(params[24]==coverage->getCoverage());
        if(const auto* stencil=dynamic_cast<const osg::StencilTwoSided*>(state.getAttribute(State::STENCIL))) {
            assert(params[9]==static_cast<float>(stencil->getFunctionRef(osg::StencilTwoSided::FRONT)));
            assert(params[16]==static_cast<float>(stencil->getFunctionRef(osg::StencilTwoSided::BACK)));
        }
        if(const auto* fog=dynamic_cast<const osg::Fog*>(state.getAttribute(State::FOG)))
            for(unsigned int k=0;k<4;k++)assert(table.texels().at(bits(params[23])+4+k)==bits(fog->getColor()[k]));
        if(material[3]&16384u) {
            const auto* env=dynamic_cast<const osg::TexEnv*>(state.getTextureAttribute(0,State::TEXENV));
            const auto* combine=dynamic_cast<const osg::TexEnvCombine*>(state.getTextureAttribute(0,State::TEXENV));
            for(unsigned int k=0;k<4;k++)assert(floating(table.texels().at(material[0]+4+k))==(env?env->getColor()[k]:combine->getConstantColor()[k]));
        }
        fixtures[1]++;fixtures.insert(fixtures.end(),{static_cast<unsigned int>(table.texels().size()),samples,bits(alpha)});
        append(material.data(),12);append(params.data(),50);append(table.texels().data(),table.texels().size());
    }
    osg::ref_ptr<osg::StateSet> state() {return new osg::StateSet;}
    template<class Action> void reject(Action action) {
        auto invalid=state();action(*invalid);bool failed=false;
        try {capture(*invalid);} catch(const std::runtime_error&){failed=true;}
        assert(failed);
    }
}
int main() {
    const int low=std::numeric_limits<int>::min(),high=std::numeric_limits<int>::max();
    const int scissors[][4]={{0,0,35,19},{-2,1,6,4},{0,0,35,1},{0,18,35,1},{34,0,1,19},
        {15,15,2,2},{32,16,3,3},{-2,-2,3,3},{-4,-4,3,3},{35,0,1,19},{0,19,35,1},
        {0,0,0,19},{0,0,35,0},{low,low,high,high},{high,high,high,high},
        {-1,-1,high,high},{-high+5,-high+3,high,high},{high-5,high-3,high,high}};
    for(const auto& rect:scissors)for(unsigned int samples:{1u,4u,16u}) {
        auto source=state();source->setAttributeAndModes(new osg::Scissor(rect[0],rect[1],rect[2],rect[3]),State::ON);
        capture(*source,.5f,samples);
    }
    const float infinity=std::numeric_limits<float>::infinity(),nan=std::numeric_limits<float>::quiet_NaN();
    for(float reference:{-4.f,.375f,4.f,-infinity,infinity})for(float alpha:{0.f,.5f,1.f})for(unsigned int function=GL_NEVER;function<=GL_ALWAYS;function++) {
        auto source=state();source->setAttributeAndModes(new osg::AlphaFunc(static_cast<osg::AlphaFunc::ComparisonFunction>(function),reference),State::ON);
        capture(*source,alpha);
    }
    const float ranges[][2]={{-4,3},{.8f,-.25f},{-4,-2},{2,4},{-infinity,infinity},{infinity,-infinity}};
    for(const auto& range:ranges) {
        auto source=state();source->setAttributeAndModes(new osg::Depth(osg::Depth::ALWAYS,range[0],range[1],true),State::ON);capture(*source);
    }
    for(const auto& color:{osg::Vec4(-4,.375,3,2),osg::Vec4(-infinity,infinity,.25,-infinity)})
    for(unsigned int factor:{GL_CONSTANT_COLOR,GL_ONE_MINUS_CONSTANT_COLOR,GL_CONSTANT_ALPHA,GL_ONE_MINUS_CONSTANT_ALPHA}) {
        auto source=state();source->setAttribute(new osg::BlendColor(color));
        source->setAttributeAndModes(new osg::BlendFunc(factor,GL_ONE_MINUS_SRC_ALPHA,factor,GL_ONE_MINUS_SRC_ALPHA),State::ON);capture(*source);
    }
    for(float coverage:{-10.f,0.f,.4f,1.f,10.f})for(bool invert:{false,true})for(unsigned int samples:{1u,4u,16u}) {
        auto source=state();auto* sample=new osg::Multisample;sample->setSampleCoverage(coverage,invert);
        source->setAttribute(sample);source->setMode(0x80A0,State::ON);capture(*source,.5f,samples);
    }
    for(int reference:{low,-1,0,127,255,256,high})for(unsigned int function=GL_NEVER;function<=GL_ALWAYS;function++) {
        auto source=state();auto* stencil=new osg::StencilTwoSided;
        stencil->setFunction(osg::StencilTwoSided::FRONT,static_cast<osg::StencilTwoSided::Function>(function),reference,255);
        stencil->setFunction(osg::StencilTwoSided::BACK,static_cast<osg::StencilTwoSided::Function>(function),reference==low?high:-reference,255);
        for(const auto face:{osg::StencilTwoSided::FRONT,osg::StencilTwoSided::BACK})
            stencil->setOperation(face,osg::StencilTwoSided::REPLACE,osg::StencilTwoSided::INVERT,osg::StencilTwoSided::REPLACE);
        source->setAttributeAndModes(stencil,State::ON);capture(*source);
    }
    for(const auto mode:{osg::Fog::LINEAR,osg::Fog::EXP,osg::Fog::EXP2}) {
        auto source=state();auto* fog=new osg::Fog;fog->setMode(mode);fog->setDensity(.5);fog->setStart(0);fog->setEnd(2);
        fog->setColor({-4,.375,3,2});source->setAttributeAndModes(fog,State::ON);capture(*source);
    }
    osg::ref_ptr<osg::Image> image=new osg::Image;image->allocateImage(1,1,1,GL_RGBA,GL_UNSIGNED_BYTE);
    const unsigned int pixel=0x8073bf40u;std::memcpy(image->data(),&pixel,4);
    osg::ref_ptr<osg::Texture2D> texture=new osg::Texture2D(image);
    texture->setFilter(osg::Texture::MIN_FILTER,osg::Texture::NEAREST);texture->setFilter(osg::Texture::MAG_FILTER,osg::Texture::NEAREST);
    for(bool combine:{false,true})for(const auto& color:{osg::Vec4(-4,.375,3,2),osg::Vec4(-infinity,infinity,.25,-infinity)}) {
        if(combine&&!std::isfinite(color[0]))continue;
        auto source=state();source->setTextureAttributeAndModes(0,texture,State::ON);
        if(combine) {
            auto* env=new osg::TexEnvCombine;env->setConstantColor(color);env->setCombine_RGB(osg::TexEnvCombine::INTERPOLATE);
            env->setSource0_RGB(osg::TexEnvCombine::CONSTANT);env->setSource1_RGB(osg::TexEnvCombine::PRIMARY_COLOR);
            env->setSource2_RGB(osg::TexEnvCombine::TEXTURE);env->setCombine_Alpha(osg::TexEnvCombine::REPLACE);
            env->setSource0_Alpha(osg::TexEnvCombine::CONSTANT);source->setTextureAttribute(0,env);
        } else {auto* env=new osg::TexEnv(osg::TexEnv::BLEND);env->setColor(color);source->setTextureAttribute(0,env);}
        capture(*source);
    }
    reject([](auto& s){s.setAttributeAndModes(new osg::Scissor(0,0,-1,2),State::ON);});
    reject([&](auto& s){s.setAttributeAndModes(new osg::AlphaFunc(osg::AlphaFunc::LESS,nan),State::ON);});
    reject([&](auto& s){s.setAttribute(new osg::BlendColor({nan,0,0,0}));});
    reject([&](auto& s){s.setAttribute(new osg::Depth(osg::Depth::LESS,nan,1));});
    reject([&](auto& s){auto* sample=new osg::Multisample;sample->setSampleCoverage(infinity,false);s.setAttribute(sample);s.setMode(0x80A0,State::ON);});
    reject([&](auto& s){auto* fog=new osg::Fog;fog->setColor({infinity,0,0,1});s.setAttributeAndModes(fog,State::ON);});
    reject([&](auto& s){s.setTextureAttributeAndModes(0,texture,State::ON);auto* env=new osg::TexEnv;env->setColor({nan,0,0,1});s.setTextureAttribute(0,env);});
    reject([&](auto& s){s.setTextureAttributeAndModes(0,texture,State::ON);auto* env=new osg::TexEnvCombine;env->setConstantColor({infinity,0,0,1});s.setTextureAttribute(0,env);});
    EM_ASM({if(process.env.WEBCUDA_RASTER_FIXTURES)require('fs').writeFileSync(process.env.WEBCUDA_RASTER_FIXTURES,
        HEAPU8.subarray(Number($0),Number($0)+Number($1)));},fixtures.data(),fixtures.size()*4);
    std::printf("Raw raster state: %u real producer fixtures, raw GL scissor, alpha, depth, blend, coverage, stencil, fog and texture environment values passed\n",fixtures[1]);
}
