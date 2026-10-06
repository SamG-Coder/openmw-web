// Exercise the same capture entrypoints used by Viewer, including the material
// records consumed by CUDA. Geometry-only fixtures do not cover this boundary.
#include <cassert>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <osg/CullFace>
#include <osg/FrontFace>
#include <osg/Geometry>
#include <osg/LineWidth>
#include <osg/Point>
#include <osg/PointSprite>
#include <osg/PolygonMode>
#include <osg/PolygonOffset>
#include <osg/TexMat>
#include <osgParticle/ConnectedParticleSystem>
#include <components/webcuda/geometrypacket.hpp>
#include <components/webcuda/materialtable.hpp>
#include "vertex-input-reference.hpp"

namespace ClipReference {
    struct Dim { unsigned int x=0,y=0; };
    Dim blockIdx,blockDim{1,0},threadIdx,gridDim{1,0};
#define __global__
#include "clip.cu"
#undef __global__
}

namespace {
    struct Fixture {
        osg::Matrixd identity;
        osg::ref_ptr<osg::StateSet> state=new osg::StateSet;
        osg::ref_ptr<osg::PolygonMode> polygon=new osg::PolygonMode;
        osg::ref_ptr<osg::TexMat> textureMatrix=new osg::TexMat(osg::Matrix::scale(2,3,4));
        WebCuda::DrawContext context;
        Fixture() {
            context.projection=&identity;context.modelView=&identity;context.states={state};
            const auto override=osg::StateAttribute::ON|osg::StateAttribute::OVERRIDE;
            polygon->setMode(osg::PolygonMode::FRONT,osg::PolygonMode::LINE);
            polygon->setMode(osg::PolygonMode::BACK,osg::PolygonMode::POINT);
            state->setAttribute(polygon,override);
            state->setAttributeAndModes(new osg::CullFace(osg::CullFace::FRONT_AND_BACK),override);
            state->setAttribute(new osg::FrontFace(osg::FrontFace::CLOCKWISE));
            state->setAttribute(new osg::PolygonOffset(2.5f,3.25f));
            for(const auto capability:{GL_POLYGON_OFFSET_FILL,GL_POLYGON_OFFSET_LINE,GL_POLYGON_OFFSET_POINT})
                state->setMode(capability,override);
            state->setAttribute(new osg::LineWidth(5.f));state->setAttribute(new osg::Point(7.f));
            osg::ref_ptr<osg::Image> image=new osg::Image;image->allocateImage(1,1,1,GL_RGBA,GL_UNSIGNED_BYTE);
            std::memset(image->data(),255,4);
            osg::ref_ptr<osg::Texture2D> texture=new osg::Texture2D(image);
            texture->setFilter(osg::Texture::MIN_FILTER,osg::Texture::LINEAR);
            state->setTextureAttributeAndModes(0,texture);
            state->setTextureAttribute(0,textureMatrix);
            state->setTextureAttribute(0,new osg::PointSprite);
            state->setMode(GL_POINT_SPRITE_ARB,osg::StateAttribute::ON);
        }
    };
    void material(const WebCuda::MaterialTable& table,unsigned int id,bool expanded,bool sprite,bool gui=false) {
        const auto* record=table.materials().data()+id*12;
        const auto* raster=table.rasterParams().data()+id*50;
        assert(bool(record[3]&4194304u)==expanded);
        assert(((record[9]>>14)&3u)==(expanded?0u:3u));
        assert(((record[9]>>27)&15u)==(expanded?0u:9u));
        assert((record[9]&65536u)!=0); // Keep facing for polygons; CUDA ignores it for non-polygon stencil.
        for(const auto offset:{0,1,39,40,41,42}) {
            const bool factor=offset==0||offset==39||offset==41;
            assert(raster[offset]==(expanded?0.f:(factor?2.5f:3.25f)));
        }
        assert(raster[37]==5.f&&raster[38]==7.f);
        // Feed captured records into the authored clip kernel. An expanded
        // footprint crossing the viewport must keep its original vertices;
        // ordinary polygons must still clip to the side planes.
        const float footprint[]={-.5f,-.5f,0,1, 1.5f,-.5f,0,1, 0,.5f,0,1};
        const unsigned int triangle[]={0,1,2,id},edges[]={7};
        float positions[84]={},weights[84]={};unsigned int valid[7]={};
        ClipReference::clip_triangles(footprint,triangle,table.materials().data(),edges,positions,weights,valid,1,4,4);
        if(expanded) {
            assert(valid[0]&&std::memcmp(positions,footprint,sizeof(footprint))==0);
            for(unsigned int t=1;t<7;t++)assert(!valid[t]);
        } else {
            assert(valid[0]);
            for(unsigned int t=0;t<7;t++)if(valid[t])for(unsigned int v=0;v<3;v++)
                assert(positions[t*12+v*4]<=positions[t*12+v*4+3]);
        }
        if(gui) {assert((record[3]&1u)==0);return;}
        assert((record[3]&16384u)!=0);
        const auto environment=record[0];
        for(unsigned int k=0;k<16;k++) {
            float value;std::memcpy(&value,&table.texels().at(environment+28+k),4);
            const float expected=k%5?0.f:(sprite?1.f:(k==0?2.f:k==5?3.f:k==10?4.f:1.f));
            assert(value==expected);
        }
    }
    osg::ref_ptr<osg::Geometry> geometry(unsigned int mode) {
        osg::ref_ptr<osg::Geometry> result=new osg::Geometry;
        osg::ref_ptr<osg::Vec3Array> positions=new osg::Vec3Array;
        positions->push_back({-.5f,-.5f,0});positions->push_back({.5f,-.5f,0});positions->push_back({0,.5f,0});
        result->setVertexArray(positions);
        result->addPrimitiveSet(new osg::DrawArrays(mode,0,mode==GL_LINES?2:3));
        return result;
    }
    void geometryCases() {
        Fixture f;
        for(const auto mode:{GL_TRIANGLES,GL_POINTS,GL_LINES,GL_LINE_STRIP,GL_LINE_LOOP})for(const bool gui:{false,true}) {
            WebCuda::MaterialTable table(64,64);
            const WebCuda::MaterialResolver resolve=[&](const auto& c,const auto* t,bool gui){return table.encode(c,t,gui);};
            const auto source=geometry(mode);
            WebCuda::GeometryPacket dense,compact(true);
            WebCuda::captureGeometry(dense,*source,f.context,resolve,gui);
            WebCuda::captureGeometry(compact,*source,f.context,resolve,gui);
            assert(!dense.triangles.empty()&&dense.triangles==compact.triangles);
            VertexInputReference::verify(compact,dense);
            for(unsigned int i=3;i<dense.triangles.size();i+=4)
                material(table,dense.triangles[i],mode!=GL_TRIANGLES,mode==GL_POINTS,gui);
            assert(f.context.states.size()==1&&!f.context.screenPrimitiveDraw&&!f.context.pointDraw);
            assert(f.polygon->getMode(osg::PolygonMode::FRONT)==osg::PolygonMode::LINE);
        }
        // A single drawable can mix polygon, line and point topology. Its three
        // material variants must retain distinct face/sprite semantics.
        auto mixed=geometry(GL_TRIANGLES);
        mixed->addPrimitiveSet(new osg::DrawArrays(GL_LINES,0,2));
        mixed->addPrimitiveSet(new osg::DrawArrays(GL_POINTS,0,1));
        WebCuda::MaterialTable table(64,64);
        WebCuda::GeometryPacket packet(true);
        WebCuda::captureGeometry(packet,*mixed,f.context,[&](const auto& c,const auto* t,bool gui){return table.encode(c,t,gui);});
        assert(packet.triangles.size()==20);
        material(table,packet.triangles[3],false,false);
        for(const auto i:{7,11})material(table,packet.triangles[i],true,false);
        for(const auto i:{15,19})material(table,packet.triangles[i],true,true);
        // Later draws must re-read modified state, without changing old records.
        const auto original=table.materials();const auto oldRaster=table.rasterParams();
        f.polygon->setMode(osg::PolygonMode::FRONT_AND_BACK,osg::PolygonMode::FILL);
        f.state->setMode(GL_CULL_FACE,osg::StateAttribute::OFF);
        WebCuda::GeometryPacket next;
        WebCuda::captureGeometry(next,*mixed,f.context,[&](const auto& c,const auto* t,bool gui){return table.encode(c,t,gui);});
        assert((table.materials()[next.triangles[3]*12+9]&((15u<<27)|(3u<<14)))==0);
        assert(std::equal(original.begin(),original.end(),table.materials().begin()));
        assert(std::equal(oldRaster.begin(),oldRaster.end(),table.rasterParams().begin()));
    }
    void particles() {
        Fixture f;
        osg::ref_ptr<osgParticle::ParticleSystem> system=new osgParticle::ParticleSystem;
        for(const auto shape:{osgParticle::Particle::QUAD,osgParticle::Particle::LINE,osgParticle::Particle::POINT}) {
            osgParticle::Particle prototype;prototype.setShape(shape);
            system->createParticle(&prototype);
        }
        WebCuda::MaterialTable table(64,64);
        const WebCuda::MaterialResolver resolve=[&](const auto& c,const auto* t,bool gui){return table.encode(c,t,gui);};
        WebCuda::GeometryPacket dense,compact(true);
        WebCuda::captureParticles(dense,*system,f.context,resolve);
        WebCuda::captureParticles(compact,*system,f.context,resolve);
        assert(dense.triangles.size()==24&&dense.triangles==compact.triangles);
        VertexInputReference::verify(compact,dense);
        for(const auto i:{3,7})material(table,dense.triangles[i],false,false);
        for(const auto i:{11,15})material(table,dense.triangles[i],true,false);
        for(const auto i:{19,23})material(table,dense.triangles[i],true,true);
        // Connected systems keep both variants: CUDA chooses a thin line or a
        // polygon ribbon using view-dependent size. Polygon edges remain intact.
        osg::ref_ptr<osgParticle::ConnectedParticleSystem> ribbon=new osgParticle::ConnectedParticleSystem;
        ribbon->createParticle(nullptr)->setPosition({-1,0,0});
        ribbon->createParticle(nullptr)->setPosition({1,0,0});
        WebCuda::GeometryPacket connected(true);
        WebCuda::captureParticles(connected,*ribbon,f.context,resolve);
        assert(connected.ribbonRanges.size()==13);
        material(table,connected.ribbonRanges[6],false,false);
        material(table,connected.ribbonRanges[7],true,false);
        assert((connected.polygonEdges==std::vector<std::uint32_t>{3u,6u}));
    }
}
int main() {
    geometryCases();particles();
    std::puts("Shared game capture: polygon/point/line/mixed geometry, decorations, particle sprites, ribbon variants, compact inputs and state mutation passed");
}
