#include "renderer.hpp"

#include <stdexcept>
#include <osg/Camera>
#include <osg/View>
#include <osgUtil/SceneView>

namespace WebCuda
{
    Renderer::Renderer(osg::Camera* camera, SubmissionSink& sink)
        : osgViewer::Renderer(camera), mSink(sink)
    {
        setCompileOnNextDraw(false);
        setGraphicsThreadDoesCull(true);
    }

    void Renderer::cull_draw()
    {
        auto* scene = getSceneView(0);
        if (getDone() || !scene) return;
        auto* camera = scene->getCamera();
        // OSG's updateSceneView dereferences the graphics state when the view
        // has no frame stamp. Require the engine's normal frame-stamped view.
        if (!camera || !camera->getView() || !camera->getView()->getFrameStamp())
            throw std::runtime_error("WebCuda requires a frame-stamped camera view");
        updateSceneView(scene);
        scene->inheritCullSettings(*camera);
        scene->cull();
        submitStage(*scene->getRenderStage(), mSink,{},&camera->getViewMatrix());
    }

    void Renderer::cull()
    {
        throw std::runtime_error("WebCuda requires single-threaded cull and submission");
    }

    void Renderer::draw()
    {
        throw std::runtime_error("WebCuda requires single-threaded cull and submission");
    }

    void Renderer::compile()
    {
        // Geometry and textures are uploaded by the sink, never by OSG's GL compiler.
    }
}
