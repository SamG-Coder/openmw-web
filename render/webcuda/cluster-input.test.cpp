// Real OSG clustered-light capture. The binary also feeds native GPU and host checks.
#include <cassert>
#include <cmath>
#include <cstring>
#include <cstdio>
#include <emscripten.h>
#include <osg/BufferIndexBinding>
#include <osg/BufferTemplate>
#include <osg/Program>
#include <osg/Shader>
#include <osg/ValueObject>
#include <components/webcuda/lightinputs.hpp>
#include <components/webcuda/materialtable.hpp>

namespace {
using Buffer=osg::BufferTemplate<std::vector<SceneUtil::PointLight>>;
std::vector<unsigned int> fixtures{0x434c4131u,0};
template<class T> void append(const std::vector<T>& values) {
    static_assert(sizeof(T)==4);const auto old=fixtures.size();fixtures.resize(old+values.size());
    std::memcpy(fixtures.data()+old,values.data(),values.size()*4);
}
void capture(unsigned int count,unsigned int first,bool raw,unsigned int fadeMode,const osg::Matrixd& view,bool dummy=false,unsigned int cameraMode=0) {
    osg::ref_ptr<osg::StateSet> state=new osg::StateSet;
    osg::ref_ptr<osg::Program> program=new osg::Program;
    osg::ref_ptr<osg::Shader> vertex=new osg::Shader(osg::Shader::VERTEX),fragment=new osg::Shader(osg::Shader::FRAGMENT);
    vertex->setName("objects.vert");fragment->setName("objects.frag");
    fragment->setUserValue("webcuda.defines",std::string("lightingMethodClustered=1\nclassicFalloff=0\n"));
    program->addShader(vertex);program->addShader(fragment);state->setAttribute(program);
    state->addUniform(new osg::Uniform("osg_ViewMatrixInverse",osg::Matrixf{}));
    state->addUniform(new osg::Uniform("gridSize",osg::Vec3f(2,2,4)));
    state->addUniform(new osg::Uniform("screenRes",osg::Vec2f(16,16)));
    state->addUniform(new osg::Uniform("near",cameraMode?5.f:.1f));state->addUniform(new osg::Uniform("clusterFar",100.f));
    osg::ref_ptr<Buffer> buffer=new Buffer;
    osg::ref_ptr<WebCuda::LightInputs> inputs=new WebCuda::LightInputs(WebCuda::LightInputs::Points,view);
    inputs->radiusMultiplier=fadeMode%2?.375f:2.5f;
    std::vector<float> expected;
    for(unsigned int i=0;i<first+count;i++) {
        osg::ref_ptr<osg::Light> light=new osg::Light;
        light->setPosition(osg::Vec4f(-3.f+i*.03125f,.125f*i,-2.f-i*.25f,1.f));
        light->setDiffuse(osg::Vec4f(i%2?-.1f:.2f,.35f,.75f,.625f));
        light->setSpecular(osg::Vec4f(.125f,.5f,1.125f,.875f));light->setAmbient(osg::Vec4f(.1f,.2f,.3f,1));
        light->setConstantAttenuation(.75f);light->setLinearAttenuation(.125f);light->setQuadraticAttenuation(.0125f);
        auto value=WebCuda::captureClusterLight(*light,16.f+i);
        if(dummy)value=SceneUtil::PointLight{};
        buffer->getData().push_back(value);
        const float distance=fadeMode==1?1.f:fadeMode==2?7.f:16.f;
        inputs->fades.push_back({distance,0,0,4,fadeMode==0?0.f:12.f});
        if(i<first)continue;
        if(raw) {
            value.mPosition=value.mPosition*view;
            const float fade=fadeMode==0?1.f:1.f-std::clamp((osg::Vec3f(distance,0,0).length()-4.f)/8.f,0.f,1.f);
            value.mDiffuse*=fade;value.mSpecular*=fade;value.mRadius*=inputs->radiusMultiplier;
        }
        for(const auto* v:{&value.mPosition,&value.mDiffuse,&value.mAmbient,&value.mSpecular})
            for(unsigned int k=0;k<4;k++)expected.push_back((*v)[k]);
        expected.insert(expected.end(),{value.mConstant,value.mLinear,value.mQuadratic,value.mRadius});
    }
    if(raw)buffer->setUserData(inputs);
    osg::ref_ptr<osg::ShaderStorageBufferBinding> binding=new osg::ShaderStorageBufferBinding(2,buffer,first*sizeof(SceneUtil::PointLight),count*sizeof(SceneUtil::PointLight));
    state->setAttribute(binding);
    osg::Matrixd projection=osg::Matrixd::perspective(60.,1.,.1,100.);
    if(cameraMode)projection.makeOrtho(-40,24,-16,48,5,100);
    if(cameraMode==2){projection(2,2)=1./95.;projection(3,2)=100./95.;} // reversed zero-to-one
    WebCuda::DrawContext context;context.states={state};context.projection=&projection;
    WebCuda::MaterialTable table(16,16);table.encode(context);
    assert(table.clusterRecords().size()==10&&table.clusterLights().size()==count*20);
    assert(bool(table.clusterRecords()[7]&0x80000000u)==raw);
    if(count)assert(table.clusterLights()[0]==buffer->getData()[first].mPosition.x());
    const auto captured=table.clusterLights(),metadata=table.clusterProjections();
    table.encode(context);assert(table.clusterRecords().size()==10); // unchanged value reuse
    fixtures[1]++;
    for(auto size:{table.materials().size(),table.texels().size(),table.rasterParams().size(),table.clusterRecords().size(),
        table.clusterMaterials().size(),table.clusterLights().size(),table.clusterProjections().size()})fixtures.push_back(size);
    append(table.materials());append(table.texels());append(table.rasterParams());append(table.clusterRecords());
    append(table.clusterMaterials());append(table.clusterLights());append(table.clusterProjections());append(expected);
    if(raw) {
        inputs->view(3,0)+=1.f;table.encode(context);
        assert(table.clusterRecords().size()==20&&table.clusterProjections()!=metadata);
        assert(std::equal(captured.begin(),captured.end(),table.clusterLights().begin()));
        if(count) {
            inputs->fades[first][0]+=.25f;table.encode(context);assert(table.clusterRecords().size()==30);
        }
        // A canonical replacement binding must not inherit another buffer's raw metadata.
        osg::ref_ptr<Buffer> canonical=new Buffer;canonical->getData()=buffer->getData();
        binding->setBufferData(canonical);table.encode(context);
        assert(!(table.clusterRecords()[table.clusterRecords().size()-3]&0x80000000u));
    }
    // Missing camera data must remain an explicit failure, never a guessed
    // main-camera value: local-map producers now provide their own near plane.
    state->removeUniform("near");
    bool rejected=false;
    try { table.encode(context); } catch(const std::runtime_error& error) {
        rejected=std::string(error.what()).find("clustered near uniform")!=std::string::npos;
    }
    assert(rejected);
}
}
int main() {
    const auto identity=osg::Matrixd::identity();
    const auto camera=osg::Matrixd::rotate(.63,osg::Vec3d(.2,.5,.7))*osg::Matrixd::translate(12.5,-7.25,91.75);
    const auto reflected=osg::Matrixd::scale(1,1,-1)*osg::Matrixd::translate(-8192.125,4096.25,0);
    for(const auto& view:{identity,camera,reflected})for(unsigned int count:{0u,1u,8u,65u,130u})
        for(unsigned int first:{0u,2u})if(count||!first)for(bool raw:{false,true})for(unsigned int fade=0;fade<4;fade++)
            capture(count,first,raw,fade,view);
    capture(1,0,true,0,camera,true);capture(1,0,false,0,camera,true);
    for(unsigned int mode:{1u,2u})for(unsigned int count:{0u,8u,65u,130u})for(bool raw:{false,true})
        capture(count,0,raw,2,identity,false,mode);
    std::printf("Cluster light input: %u OSG fixtures, binding slices, empty/dummy lights, camera/fade cache edits and replacement ownership passed\n",fixtures[1]);
    EM_ASM({const out=process.env.WEBCUDA_CLUSTER_FIXTURES;if(out)require('fs').writeFileSync(out,Buffer.from(HEAPU8.subarray(Number($0),Number($0)+Number($1))));},fixtures.data(),fixtures.size()*4);
}
