#ifndef OPENMW_COMPONENTS_WEBCUDA_MATERIALSTATE_H
#define OPENMW_COMPONENTS_WEBCUDA_MATERIALSTATE_H
#include <cstdint>
#include <array>
#include <vector>
#include <osg/ref_ptr>
#include <osg/StateSet>
#include "submission.hpp"
namespace osg { class Image; class Program; }
namespace WebCuda
{
    // Uses OSG's own OVERRIDE/PROTECTED merge rules for attributes, texture
    // units, uniforms, defines and modes. Attribute objects remain shared: the
    // material encoder must consume them synchronously before scene updates.
    bool isBuiltinParticleProgram(const osg::Program&);
    bool isBuiltinDefaultProgram(const osg::Program&);
    bool usesZeroToOneDepth(const osg::StateSet&);
    osg::ref_ptr<osg::StateSet> resolveState(const DrawContext&);
    // Encode fixed raster state; texture fields 0..2 are filled by the resource
    // table. Shader/material lighting and uniforms remain a separate translation.
    std::array<std::uint32_t,12> encodeRasterState(const osg::StateSet&, std::uint32_t width,
        std::uint32_t height, bool normalizedTarget = true);
    std::array<float,14> encodeStencilState(const osg::StateSet&);
    struct TexturePixels
    {
        std::uint32_t width = 0, height = 0;
        std::vector<std::uint32_t> rgba;
    };
    // Asset conversion only, no filtering or shading. Keeps source row order.
    // Compressed/mipmapped/HDR images require separate handling by the encoder.
    TexturePixels copyTexturePixels(const osg::Image&);
}
#endif
