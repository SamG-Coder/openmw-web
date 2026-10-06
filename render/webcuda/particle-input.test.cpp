// Compare compact particle capture and the authored unpack kernel with the
// preceding dense producer, including offsets among ordinary draw packets.
#include <cassert>
#include <cmath>
#include <cstdio>
#include <limits>
#include <osg/Geometry>
#include <osg/LineWidth>
#include <osg/Point>
#include <osg/PointSprite>
#include <osg/Program>
#include <osg/Shader>
#include <osg/Uniform>
#include <osgParticle/ParticleSystem>
#include <components/webcuda/geometrypacket.hpp>
#include "vertex-input-reference.hpp"

namespace {
    struct Fixture {
        osg::Matrixd matrix=osg::Matrix::translate(.25,-.5,-3);
        osg::ref_ptr<osgParticle::ParticleSystem> system=new osgParticle::ParticleSystem;
        osg::ref_ptr<osg::StateSet> state=new osg::StateSet;
        osg::ref_ptr<osg::Point> point=new osg::Point(7.f);
        osg::ref_ptr<osg::LineWidth> line=new osg::LineWidth(3.5f);
        WebCuda::DrawContext context;
        Fixture() {
            context.projection=&matrix;context.modelView=&matrix;context.view=&matrix;context.states={state};
            point->setDistanceAttenuation({.5f,.25f,.125f});point->setMinSize(2.f);point->setMaxSize(48.f);point->setFadeThresholdSize(4.f);
            state->setAttribute(point);state->setAttribute(line);
            system->setAlignVectors({1.25f,.5f,-.25f},{.125f,1.5f,.75f});
            for(unsigned int k=0;k<3;k++) {
                context.particleNormal[k]=float(k+1)*.25f;
                context.currentSecondaryColor[k]=float(k+1)*.125f;
            }
        }
        void shaderSprites() {
            // The configured OSG library disables its GL setup helper. Supply
            // that helper's exact built-in program and enable its input route.
            osg::ref_ptr<osg::Program> program=new osg::Program;
            program->addShader(new osg::Shader(osg::Shader::VERTEX,R"(
                uniform float visibilityDistance; varying vec3 basic_prop;
                void main(void) {
                    basic_prop = gl_MultiTexCoord0.xyz;
                    vec4 ecPos = gl_ModelViewMatrix * gl_Vertex;
                    float ecDepth = -ecPos.z;
                    if (visibilityDistance > 0.0) {
                        if (ecDepth <= 0.0 || ecDepth >= visibilityDistance) basic_prop.x = -1.0;
                    }
                    gl_Position = ftransform(); gl_ClipVertex = ecPos;
                    vec4 color = gl_Color; color.a *= basic_prop.z;
                    gl_FrontColor = color; gl_BackColor = gl_FrontColor;
                }
            )"));
            program->addShader(new osg::Shader(osg::Shader::FRAGMENT,R"(
                uniform sampler2D baseTexture; varying vec3 basic_prop;
                void main(void) {
                    if (basic_prop.x < 0.0) discard;
                    gl_FragColor = gl_Color * texture2D(baseTexture, gl_TexCoord[0].xy);
                }
            )"));
            state->setAttribute(program);system->setUseShaders(true);system->setUseVertexArray(true);
            state->addUniform(new osg::Uniform("visibilityDistance",12.5f));
        }
        void add(unsigned int count,unsigned int shapeOffset=0) {
            const osgParticle::Particle::Shape shapes[]={osgParticle::Particle::QUAD,osgParticle::Particle::LINE,osgParticle::Particle::POINT};
            for(unsigned int i=0;i<count;i++) {
                osgParticle::Particle prototype;prototype.setShape(shapes[(i+shapeOffset)%3]);prototype.setLifeTime(20);
                const float size=.125f+float(i%11)*.1f,alpha=.25f+float(i%5)*.125f;
                prototype.setSizeRange(osgParticle::rangef(size,size));prototype.setAlphaRange(osgParticle::rangef(alpha,alpha));
                const osg::Vec4 color(float(i%3)*.25f,float(i%7)*.125f,.75f,.5f);
                prototype.setColorRange(osgParticle::rangev4(color,color));prototype.setTextureTile(3,5,14);
                auto* particle=system->createParticle(&prototype);particle->update(.25*(i%4+1),false);
                particle->setPosition({float(i%5)*.2f-.5f,float(i%3)*.3f,-.25f});
                particle->setAngle({float(i%3)*.125f,-.25f,.5f});particle->setVelocity({.25f,-.5f,.75f});
                particle->setDepth(i%4==0?-1.:i%4==1?25.:5.);
                if(i%13==12){particle->kill();particle->update(0,false);}
            }
        }
    };
    osg::ref_ptr<osg::Geometry> triangle() {
        osg::ref_ptr<osg::Geometry> result=new osg::Geometry;
        auto* positions=new osg::Vec3Array;positions->push_back({-1,0,0});positions->push_back({1,0,0});positions->push_back({0,1,0});
        result->setVertexArray(positions);result->addPrimitiveSet(new osg::DrawArrays(GL_TRIANGLES,0,3));return result;
    }
    std::size_t oldWords=0,newWords=0;
    void compare(Fixture& f,bool neighbors=true) {
        WebCuda::GeometryPacket dense,compact(true);
        const auto geometry=triangle();
        auto ordinary=[&]{for(auto* packet:{&dense,&compact})WebCuda::appendGeometry(*packet,*geometry,f.context,1);};
        if(neighbors)ordinary();
        const auto before=compact.vertexInputs.size();
        for(auto* packet:{&dense,&compact})WebCuda::appendParticles(*packet,*f.system,f.context,2,3,4);
        const auto descriptor=compact.vertexLayouts.size()-32;
        const auto count=compact.vertexLayouts[descriptor+1];
        assert(compact.vertexLayouts[descriptor+3]==2&&compact.vertexLayouts[descriptor+2]*4==count);
        assert(compact.vertexInputs.size()-before==23+count/4*17);
        if(f.system->getUseShaders())for(unsigned int particle=0;particle<count/4;particle++)
            assert(compact.vertexInputs[compact.vertexLayouts[descriptor+6]+particle*17+16]==8.f);
        oldWords+=count*47;newWords+=compact.vertexInputs.size()-before;
        if(neighbors)ordinary();
        VertexInputReference::verify(compact,dense);
    }
    void rejects(Fixture& f) {
        for(const bool compact:{false,true}) {
            WebCuda::GeometryPacket packet(compact);bool rejected=false;
            try {WebCuda::appendParticles(packet,*f.system,f.context,0);}catch(const std::runtime_error&){rejected=true;}
            assert(rejected&&packet.vertexCount()==0&&packet.triangles.empty());
        }
    }
}
int main() {
    for(unsigned int mode=0;mode<4;mode++)for(unsigned int count:{0,1,2,7,37})for(unsigned int detail:{1,3}) {
        Fixture f;f.add(count);f.system->setLevelOfDetail(detail);
        if(mode==1)f.system->setParticleScaleReferenceFrame(osgParticle::ParticleSystem::WORLD_COORDINATES);
        if(mode==2)f.system->setParticleAlignment(osgParticle::ParticleSystem::FIXED);
        if(mode==3)f.shaderSprites();
        if(count==7){f.system->setSortMode(osgParticle::ParticleSystem::SORT_FRONT_TO_BACK);f.system->setVisibilityDistance(10.);}
        for(const auto capability:{0x864Fu,0x809Du,static_cast<unsigned>(GL_POINT_SMOOTH),static_cast<unsigned>(GL_POINT_SPRITE_ARB)})
            f.state->setMode(capability,count%2?osg::StateAttribute::ON:osg::StateAttribute::OFF);
        compare(f);
        // The next capture must observe mutable particle and inherited state.
        if(count) {
            f.system->getParticle(0)->setPosition({7,-3,2});f.point->setSize(9.f);f.line->setWidth(2.5f);
            f.context.particleNormal[0]=-.75f;compare(f,false);
        }
    }
    Fixture invalid;invalid.add(3);
    invalid.system->getParticle(0)->setPosition({std::numeric_limits<float>::infinity(),0,0});rejects(invalid);
    invalid.system->getParticle(0)->setPosition({0,0,0});invalid.point->setMinSize(-1);rejects(invalid);
    invalid.point->setMinSize(2);invalid.line->setWidth(0);rejects(invalid);
    Fixture ignored;ignored.add(1);ignored.point->setMinSize(-1);ignored.line->setWidth(0);compare(ignored);
    Fixture unusedAngle;unusedAngle.add(1,2);unusedAngle.system->getParticle(0)->setAngle({NAN,NAN,NAN});compare(unusedAngle);
    Fixture empty;empty.system->setAlignVectors({NAN,NAN,NAN},{NAN,NAN,NAN});compare(empty);
    VertexInputReference::save();
    std::printf("Particle input capture: billboard/local/world/fixed, points, lines, shader sprites, LOD, visibility, dead particles, offsets and edits passed; payload %zu -> %zu words\n",oldWords,newWords);
}
