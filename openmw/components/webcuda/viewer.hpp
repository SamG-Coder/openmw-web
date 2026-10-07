#ifndef OPENMW_COMPONENTS_WEBCUDA_VIEWER_H
#define OPENMW_COMPONENTS_WEBCUDA_VIEWER_H
#include <memory>
#include <chrono>
#include <functional>
#include <string>
#include <osg/Image>
#include <set>
#include <osgViewer/Viewer>
#include <osg/observer_ptr>
#include "geometrypacket.hpp"
#include "materialtable.hpp"
namespace WebCuda
{
    // Owns the sink for every camera created by OSG, including loading cameras.
    class Viewer final : public osgViewer::Viewer, private SubmissionSink
    {
    public:
        Viewer();
        ~Viewer() override;
        osg::GraphicsOperation* createRenderer(osg::Camera*) override;
        void renderingTraversals() override;
        static bool requested();
        bool refreshDeviceGeneration();
        void completeDeviceRecovery();
        using ImageCompletion=std::function<void(osg::ref_ptr<osg::Image>,std::string)>;
        // A null camera requests the final screen, including post-render GUI.
        void captureImage(osg::Camera*,unsigned int,unsigned int,ImageCompletion,unsigned int channels=3);

        void capturePreviousFrame(osg::Texture2D*);
        void captureFogImage(unsigned int width,unsigned int height,const std::vector<unsigned int>& inputs,ImageCompletion);

        static unsigned int queryPixels(const osg::Geometry*, const osg::Camera*);
    private:
        unsigned int mDeviceGeneration=0;
        std::vector<osg::ref_ptr<osg::Texture2D>> mFrameSnapshots;
        std::vector<osg::observer_ptr<osg::Texture2D>> mSnapshotTextures;
        void collectExpiredTargets();
        void collectImages();
        struct ImageRequest {
            osg::observer_ptr<osg::Camera> camera;
            unsigned int width,height;
            ImageCompletion completion;
            unsigned int channels=3;
            bool submitted=false;
            bool finalScreen=false;
            std::chrono::steady_clock::time_point started=std::chrono::steady_clock::now();
        };
        std::map<unsigned int,ImageRequest> mImageRequests;
        unsigned int mNextImageRequest=1;
        std::vector<unsigned int> mFrameImageRequests;
        std::vector<osg::observer_ptr<osg::Camera>> mFrameCompletionCameras,mSubmittedCompletionCameras;
        struct CameraImageState {
            osg::observer_ptr<osg::Camera> camera;
            osg::ref_ptr<osg::Image> image;
            unsigned int width,height,channels;
            int x,y;
            int status=0;
        };
        std::map<const osg::Camera*,std::shared_ptr<CameraImageState>> mCameraImages;

        void beginPass(const osgUtil::RenderStage&) override;
        void endPass(const osgUtil::RenderStage&) override;
        void geometry(const osg::Geometry&, const DrawContext&) override;
        void text(const osgText::Text&,const DrawContext&) override;
        unsigned int frameNumber() const override;
        float simulationTime() const override;
        const osg::Camera* currentCamera() const override { return mPassCamera; }
        bool isColorTarget(const osg::Texture2D&) const override;
        void captureDepth(const osg::Texture2D&) override;
        void beginColorTarget(const osg::Texture2D&) override;
        void beginDepthTarget(const osg::Texture2D&) override;
        void beginTextureTarget(const osg::Texture2D&,bool);
        void endColorTarget() override;
        void beginDepthIsolation(float) override;
        void endDepthIsolation() override;
        void resolveScene(const osg::Texture2D&,const osg::Texture2D*,float,float) override;
        void adjustScene(float,float) override;
        void distortScene(const osg::Texture2D&) override;
        void debugScene(const osg::Texture2D*,const osg::Texture2D*,const DebugSettings&) override;
        void bloomScene(const osg::Texture2D&,const BloomSettings&) override;
        void sceneLuminance(const osg::Texture2D&,unsigned int,unsigned int,float,float,float,bool) override;
        void splitDepthPass(bool,float);
        void ripples(const osg::Texture2D&,const float*,unsigned int,float,float,float,bool) override;
        void particles(const osgParticle::ParticleSystem&, const DrawContext&) override;
        void gui(const osg::Array&, std::size_t, const osg::Texture2D*, const DrawContext&) override;
        std::shared_ptr<MaterialTable> mTable;
        GeometryPacket mPacket{true};
        unsigned int mWidth=0, mHeight=0;
        struct Target { osg::observer_ptr<const osg::Texture2D> texture; std::uint32_t id; };
        std::map<const osg::Texture2D*,Target> mTargets;
        struct StencilTarget { osg::observer_ptr<const osg::Object> owner;std::uint32_t id; };
        std::map<const osg::Object*,StencilTarget> mStencilTargets;
        std::map<const osg::Object*,StencilTarget> mDepthRenderbuffers;
        struct ColorRenderbuffer {
            osg::observer_ptr<const osg::Object> owner;
            std::uint32_t id;
            unsigned int format;
        };
        // Camera-owned implicit renderbuffers use the component as part of identity.
        std::map<std::pair<const osg::Object*,unsigned int>,ColorRenderbuffer> mColorRenderbuffers;
        std::vector<std::uint32_t> mRetiredTargets;
        std::uint32_t mNextTarget=1;
        std::uint32_t mCurrentTarget=0;
        struct ResolveAttachment { std::uint32_t target;unsigned int plane,format; };
        std::vector<ResolveAttachment> mResolveAttachments;
        std::uint32_t mResolveSource=0;
        int mResolveX=0,mResolveY=0;
        unsigned int mResolveWidth=0,mResolveHeight=0;
        const osg::Camera* mPassCamera=nullptr;
        struct SavedStage {
            std::shared_ptr<MaterialTable> table;
            unsigned int width=0,height=0;
            std::uint32_t currentTarget=0,resolveSource=0;
            int resolveX=0,resolveY=0;
            unsigned int resolveWidth=0,resolveHeight=0;
            const osg::Camera* passCamera=nullptr;
            std::vector<ResolveAttachment> resolveAttachments;
            // JS-side pass state must be reopened when the parent resumes after
            // a nested OSG camera. Clear is deliberately suppressed on resume.
            std::uint32_t depthTarget=0,normalTarget=0,stencilTarget=0;
            unsigned int colorFormat=0x8058,depthFormat=0x81A6,normalFormat=0x8058;
            unsigned int stencilBits=0,clearColorMask=15,sampleCount=1;
            int viewportX=0,viewportY=0;
            unsigned int viewportWidth=0,viewportHeight=0;
            float clearDepth=1.f;
            int clearStencil=0;
        };
        std::vector<SavedStage> mStageStack;
        struct SavedTarget { std::shared_ptr<MaterialTable> table;unsigned int width,height;std::uint32_t target; };
        std::vector<SavedTarget> mTargetStack;
        std::set<std::uint32_t> mColorTargetsWritten;
    };
}
#endif
