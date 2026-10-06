#ifndef OPENMW_WEBCUDA_MAPTEXTURE_H
#define OPENMW_WEBCUDA_MAPTEXTURE_H
#include <osg/Texture2D>
#include <memory>
#include <vector>
#include <cstdint>
namespace WebCuda {
// Raw land samples and decoded palette inputs. Pixel generation lives in CUDA.
class MapTexture final : public osg::Texture2D {
public:
    MapTexture(std::shared_ptr<const std::vector<std::uint32_t>> source,bool alpha,int width,int height)
        : data(std::move(source)),alphaOnly(alpha) { setTextureSize(width,height);setInternalFormat(GL_RGBA8); }
    MapTexture(const MapTexture& other,const osg::CopyOp& copy=osg::CopyOp::SHALLOW_COPY)
        : osg::Texture2D(other,copy),data(other.data),alphaOnly(other.alphaOnly) {}
    osg::Object* cloneType() const override { return new MapTexture(*this); }
    osg::Object* clone(const osg::CopyOp& copy) const override { return new MapTexture(*this,copy); }
    const std::shared_ptr<const std::vector<std::uint32_t>> data;
    const bool alphaOnly;
};
}
#endif
