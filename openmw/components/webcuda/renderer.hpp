#ifndef OPENMW_COMPONENTS_WEBCUDA_RENDERER_H
#define OPENMW_COMPONENTS_WEBCUDA_RENDERER_H

#include <osgViewer/Renderer>
#include "submission.hpp"

namespace WebCuda
{
    // Single-threaded OSG culling adapter. The sink owns all GPU work; this
    // operation never compiles OSG GL objects or calls SceneView::draw().
    // The sink must outlive the renderer. Installation requires a complete sink.
    class Renderer final : public osgViewer::Renderer
    {
    public:
        Renderer(osg::Camera* camera, SubmissionSink& sink);
        void cull_draw() override;
        void cull() override;
        void draw() override;
        void compile() override;

    private:
        SubmissionSink& mSink;
    };
}
#endif
