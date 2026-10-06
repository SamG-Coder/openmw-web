#include <array>

#include <osgUtil/RenderBin>
#include <components/webcuda/submission.hpp>

namespace osg
{
    class FrameBufferObject;
}

namespace MWRender
{
    class DistortionCallback : public osgUtil::RenderBin::DrawCallback, public WebCuda::CustomRenderBin
    {
    public:
        bool shouldSubmitWebCuda(const WebCuda::SubmissionSink&) const override;
        const osg::StateSet* beginWebCuda(WebCuda::SubmissionSink&) override;
        void endWebCuda(WebCuda::SubmissionSink&) override;
        void drawImplementation(
            osgUtil::RenderBin* bin, osg::RenderInfo& renderInfo, osgUtil::RenderLeaf*& previous) override;

        void setFBO(const osg::ref_ptr<osg::FrameBufferObject>& fbo, size_t frameId) { mFBO[frameId] = fbo; }
        void setOriginalFBO(const osg::ref_ptr<osg::FrameBufferObject>& fbo, size_t frameId)
        {
            mOriginalFBO[frameId] = fbo;
        }

    private:
        osg::ref_ptr<osg::StateSet> mWebCudaState;
        std::array<osg::observer_ptr<osg::FrameBufferObject>, 2> mFBO;
        std::array<osg::observer_ptr<osg::FrameBufferObject>, 2> mOriginalFBO;
    };
}
