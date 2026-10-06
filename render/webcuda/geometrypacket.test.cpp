#include <cassert>
#include <cmath>
#include <cstring>
#include <cstdio>
#include <stdexcept>
#include <osg/Geometry>
#include <osg/Matrix>
#include <osg/Texture2D>
#include <osg/Program>
#include <osg/Shader>
#include <osg/Uniform>
#include <osg/Fog>
#include <osg/DisplaySettings>
#include <osg/TexMat>
#include <osgUtil/RenderStage>
#include <components/webcuda/geometrypacket.hpp>
#include <components/webcuda/deformation.hpp>
#include <components/webcuda/vertexstreamcache.hpp>
#include <osgParticle/ParticleSystem>
#include <osg/UserDataContainer>
#include "vertex-input-reference.hpp"

namespace {
    void streamCache() {
        WebCuda::VertexStreamCache cache(168,0);
        auto make=[](){return osg::ref_ptr<osg::Vec3Array>(new osg::Vec3Array(3));};
        auto a=make(),b=make(),c=make();unsigned int converted=0;
        auto capture=[&](const osg::Vec3Array* source){return cache.capture(source,3,4,[&](unsigned int i){
            converted++;const auto& v=(*source)[i];return osg::Vec4(v.x(),v.y(),v.z(),1);});};
        const auto first=capture(a)->version;
        assert(capture(a)->version==first&&converted==3);
        // Dirty notifications alone are insufficient evidence of changed bytes.
        a->dirty();assert(capture(a)->version==first&&converted==3);
        (*a)[1].x()=17;const auto changed=capture(a)->version;
        assert(changed!=first&&capture(a)->values[4]==17&&converted==6);
        (*a)[1].x()=std::numeric_limits<float>::infinity();
        bool rejected=false;try {capture(a);}catch(const std::runtime_error&){rejected=true;}
        assert(rejected&&cache.size()==1&&cache.bytes()==84);
        (*a)[1].x()=17;assert(capture(a)->version==changed);
        capture(b);assert(cache.bytes()==168);capture(c);assert(cache.bytes()==168);
        assert(capture(a)->version!=changed&&cache.bytes()==168);
        c=nullptr; // Weak ownership must let released source objects expire.
        for(unsigned int i=0;i<1024;i++)capture(a);
        assert(cache.size()==1&&cache.bytes()==84);
        WebCuda::VertexStreamCache disabled(8,0);
        assert(!disabled.capture(a,3,4,[](unsigned int){return osg::Vec4();}));
        std::puts("Vertex stream cache: exact mutation detection, dirty-only reuse, finite inputs, LRU budget and weak source lifetime passed");
    }
    template<class Array, class Value>
    osg::ref_ptr<Array> repeated(const Value& value) {
        auto result=osg::ref_ptr<Array>(new Array);
        for(unsigned int i=0;i<3;i++)result->push_back(value);
        return result;
    }
    void near(float actual,float expected) { assert(std::fabs(actual-expected)<1e-6f); }
    void arrayCapture() {
        osg::Matrixd identity;
        WebCuda::DrawContext context{&identity,&identity,{}};
        osg::ref_ptr<osg::Geometry> geometry=new osg::Geometry;
        auto positions=repeated<osg::Vec3Array>(osg::Vec3(2,3,4));
        geometry->setVertexArray(positions);
        geometry->addPrimitiveSet(new osg::DrawArrays(GL_TRIANGLES,0,3));
        struct Case { osg::ref_ptr<osg::Array> array; osg::Vec4 value; };
        const Case vectors[]={
            {repeated<osg::FloatArray>(2.f),{2,0,0,1}},
            {repeated<osg::DoubleArray>(2.0),{2,0,0,1}},
            {repeated<osg::Vec2Array>(osg::Vec2(2,3)),{2,3,0,1}},
            {repeated<osg::Vec3Array>(osg::Vec3(2,3,4)),{2,3,4,1}},
            {repeated<osg::Vec4Array>(osg::Vec4(2,3,4,5)),{2,3,4,5}},
            {repeated<osg::Vec2dArray>(osg::Vec2d(2,3)),{2,3,0,1}},
            {repeated<osg::Vec3dArray>(osg::Vec3d(2,3,4)),{2,3,4,1}},
            {repeated<osg::Vec4dArray>(osg::Vec4d(2,3,4,5)),{2,3,4,5}}};
        // UV binding is deliberately OFF: OSG still consumes UVs per vertex.
        // Check all four units, their R/Q fields and homogeneous position W.
        for(unsigned int type=0;type<std::size(vectors);type++) {
            const auto& c=vectors[type];
            if(type>=2)geometry->setVertexArray(static_cast<osg::Array*>(c.array->clone(osg::CopyOp::SHALLOW_COPY)));
            for(unsigned int unit=0;unit<4;unit++)geometry->setTexCoordArray(unit,c.array,osg::Array::BIND_OFF);
            WebCuda::GeometryPacket packet;
            VertexInputReference::append(packet,*geometry,context,7);
            for(unsigned int v=0;v<3;v++) {
                for(unsigned int k=0;k<4;k++)near(packet.vertices[v*10+k],type>=2?c.value[k]:osg::Vec4(2,3,4,1)[k]);
                for(unsigned int unit=0;unit<4;unit++) {
                    const auto xy=unit?10+(unit-1)*2:16;
                    near(packet.attributes[v*34+xy],c.value.x());
                    near(packet.attributes[v*34+xy+1],c.value.y());
                    near(packet.attributes[v*34+26+unit*2],c.value.z());
                    near(packet.attributes[v*34+27+unit*2],c.value.w());
                }
                near(packet.vertices[v*10+8],c.value.x());near(packet.vertices[v*10+9],c.value.y());
            }
        }
        geometry->setVertexArray(positions);
        for(unsigned int unit=0;unit<4;unit++)geometry->setTexCoordArray(unit,nullptr);
        const Case colors[]={
            {repeated<osg::Vec3Array>(osg::Vec3(.25f,.5f,.75f)),{.25f,.5f,.75f,1}},
            {repeated<osg::Vec4Array>(osg::Vec4(.25f,.5f,.75f,.125f)),{.25f,.5f,.75f,.125f}},
            {repeated<osg::Vec3dArray>(osg::Vec3d(.25,.5,.75)),{.25f,.5f,.75f,1}},
            {repeated<osg::Vec4dArray>(osg::Vec4d(.25,.5,.75,.125)),{.25f,.5f,.75f,.125f}},
            {repeated<osg::Vec3ubArray>(osg::Vec3ub(0,128,255)),{0,128.f/255.f,1,1}},
            {repeated<osg::Vec4ubArray>(osg::Vec4ub(0,128,255,64)),{0,128.f/255.f,1,64.f/255.f}}};
        for(const auto& c:colors) {
            geometry->setColorArray(c.array,osg::Array::BIND_PER_VERTEX);
            WebCuda::GeometryPacket packet;VertexInputReference::append(packet,*geometry,context,7);
            for(unsigned int v=0;v<3;v++)for(unsigned int k=0;k<4;k++)near(packet.vertices[v*10+4+k],c.value[k]);
        }
        auto color=repeated<osg::Vec4Array>(osg::Vec4(.1f,.2f,.3f,.4f));
        (*color)[1].set(.5f,.6f,.7f,.8f);(*color)[2]=(*color)[1];
        auto secondary=repeated<osg::Vec3ubArray>(osg::Vec3ub(0,128,255));
        (*secondary)[1].set(255,64,0);(*secondary)[2]=(*secondary)[1];
        auto normals=repeated<osg::Vec3dArray>(osg::Vec3d(1,2,3));
        (*normals)[1].set(4,5,6);(*normals)[2]=(*normals)[1];
        auto fogCoordinates=repeated<osg::DoubleArray>(.25);
        (*fogCoordinates)[1]=(*fogCoordinates)[2]=.75;
        auto tangent=repeated<osg::Vec4Array>(osg::Vec4(1,0,0,-1));
        geometry->setTexCoordArray(7,tangent,osg::Array::BIND_OFF);
        geometry->addPrimitiveSet(new osg::DrawArrays(GL_TRIANGLES,0,3));
        osg::ref_ptr<osg::StateSet> state=new osg::StateSet;
        osg::ref_ptr<osg::Fog> fog=new osg::Fog;
        fog->setFogCoordinateSource(osg::Fog::FOG_COORDINATE);
        state->setAttributeAndModes(fog,osg::StateAttribute::ON);context.states={state};
        for(const auto binding:{osg::Array::BIND_OVERALL,osg::Array::BIND_PER_VERTEX,osg::Array::BIND_PER_PRIMITIVE_SET}) {
            geometry->setColorArray(color,binding);geometry->setSecondaryColorArray(secondary,binding);
            geometry->setNormalArray(normals,binding);geometry->setFogCoordArray(fogCoordinates,binding);
            WebCuda::GeometryPacket packet;VertexInputReference::append(packet,*geometry,context,7);
            const unsigned int draws=binding==osg::Array::BIND_PER_PRIMITIVE_SET?2:1;
            assert(packet.vertices.size()==draws*30&&packet.triangles.size()==8);
            for(unsigned int draw=0;draw<draws;draw++)for(unsigned int v=0;v<3;v++) {
                const auto source=binding==osg::Array::BIND_PER_VERTEX?v:draw;
                const auto dest=draw*3+v;
                for(unsigned int k=0;k<4;k++)near(packet.vertices[dest*10+4+k],(*color)[source][k]);
                for(unsigned int k=0;k<3;k++) {
                    near(packet.secondaryColors[dest*3+k],(*secondary)[source][k]/255.f);
                    near(packet.attributes[dest*34+3+k],(*normals)[source][k]);
                }
                near(packet.attributes[dest*34],-1);
                near(packet.attributes[dest*34+2],(*fogCoordinates)[source]);
                near(packet.attributes[dest*34+9],-1);
                for(unsigned int unit=0;unit<4;unit++)near(packet.attributes[dest*34+27+unit*2],1);
            }
        }
        // Disabled arrays use current values even when their element type is
        // unsupported. Each subsequent capture must observe in-place changes.
        auto unsupported=repeated<osg::IntArray>(123);
        geometry->setColorArray(unsupported,osg::Array::BIND_OFF);
        geometry->setSecondaryColorArray(unsupported,osg::Array::BIND_OFF);
        geometry->setNormalArray(unsupported,osg::Array::BIND_OFF);
        geometry->setFogCoordArray(unsupported,osg::Array::BIND_OFF);
        context.hasCurrentColor=true;context.currentColor[3]=.25f;
        context.currentSecondaryColor[1]=.5f;context.currentNormal[2]=.75f;context.currentFogCoordinate=.125f;
        WebCuda::GeometryPacket current;VertexInputReference::append(current,*geometry,context,7);
        near(current.vertices[7],.25f);near(current.secondaryColors[1],.5f);
        near(current.attributes[5],.75f);near(current.attributes[2],.125f);
        (*positions)[0].x()=9;fog->setFogCoordinateSource(osg::Fog::FRAGMENT_DEPTH);
        WebCuda::GeometryPacket changed;VertexInputReference::append(changed,*geometry,context,7);
        near(changed.vertices[0],9);near(changed.attributes[0],0);near(changed.attributes[2],0);

        // Bad/short inputs fail before committing this draw to the packet.
        auto reject=[&]() {
            bool rejected=false;WebCuda::GeometryPacket packet;
            try { VertexInputReference::append(packet,*geometry,context,7); }catch(const std::runtime_error&) { rejected=true; }
            assert(rejected&&packet.vertices.empty()&&packet.triangles.empty()&&packet.matrices.empty());
        };
        geometry->setTexCoordArray(0,unsupported);reject();geometry->setTexCoordArray(0,nullptr);
        auto shortUv=osg::ref_ptr<osg::Vec2Array>(new osg::Vec2Array(1));
        geometry->setTexCoordArray(1,shortUv);reject();geometry->setTexCoordArray(1,nullptr);
        color->resize(1);geometry->setColorArray(color,osg::Array::BIND_PER_VERTEX);reject();geometry->setColorArray(nullptr);
        normals->resize(1);geometry->setNormalArray(normals,osg::Array::BIND_PER_VERTEX);reject();geometry->setNormalArray(nullptr);
        secondary->resize(1);geometry->setSecondaryColorArray(secondary,osg::Array::BIND_PER_VERTEX);reject();geometry->setSecondaryColorArray(nullptr);
        fog->setFogCoordinateSource(osg::Fog::FOG_COORDINATE);
        fogCoordinates->resize(1);geometry->setFogCoordArray(fogCoordinates,osg::Array::BIND_PER_VERTEX);reject();geometry->setFogCoordArray(nullptr);
        tangent->resize(1);reject();geometry->setTexCoordArray(7,nullptr);
        geometry->setNormalArray(normals);normals->setBinding(osg::Array::BIND_UNDEFINED);reject();geometry->setNormalArray(nullptr);
        geometry->setVertexArray(repeated<osg::FloatArray>(1.f));reject();
    }
}
int main() {
    arrayCapture();
    osg::ref_ptr<osg::Geometry> geometry=new osg::Geometry;
    osg::ref_ptr<osg::Vec3Array> positions=new osg::Vec3Array;
    positions->push_back(osg::Vec3(-1,1,0)); positions->push_back(osg::Vec3(1,1,0));
    positions->push_back(osg::Vec3(-1,-1,0)); positions->push_back(osg::Vec3(1,-1,0));
    geometry->setVertexArray(positions);
    osg::ref_ptr<osg::Vec4ubArray> colors=new osg::Vec4ubArray;
    colors->push_back(osg::Vec4ub(255,128,0,255));
    geometry->setColorArray(colors,osg::Array::BIND_OVERALL);
    osg::ref_ptr<osg::Vec2Array> uv=new osg::Vec2Array;
    for(int i=0;i<4;i++) uv->push_back(osg::Vec2(i%2,i/2));
    geometry->setTexCoordArray(0,uv);
    geometry->addPrimitiveSet(new osg::DrawArrays(GL_TRIANGLE_STRIP,0,4));
    osg::Matrixd model=osg::Matrixd::translate(2,3,4),projection;
    WebCuda::DrawContext context{&projection,&model,{}};
    WebCuda::GeometryPacket packet;
    VertexInputReference::append(packet,*geometry,context,7);
    assert(packet.vertices.size()==40 && packet.matrixIds.size()==4 && packet.matrices.size()==32);
    assert(packet.matrices[12]==2 && packet.matrices[13]==3 && packet.matrices[14]==4);
    assert(packet.vertices[4]==1 && std::fabs(packet.vertices[5]-128.f/255.f)<1e-6);
    assert((packet.triangles==std::vector<std::uint32_t>{0,1,2,7,1,3,2,7}));
    VertexInputReference::append(packet,*geometry,context,8);
    assert(packet.triangles[8]==4 && packet.matrixIds[4]==1 && packet.triangles[11]==8);
    // Lines now capture original endpoints plus four expansion vertices per
    // segment. Rendering and expansion remain CUDA work.
    geometry->setPrimitiveSet(0,new osg::DrawArrays(GL_LINES,0,4));
    WebCuda::GeometryPacket lines;
    VertexInputReference::append(lines,*geometry,context,7);
    assert(lines.screenPrimitives.size()==24 && lines.vertices.size()==120);
    assert(lines.screenPrimitives[0]==0 && lines.screenPrimitives[1]==1);
    assert(lines.screenPrimitives[12]==2 && lines.screenPrimitives[13]==3);
    assert(lines.triangles.size()==16);
    // An unknown topology must not leave partially appended vertices.
    geometry->setPrimitiveSet(0,new osg::DrawArrays(0xffffffffu,0,4));
    bool rejected=false;
    try { VertexInputReference::append(packet,*geometry,context,0); } catch(const std::runtime_error&) { rejected=true; }
    assert(rejected && packet.vertices.size()==80);
    // MyGUI byte layout exactly matches its GL unsigned-byte RGBA attributes.
    osg::ref_ptr<osg::UByteArray> gui=new osg::UByteArray(72);
    for(int i=0;i<3;i++) {
        float p[3]={float(i),2,3},t[2]={.25f,.75f};
        std::memcpy(&(*gui)[i*24],p,12); std::memcpy(&(*gui)[i*24+16],t,8);
        (*gui)[i*24+12]=10; (*gui)[i*24+13]=20; (*gui)[i*24+14]=30; (*gui)[i*24+15]=40;
    }
    bool consumed=false,guiResolved=false;
    osg::ref_ptr<osg::Texture2D> texture=new osg::Texture2D;
    WebCuda::GeometrySink sink([&](const WebCuda::DrawContext&,const osg::Texture2D* t,bool gui){guiResolved=gui && t==texture;return 9;},
        [&](const osgUtil::RenderStage&,const WebCuda::GeometryPacket& result){
            consumed=true; assert(result.vertices.size()==30 && result.triangles[3]==9);
            assert(result.vertices[8]==.25f && std::fabs(result.vertices[4]-10.f/255.f)<1e-6);
        });
    osg::ref_ptr<osgUtil::RenderStage> stage=new osgUtil::RenderStage;
    sink.beginPass(*stage); sink.gui(*gui,3,texture,context); sink.endPass(*stage);
    assert(consumed && guiResolved);
    geometry->setPrimitiveSet(0,new osg::DrawArrays(GL_TRIANGLE_STRIP,0,4));
    osg::ref_ptr<osg::StateSet> shaderState=new osg::StateSet;
    osg::ref_ptr<osg::Program> program=new osg::Program;
    program->addShader(new osg::Shader(osg::Shader::VERTEX,"void main() { gl_Position = modelToClip(gl_Vertex); }"));
    shaderState->setAttribute(program);context.states={shaderState};
    WebCuda::GeometryPacket shaderPacket;
    rejected=false;
    try { VertexInputReference::append(shaderPacket,*geometry,context,0); } catch(const std::runtime_error&) { rejected=true; }
    assert(rejected);
    osg::Matrixf shaderProjection=osg::Matrixf::scale(2,3,4);
    shaderState->addUniform(new osg::Uniform("projectionMatrix",shaderProjection));
    VertexInputReference::append(shaderPacket,*geometry,context,0);
    for(unsigned int k=0;k<16;k++)assert(shaderPacket.matrices[16+k]==shaderProjection.ptr()[k]);
    // Shadow and compatibility shaders retain their explicit camera projection,
    // even when an unrelated projection uniform is inherited from an ancestor.
    program->getShader(0)->setShaderSource("void main() { gl_Position=gl_ModelViewProjectionMatrix*gl_Vertex; }");
    WebCuda::GeometryPacket shadowPacket;
    VertexInputReference::append(shadowPacket,*geometry,context,0);
    for(unsigned int k=0;k<16;k++)assert(shadowPacket.matrices[16+k]==projection.ptr()[k]);
    // The dependency's unnamed default shader uses UV.xy without TexMat and
    // the camera's MVP even when a world projection uniform is inherited.
    const auto previousHint=osg::DisplaySettings::instance()->getShaderHint();
    osg::DisplaySettings::instance()->setShaderHint(osg::DisplaySettings::SHADER_GLES3);
    osg::ref_ptr<osg::StateSet> defaults=new osg::StateSet;defaults->setGlobalDefaults();
    osg::DisplaySettings::instance()->setShaderHint(previousHint);
    defaults->setMode(GL_LIGHTING,osg::StateAttribute::ON);
    defaults->addUniform(new osg::Uniform("projectionMatrix",shaderProjection));
    defaults->setTextureAttribute(0,new osg::TexMat(osg::Matrix::scale(4,5,6)));
    context.states={defaults};
    WebCuda::GeometryPacket defaultPacket;VertexInputReference::append(defaultPacket,*geometry,context,0);
    for(unsigned int k=0;k<16;k++) {
        assert(defaultPacket.uvMatrices[k]==(k%5==0?1.f:0.f));
        assert(defaultPacket.matrices[16+k]==projection.ptr()[k]);
    }
    assert(defaultPacket.vertices[8]==uv->at(0).x()&&defaultPacket.vertices[9]==uv->at(0).y());
    assert(defaultPacket.fixedLighting[0]==0&&!(defaultPacket.fixedLighting[1]&1u));
    // Mixed draw encodings must relocate every stream/dense offset and retain
    // generated vertices and live source mutations across consecutive captures.
    WebCuda::GeometryPacket mixed(true),reference;
    for(auto* output:{&mixed,&reference}) {
        WebCuda::appendGeometry(*output,*geometry,context,7);
        WebCuda::appendGui(*output,*gui,3,context,9);
    }
    VertexInputReference::verify(mixed,reference);
    (*positions)[0].x()=23;(*colors)[0].r()=5;
    geometry->setPrimitiveSet(0,new osg::DrawArrays(GL_LINES,0,4));
    for(auto* output:{&mixed,&reference})WebCuda::appendGeometry(*output,*geometry,context,11);
    VertexInputReference::verify(mixed,reference);
    osg::ref_ptr<osgParticle::ParticleSystem> system=new osgParticle::ParticleSystem;
    system->setUseShaders(false);system->createParticle(nullptr);
    for(auto* output:{&mixed,&reference})WebCuda::appendParticles(*output,*system,context,12);
    VertexInputReference::verify(mixed,reference);
    auto base=osg::ref_ptr<osg::Vec3Array>(new osg::Vec3Array(*positions));(*base)[1].set(11,12,13);
    auto offsets=osg::ref_ptr<osg::Vec3Array>(new osg::Vec3Array(4));(*offsets)[1].set(.5f,.25f,.125f);
    osg::ref_ptr<WebCuda::MorphInputs> morph=new WebCuda::MorphInputs;morph->base=base;morph->targets.push_back({offsets,.75f});
    geometry->getOrCreateUserDataContainer()->addUserObject(morph);
    for(auto* output:{&mixed,&reference})WebCuda::appendGeometry(*output,*geometry,context,13);
    VertexInputReference::verify(mixed,reference);
    auto skin=osg::ref_ptr<WebCuda::SkinInputs>(new WebCuda::SkinInputs);
    auto skinSource=osg::ref_ptr<osg::Geometry>(new osg::Geometry(*geometry,osg::CopyOp::SHALLOW_COPY));
    skinSource->setUserDataContainer(nullptr);skin->source=skinSource;
    skin->bones.push_back({osg::Matrixf::identity(),osg::Matrixf::translate(1,2,3),true});
    skin->groups.push_back({{{0,1.f}},{0,1,2,3}});
    geometry->getOrCreateUserDataContainer()->addUserObject(skin);
    for(auto* output:{&mixed,&reference})WebCuda::appendGeometry(*output,*geometry,context,14);
    VertexInputReference::verify(mixed,reference);
    osg::ref_ptr<osg::Geometry> large=new osg::Geometry;
    osg::ref_ptr<osg::Vec3Array> largePositions=new osg::Vec3Array,largeNormals=new osg::Vec3Array;
    osg::ref_ptr<osg::Vec2Array> largeUv=new osg::Vec2Array;
    for(unsigned int i=0;i<3072;i++) {
        largePositions->push_back(osg::Vec3(i%17,i%13,i%11));largeNormals->push_back(osg::Vec3(0,0,1));
        largeUv->push_back(osg::Vec2((i%31)*.03125f,(i%7)*.125f));
    }
    large->setVertexArray(largePositions);large->setNormalArray(largeNormals,osg::Array::BIND_PER_VERTEX);
    large->setTexCoordArray(0,largeUv);large->addPrimitiveSet(new osg::DrawArrays(GL_TRIANGLES,0,3072));
    for(unsigned int draw=0;draw<2;draw++)for(auto* output:{&mixed,&reference})WebCuda::appendGeometry(*output,*large,context,15);
    VertexInputReference::verify(mixed,reference);
    assert(mixed.vertexResources.size()==9); // Three arrays, shared by both draws.
    const auto layout=mixed.vertexLayouts.size()-64;
    for(const auto field:{8u,14u,20u})assert(mixed.vertexLayouts[layout+field]==mixed.vertexLayouts[layout+32+field]);
    const auto originalPositionVersion=mixed.vertexResources[0],normalVersion=mixed.vertexResources[3];
    const auto oldPositionOffset=mixed.vertexResources[1];
    (*largePositions)[0].x()=42; // Deliberately no dirty() call.
    WebCuda::GeometryPacket mutated(true),mutatedReference;
    WebCuda::appendGeometry(mutated,*large,context,15);WebCuda::appendGeometry(mutatedReference,*large,context,15);
    assert(mutated.vertexResources[0]!=originalPositionVersion&&mutated.vertexResources[3]==normalVersion);
    assert(mutated.vertexInputs[mutated.vertexResources[1]]==42&&mixed.vertexInputs[oldPositionOffset]==0);
    VertexInputReference::verify(mutated,mutatedReference);
    streamCache();
    VertexInputReference::save();
    std::puts("WebCuda geometry packets: OSG strips, colors/UVs, matrix ABI, batching, rejection and MyGUI bytes passed");
}
