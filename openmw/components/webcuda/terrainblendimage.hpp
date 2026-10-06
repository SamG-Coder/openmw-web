#ifndef OPENMW_WEBCUDA_TERRAINBLENDIMAGE_H
#define OPENMW_WEBCUDA_TERRAINBLENDIMAGE_H

#include <osg/Image>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <vector>

namespace WebCuda
{
    // Immutable terrain inputs, not an image painted on the CPU. Mode 0 stores
    // [grid width, grid height, layer count, layer IDs...]. Mode 1 stores
    // [quad columns, quad rows, layer count, quad offsets...], then each quad's
    // base layer, 290 source-vertex offsets and ordered (layer, opacity bits)
    // pairs. Zero quad offsets denote absent land. Offsets are source-relative.
    // The image supplies dimensions/identity to Terrain's existing texture path.
    class TerrainBlendImage final : public osg::Image
    {
    public:
        TerrainBlendImage(std::shared_ptr<const std::vector<std::uint32_t>> source,
            unsigned int sourceMode, unsigned int layerIndex, int width, int height)
            : inputs(std::move(source)), mode(sourceMode), layer(layerIndex)
        {
            if (!inputs || inputs->size() < 3 || mode > 1 || width <= 0 || height <= 0
                || layer >= (*inputs)[2])
                throw std::invalid_argument("Invalid CUDA terrain blend image");
            setImage(width, height, 1, GL_ALPHA, GL_ALPHA, GL_UNSIGNED_BYTE, nullptr, NO_DELETE, 1);
        }
        TerrainBlendImage(const TerrainBlendImage& other, const osg::CopyOp& copy = osg::CopyOp::SHALLOW_COPY)
            : osg::Image(other, copy), inputs(other.inputs), mode(other.mode), layer(other.layer) {}
        osg::Object* cloneType() const override { return new TerrainBlendImage(*this); }
        osg::Object* clone(const osg::CopyOp& copy) const override { return new TerrainBlendImage(*this, copy); }

        const std::shared_ptr<const std::vector<std::uint32_t>> inputs;
        const unsigned int mode, layer;
    };
}
#endif
