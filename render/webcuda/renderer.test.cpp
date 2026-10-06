#include <cassert>
#include <cstdio>
#include <stdexcept>
#include <osg/Geode>
#include <osg/Geometry>
#include <osg/FrameStamp>
#include <osgViewer/View>
#include <components/webcuda/renderer.hpp>
#include <components/webcuda/geometrypacket.hpp>

struct Sink : WebCuda::SubmissionSink
{
    int passes = 0, draws = 0;
    void beginPass(const osgUtil::RenderStage&) override { ++passes; }
    void endPass(const osgUtil::RenderStage&) override {}
    void geometry(const osg::Geometry&, const WebCuda::DrawContext& c) override {
        assert(c.projection && c.modelView);
        ++draws;
    }
    void gui(const osg::Array&, std::size_t, const osg::Texture2D*, const WebCuda::DrawContext&) override {}
};

int main()
{
    // No graphics context exists in this Node process. Any GL compilation or
    // draw traversal would fail; culling and submission must work independently.
    osg::ref_ptr<osgViewer::View> view = new osgViewer::View;
    view->setFrameStamp(new osg::FrameStamp);
    auto* camera = view->getCamera();
    camera->setViewport(0, 0, 64, 64);
    camera->setProjectionMatrix(osg::Matrix::identity());
    camera->setViewMatrix(osg::Matrix::identity());
    osg::ref_ptr<osg::Geometry> geometry = new osg::Geometry;
    auto* positions = new osg::Vec3Array;
    positions->push_back(osg::Vec3(-0.5f, -0.5f, 0.f));
    positions->push_back(osg::Vec3(0.5f, -0.5f, 0.f));
    positions->push_back(osg::Vec3(0.f, 0.5f, 0.f));
    geometry->setVertexArray(positions);
    geometry->addPrimitiveSet(new osg::DrawArrays(GL_TRIANGLES, 0, 3));
    osg::ref_ptr<osg::Geode> geode = new osg::Geode;
    geode->addDrawable(geometry);
    camera->addChild(geode);
    Sink sink;
    osg::ref_ptr<WebCuda::Renderer> renderer = new WebCuda::Renderer(camera, sink);
    renderer->cull_draw();
    assert(sink.passes == 1 && sink.draws == 1);
    renderer->setDone(true);
    renderer->cull_draw();
    assert(sink.draws == 1);
    bool rejected = false;
    try { renderer->draw(); } catch (const std::runtime_error&) { rejected = true; }
    assert(rejected);
    bool encoded=false;
    WebCuda::GeometrySink packetSink([](const WebCuda::DrawContext&,const osg::Texture2D*,bool){return 0;},
        [&](const osgUtil::RenderStage&,const WebCuda::GeometryPacket& packet){
            assert(packet.vertices.size()==30 && packet.triangles.size()==4);
            assert(packet.vertices[0]==-.5f && packet.vertices[10]==.5f);
            assert(packet.triangles[0]==0 && packet.triangles[1]==1 && packet.triangles[2]==2);
            assert(packet.matrices.size()==32 && packet.matrixIds.size()==3);
            encoded=true;
        });
    osg::ref_ptr<WebCuda::Renderer> packetRenderer=new WebCuda::Renderer(camera,packetSink);
    packetRenderer->cull_draw();
    assert(encoded);
    std::puts("WebCuda renderer: headless cull/submission, stop and split-thread rejection passed");
    std::puts("WebCuda renderer: actual OSG cull to packed geometry sink passed");
}
