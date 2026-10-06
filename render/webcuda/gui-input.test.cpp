// Feed the real MyGUI vertex layout through the capture producer and compare
// authored CUDA construction against the independent dense capture path.
#include <cassert>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <MYGUI/MyGUI_VertexData.h>
#include <osg/Geometry>
#include <osgParticle/ParticleSystem>
#include <components/webcuda/geometrypacket.hpp>
#include "vertex-input-reference.hpp"

namespace {
    static_assert(sizeof(MyGUI::Vertex)==24 && offsetof(MyGUI::Vertex,colour)==12 && offsetof(MyGUI::Vertex,u)==16);
    struct Fixture {
        osg::Matrixd model=osg::Matrix::translate(.25,-.5,-3),projection=osg::Matrix::scale(2,3,4);
        WebCuda::DrawContext context{&projection,&model,{}};
        osg::ref_ptr<osg::UByteArray> bytes;
        explicit Fixture(unsigned int count):bytes(new osg::UByteArray((count+6)*sizeof(MyGUI::Vertex))) {
            for(unsigned int i=0;i<count+6;i++) {
                // Every channel spans all 256 byte values, in distinct orders.
                const auto color=(i&255u)|(((255u-i)&255u)<<8)|(((i+73u)&255u)<<16)|(((i*37u)&255u)<<24);
                MyGUI::Vertex vertex;vertex.set(float(i%13)*.125f-.5f,float(i%7)*.25f-1.f,
                    float(i%5)*.0625f,float(i%11)*.125f-.25f,float(i%17)*.125f,color);
                if(i>=count)vertex.x=std::numeric_limits<float>::quiet_NaN(); // Unused capacity is not captured.
                std::memcpy(&bytes->front()+i*sizeof(vertex),&vertex,sizeof(vertex));
            }
            for(unsigned int k=0;k<3;k++)context.currentSecondaryColor[k]=float(k+1)*.125f;
        }
    };
    std::size_t oldWords=0,newWords=0,guiVertices=0;
    void append(WebCuda::GeometryPacket& compact,WebCuda::GeometryPacket& dense,Fixture& f,unsigned int count) {
        const auto before=compact.vertexInputs.size();
        for(auto* packet:{&compact,&dense})WebCuda::appendGui(*packet,*f.bytes,count,f.context,7);
        const auto descriptor=compact.vertexLayouts.size()-32;
        assert(compact.vertexLayouts[descriptor+1]==count && compact.vertexLayouts[descriptor+2]==count
            && compact.vertexLayouts[descriptor+3]==3 && compact.vertexLayouts[descriptor+4]==0);
        assert(compact.vertexInputs.size()-before==3+count*9);
        oldWords+=count*47;newWords+=3+count*9;guiVertices+=count;
    }
    void compare(Fixture& f,unsigned int count,bool neighbors) {
        WebCuda::GeometryPacket compact(true),dense;
        osg::ref_ptr<osg::Geometry> geometry=new osg::Geometry;
        auto* vertices=new osg::Vec3Array;vertices->push_back({-1,0,0});vertices->push_back({1,0,0});vertices->push_back({0,1,0});
        geometry->setVertexArray(vertices);geometry->addPrimitiveSet(new osg::DrawArrays(GL_TRIANGLES,0,3));
        osg::ref_ptr<osgParticle::ParticleSystem> particles=new osgParticle::ParticleSystem;
        particles->setUseShaders(false);particles->createParticle(nullptr);
        if(neighbors)for(auto* packet:{&compact,&dense})WebCuda::appendGeometry(*packet,*geometry,f.context,1);
        append(compact,dense,f,count);
        if(neighbors) {
            for(auto* packet:{&compact,&dense})WebCuda::appendParticles(*packet,*particles,f.context,2);
            append(compact,dense,f,count);
            for(auto* packet:{&compact,&dense})WebCuda::appendGeometry(*packet,*geometry,f.context,3);
        }
        VertexInputReference::verify(compact,dense);
        if(count) {
            const auto captured=compact.vertexInputs;
            MyGUI::Vertex first;std::memcpy(&first,&f.bytes->front(),sizeof(first));
            first.x+=.125f;first.u-=.5f;first.colour^=0xff00ffffu;
            std::memcpy(&f.bytes->front(),&first,sizeof(first)); // No dirty notification.
            f.context.currentSecondaryColor[0]+=.125f;
            WebCuda::GeometryPacket changed(true),changedDense;append(changed,changedDense,f,count);
            VertexInputReference::verify(changed,changedDense);
            assert(compact.vertexInputs==captured); // Retained capture owns its bytes.
            const auto firstDraw=neighbors?32u:0u;
            assert(compact.vertexInputs[compact.vertexLayouts[firstDraw+6]]!=changed.vertexInputs[changed.vertexLayouts[6]]);
        }
    }
    void rejects(Fixture& f,std::size_t count) {
        for(bool compact:{false,true}) {
            WebCuda::GeometryPacket packet(compact);bool rejected=false;
            try {WebCuda::appendGui(packet,*f.bytes,count,f.context,0);}catch(const std::runtime_error&){rejected=true;}
            assert(rejected&&packet.vertexCount()==0&&packet.triangles.empty()&&packet.vertexInputs.empty());
        }
    }
}
int main() {
    for(unsigned int count:{0u,3u,6u,63u,66u,258u,1536u})for(bool neighbors:{false,true}) {
        Fixture f(count);compare(f,count,neighbors);
    }
    Fixture invalid(3);rejects(invalid,1);rejects(invalid,12);
    float bad=std::numeric_limits<float>::infinity();std::memcpy(&invalid.bytes->front(),&bad,4);rejects(invalid,3);
    bad=0;std::memcpy(&invalid.bytes->front(),&bad,4);
    bad=std::numeric_limits<float>::quiet_NaN();std::memcpy(&invalid.bytes->front()+16,&bad,4);rejects(invalid,3);
    bad=0;std::memcpy(&invalid.bytes->front()+16,&bad,4);
    // GUI deliberately disables inherited fixed lighting and secondary color.
    invalid.context.currentSecondaryColor[1]=std::numeric_limits<float>::infinity();
    WebCuda::GeometryPacket ignored(true),ignoredDense;append(ignored,ignoredDense,invalid,3);
    VertexInputReference::verify(ignored,ignoredDense);
    for(float value:ignoredDense.secondaryColors)assert(value==0.f);
    invalid.context.modelView=nullptr;rejects(invalid,3);
    osg::ref_ptr<osg::UByteArray> empty=new osg::UByteArray;invalid.bytes=empty;rejects(invalid,3);
    VertexInputReference::save();
    std::printf("MyGUI capture: byte order, all color levels, partial batches, mixed draws, edits, ownership and rejection passed; %zu GUI vertices, payload %zu -> %zu words\n",guiVertices,oldWords,newWords);
}
