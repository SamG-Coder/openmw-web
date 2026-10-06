#ifndef OPENMW_COMPONENTS_SCENEUTIL_MEMORYBARRIER_H
#define OPENMW_COMPONENTS_SCENEUTIL_MEMORYBARRIER_H

#include <osg/Drawable>
#include <osg/StateSet>
#include <components/webcuda/submission.hpp>

namespace SceneUtil
{
    struct MemoryBarrier : public osg::Drawable::DrawCallback, public WebCuda::CustomDrawCallback
    {
        MemoryBarrier(GLbitfield barriers)
            : _barriers(barriers)
        {
        }

        virtual void drawImplementation(osg::RenderInfo& renderInfo, const osg::Drawable* drawable) const
        {
            drawable->drawImplementation(renderInfo);
            renderInfo.getState()->get<osg::GLExtensions>()->glMemoryBarrier(_barriers);
        }
        osg::ref_ptr<osg::StateSet> captureWebCudaState() const override
        {
            // Cluster compute is re-dispatched in ordered WebGPU submissions.
            // Only its known storage dependency is represented by that ordering.
            if((_barriers&~GL_SHADER_STORAGE_BARRIER_BIT)!=0)
                throw std::runtime_error("Untranslated WebCuda memory barrier");
            return nullptr;
        }
        GLbitfield _barriers;
    };
}

#endif
