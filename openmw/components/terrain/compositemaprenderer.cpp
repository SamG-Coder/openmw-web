#include "compositemaprenderer.hpp"

#include <osg/FrameBufferObject>
#include <osg/Geometry>
#include <chrono>
#include <osg/RenderInfo>
#include <osg/Texture2D>

#include <algorithm>

namespace Terrain
{

    CompositeMapRenderer::CompositeMapRenderer()
        : mTargetFrameRate(120)
        , mMinimumTimeAvailable(0.0025)
    {
        setSupportsDisplayList(false);
        setCullingActive(false);

        mFBO = new osg::FrameBufferObject;
    }

    CompositeMapRenderer::~CompositeMapRenderer() = default;

    void CompositeMapRenderer::submitWebCuda(WebCuda::SubmissionSink& sink, const WebCuda::DrawContext& context) const
    {
        const double dt=std::min(mTimer.time_s(),0.2);
        mTimer.setStartTick();
        const double availableTime=std::max((1.0/static_cast<double>(mTargetFrameRate)-dt)*0.75,mMinimumTimeAvailable);
        // Budget background CPU capture; GPU rendering is ordered before terrain consumers.
        std::unique_lock<std::mutex> lock(mMutex);
        auto capture=[&](const osg::ref_ptr<CompositeMap>& map) {
            if(!map->mTexture)throw std::runtime_error("Composite map has no texture");
            if(map->mTexture->referenceCount()<=1) {
                map->mCompiled=map->mDrawables.size();return;
            }
            if(map->mDrawables.empty())return;
            // Validate before opening the nested pass, so unsupported drawables
            // cannot leave a half-open target or be silently omitted.
            for(size_t i=map->mCompiled;i<map->mDrawables.size();++i)
                if(!map->mDrawables[i]||!map->mDrawables[i]->asGeometry()||map->mDrawables[i]->getDrawCallback())
                    throw std::runtime_error("Unsupported terrain composite drawable");
            sink.beginColorTarget(*map->mTexture);
            try {
                for(size_t i=map->mCompiled;i<map->mDrawables.size();++i) {
                    const auto* geometry=map->mDrawables[i]->asGeometry();
                    auto draw=context;
                    if(geometry->getStateSet())draw.states.push_back(geometry->getStateSet());
                    sink.geometry(*geometry,draw);
                }
            } catch(...) {
                // Restore the enclosing pass before propagating capture failure.
                sink.endColorTarget();throw;
            }
            sink.endColorTarget();
            map->mCompiled=map->mDrawables.size();
            map->mDrawables.clear();
        };
        auto process=[&](CompileSet& queue) {
            osg::ref_ptr<CompositeMap> map=*queue.begin();queue.erase(queue.begin());
            lock.unlock();
            try {capture(map);} catch(...) {
                lock.lock();queue.insert(map);throw;
            }
            lock.lock();
        };
        while(!mImmediateCompileSet.empty())process(mImmediateCompileSet);
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::duration<double>(availableTime);
        while(!mCompileSet.empty()&&std::chrono::steady_clock::now()<deadline)process(mCompileSet);
        mTimer.setStartTick();
    }

    void CompositeMapRenderer::drawImplementation(osg::RenderInfo& renderInfo) const
    {
        double dt = mTimer.time_s();
        dt = std::min(dt, 0.2);
        mTimer.setStartTick();
        double targetFrameTime = 1.0 / static_cast<double>(mTargetFrameRate);
        double conservativeTimeRatio(0.75);
        double availableTime = std::max((targetFrameTime - dt) * conservativeTimeRatio, mMinimumTimeAvailable);

        std::lock_guard<std::mutex> lock(mMutex);

        if (mImmediateCompileSet.empty() && mCompileSet.empty())
            return;

        while (!mImmediateCompileSet.empty())
        {
            osg::ref_ptr<CompositeMap> node = *mImmediateCompileSet.begin();
            mImmediateCompileSet.erase(node);

            mMutex.unlock();
            compile(*node, renderInfo);
            mMutex.lock();
        }

        const auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(availableTime);
        while (!mCompileSet.empty() && std::chrono::steady_clock::now() < deadline)
        {
            osg::ref_ptr<CompositeMap> node = *mCompileSet.begin();
            mCompileSet.erase(node);

            mMutex.unlock();
            compile(*node, renderInfo);
            mMutex.lock();

            if (node->mCompiled < node->mDrawables.size())
            {
                // We did not compile the map fully.
                // Place it back to queue to continue work in the next time.
                mCompileSet.insert(node);
            }
        }
        mTimer.setStartTick();
    }

