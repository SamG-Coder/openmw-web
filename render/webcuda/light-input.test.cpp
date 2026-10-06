// Capture real OSG light uniforms and compare GPU preparation with the previous
// view-transform/fade/radius rules. The binary is replayed by light-input-gpu.test.cpp.
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <emscripten.h>
#include <osg/Program>
#include <osg/Shader>
#include <osg/ValueObject>
#include <components/webcuda/lightinputs.hpp>
#include <components/webcuda/materialtable.hpp>

namespace {
    std::vector<unsigned int> fixtures{0x4c495431u, 0u};
    unsigned int bits(float value) { unsigned int result; std::memcpy(&result, &value, 4); return result; }
    float floating(unsigned int value) { float result; std::memcpy(&result, &value, 4); return result; }
    void append(const std::vector<unsigned int>& words) { fixtures.insert(fixtures.end(), words.begin(), words.end()); }
    osg::ref_ptr<osg::StateSet> state() {
        osg::ref_ptr<osg::StateSet> result=new osg::StateSet;
        osg::ref_ptr<osg::Program> program=new osg::Program;
        osg::ref_ptr<osg::Shader> vertex=new osg::Shader(osg::Shader::VERTEX),fragment=new osg::Shader(osg::Shader::FRAGMENT);
        vertex->setName("objects.vert");fragment->setName("objects.frag");
        fragment->setUserValue("webcuda.defines",std::string("classicFalloff=0\n"));
        program->addShader(vertex);program->addShader(fragment);result->setAttribute(program);
        result->addUniform(new osg::Uniform("osg_ViewMatrixInverse",osg::Matrixf{}));
        return result;
    }
    void capture(unsigned int count, bool rawSun, bool rawPoints, const osg::Matrixd& view, float multiplier, unsigned int fadeMode) {
        auto source=state();
        const osg::Vec4f sunSource(1.5f,-.75f,.375f,fadeMode%2?1.f:0.f);
        osg::ref_ptr<osg::Uniform> sun=new osg::Uniform("sun_position",sunSource);
        if(rawSun)sun->setUserData(new WebCuda::LightInputs(WebCuda::LightInputs::Sun,view));
        source->addUniform(sun);
        source->addUniform(new osg::Uniform("PointLightCount",static_cast<int>(count)));
        osg::ref_ptr<osg::Uniform> lights=new osg::Uniform(osg::Uniform::FLOAT_MAT4,"LightBuffer",std::max(1u,count));
        osg::ref_ptr<WebCuda::LightInputs> inputs=new WebCuda::LightInputs(WebCuda::LightInputs::Points,view);
        inputs->radiusMultiplier=multiplier;
        for(unsigned int light=0;light<count;light++) {
            osg::ref_ptr<osg::Light> value=new osg::Light;
            value->setPosition(osg::Vec4(100.25f+light*3.f,-41.5f+light,.125f-light*2.f,1.f));
            value->setAmbient(osg::Vec4(.1f,.2f,.3f,1));
            value->setDiffuse(osg::Vec4(light%2?-.7f:.7f,.35f,1.125f,1));
            value->setSpecular(osg::Vec4(.875f,1.5f,.625f,1));
            value->setConstantAttenuation(.25f);value->setLinearAttenuation(.0125f);value->setQuadraticAttenuation(.003f);
            WebCuda::capturePointLight(*lights,light,*value,16.f+light);
            const float distance=fadeMode==1?1.f:fadeMode==2?7.f:fadeMode==3?16.f:0.f;
            inputs->fades.push_back({distance,0,0,4,fadeMode==0?0.f:12.f});
        }
        if(rawPoints&&count)lights->setUserData(inputs);
        source->addUniform(lights);
        WebCuda::DrawContext context;context.states={source};
        WebCuda::MaterialTable table(16,16);const auto id=table.encode(context);
        const auto& materials=table.materials();const auto& original=table.texels();
        auto expected=original;std::vector<unsigned int> tolerant(original.size(),0);
        const auto data=materials.at(id*12),first=original.at(data+7);
        assert(first==(rawSun||(rawPoints&&count)?388+count*5:352));
        assert(bool(original.at(data+4)&0x80000000u)==(rawSun||(rawPoints&&count)));
        expected[data+4]&=~0x80000000u;
        if(rawSun) {
            const osg::Vec4f result=sunSource*view;
            for(unsigned int k=0;k<4;k++){assert(original[data+24+k]==bits(sunSource[k]));expected[data+24+k]=bits(result[k]);tolerant[data+24+k]=1;}
        }
        for(unsigned int light=0;light<count&&rawPoints;light++) {
            const auto record=data+first+light*16;osg::Matrixf value;assert(lights->getElement(light,value));
            for(unsigned int k=0;k<16;k++)assert(original.at(record+k)==bits(value.ptr()[k]));
            const osg::Vec4f result=osg::Vec4f(value(0,0),value(0,1),value(0,2),1)*view;
            const auto& fade=inputs->fades[light];
            const float amount=fade[4]==0?1.f:1.f-std::clamp((osg::Vec3f(fade[0],fade[1],fade[2]).length()-fade[3])/(fade[4]-fade[3]),0.f,1.f);
            for(unsigned int k=0;k<3;k++) {
                expected[record+k]=bits(result[k]);tolerant[record+k]=1;
                for(unsigned int base:{8u,12u}){expected[record+base+k]=bits(floating(original[record+base+k])*amount);tolerant[record+base+k]=1;}
            }
            expected[record+15]=bits(floating(original[record+15])*multiplier);tolerant[record+15]=1;
        }
        fixtures[1]++;fixtures.insert(fixtures.end(),{static_cast<unsigned int>(materials.size()/12),static_cast<unsigned int>(original.size())});
        append(materials);append(original);append(expected);append(tolerant);
    }
}
int main() {
    const osg::Matrixd first=osg::Matrixd::identity();
    const osg::Matrixd second=osg::Matrixd::rotate(.63,osg::Vec3d(.2,.5,.7))*osg::Matrixd::translate(12.5,-7.25,91.75);
    const osg::Matrixd reflected=osg::Matrixd::scale(1,1,-1)*osg::Matrixd::translate(-8192.125,4096.25,0);
    const auto key=WebCuda::lightListKey({11,42},first);
    assert(key==WebCuda::lightListKey({11,42},first));
    assert(key!=WebCuda::lightListKey({11,42},second));
    assert(key!=WebCuda::lightListKey({42,11},first));
    for(const auto& view:{first,second,reflected})for(unsigned int count:{0u,1u,8u,32u})
        for(unsigned int flags=0;flags<4;flags++)for(unsigned int fade=0;fade<4;fade++)
            capture(count,flags&1,flags&2,view,fade%2?.375f:2.5f,fade);
    // Metadata belongs to the winning uniform. A plain child override has none.
    auto parent=state();osg::ref_ptr<osg::Uniform> raw=new osg::Uniform("sun_position",osg::Vec4(1,2,3,0));
    raw->setUserData(new WebCuda::LightInputs(WebCuda::LightInputs::Sun,second));parent->addUniform(raw);
    osg::ref_ptr<osg::StateSet> child=new osg::StateSet;child->addUniform(new osg::Uniform("sun_position",osg::Vec4(4,5,6,0)));
    WebCuda::DrawContext context;context.states={parent,child};WebCuda::MaterialTable table(16,16);const auto id=table.encode(context),data=table.materials()[id*12];
    assert(!(table.texels()[data+4]&0x80000000u));assert(table.texels()[data+24]==bits(4));
    std::printf("Light input: %u OSG producer fixtures, camera-specific cache keys and child override ownership passed\n",fixtures[1]);
    EM_ASM({const out=process.env.WEBCUDA_LIGHT_FIXTURES;if(out)require('fs').writeFileSync(out,Buffer.from(HEAPU8.subarray(Number($0),Number($0)+Number($1))));},fixtures.data(),fixtures.size()*4);
}
