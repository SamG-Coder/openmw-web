#ifndef OPENMW_COMPONENTS_WEBCUDA_SUBMISSION_H
#define OPENMW_COMPONENTS_WEBCUDA_SUBMISSION_H

#include <cstddef>
#include <vector>
#include <stdexcept>
#include <osg/Material>

namespace osg {
    class Array;
    class Geometry;
    class Matrixd;
    class StateSet;
    class Texture2D;
    class Drawable;
    class Camera;
}
namespace osgText { class Text; }
namespace osgUtil { class RenderStage; }
namespace osgParticle { class ParticleSystem; }

namespace WebCuda
{
    class ResolvedStateScope;
    // Borrowed for the duration of each synchronous submission call. The sink
    // must upload/copy changed data before returning, never retain WASM pointers
    // across asynchronous browser callbacks or a possible heap growth.
    struct DrawContext
    {
        const osg::Matrixd* projection = nullptr;
        const osg::Matrixd* modelView = nullptr;
        const osg::Matrixd* localTransform = nullptr; // optional raw drawable placement, applied in CUDA
        std::vector<const osg::StateSet*> states;
        // Borrowed only within an immutable, synchronous capture scope. Stack
        // variants are checked by resolveState; custom drawables start fresh.
        const ResolvedStateScope* resolvedState = nullptr;
        const osg::Matrixd* view = nullptr;
        const float* textPlacement = nullptr; // borrowed camera-dependent text parameters18
        const float* textGradient = nullptr; // borrowed TL/BL/BR/TR RGBA constants
        unsigned int queryId = 0;
        float simulationTime=0.f;
        float currentSecondaryColor[3]={0.f,0.f,0.f};
        float currentColor[4]={1.f,1.f,1.f,1.f};
        bool hasCurrentColor=false;
        float currentNormal[3]={0.f,0.f,1.f};
        float currentFogCoordinate=0.f;
        bool particleDraw=false;
        float particleNormal[3]={0.f,0.f,1.f};
        const osg::Matrixd* texgenModelView[4]={nullptr,nullptr,nullptr,nullptr};
        const osg::Matrixd* lightModelView[8]={nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr};
        // Raw inherited-stage transforms. CUDA composes these with the
        // application matrices; capture never multiplies the matrix pair.
        const osg::Matrixd* texgenModelViewPost[4]={nullptr,nullptr,nullptr,nullptr};
        const osg::Matrixd* lightModelViewPost[8]={nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr};
        bool screenPrimitiveDraw=false; // CUDA clips the centreline/point before expanding its raster footprint.
        bool pointDraw=false; // Ordinary point primitives: bypass replaced texture matrices.
    };

