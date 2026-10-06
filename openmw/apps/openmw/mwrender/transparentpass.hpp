#ifndef OPENMW_MWRENDER_TRANSPARENTPASS_H
#define OPENMW_MWRENDER_TRANSPARENTPASS_H

#include <array>
#include <memory>

#include <osg/FrameBufferObject>
#include <osg/StateSet>

#include <osgUtil/RenderBin>
#include <components/webcuda/submission.hpp>

namespace Shader
{
    class ShaderManager;
}

namespace Stereo
{
    class MultiviewFramebufferResolve;
}

namespace MWRender
{
    class TransparentDepthBinCallback : public osgUtil::RenderBin::DrawCallback, public WebCuda::CustomRenderBin
    {
    public:
        TransparentDepthBinCallback(Shader::ShaderManager& shaderManager, bool postPass);
        const osg::StateSet* beginWebCuda(WebCuda::SubmissionSink&) override;
        void endWebCuda(WebCuda::SubmissionSink&) override {}
        const osg::StateSet* beginReplayWebCuda(WebCuda::SubmissionSink&) override;
        bool acceptReplayWebCuda(const osg::Drawable&,const WebCuda::DrawContext&) const override;
        void endReplayWebCuda(WebCuda::SubmissionSink&) override;

        void drawImplementation(
            osgUtil::RenderBin* bin, osg::RenderInfo& renderInfo, osgUtil::RenderLeaf*& previous) override;

        std::array<osg::ref_ptr<osg::FrameBufferObject>, 2> mFbo;
        std::array<osg::ref_ptr<osg::FrameBufferObject>, 2> mMsaaFbo;
        std::array<osg::ref_ptr<osg::FrameBufferObject>, 2> mOpaqueFbo;

        std::array<std::unique_ptr<Stereo::MultiviewFramebufferResolve>, 2> mMultiviewResolve;

    private:
        osg::ref_ptr<osg::StateSet> mStateSet;
        bool mPostPass;
    };

}

#endif
