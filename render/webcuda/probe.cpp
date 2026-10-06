// Browser integration probe: real OSG cull -> material/geometry tables -> WASM
// transport. The fixture explicitly requests the supported unlit material domain.
#include <osg/FrameStamp>
#include <osg/Geode>
#include <osg/Geometry>
#include <osgViewer/View>
#include <cstring>
#include <components/webcuda/browserbridge.hpp>
#include <components/webcuda/renderer.hpp>
int main() {
    osg::ref_ptr<osgViewer::View> view=new osgViewer::View;
    view->setFrameStamp(new osg::FrameStamp);
    auto* camera=view->getCamera();
    camera->setViewport(0,0,256,256);
    camera->setProjectionMatrix(osg::Matrix::identity());camera->setViewMatrix(osg::Matrix::identity());
    osg::ref_ptr<osg::Geometry> geometry=new osg::Geometry;
    osg::ref_ptr<osg::Vec3Array> positions=new osg::Vec3Array;
    positions->push_back(osg::Vec3(-.8f,-.8f,0));positions->push_back(osg::Vec3(.8f,-.8f,0));positions->push_back(osg::Vec3(0,.8f,0));
    geometry->setVertexArray(positions);geometry->addPrimitiveSet(new osg::DrawArrays(GL_TRIANGLES,0,3));
    osg::ref_ptr<osg::Vec2Array> uv=new osg::Vec2Array(3);for(auto& value:*uv)value.set(.5f,.5f);
    geometry->setTexCoordArray(0,uv);
    osg::ref_ptr<osg::Image> image=new osg::Image;
    const unsigned int words[]={0x001ff800,0};auto* bytes=new unsigned char[8];std::memcpy(bytes,words,8);
    image->setImage(4,4,1,0x83f1,0x83f1,GL_UNSIGNED_BYTE,bytes,osg::Image::USE_NEW_DELETE);
    osg::ref_ptr<osg::Texture2D> texture=new osg::Texture2D(image);
    texture->setWrap(osg::Texture::WRAP_S,osg::Texture::CLAMP_TO_EDGE);texture->setWrap(osg::Texture::WRAP_T,osg::Texture::CLAMP_TO_EDGE);
    texture->setFilter(osg::Texture::MIN_FILTER,osg::Texture::LINEAR);texture->setFilter(osg::Texture::MAG_FILTER,osg::Texture::LINEAR);
    osg::ref_ptr<osg::Geode> geode=new osg::Geode;geode->addDrawable(geometry);camera->addChild(geode);
    auto table=std::make_shared<WebCuda::MaterialTable>(256,256);
    WebCuda::GeometrySink sink([&](const WebCuda::DrawContext& context,const osg::Texture2D*,bool){return WebCuda::writableMaterialTable(table).encode(context,texture,true);},
        [&](const osgUtil::RenderStage&,const WebCuda::GeometryPacket& packet){WebCuda::submitBrowserPass(WebCuda::GeometryPacket(packet),table,256,256);});
    osg::ref_ptr<WebCuda::Renderer> renderer=new WebCuda::Renderer(camera,sink);
    renderer->cull_draw();
}