    struct DebugSettings
    {
        bool displayDepth=true,displayNormals=true,worldNormals=false,reverseZ=false;
        float nearPlane=0.f,farPlane=0.f,depthFactor=1.f;
        float view[16]={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};
    };
    struct BloomSettings
    {
        float gamma=2.2f,threshold=0.35f,clamp=1.f,skyFactor=0.5f,radius=0.5f,strength=0.25f;
        float nearPlane=0.f,farPlane=0.f,resolutionWidth=0.f,resolutionHeight=0.f,time=0.f;
        bool reverseZ=false;
    };
    class SubmissionSink
    {
    public:
        // Current compatibility attributes survive render-stage/frame boundaries.
        // These are submitted values, not CPU-transformed rendering results.
        struct CurrentAttributes {
            float secondaryColor[3]={0.f,0.f,0.f};
            float color[4]={1.f,1.f,1.f,1.f};
            float normal[3]={0.f,0.f,1.f};
            float fogCoordinate=0.f;
            osg::ref_ptr<const osg::Material> material;
            osg::ref_ptr<const osg::Material> defaultMaterial;
        };
        CurrentAttributes currentAttributes;
        virtual ~SubmissionSink() = default;
        virtual void beginPass(const osgUtil::RenderStage& stage) = 0;
        virtual void endPass(const osgUtil::RenderStage& stage) = 0;
        virtual void geometry(const osg::Geometry& geometry, const DrawContext& context) = 0;
        virtual void text(const osgText::Text&,const DrawContext&) { throw std::runtime_error("Text submission unsupported by sink"); }
        virtual unsigned int frameNumber() const { return 0; }
        virtual float simulationTime() const { return 0.f; }
        virtual const osg::Camera* currentCamera() const { return nullptr; }
        virtual bool isColorTarget(const osg::Texture2D&) const { return false; }
        virtual void captureDepth(const osg::Texture2D&) { throw std::runtime_error("Depth capture unsupported by sink"); }
        virtual void beginColorTarget(const osg::Texture2D&) { throw std::runtime_error("Nested color target unsupported by sink"); }
        virtual void endColorTarget() { throw std::runtime_error("Nested color target unsupported by sink"); }
        virtual void beginDepthTarget(const osg::Texture2D&) { throw std::runtime_error("Nested depth target unsupported by sink"); }
        virtual void beginDepthIsolation(float) { throw std::runtime_error("Depth isolation is unsupported by this sink"); }
        virtual void endDepthIsolation() { throw std::runtime_error("Depth isolation is unsupported by this sink"); }
        virtual void resolveScene(const osg::Texture2D&,const osg::Texture2D*,float=1.f,float=1.f)
        { throw std::runtime_error("Scene resolve is unsupported by this sink"); }
        virtual void debugScene(const osg::Texture2D*,const osg::Texture2D*,const DebugSettings&)
        { throw std::runtime_error("Scene debug is unsupported by this sink"); }
        virtual void bloomScene(const osg::Texture2D&,const BloomSettings&)
        { throw std::runtime_error("Scene bloom is unsupported by this sink"); }
        virtual void sceneLuminance(const osg::Texture2D&,unsigned int,unsigned int,float,float,float,bool)
        { throw std::runtime_error("Scene luminance is unsupported by this sink"); }
        virtual void distortScene(const osg::Texture2D&)
        { throw std::runtime_error("Scene distortion is unsupported by this sink"); }
        virtual void adjustScene(float,float)
        { throw std::runtime_error("Scene adjustments are unsupported by this sink"); }
        virtual void ripples(const osg::Texture2D&,const float*,unsigned int,float,float,float,bool)
        { throw std::runtime_error("This WebCuda sink does not accept ripple simulation"); }
        virtual void particles(const osgParticle::ParticleSystem&, const DrawContext&)
        { throw std::runtime_error("This WebCuda sink does not accept particles"); }
        // MyGUI's existing packed layout: float xyz, uint32 RGBA, float uv (24 bytes).
        virtual void gui(const osg::Array& vertices, std::size_t vertexCount,
            const osg::Texture2D* texture, const DrawContext& context) = 0;
    };

    // Custom drawables participate explicitly. Never invoke drawImplementation:
    // that would quietly reintroduce OpenGL into the WebCuda render path.
    class CustomDrawCallback
    {
    public:
        virtual ~CustomDrawCallback() = default;
        virtual osg::ref_ptr<osg::StateSet> captureWebCudaState() const = 0;
    };
    class CustomDrawable
    {
    public:
        virtual ~CustomDrawable() = default;
        virtual void submitWebCuda(SubmissionSink& sink, const DrawContext& context) const = 0;
    };
    class CustomRenderBin
    {
    public:
        virtual ~CustomRenderBin() = default;
        virtual bool shouldSubmitWebCuda(const SubmissionSink&) const { return true; }
        virtual const osg::StateSet* beginWebCuda(SubmissionSink&) = 0;
        virtual void endWebCuda(SubmissionSink&) = 0;
        virtual const osg::StateSet* beginReplayWebCuda(SubmissionSink&) { return nullptr; }
        virtual bool acceptReplayWebCuda(const osg::Drawable&,const DrawContext&) const { return true; }
        virtual void endReplayWebCuda(SubmissionSink&) {}
        virtual bool replaySubtreeWebCuda() const { return false; }
    };

    // Submit sorted OSG draw data, including pre/post render cameras and bins.
    // Unsupported custom drawables fail explicitly instead of disappearing.
    void submitStage(osgUtil::RenderStage& stage, SubmissionSink& sink,
        const std::vector<const osg::StateSet*>& inherited = {}, const osg::Matrixd* view = nullptr);
}
#endif
