#include "distortion.hpp"

#include <osg/FrameBufferObject>
#include <osg/ColorMask>
#include <osg/Texture2D>

#include "postprocessor.hpp"

namespace MWRender
{
    bool DistortionCallback::shouldSubmitWebCuda(const WebCuda::SubmissionSink& sink) const
    {
        const auto frame=sink.frameNumber()%2;
        if(!mOriginalFBO[frame].valid()||!mFBO[frame].valid())return false;
        const auto* texture=dynamic_cast<const osg::Texture2D*>(mOriginalFBO[frame]->getAttachment(osg::Camera::COLOR_BUFFER0).getTexture());
        return texture&&sink.isColorTarget(*texture);
    }
    const osg::StateSet* DistortionCallback::beginWebCuda(WebCuda::SubmissionSink& sink)
    {
        const auto* texture=dynamic_cast<const osg::Texture2D*>(mFBO[sink.frameNumber()%2]->getAttachment(osg::Camera::COLOR_BUFFER0).getTexture());
        if(!texture)throw std::runtime_error("Distortion requires a 2D color attachment");
        sink.beginColorTarget(*texture);
        if(!mWebCudaState) {
            mWebCudaState=new osg::StateSet;
            mWebCudaState->setAttributeAndModes(new osg::ColorMask(true,true,true,true),osg::StateAttribute::ON|osg::StateAttribute::OVERRIDE|osg::StateAttribute::PROTECTED);
        }
        return mWebCudaState;
    }
    void DistortionCallback::endWebCuda(WebCuda::SubmissionSink& sink) { sink.endColorTarget(); }

    void DistortionCallback::drawImplementation(
        osgUtil::RenderBin* bin, osg::RenderInfo& renderInfo, osgUtil::RenderLeaf*& previous)
    {
        osg::State* state = renderInfo.getState();
        unsigned frameId = state->getFrameStamp()->getFrameNumber() % 2;

        PostProcessor* postProcessor = dynamic_cast<PostProcessor*>(renderInfo.getCurrentCamera()->getUserData());

        if (!postProcessor || bin->getStage()->getFrameBufferObject() != postProcessor->getPrimaryFbo(frameId))
            return;

        mFBO[frameId]->apply(*state);

        const osg::Texture* tex
            = mFBO[frameId]->getAttachment(osg::FrameBufferObject::BufferComponent::COLOR_BUFFER0).getTexture();

        glViewport(0, 0, tex->getTextureWidth(), tex->getTextureHeight());
        glClearColor(0.0, 0.0, 0.0, 1.0);
        glColorMask(true, true, true, true);
        state->haveAppliedAttribute(osg::StateAttribute::Type::COLORMASK);
        glClear(GL_COLOR_BUFFER_BIT);

        bin->drawImplementation(renderInfo, previous);

        tex = mOriginalFBO[frameId]->getAttachment(osg::FrameBufferObject::BufferComponent::COLOR_BUFFER0).getTexture();
        glViewport(0, 0, tex->getTextureWidth(), tex->getTextureHeight());
        mOriginalFBO[frameId]->apply(*state);
    }
}
