#ifndef OPENMW_COMPONENTS_WEBCUDA_LIGHTINPUTS_H
#define OPENMW_COMPONENTS_WEBCUDA_LIGHTINPUTS_H

#include <array>
#include <algorithm>
#include <vector>
#include <utility>
#include <osg/Light>
#include <osg/Matrixd>
#include <osg/Matrixf>
#include <osg/Uniform>
#include <components/sceneutil/clusteredlighting.hpp>

namespace WebCuda
{
    // Attach to the actual uniform, so a child override cannot accidentally
    // inherit the raw-input marker belonging to a different light value.
    struct LightInputs final : osg::Referenced
    {
        enum Kind { Sun, Points };
        explicit LightInputs(Kind value, const osg::Matrixd& camera)
            : kind(value), view(camera) {}
        Kind kind;
        osg::Matrixf view;
        float radiusMultiplier = 1.f;
        // Already available scene-culling centers, followed by fade start/end.
        // Color fading is evaluated in CUDA; end == 0 disables it.
        std::vector<std::array<float, 5>> fades;
    };

    using LightListKey = std::pair<std::vector<int>, std::array<double, 16>>;
    inline LightListKey lightListKey(std::vector<int> ids, const osg::Matrixd& view)
    {
        LightListKey key{std::move(ids), {}};
        std::copy_n(view.ptr(), 16, key.second.begin());
        return key;
    }

    inline void capturePointLight(osg::Uniform& target, unsigned int index,
        const osg::Light& light, float radius)
    {
        osg::Matrixf record;
        for (unsigned int k = 0; k < 3; ++k)
        {
            record(0, k) = light.getPosition()[k];
            record(1, k) = light.getAmbient()[k];
            record(2, k) = light.getDiffuse()[k];
            record(3, k) = light.getSpecular()[k];
        }
        record(0, 3) = light.getConstantAttenuation();
        record(1, 3) = light.getLinearAttenuation();
        record(2, 3) = light.getQuadraticAttenuation();
        record(3, 3) = radius;
        target.setElement(index, record);
    }

    inline SceneUtil::PointLight captureClusterLight(const osg::Light& light, float radius)
    {
        return {light.getPosition(), light.getDiffuse(), light.getAmbient(), light.getSpecular(),
            light.getConstantAttenuation(), light.getLinearAttenuation(), light.getQuadraticAttenuation(), radius};
    }
}
#endif