    void CompositeMapRenderer::compile(CompositeMap& compositeMap, osg::RenderInfo& renderInfo) const
    {
        // if there are no more external references we can assume the texture is no longer required
        if (compositeMap.mTexture->referenceCount() <= 1)
        {
            compositeMap.mCompiled = compositeMap.mDrawables.size();
            return;
        }

        osg::Timer timer;
        osg::State& state = *renderInfo.getState();
        osg::GLExtensions* ext = state.get<osg::GLExtensions>();

        if (!mFBO)
            return;

        if (!ext->isFrameBufferObjectSupported)
            return;

        osg::FrameBufferAttachment attach(compositeMap.mTexture);
        mFBO->setAttachment(osg::Camera::COLOR_BUFFER, attach);
        mFBO->apply(state, osg::FrameBufferObject::DRAW_FRAMEBUFFER);

        GLenum status = ext->glCheckFramebufferStatus(GL_FRAMEBUFFER_EXT);

        if (status != GL_FRAMEBUFFER_COMPLETE_EXT)
        {
            GLuint fboId = state.getGraphicsContext() ? state.getGraphicsContext()->getDefaultFboId() : 0;
            ext->glBindFramebuffer(GL_FRAMEBUFFER_EXT, fboId);
            OSG_ALWAYS << "Error attaching FBO" << std::endl;
            return;
        }

        // inform State that Texture attribute has changed due to compiling of FBO texture
        // should OSG be doing this on its own?
        state.haveAppliedTextureAttribute(state.getActiveTextureUnit(), osg::StateAttribute::TEXTURE);

        for (size_t i = compositeMap.mCompiled; i < compositeMap.mDrawables.size(); ++i)
        {
            osg::Drawable* drw = compositeMap.mDrawables[i];
            osg::StateSet* stateset = drw->getStateSet();

            if (stateset)
                renderInfo.getState()->pushStateSet(stateset);

            renderInfo.getState()->apply();

            glViewport(0, 0, compositeMap.mTexture->getTextureWidth(), compositeMap.mTexture->getTextureHeight());
            drw->drawImplementation(renderInfo);

            if (stateset)
                renderInfo.getState()->popStateSet();

            ++compositeMap.mCompiled;

            compositeMap.mDrawables[i] = nullptr;
        }
        if (compositeMap.mCompiled == compositeMap.mDrawables.size())
            compositeMap.mDrawables = std::vector<osg::ref_ptr<osg::Drawable>>();

        state.haveAppliedAttribute(osg::StateAttribute::VIEWPORT);

        GLuint fboId = state.getGraphicsContext() ? state.getGraphicsContext()->getDefaultFboId() : 0;
        ext->glBindFramebuffer(GL_FRAMEBUFFER_EXT, fboId);
    }

    void CompositeMapRenderer::setMinimumTimeAvailableForCompile(double time)
    {
        mMinimumTimeAvailable = time;
    }

    void CompositeMapRenderer::setTargetFrameRate(float framerate)
    {
        mTargetFrameRate = framerate;
    }

    void CompositeMapRenderer::addCompositeMap(CompositeMap* compositeMap, bool immediate)
    {
        std::lock_guard<std::mutex> lock(mMutex);
        if (immediate)
            mImmediateCompileSet.insert(compositeMap);
        else
            mCompileSet.insert(compositeMap);
    }

    void CompositeMapRenderer::setImmediate(CompositeMap* compositeMap)
    {
        std::lock_guard<std::mutex> lock(mMutex);
        CompileSet::iterator found = mCompileSet.find(compositeMap);
        if (found == mCompileSet.end())
            return;
        else
        {
            mImmediateCompileSet.insert(compositeMap);
            mCompileSet.erase(found);
        }
    }

    size_t CompositeMapRenderer::getCompileSetSize() const
    {
        std::lock_guard<std::mutex> lock(mMutex);
        return mCompileSet.size();
    }

    CompositeMap::CompositeMap()
        : mCompiled(0)
    {
    }

    CompositeMap::~CompositeMap() {}

}
