#include "viewer.hpp"
#include <osgText/Text>
#include <osgText/Glyph>
#include <osg/Geometry>
#include "renderer.hpp"
#include "browserbridge.hpp"
#include <osgUtil/RenderStage>
#include <osg/FrameBufferObject>
#include <osg/GraphicsContext>
#include <osg/OcclusionQueryNode>
#include <osg/observer_ptr>
#include <limits>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <stdexcept>
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
EM_JS(unsigned int, omw_webcuda_device_generation, (), { return Module.webcudaEnabled ? (Module.webcudaDeviceGeneration || 0) : 0; })
EM_JS(void, omw_webcuda_recovery_ready, (), { Module.webcudaRecoveryPending=false; })
EM_JS(void, omw_webcuda_capture_image, (unsigned int id,unsigned int width,unsigned int height,int finalScreen), {
    Module.webcudaImageResults ??= new Map();
    const entry={pending:true};
    Module.webcudaImageResults.set(id,entry);
    const finish=value=>{if(Module.webcudaImageResults.get(id)===entry)Module.webcudaImageResults.set(id,value);};
    try {
        Module.webcudaCaptureImage(width,height,Boolean(finalScreen)).then(
            image=>finish({image}),
            error=>finish({error:String(error)}));
    } catch(error) {finish({error:String(error)});}
})
EM_JS(void, omw_webcuda_capture_fog, (unsigned int id,unsigned int width,unsigned int height,const unsigned int* inputs,size_t count), {
    Module.webcudaImageResults ??= new Map();
    const entry={pending:true};Module.webcudaImageResults.set(id,entry);
    const finish=value=>{if(Module.webcudaImageResults.get(id)===entry)Module.webcudaImageResults.set(id,value);};
    try {
        const start=Number(inputs)/4,length=Number(count);
        if(!Number.isSafeInteger(start)||!Number.isSafeInteger(length)||start<0||length<1||start+length>HEAPU32.length)throw Error('Invalid fog readback input range');
        const snapshot=HEAPU32.slice(start,start+length);
        Module.webcudaGenerateFogImage(width,height,snapshot).then(image=>finish({image}),error=>finish({error:String(error)}));
    } catch(error) {finish({error:String(error)});}
})
EM_JS(void, omw_webcuda_cancel_image, (unsigned int id), { Module.webcudaImageResults?.delete(id); })
EM_JS(int, omw_webcuda_image_host_alive, (), { return Module.webcudaEnabled&&!Module.webcudaImageError?1:0; })
EM_JS(int, omw_webcuda_poll_image, (unsigned int id,unsigned char* destination,unsigned int width,unsigned int height,unsigned int channels), {
    const item=Module.webcudaImageResults?.get(id);
    if(!item||item.pending)return 0;
    if(item.error){Module.webcudaImageResults.delete(id);console.error(item.error);return -1;}
    if(!destination)return 1;
    const image=item.image,start=Number(destination),bytes=width*height*channels;
    if(image.width!==width||image.height!==height||image.rgba.length!==width*height*4
        ||!Number.isSafeInteger(start)||start<0||start+bytes>HEAPU8.length) {
        Module.webcudaImageResults.delete(id);return -1;
    }
    for(let pixel=0;pixel<width*height;pixel++)HEAPU8.set(image.rgba.subarray(pixel*4,pixel*4+channels),start+pixel*channels);
    Module.webcudaImageResults.delete(id);return 1;
})
EM_JS(unsigned int, omw_webcuda_query_pixels, (unsigned int id), {
    return Module.webcudaQueryResults?.get(id) ?? 0;
})
EM_JS(int, omw_webcuda_requested, (), { return Module.webcudaSelected === true || Module.webcudaEnabled === true ? 1 : 0; })
EM_JS(int, omw_webcuda_begin_frame, (), {
    if (typeof Module.webcudaBeginFrame !== 'function') throw Error('Missing WebCuda frame host');
    return Module.webcudaBeginFrame() ? 1 : 0;
})
EM_JS(int, omw_webcuda_profile_capture, (), { return Module.webcudaProfileCapture?1:0; })
EM_JS(void, omw_webcuda_capture_timings, (const double* values), {
    const start=Number(values)/8;
    if(!Number.isSafeInteger(start)||start<0||start+8>HEAPF64.length)throw Error('Invalid capture timing range');
    const v=HEAPF64.subarray(start,start+8);
    Module.webcudaCaptureTimings={materialCopyMs:v[0],materialEncodeMs:v[1],geometryEncodeMs:v[2],atlasResizeMs:v[3],
        materialCopies:v[4],materialEncodes:v[5],geometryEncodes:v[6],atlasResizes:v[7]};
})
EM_JS(void, omw_webcuda_snapshot, (unsigned int target,unsigned int width,unsigned int height), {
    Module.webcudaSnapshotPreviousFrame(target,width,height);
})
EM_JS(void, omw_webcuda_end_frame, (int commit), {
    Module.webcudaEndFrame(Boolean(commit));
})
EM_JS(void, omw_webcuda_resolve_attachment, (unsigned int source,unsigned int target,unsigned int plane,unsigned int format,unsigned int width,unsigned int height,int x,int y,unsigned int vw,unsigned int vh), {
    Module.webcudaResolveAttachment({sourceId:source,targetId:target,plane,format,width,height,viewport:[x,y,vw,vh]});
})
EM_JS(void, omw_webcuda_retire_target, (unsigned int id), {
    Module.webcudaRetireTarget(id);
})
EM_JS(void, omw_webcuda_depth_isolation, (int begin,float depth), {
    Module.webcudaDepthIsolation(Boolean(begin),depth);
})
EM_JS(void, omw_webcuda_debug, (unsigned int depth,unsigned int normals,unsigned int flags,const float* values), {
    const start=Number(values)/4;
    Module.webcudaDebugScene(depth,normals,flags,HEAPF32.slice(start,start+19));
})
EM_JS(void, omw_webcuda_bloom, (unsigned int depth,const float* values,int reverse), {
    const start=Number(values)/4;
    Module.webcudaBloomScene(depth,HEAPF32.slice(start,start+11),Boolean(reverse));
})
EM_JS(void, omw_webcuda_luminance, (unsigned int source,unsigned int width,unsigned int height,
    float sx,float sy,float speed,int reset,double time,unsigned int viewportWidth,unsigned int viewportHeight), {
    Module.webcudaSceneLuminance({sourceId:source,width,height,sx,sy,speed,reset:Boolean(reset),time,viewportWidth,viewportHeight});
})
EM_JS(void, omw_webcuda_distort, (unsigned int target), { Module.webcudaDistortScene(target); })
EM_JS(void, omw_webcuda_adjust, (float gamma,float contrast), { Module.webcudaAdjustScene(gamma,contrast); })
EM_JS(void, omw_webcuda_resolve, (unsigned int scene,unsigned int distortion,unsigned int format,unsigned int destinationFormat,float scaleX,float scaleY), {
    Module.webcudaResolveScene(scene,distortion,format,destinationFormat,scaleX,scaleY);
})
EM_JS(void, omw_webcuda_capture_depth, (unsigned int target,unsigned int width,unsigned int height), {
    Module.webcudaCaptureDepth(target,width,height);
})
EM_JS(void, omw_webcuda_color_target, (int begin,unsigned int target,unsigned int colorFormat,unsigned int depthFormat), {
    Module.webcudaColorTarget(Boolean(begin),target,colorFormat,depthFormat);
})
EM_JS(void, omw_webcuda_ripples, (unsigned int target,unsigned int width,unsigned int height,
    const float* positions,unsigned int count,float ox,float oy,float time,int simulate), {
    const start=Number(positions)/4;
    if(!Number.isSafeInteger(start)||start<0||count>100||start+count*3>HEAPF32.length)throw Error('Invalid ripple source');
    Module.webcudaSubmitRipple({kind:'ripples',targetId:target,width,height,positions:HEAPF32.slice(start,start+count*3),ox,oy,time,simulate:Boolean(simulate)});
})
EM_JS(void, omw_webcuda_pass_state, (unsigned int mask, float red, float green, float blue,
    float alpha, float depth, unsigned int target,unsigned int depthTarget,unsigned int normalTarget,unsigned int colorFormat,unsigned int depthFormat,int clearStencil,unsigned int stencilBits,unsigned int stencilTarget,unsigned int clearColorMask,int viewportX,int viewportY,unsigned int viewportWidth,unsigned int viewportHeight,unsigned int sampleCount,unsigned int normalFormat), {
    Module.webcudaPassState({clearMask:mask,clearColor:[red,green,blue,alpha],clearDepth:depth,targetId:target,depthTargetId:depthTarget,normalTargetId:normalTarget,normalFormat,sampleCount,colorFormat,depthFormat,clearStencil,stencilBits,stencilTargetId:stencilTarget,clearColorMask,viewport:[viewportX,viewportY,viewportWidth,viewportHeight]});
})
#endif
namespace WebCuda
{
    namespace
    {
        bool floatingColorFormat(unsigned int format)
        {
            return format==GL_RGBA16F_ARB||format==GL_RGBA32F_ARB||format==0x881B||format==0x8815
                ||format==0x822D||format==0x822E||format==0x822F||format==0x8230;
        }
        bool wideColorAtlas(unsigned int format)
        {
            return floatingColorFormat(format)||format==0x822A||format==0x822C||format==0x8054||format==0x805B
                ||(format>=0x8F94&&format<=0x8F9B);
        }
        bool allowsNegativeColor(unsigned int format)
        {
            return floatingColorFormat(format)||(format>=0x8F94&&format<=0x8F9B);
        }
        struct QueryIdentity
        {
            osg::observer_ptr<const osg::Geometry> geometry;
            osg::observer_ptr<const osg::Camera> camera;
            unsigned int id;
        };
        // Single-threaded viewer. Weak references prevent pointer reuse from
        // accepting results belonging to a destroyed query or camera.
        unsigned int queryIdentity(const osg::Geometry* geometry,const osg::Camera* camera)
        {
            static std::vector<QueryIdentity> identities;
            static unsigned int next=1;
            if(!geometry||!camera)return 0;
            for(auto it=identities.begin();it!=identities.end();)
            {
                if(!it->geometry.valid()||!it->camera.valid())it=identities.erase(it);
                else {
                    if(it->geometry.get()==geometry&&it->camera.get()==camera)return it->id;
                    ++it;
                }
            }
            if(next==std::numeric_limits<unsigned int>::max())throw std::runtime_error("WebCuda query identity overflow");
            const auto id=next++;
            identities.push_back({geometry,camera,id});return id;
        }
    }
    unsigned int Viewer::queryPixels(const osg::Geometry* geometry,const osg::Camera* camera)
    {
#ifdef __EMSCRIPTEN__
        return omw_webcuda_query_pixels(queryIdentity(geometry,camera));
#else
        return 0;
#endif
    }
    bool Viewer::requested()
    {
#ifdef __EMSCRIPTEN__
        return omw_webcuda_requested()!=0;
#else
        return false;
#endif
    }
    Viewer::Viewer()
    {
        setThreadingModel(SingleThreaded);
        // The base constructor cannot dispatch to our virtual factory.
        getCamera()->setRenderer(createRenderer(getCamera()));
    }
    Viewer::~Viewer()
    {
        auto requests=std::move(mImageRequests);
        for(auto& [id,request]:requests) {
#ifdef __EMSCRIPTEN__
            omw_webcuda_cancel_image(id);
#endif
            try {request.completion(nullptr,"WebCuda viewer destroyed");} catch(...) {}
        }
    }
    osg::GraphicsOperation* Viewer::createRenderer(osg::Camera* camera)
    {
        return new Renderer(camera,*this);
    }
    void Viewer::collectExpiredTargets()
    {
        // The viewer is single threaded. Weak ownership lets engine-side target
        // replacement release objects and prevents pointer reuse reusing an ID.
        const auto collect=[this](auto& targets,auto alive) {
            for(auto it=targets.begin();it!=targets.end();) {
                if(alive(it->second)){++it;continue;}
                mRetiredTargets.push_back(it->second.id);
                it=targets.erase(it);
            }
        };
        for(auto it=mCameraImages.begin();it!=mCameraImages.end();) {
            const auto* camera=it->second->camera.get();
            bool attached=false;
            if(camera)for(const auto& entry:camera->getBufferAttachmentMap())if(entry.second._image==it->second->image){attached=true;break;}
            if(!attached)it=mCameraImages.erase(it);else ++it;
        }
        collect(mTargets,[](const auto& value){return value.texture.valid();});
        collect(mStencilTargets,[](const auto& value){return value.owner.valid();});
        collect(mDepthRenderbuffers,[](const auto& value){return value.owner.valid();});
        collect(mColorRenderbuffers,[](const auto& value){return value.owner.valid();});
    }
    void Viewer::captureImage(osg::Camera* camera,unsigned int width,unsigned int height,ImageCompletion completion,unsigned int channels)
    {
        if(!width||!height||!completion||(channels!=3&&channels!=4)||std::uint64_t(width)*height>std::numeric_limits<int>::max()/4)
            throw std::invalid_argument("Invalid WebCuda image request");
        if(mNextImageRequest==std::numeric_limits<unsigned int>::max())throw std::runtime_error("Image request identity overflow");
        mImageRequests.emplace(mNextImageRequest++,ImageRequest{camera,width,height,std::move(completion),channels,false,camera==nullptr});
    }
    void Viewer::captureFogImage(unsigned int width,unsigned int height,const std::vector<unsigned int>& inputs,ImageCompletion completion)
    {
        if(!width||!height||!completion||inputs.empty()||std::uint64_t(width)*height>std::numeric_limits<int>::max()/4
            ||inputs.size()!=1u+std::uint64_t(width)*height+std::uint64_t(inputs[0])*3u)
            throw std::invalid_argument("Invalid fog image snapshot");
        if(mNextImageRequest==std::numeric_limits<unsigned int>::max())throw std::runtime_error("Image request identity overflow");
#ifdef __EMSCRIPTEN__
        const auto id=mNextImageRequest++;
        // Standalone GPU job: not tied to a camera or the lifetime of a map segment.
        mImageRequests.emplace(id,ImageRequest{nullptr,width,height,std::move(completion),4,true,true});
        omw_webcuda_capture_fog(id,width,height,inputs.data(),inputs.size());
#else
        throw std::runtime_error("Fog GPU readback requires browser transport");
#endif
    }
    void Viewer::collectImages()
    {
#ifdef __EMSCRIPTEN__
        struct Ready { ImageCompletion completion;osg::ref_ptr<osg::Image> image;std::string error; };
        std::vector<Ready> ready;
        for(auto it=mImageRequests.begin();it!=mImageRequests.end();) {
            auto& request=it->second;
            int status=request.submitted?omw_webcuda_poll_image(it->first,nullptr,request.width,request.height,request.channels):0;
            if(!request.submitted&&!request.finalScreen&&!request.camera.valid())status=-1;
            const bool timedOut=std::chrono::steady_clock::now()-request.started>std::chrono::seconds(30);
            if(!omw_webcuda_image_host_alive()||timedOut)status=-1;
            if(status<0)omw_webcuda_cancel_image(it->first);
            if(status==0){++it;continue;}
            osg::ref_ptr<osg::Image> image;
            if(status>0) {
                image=new osg::Image;
                image->allocateImage(request.width,request.height,1,request.channels==4?GL_RGBA:GL_RGB,GL_UNSIGNED_BYTE,1);
                status=omw_webcuda_poll_image(it->first,image->data(),request.width,request.height,request.channels);
            }
            if(status<0)image=nullptr;
            ready.push_back({std::move(request.completion),image,status>0?"":"WebCuda image capture failed"});
            it=mImageRequests.erase(it);
        }
        // Callbacks may enqueue another image request or change the scene.
        for(auto& result:ready)result.completion(result.image,std::move(result.error));
#endif
    }
    void Viewer::capturePreviousFrame(osg::Texture2D* texture)
    {
        if(!texture||texture->getTextureWidth()<=0||texture->getTextureHeight()<=0)
            throw std::invalid_argument("Invalid loading snapshot texture");
        auto found=mTargets.find(texture);
        if(found==mTargets.end()) {
            if(mNextTarget>=0x20000000u)throw std::runtime_error("Snapshot identity overflow");
            mTargets.emplace(texture,Target{texture,mNextTarget++});
        }
        if(std::find(mFrameSnapshots.begin(),mFrameSnapshots.end(),texture)==mFrameSnapshots.end())mFrameSnapshots.push_back(texture);
        if(std::none_of(mSnapshotTextures.begin(),mSnapshotTextures.end(),[texture](const auto& value){return value.get()==texture;}))
            mSnapshotTextures.emplace_back(texture);
    }
    bool Viewer::refreshDeviceGeneration()
    {
#ifdef __EMSCRIPTEN__
        const unsigned int generation=omw_webcuda_device_generation();
        if(!generation||generation==mDeviceGeneration)return false;
        const bool replacement=mDeviceGeneration!=0||generation>1;
        mDeviceGeneration=generation;
        if(!replacement)return false;
        if(mTable)throw std::logic_error("Device replacement during render submission");
        for(const auto& camera:mSubmittedCompletionCameras)if(camera.valid())camera->setUserValue("webcuda.passComplete",false);
        for(const auto& camera:mFrameCompletionCameras)if(camera.valid())camera->setUserValue("webcuda.passComplete",false);
        mSubmittedCompletionCameras.clear();mFrameCompletionCameras.clear();
        mCameraImages.clear();mFrameImageRequests.clear();
        auto requests=std::move(mImageRequests);mImageRequests.clear();
        for(auto& [id,request]:requests) {
            omw_webcuda_cancel_image(id);
            try {request.completion(nullptr,"WebCuda device replaced");}catch(...) {}
        }
        mTargets.clear();mStencilTargets.clear();mDepthRenderbuffers.clear();mColorRenderbuffers.clear();
        mRetiredTargets.clear();mColorTargetsWritten.clear();mTargetStack.clear();mResolveAttachments.clear();
        mCurrentTarget=0;mResolveSource=0;mPassCamera=nullptr;
        mFrameSnapshots.clear();
        for(auto it=mSnapshotTextures.begin();it!=mSnapshotTextures.end();) {
            if(!it->valid()){it=mSnapshotTextures.erase(it);continue;}
            mFrameSnapshots.emplace_back(it->get());++it;
        }
        // Previous framebuffer pixels are lost. Recreate live loading targets
        // via the CUDA snapshot path, which clears them if no screen exists yet.
        for(const auto& texture:mFrameSnapshots) {
            if(mNextTarget>=0x20000000u)throw std::runtime_error("Snapshot identity overflow after device replacement");
            mTargets.emplace(texture.get(),Target{texture.get(),mNextTarget++});
        }
        mPacket={};
        return true;
#else
        return false;
#endif
    }

    void Viewer::completeDeviceRecovery()
    {
#ifdef __EMSCRIPTEN__
        omw_webcuda_recovery_ready();
#endif
    }

    void Viewer::renderingTraversals()
    {
#ifdef __EMSCRIPTEN__
        collectImages();
        if (!omw_webcuda_begin_frame()) return;
        beginCaptureProfile(omw_webcuda_profile_capture()!=0);
        // Host acceptance follows successful GPU idle of the previous frame.
        // Failed or disposed hosts never accept another frame.
        for(const auto& camera:mSubmittedCompletionCameras)if(camera.valid())camera->setUserValue("webcuda.passComplete",true);
        mSubmittedCompletionCameras.clear();mFrameCompletionCameras.clear();
        mColorTargetsWritten.clear();
        mFrameImageRequests.clear();
        try {
            collectExpiredTargets();
            // The host accepted a frame only after finishing the previous one.
            // Retire before recording this frame; mid-frame expirations wait
            // here until the next accepted frame, including after an abort.
            for(const auto id:mRetiredTargets)omw_webcuda_retire_target(id);
            mRetiredTargets.clear();
            for(const auto& texture:mFrameSnapshots)
                omw_webcuda_snapshot(mTargets.at(texture.get()).id,texture->getTextureWidth(),texture->getTextureHeight());
            osgViewer::Viewer::renderingTraversals();
            for(auto& [id,request]:mImageRequests)if(!request.submitted&&request.finalScreen) {
                omw_webcuda_capture_image(id,request.width,request.height,1);
                request.submitted=true;mFrameImageRequests.push_back(id);
            }
            if(captureProfile.enabled)omw_webcuda_capture_timings(captureProfile.values.data());
            omw_webcuda_end_frame(1);
            mSubmittedCompletionCameras=std::move(mFrameCompletionCameras);
            mFrameSnapshots.clear();
        } catch (...) {
            mTable.reset(); mPacket={};
            mTargetStack.clear();
            mFrameCompletionCameras.clear();
            omw_webcuda_end_frame(0);
            // Only requests recorded in this aborted frame can be retried. The
            // JS result entry is canceled so late promise rejection is ignored.
            for(const auto id:mFrameImageRequests) {
                omw_webcuda_cancel_image(id);
                const auto found=mImageRequests.find(id);
                if(found!=mImageRequests.end())found->second.submitted=false;
            }
            mFrameImageRequests.clear();
            throw;
        }
#else
        throw std::runtime_error("WebCuda Viewer requires browser transport");
#endif
    }
    void Viewer::beginPass(const osgUtil::RenderStage& stage)
    {
        collectExpiredTargets();
        if (mTable) throw std::logic_error("Nested WebCuda render stage");
        const auto* viewport=stage.getViewport();
        if (!viewport || viewport->width()<=0 || viewport->height()<=0)
            throw std::runtime_error("WebCuda stage has no viewport");
        for(const auto value:{viewport->x(),viewport->y(),viewport->width(),viewport->height()})
            if(!std::isfinite(value)||std::trunc(value)!=value||std::abs(value)>std::numeric_limits<int>::max())
                throw std::runtime_error("WebCuda requires an integer camera viewport");
        const auto inferredWidth=viewport->width()+std::max(0.0,viewport->x());
        const auto inferredHeight=viewport->height()+std::max(0.0,viewport->y());
        if(inferredWidth>std::numeric_limits<int>::max()||inferredHeight>std::numeric_limits<int>::max())
            throw std::runtime_error("Camera viewport extent overflow");
        const auto* camera=stage.getCamera();
        mPassCamera=camera;
        std::uint32_t targetId=0,depthId=0,normalId=0;
        unsigned int depthFormat=0x81A6,colorFormat=GL_RGBA8,stencilBits=0,stencilId=0,sampleCount=1,normalFormat=GL_RGBA8;
        struct Attachment { osg::Camera::BufferComponent component;osg::Texture2D* texture;unsigned int level;bool hasTexture;unsigned int format;const osg::Object* owner;bool hasImage;unsigned int samples,colorSamples; };
        std::vector<Attachment> attachments;
        // PingPongCull installs the scene FBO directly on RenderStage. It is
        // authoritative over the camera's static attachment map.
        mResolveAttachments.clear();
        if(const auto* fbo=stage.getFrameBufferObject()) {
            for(const auto& [component,attachment]:fbo->getAttachmentMap())
                attachments.push_back({component,const_cast<osg::Texture2D*>(dynamic_cast<const osg::Texture2D*>(attachment.getTexture())),attachment.getTextureLevel(),attachment.getTexture()!=nullptr,attachment.getRenderBuffer()?attachment.getRenderBuffer()->getInternalFormat():0u,attachment.getTexture()?static_cast<const osg::Object*>(attachment.getTexture()):attachment.getRenderBuffer(),false,attachment.getRenderBuffer()?static_cast<unsigned int>(attachment.getRenderBuffer()->getSamples()):0u,attachment.getRenderBuffer()?static_cast<unsigned int>(attachment.getRenderBuffer()->getColorSamples()):0u});
        } else if(camera)for(const auto& [component,attachment]:camera->getBufferAttachmentMap())
            attachments.push_back({component,dynamic_cast<osg::Texture2D*>(attachment._texture.get()),attachment._level,attachment._texture.valid(),attachment._internalFormat?attachment._internalFormat:(attachment._image.valid()?static_cast<unsigned int>(attachment._image->getInternalTextureFormat()?attachment._image->getInternalTextureFormat():GL_RGBA8):0u),attachment._texture?static_cast<const osg::Object*>(attachment._texture.get()):camera,attachment._image.valid(),attachment._multisampleSamples,attachment._multisampleColorSamples});
        if(attachments.empty()) {
            const auto* graphics=camera&&camera->getGraphicsContext()?camera->getGraphicsContext():getCamera()->getGraphicsContext();
            if(graphics&&graphics->getTraits()) {
                stencilBits=graphics->getTraits()->stencil;
                if(graphics->getTraits()->sampleBuffers)sampleCount=std::max(1u,graphics->getTraits()->samples);
            }
        }
        // Image copies belong to camera output requests, independently of whether
        // a render-stage FBO overrides its texture/renderbuffer destinations.
        bool hasPrimaryImage=false;
        if(camera)for(const auto& [imageComponent,imageAttachment]:camera->getBufferAttachmentMap()) {
            if(imageAttachment._image.valid()) {
                if(hasPrimaryImage)throw std::runtime_error("Multiple camera image destinations require separate readback requests");
                hasPrimaryImage=true;
                if(imageComponent!=osg::Camera::COLOR_BUFFER&&imageComponent!=osg::Camera::COLOR_BUFFER0)
                    throw std::runtime_error("Only primary color camera images have a readback path");
                auto* mutableCamera=const_cast<osg::Camera*>(camera);
                osg::ref_ptr<osg::Image> image=imageAttachment._image;
                if(!image||image->getDataType()!=GL_UNSIGNED_BYTE||(image->getPixelFormat()!=GL_RGB&&image->getPixelFormat()!=GL_RGBA))
                    throw std::runtime_error("Camera readback requires RGB/RGBA unsigned bytes");
                const auto width=static_cast<unsigned int>(viewport->width()),height=static_cast<unsigned int>(viewport->height());
                const unsigned int channels=image->getPixelFormat()==GL_RGBA?4u:3u;
                auto& ticket=mCameraImages[camera];
                if(!ticket||!ticket->camera.valid()||ticket->image!=image||ticket->width!=width||ticket->height!=height||ticket->channels!=channels||ticket->x!=viewport->x()||ticket->y!=viewport->y())
                    ticket=std::make_shared<CameraImageState>(CameraImageState{mutableCamera,image,width,height,channels,static_cast<int>(viewport->x()),static_cast<int>(viewport->y())});
                bool oneShot=false;camera->getUserValue("webcuda.imageCaptureOneShot",oneShot);
                int requestedState=0;camera->getUserValue("webcuda.imageCapture",requestedState);
                if(ticket->status==0||(ticket->status==2&&(!oneShot||requestedState==0))||(ticket->status<0&&requestedState==0)) {
                    ticket->status=1;
                    mutableCamera->setUserValue("webcuda.imageCapture",1);
                    std::weak_ptr<CameraImageState> weak=ticket;
                    const auto component=imageComponent;
                    captureImage(mutableCamera,width,height,
                        [weak,component](osg::ref_ptr<osg::Image> result,std::string error) {
                            const auto captured=weak.lock();
                            if(!captured||!captured->camera.valid())return;
                            auto* camera=captured->camera.get();
                            const auto& attachments=camera->getBufferAttachmentMap();
                            const auto found=attachments.find(component);
                            const auto* viewport=camera->getViewport();
                            // A replaced attachment or resized viewport invalidates this
                            // result; never publish old pixels into the new destination.
                            if(found==attachments.end()||found->second._image!=captured->image||!viewport
                                ||viewport->width()!=captured->width||viewport->height()!=captured->height
                                ||viewport->x()!=captured->x||viewport->y()!=captured->y
                                ||captured->image->getPixelFormat()!=(captured->channels==4?GL_RGBA:GL_RGB)
                                ||captured->image->getDataType()!=GL_UNSIGNED_BYTE) {
                                captured->status=0;camera->setUserValue("webcuda.imageCapture",0);return;
                            }
                            if(!result){captured->status=-1;camera->setUserValue("webcuda.imageCapture",-1);camera->setUserValue("webcuda.imageCaptureError",error);return;}
                            auto* image=captured->image.get();
                            image->allocateImage(result->s(),result->t(),1,captured->channels==4?GL_RGBA:GL_RGB,GL_UNSIGNED_BYTE,1);
                            std::memcpy(image->data(),result->data(),static_cast<size_t>(result->s())*result->t()*captured->channels);
                            image->dirty();captured->status=2;camera->setUserValue("webcuda.imageCapture",2);
                        },channels);
                }
            }
        }
        bool haveAttachmentSamples=false;
        for(const auto& attachment:attachments) {
            const unsigned int samples=std::max(1u,attachment.samples);
            if(attachment.colorSamples&&attachment.colorSamples!=samples)
                throw std::runtime_error("Separate coverage/color sample counts require coverage-sample support");
            if(haveAttachmentSamples&&samples!=sampleCount)throw std::runtime_error("Mixed attachment sample counts");
            sampleCount=samples;haveAttachmentSamples=true;
            const auto component=attachment.component;
            if(component==osg::Camera::STENCIL_BUFFER) {
                const auto format=attachment.texture?attachment.texture->getInternalFormat():attachment.format;
                if(format!=0x8D48||attachment.level!=0||!attachment.owner||(attachment.hasTexture&&!attachment.texture))
                    throw std::runtime_error("Standalone stencil requires a base-level eight-bit attachment");
                auto found=mStencilTargets.find(attachment.owner);
                if(found==mStencilTargets.end()) {
                    if(mNextTarget>=0x20000000u)throw std::runtime_error("Stencil target identity overflow");
                    found=mStencilTargets.emplace(attachment.owner,StencilTarget{attachment.owner,mNextTarget++}).first;
                }
                stencilId=found->second.id;stencilBits=8;continue;
            }
            const bool depth=component==osg::Camera::DEPTH_BUFFER||component==osg::Camera::PACKED_DEPTH_STENCIL_BUFFER;
            if(depth&&!attachment.hasTexture) {
                if(!attachment.owner)throw std::runtime_error("Depth renderbuffer has no owner");
                if(attachment.format)depthFormat=attachment.format;
                auto found=mDepthRenderbuffers.find(attachment.owner);
                if(found==mDepthRenderbuffers.end()) {
                    if(mNextTarget>=0x20000000u)throw std::runtime_error("Depth target identity overflow");
                    found=mDepthRenderbuffers.emplace(attachment.owner,StencilTarget{attachment.owner,mNextTarget++|0x80000000u}).first;
                }
                depthId=found->second.id;continue;
            }
            const bool normal=component==osg::Camera::COLOR_BUFFER1;
            if(!depth && !normal && component!=osg::Camera::COLOR_BUFFER && component!=osg::Camera::COLOR_BUFFER0)
                throw std::runtime_error("WebCuda MRT/stencil attachments require a matching material");
            if(!depth&&!attachment.hasTexture) {
                if(!attachment.owner||attachment.level!=0||attachment.format==0)
                    throw std::runtime_error("Color renderbuffer has no owner or format");
                const auto key=std::make_pair(attachment.owner,static_cast<unsigned int>(component));
                auto found=mColorRenderbuffers.find(key);
                if(found!=mColorRenderbuffers.end()&&found->second.format!=attachment.format) {
                    mRetiredTargets.push_back(found->second.id);
                    mColorRenderbuffers.erase(found);found=mColorRenderbuffers.end();
                }
                if(found==mColorRenderbuffers.end()) {
                    if(mNextTarget>=0x20000000u)throw std::runtime_error("Color renderbuffer identity overflow");
                    const auto kind=(normal?0x40000000u:0u)|(wideColorAtlas(attachment.format)?0x20000000u:0u);
                    found=mColorRenderbuffers.emplace(key,ColorRenderbuffer{attachment.owner,mNextTarget++|kind,attachment.format}).first;
                }
                if(normal){normalId=found->second.id;normalFormat=attachment.format;}
                else {targetId=found->second.id;colorFormat=attachment.format;}
                continue;
            }
            auto* texture=attachment.texture;
            if(!texture||attachment.level!=0)
                throw std::runtime_error("WebCuda camera requires a base-level 2D color target");
            if(depth)depthFormat=texture->getInternalFormat();
            else if(!normal)colorFormat=texture->getInternalFormat();
            else {
                normalFormat=texture->getInternalFormat();
            }
            const bool wide=!depth&&wideColorAtlas(texture->getInternalFormat());
            const auto kind=depth?0x80000000u:((normal?0x40000000u:0u)|(wide?0x20000000u:0u));
            auto found=mTargets.find(texture);
            if(found==mTargets.end()) {
                if(mNextTarget>=0x20000000u)throw std::runtime_error("WebCuda target identity overflow");
                found=mTargets.emplace(texture,Target{texture,mNextTarget++|kind}).first;
            }
            if((found->second.id&0xe0000000u)!=kind)throw std::runtime_error("Render texture changed attachment type");
            if(texture->getTextureWidth()==0||texture->getTextureHeight()==0)texture->setTextureSize(inferredWidth,inferredHeight);
            if(depth)depthId=found->second.id;else if(normal)normalId=found->second.id;else targetId=found->second.id;
        }
        if(sampleCount!=1&&sampleCount!=2&&sampleCount!=4&&sampleCount!=8&&sampleCount!=16)
            throw std::runtime_error("Unsupported camera sample count");
        if(depthFormat==0x88F0||depthFormat==0x8CAD)stencilBits=8;
        if(stencilBits!=0&&stencilBits!=8)throw std::runtime_error("Unsupported stencil bit depth");
        if(normalId&&!targetId)throw std::runtime_error("Normal target requires a primary color attachment");
        if(!targetId&&depthId)targetId=depthId;
        if(!targetId&&stencilId)targetId=stencilId;
        mCurrentTarget=targetId;
        mWidth=static_cast<unsigned int>(inferredWidth);
        mHeight=static_cast<unsigned int>(inferredHeight);
        if(attachments.empty()) {
            const auto* graphics=camera&&camera->getGraphicsContext()?camera->getGraphicsContext():getCamera()->getGraphicsContext();
            if(graphics&&graphics->getTraits()&&graphics->getTraits()->width>0&&graphics->getTraits()->height>0) {
                mWidth=graphics->getTraits()->width;mHeight=graphics->getTraits()->height;
            }
        } else {
            bool sized=false;
            for(const auto& attachment:attachments) {
                const auto* renderbuffer=dynamic_cast<const osg::RenderBuffer*>(attachment.owner);
                const int width=attachment.texture?attachment.texture->getTextureWidth():renderbuffer?renderbuffer->getWidth():0;
                const int height=attachment.texture?attachment.texture->getTextureHeight():renderbuffer?renderbuffer->getHeight():0;
                if(width<=0||height<=0)continue;
                if(sized&&(mWidth!=static_cast<unsigned int>(width)||mHeight!=static_cast<unsigned int>(height)))
                    throw std::runtime_error("Mixed attachment dimensions require separate plane extents");
                mWidth=width;mHeight=height;sized=true;
            }
        }
        mResolveSource=targetId;
        if(const auto* resolve=stage.getMultisampleResolveFramebufferObject()) {
            mResolveX=viewport->x();mResolveY=viewport->y();mResolveWidth=viewport->width();mResolveHeight=viewport->height();
            for(const auto& [component,attachment]:resolve->getAttachmentMap()) {
                auto* texture=const_cast<osg::Texture2D*>(dynamic_cast<const osg::Texture2D*>(attachment.getTexture()));
                if(!texture||attachment.getTextureLevel()!=0||attachment.isMultisample())
                    throw std::runtime_error("Resolve destination requires a base-level single-sample 2D texture");
                if(texture->getTextureWidth()==0||texture->getTextureHeight()==0)texture->setTextureSize(mWidth,mHeight);
                if(texture->getTextureWidth()!=static_cast<int>(mWidth)||texture->getTextureHeight()!=static_cast<int>(mHeight))
                    throw std::runtime_error("Resolve attachment dimensions differ");
                unsigned int plane=0,kind=wideColorAtlas(texture->getInternalFormat())?0x20000000u:0u;
                if(component==osg::Camera::DEPTH_BUFFER||component==osg::Camera::PACKED_DEPTH_STENCIL_BUFFER) {
                    if(!depthId)throw std::runtime_error("Resolve source lacks depth attachment");
                    plane=component==osg::Camera::DEPTH_BUFFER?1u:4u;kind=0x80000000u;
                } else if(component==osg::Camera::COLOR_BUFFER1) {
                    if(!normalId)throw std::runtime_error("Resolve source lacks normal attachment");
                    plane=2;kind|=0x40000000u;
                } else if(component!=osg::Camera::COLOR_BUFFER&&component!=osg::Camera::COLOR_BUFFER0)
                    throw std::runtime_error("Resolve attachment requires an explicit plane mapping");
                auto found=mTargets.find(texture);
                if(found==mTargets.end()) {
                    if(mNextTarget>=0x20000000u)throw std::runtime_error("Resolve target identity overflow");
                    found=mTargets.emplace(texture,Target{texture,mNextTarget++|kind}).first;
                }
                if((found->second.id&0xe0000000u)!=kind||found->second.id==targetId||found->second.id==depthId||found->second.id==normalId)
                    throw std::runtime_error("Invalid resolve attachment identity or feedback");
                mResolveAttachments.push_back({found->second.id,plane,static_cast<unsigned int>(texture->getInternalFormat())});
            }
        }
        mTable=std::make_shared<MaterialTable>(mWidth,mHeight);
        mTable->setDepthOnly((targetId&0x80000000u)!=0||(stencilId&&targetId==stencilId));
        // An offscreen color-only FBO has no depth storage. The window
        // framebuffer uses its context-provided depth buffer.
        mTable->setHasDepth(attachments.empty()||depthId!=0);
        mTable->setFloatingColor(allowsNegativeColor(colorFormat));
        mTable->setSimulationTime(static_cast<float>(getFrameStamp()->getSimulationTime()));
        mTable->setRenderTextureResolver([this,targetId,depthId,normalId](const osg::Texture2D* texture) {
            const auto found=mTargets.find(texture);
            if(found==mTargets.end()||!found->second.texture.valid())return std::uint32_t(0);
            if(found->second.id==targetId||found->second.id==depthId||found->second.id==normalId)throw std::runtime_error("WebCuda camera reads its own attachment");
            return found->second.id;
        });
        mPacket={};
#ifdef __EMSCRIPTEN__
        const auto& color=stage.getClearColor();
        const auto clearMask=(targetId&0x80000000u)?stage.getClearMask()&~GL_COLOR_BUFFER_BIT:stage.getClearMask();
        const auto* channels=stage.getColorMask();
        const unsigned int clearColorMask=channels
            ?(channels->getRedMask()?1u:0u)|(channels->getGreenMask()?2u:0u)
                |(channels->getBlueMask()?4u:0u)|(channels->getAlphaMask()?8u:0u):15u;
        omw_webcuda_pass_state(clearMask,color.r(),color.g(),color.b(),color.a(),stage.getClearDepth(),targetId,depthId,normalId,colorFormat,depthFormat,stage.getClearStencil(),stencilBits,stencilId,clearColorMask,viewport->x(),viewport->y(),viewport->width(),viewport->height(),sampleCount,normalFormat);
#endif
    }
    void Viewer::endPass(const osgUtil::RenderStage&)
    {
        if(!mTargetStack.empty())throw std::logic_error("Unclosed WebCuda color target");
        if (!mTable) throw std::logic_error("WebCuda stage not started");
        if (!submitBrowserPass(std::move(mPacket),mTable,mWidth,mHeight))
            throw std::runtime_error("WebCuda frame host rejected an accepted frame");
#ifdef __EMSCRIPTEN__
        for(const auto& attachment:mResolveAttachments)
            omw_webcuda_resolve_attachment(mCurrentTarget,attachment.target,attachment.plane,attachment.format,
                mWidth,mHeight,mResolveX,mResolveY,mResolveWidth,mResolveHeight);
#endif
#ifdef __EMSCRIPTEN__
        for(auto& [id,request]:mImageRequests)if(!request.submitted&&!request.finalScreen&&request.camera.get()==mPassCamera) {
            omw_webcuda_capture_image(id,request.width,request.height,0);
            request.submitted=true;mFrameImageRequests.push_back(id);
        }
#endif
        bool notifyCompletion=false;
        if(mPassCamera&&mPassCamera->getUserValue("webcuda.notifyPassComplete",notifyCompletion)&&notifyCompletion)
            mFrameCompletionCameras.emplace_back(const_cast<osg::Camera*>(mPassCamera));
        mResolveAttachments.clear();
        mTable.reset(); mPacket={};
    }
    void Viewer::geometry(const osg::Geometry& geometry,const DrawContext& context)
    {
        if (!mTable) throw std::logic_error("WebCuda geometry outside stage");
        writableMaterialTable(mTable);
        auto draw=context;
        if(dynamic_cast<const osg::QueryGeometry*>(&geometry))draw.queryId=queryIdentity(&geometry,mPassCamera);
        bool screen=false;
        for(unsigned int i=0;i<geometry.getNumPrimitiveSets();i++) {
            const auto mode=geometry.getPrimitiveSet(i)->getMode();
            screen=screen||mode==GL_POINTS||mode==GL_LINES||mode==GL_LINE_STRIP||mode==GL_LINE_LOOP;
        }
        const auto material=mTable->encode(draw);
        if(!screen){appendGeometry(mPacket,geometry,draw,material);return;}
        osg::ref_ptr<osg::StateSet> screenState=new osg::StateSet;
        screenState->setMode(GL_CULL_FACE,osg::StateAttribute::OFF|osg::StateAttribute::OVERRIDE|osg::StateAttribute::PROTECTED);
        screenState->setMode(GL_POLYGON_OFFSET_FILL,osg::StateAttribute::OFF|osg::StateAttribute::OVERRIDE|osg::StateAttribute::PROTECTED);
        auto screenContext=draw;screenContext.states.push_back(screenState);
        const auto screenMaterial=mTable->encode(screenContext);
        auto pointContext=screenContext;pointContext.pointDraw=true;
        appendGeometry(mPacket,geometry,draw,material,screenMaterial,mTable->encode(pointContext));
    }
    float Viewer::simulationTime() const { return static_cast<float>(getFrameStamp()->getSimulationTime()); }
    unsigned int Viewer::frameNumber() const { return getFrameStamp()->getFrameNumber(); }
    bool Viewer::isColorTarget(const osg::Texture2D& texture) const
    {
        const auto found=mTargets.find(&texture);
        if(found==mTargets.end()||!found->second.texture.valid())return false;
        if(found->second.id==mCurrentTarget)return true;
        if(mCurrentTarget!=mResolveSource)return false;
        return std::any_of(mResolveAttachments.begin(),mResolveAttachments.end(),[&](const auto& attachment) {
            return attachment.plane==0&&attachment.target==found->second.id;
        });
    }
    void Viewer::beginColorTarget(const osg::Texture2D& texture)
    { beginTextureTarget(texture,false); }
    void Viewer::beginDepthTarget(const osg::Texture2D& texture)
    { beginTextureTarget(texture,true); }
    void Viewer::beginTextureTarget(const osg::Texture2D& texture,bool depth)
    {
        collectExpiredTargets();
        if(!mTable||texture.getTextureWidth()<=0||texture.getTextureHeight()<=0)throw std::runtime_error("Invalid nested color target");
        const bool floating=allowsNegativeColor(texture.getInternalFormat());
        const auto kind=depth?0x80000000u:wideColorAtlas(texture.getInternalFormat())?0x20000000u:0u;
        auto found=mTargets.find(&texture);
        if(found==mTargets.end()) {
            if(mNextTarget>=0x20000000u)throw std::runtime_error("Color target identity overflow");
            found=mTargets.emplace(&texture,Target{&texture,mNextTarget++|kind}).first;
        }
        if((found->second.id&0xe0000000u)!=kind||found->second.id==mCurrentTarget)throw std::runtime_error("Invalid nested color target identity");
        if(!submitBrowserPass(std::move(mPacket),mTable,mWidth,mHeight))throw std::runtime_error("Color target boundary rejected");
        mTargetStack.push_back({std::move(mTable),mWidth,mHeight,mCurrentTarget});
        mWidth=texture.getTextureWidth();mHeight=texture.getTextureHeight();mCurrentTarget=found->second.id;mPacket={};
        mColorTargetsWritten.insert(mCurrentTarget);
        mTable=std::make_shared<MaterialTable>(mWidth,mHeight);mTable->setFloatingColor(floating);mTable->setHasDepth(depth);mTable->setDepthOnly(depth);
        mTable->setSimulationTime(static_cast<float>(getFrameStamp()->getSimulationTime()));
        const auto target=mCurrentTarget;
        mTable->setRenderTextureResolver([this,target](const osg::Texture2D* value) {
            const auto item=mTargets.find(value);if(item==mTargets.end()||!item->second.texture.valid())return std::uint32_t(0);
            if(item->second.id==target)throw std::runtime_error("Color target samples itself");return item->second.id;
        });
#ifdef __EMSCRIPTEN__
        omw_webcuda_color_target(1,mCurrentTarget,depth?GL_RGBA8:texture.getInternalFormat(),depth?texture.getInternalFormat():0x81A6);
#endif
    }
    void Viewer::endColorTarget()
    {
        if(!mTable||mTargetStack.empty())throw std::logic_error("Unbalanced nested color target");
        if(!submitBrowserPass(std::move(mPacket),mTable,mWidth,mHeight))throw std::runtime_error("Color target completion rejected");
        auto saved=std::move(mTargetStack.back());mTargetStack.pop_back();
        mTable=std::move(saved.table);mWidth=saved.width;mHeight=saved.height;mCurrentTarget=saved.target;mPacket={};
#ifdef __EMSCRIPTEN__
        omw_webcuda_color_target(0,mCurrentTarget,GL_RGBA8,0x81A6);
#endif
    }
    void Viewer::captureDepth(const osg::Texture2D& texture)
    {
        collectExpiredTargets();
        if(!mTable||texture.getTextureWidth()!=static_cast<int>(mWidth)||texture.getTextureHeight()!=static_cast<int>(mHeight))throw std::runtime_error("Depth capture dimensions differ from scene");
        auto found=mTargets.find(&texture);
        if(found==mTargets.end()) {
            if(mNextTarget>=0x20000000u)throw std::runtime_error("Depth target identity overflow");
            found=mTargets.emplace(&texture,Target{&texture,mNextTarget++|0x80000000u}).first;
        }
        if((found->second.id&0xe0000000u)!=0x80000000u||found->second.id==mCurrentTarget)throw std::runtime_error("Invalid depth capture destination");
        if(!submitBrowserPass(std::move(mPacket),mTable,mWidth,mHeight))throw std::runtime_error("Depth capture boundary rejected");
        mPacket={};
#ifdef __EMSCRIPTEN__
        omw_webcuda_capture_depth(found->second.id,mWidth,mHeight);
#endif
    }
    void Viewer::splitDepthPass(bool begin,float depth)
    {
        if(!mTable)throw std::logic_error("Depth isolation outside camera pass");
        if(!submitBrowserPass(std::move(mPacket),mTable,mWidth,mHeight))throw std::runtime_error("WebCuda depth pass was rejected");
        mPacket={};
#ifdef __EMSCRIPTEN__
        omw_webcuda_depth_isolation(begin,depth);
#endif
    }
    void Viewer::beginDepthIsolation(float depth) { splitDepthPass(true,depth); }
    void Viewer::endDepthIsolation() { splitDepthPass(false,0); }
    void Viewer::resolveScene(const osg::Texture2D& scene,const osg::Texture2D* distortion,float scaleX,float scaleY)
    {
        collectExpiredTargets();
        const auto source=mTargets.find(&scene);
        const auto effect=distortion?mTargets.find(distortion):mTargets.end();
        if(!mTable||source==mTargets.end())throw std::runtime_error("Scene resolve texture is unregistered");
        // An empty distortion bin produces no callback. Resolve the scene
        // unchanged instead of reusing stale offsets from an earlier frame.
        const auto distortionId=effect!=mTargets.end()&&mColorTargetsWritten.count(effect->second.id)?effect->second.id:0u;
        if(!submitBrowserPass(std::move(mPacket),mTable,mWidth,mHeight))throw std::runtime_error("Scene resolve boundary rejected");
        mPacket={};
#ifdef __EMSCRIPTEN__
        unsigned int destinationFormat=GL_RGBA8;
        if(mCurrentTarget) {
            bool found=false;
            for(const auto& [texture,target]:mTargets)if(target.id==mCurrentTarget&&target.texture.valid()) {
                destinationFormat=texture->getInternalFormat();found=true;break;
            }
            if(!found)for(const auto& [key,target]:mColorRenderbuffers)
                if(target.id==mCurrentTarget&&target.owner.valid()) {
                    destinationFormat=target.format;found=true;break;
                }
            if(!found)throw std::runtime_error("Postprocess destination is unregistered");
        }
        omw_webcuda_resolve(source->second.id,distortionId,scene.getInternalFormat(),destinationFormat,scaleX,scaleY);
#endif
    }
    void Viewer::debugScene(const osg::Texture2D* depth,const osg::Texture2D* normals,const DebugSettings& settings)
    {
        collectExpiredTargets();
        if(!mTable||!mPacket.triangles.empty())throw std::runtime_error("Debug requires a resolved pass");
        const auto identity=[this](const osg::Texture2D* texture) {
            if(!texture)return 0u;
            const auto found=mTargets.find(texture);
            if(found==mTargets.end())throw std::runtime_error("Debug attachment is unregistered");
            return found->second.id;
        };
        const auto depthId=settings.displayDepth?identity(depth):0u;
        const auto normalId=settings.displayNormals?identity(normals):0u;
        if(settings.displayDepth&&!depthId)throw std::runtime_error("Debug depth attachment is missing");
        float values[19]={settings.nearPlane,settings.farPlane,settings.depthFactor};
        for(unsigned int i=0;i<16;i++)values[3+i]=settings.view[i];
        const unsigned int flags=(settings.displayDepth?1u:0u)|(normalId?2u:0u)
            |(settings.worldNormals?4u:0u)|(settings.reverseZ?8u:0u);
#ifdef __EMSCRIPTEN__
        omw_webcuda_debug(depthId,normalId,flags,values);
#endif
    }
    void Viewer::bloomScene(const osg::Texture2D& depth,const BloomSettings& settings)
    {
        collectExpiredTargets();
        const auto found=mTargets.find(&depth);
        if(!mTable||!mPacket.triangles.empty()||found==mTargets.end())throw std::runtime_error("Bloom requires a resolved pass and registered depth");
        const float values[]={settings.gamma,settings.threshold,settings.clamp,settings.skyFactor,settings.radius,settings.strength,
            settings.nearPlane,settings.farPlane,settings.resolutionWidth,settings.resolutionHeight,settings.time};
#ifdef __EMSCRIPTEN__
        omw_webcuda_bloom(found->second.id,values,settings.reverseZ);
#endif
    }
    void Viewer::sceneLuminance(const osg::Texture2D& texture,unsigned int width,unsigned int height,
        float sx,float sy,float speed,bool reset)
    {
        collectExpiredTargets();
        const auto source=mTargets.find(&texture);
        if(!mTable||source==mTargets.end())throw std::runtime_error("Luminance source is unregistered");
        if(!submitBrowserPass(std::move(mPacket),mTable,mWidth,mHeight))throw std::runtime_error("Luminance boundary rejected");
        mPacket={};
#ifdef __EMSCRIPTEN__
        omw_webcuda_luminance(source->second.id,width,height,sx,sy,speed,reset,getFrameStamp()->getSimulationTime(),mWidth,mHeight);
#endif
    }
    void Viewer::distortScene(const osg::Texture2D& texture)
    {
        collectExpiredTargets();
        if(!mTable||!mPacket.triangles.empty())throw std::runtime_error("Scene distortion requires a resolved pass boundary");
        const auto effect=mTargets.find(&texture);
        if(effect==mTargets.end()||!mColorTargetsWritten.count(effect->second.id))return;
#ifdef __EMSCRIPTEN__
        omw_webcuda_distort(effect->second.id);
#endif
    }
    void Viewer::adjustScene(float gamma,float contrast)
    {
        if(!mTable||!mPacket.triangles.empty())throw std::runtime_error("Scene adjustments require a resolved pass boundary");
#ifdef __EMSCRIPTEN__
        omw_webcuda_adjust(gamma,contrast);
#endif
    }
    void Viewer::ripples(const osg::Texture2D& texture,const float* positions,unsigned int count,float ox,float oy,float time,bool simulate)
    {
        collectExpiredTargets();
        const auto found=mTargets.find(&texture);
        if(!mTable||found==mTargets.end()||!(found->second.id&0x20000000u)||!mPacket.triangles.empty())
            throw std::runtime_error("Ripple simulation requires its own registered floating target pass");
#ifdef __EMSCRIPTEN__
        omw_webcuda_ripples(found->second.id,texture.getTextureWidth(),texture.getTextureHeight(),positions,count,ox,oy,time,simulate);
#endif
    }
    void Viewer::particles(const osgParticle::ParticleSystem& particles,const DrawContext& context)
    {
        if (!mTable) throw std::logic_error("WebCuda particles outside stage");
        writableMaterialTable(mTable);
        // Expanded point/line triangles represent non-polygon primitives.
        // Polygon culling and polygon-fill offset must not apply to them.
        osg::ref_ptr<osg::StateSet> screenState=new osg::StateSet;
        screenState->setMode(GL_CULL_FACE,osg::StateAttribute::OFF|osg::StateAttribute::OVERRIDE|osg::StateAttribute::PROTECTED);
        screenState->setMode(GL_POLYGON_OFFSET_FILL,osg::StateAttribute::OFF|osg::StateAttribute::OVERRIDE|osg::StateAttribute::PROTECTED);
        auto particleContext=context;particleContext.particleDraw=true;
        auto screenContext=particleContext;screenContext.states.push_back(screenState);
        appendParticles(mPacket,particles,particleContext,mTable->encode(particleContext),mTable->encode(screenContext));
    }
    void Viewer::text(const osgText::Text& text,const DrawContext& context)
    {
        if(!mTable)throw std::logic_error("Text outside WebCuda stage");
        writableMaterialTable(mTable);
        if(!text.getCoords()||text.getCoords()->empty()||text.getColor().a()==0.f)return;
        if(text.getColorGradientMode()!=osgText::Text::SOLID&&text.getColorGradientMode()!=osgText::Text::PER_CHARACTER&&text.getColorGradientMode()!=osgText::Text::OVERALL)
            throw std::runtime_error("Unsupported text gradient mode");
        const osg::Matrixd placement(text.getMatrix());
        auto draw=context;draw.localTransform=&placement;draw.textGradient=nullptr;
        std::array<float,18> textPlacement{};
        if(text.getCharacterSizeMode()!=osgText::TextBase::OBJECT_COORDS||text.getAutoRotateToScreen()) {
            textPlacement[0]=static_cast<float>(text.getCharacterSizeMode());
            textPlacement[1]=text.getAutoRotateToScreen()?1.f:0.f;
            textPlacement[2]=text.getGlyphNormalized()?1.f:0.f;
            textPlacement[3]=text.getCharacterHeight();textPlacement[4]=text.getCharacterAspectRatio();
            textPlacement[5]=static_cast<float>(text.getFontHeight());
            for(unsigned int k=0;k<3;k++) {textPlacement[6+k]=text.getLayoutOffset()[k];textPlacement[9+k]=text.getPosition()[k];}
            for(unsigned int k=0;k<4;k++)textPlacement[12+k]=static_cast<float>(text.getRotation()[k]);
            const auto* viewport=mPassCamera?mPassCamera->getViewport():nullptr;
            textPlacement[16]=viewport?viewport->width():mWidth;textPlacement[17]=viewport?viewport->height():mHeight;
            draw.textPlacement=textPlacement.data();
        }
        // Preserve OSG's decoration-before-glyph ordering and original topology.
        if((text.getDrawMode()&~osgText::TextBase::TEXT)!=0) {
            osg::ref_ptr<osg::StateSet> lineState=new osg::StateSet;
            lineState->setMode(GL_CULL_FACE,osg::StateAttribute::OFF|osg::StateAttribute::OVERRIDE|osg::StateAttribute::PROTECTED);
            lineState->setMode(GL_POLYGON_OFFSET_FILL,osg::StateAttribute::OFF|osg::StateAttribute::OVERRIDE|osg::StateAttribute::PROTECTED);
            auto lineDraw=draw;lineDraw.states.push_back(lineState);
            for(const auto& primitive:text.getDecorationPrimitives()) {
                if(!primitive)throw std::runtime_error("Missing text decoration primitive");
                osg::ref_ptr<osg::Geometry> geometry=new osg::Geometry;
                geometry->setVertexArray(new osg::Vec3Array(*text.getCoords()));
                osg::ref_ptr<osg::Vec4Array> colors=new osg::Vec4Array;
                colors->push_back(primitive->getMode()==GL_TRIANGLES?text.getBoundingBoxColor():osg::Vec4(1.f,1.f,1.f,1.f));
                geometry->setColorArray(colors,osg::Array::BIND_OVERALL);
                geometry->addPrimitiveSet(primitive);
                appendGeometry(mPacket,*geometry,draw,mTable->encode(draw,nullptr,true),mTable->encode(lineDraw,nullptr,true));
            }
        }
        if((text.getDrawMode()&osgText::TextBase::TEXT)==0)return;
        struct UVReader : osg::Drawable::ConstAttributeFunctor {
            osg::ref_ptr<osg::Vec2Array> values;
            void apply(osg::Drawable::AttributeType type,unsigned int count,const osg::Vec2* data) override {
                if(type==osg::Drawable::TEXTURE_COORDS_0)values=new osg::Vec2Array(count,data);
            }
        } uv;
        text.accept(uv);
        if(!uv.values||uv.values->size()!=text.getCoords()->size())throw std::runtime_error("Missing glyph UV coordinates");
        std::array<float,7> backdrop{};
        if(text.getBackdropType()!=osgText::Text::NONE) {
            const auto type=static_cast<unsigned int>(text.getBackdropType());
            if(type>8u)throw std::runtime_error("Unknown text backdrop type");
            const float horizontal=text.getBackdropHorizontalOffset(),vertical=text.getBackdropVerticalOffset();
            backdrop[0]=type==8u?2.f:1.f;
            backdrop[1]=(type<=2u||type==8u)?horizontal:(type>=5u?-horizontal:0.f);
            backdrop[2]=(type==0u||type==3u||type==5u)?-vertical:((type==2u||type==4u||type==7u)?vertical:0.f);
            for(unsigned int channel=0;channel<4;channel++)backdrop[3+channel]=text.getBackdropColor()[channel];
        }
        std::array<float,16> gradient{};
        if(text.getColorGradientMode()==osgText::Text::OVERALL) {
            const osg::Vec4 corners[]{text.getColorGradientTopLeft(),text.getColorGradientBottomLeft(),
                text.getColorGradientBottomRight(),text.getColorGradientTopRight()};
            for(unsigned int corner=0;corner<4;corner++)for(unsigned int channel=0;channel<4;channel++)gradient[corner*4+channel]=corners[corner][channel];
            draw.textGradient=gradient.data();
        }
        for(const auto& [atlas,quads]:text.getTextureGlyphQuadMap()) {
            if(!atlas||!quads._primitives)throw std::runtime_error("Incomplete glyph atlas group");
            const bool distanceField=atlas->getShaderTechnique()>osgText::GREYSCALE;
            auto dimension=[&](const char* name,float fallback) {
                if(const auto* state=text.getStateSet()) {
                    const auto& defines=state->getDefineList();const auto found=defines.find(name);
                    if(found!=defines.end()) {
                        size_t end=0;const float value=std::stof(found->second.first,&end);
                        if(end!=found->second.first.size()||!std::isfinite(value)||value<=0)throw std::runtime_error("Invalid glyph dimension define");
                        return value;
                    }
                }
                return fallback;
            };
            auto* image=atlas->createImage();
            if(!image)throw std::runtime_error("Glyph atlas has no CPU image");
            const auto format=image->getPixelFormat();
            if(distanceField?(format!=GL_LUMINANCE_ALPHA&&format!=GL_RG):(format!=GL_ALPHA&&format!=GL_RED))throw std::runtime_error("Unsupported glyph coverage format");
            osg::ref_ptr<osg::Texture2D> texture=new osg::Texture2D(image);
            texture->setFilter(osg::Texture::MIN_FILTER,atlas->getFilter(osg::Texture::MIN_FILTER));
            texture->setFilter(osg::Texture::MAG_FILTER,atlas->getFilter(osg::Texture::MAG_FILTER));
            texture->setWrap(osg::Texture::WRAP_S,atlas->getWrap(osg::Texture::WRAP_S));
            texture->setWrap(osg::Texture::WRAP_T,atlas->getWrap(osg::Texture::WRAP_T));
            osg::ref_ptr<osg::Geometry> geometry=new osg::Geometry;
            geometry->setVertexArray(new osg::Vec3Array(*text.getCoords()));
            geometry->setTexCoordArray(0,uv.values,osg::Array::BIND_PER_VERTEX);
            osg::ref_ptr<osg::Vec4Array> colors=new osg::Vec4Array;
            if(text.getColorGradientMode()==osgText::Text::PER_CHARACTER) {
                // OSG stores glyph corners in TL, BL, BR, TR order. These are
                // authored color inputs; interpolation remains in material.cu.
                const osg::Vec4 corners[]{text.getColorGradientTopLeft(),text.getColorGradientBottomLeft(),
                    text.getColorGradientBottomRight(),text.getColorGradientTopRight()};
                for(unsigned int i=0;i<text.getCoords()->size();++i)colors->push_back(corners[i%4u]);
                geometry->setColorArray(colors,osg::Array::BIND_PER_VERTEX);
            } else {
                colors->push_back(text.getColor());geometry->setColorArray(colors,osg::Array::BIND_OVERALL);
            }
            geometry->addPrimitiveSet(quads._primitives);
            appendGeometry(mPacket,*geometry,draw,mTable->encodeGlyph(draw,texture,format==GL_RED||format==GL_RG,distanceField,dimension("GLYPH_DIMENSION",32.f),dimension("TEXTURE_DIMENSION",1024.f),backdrop.data()));
        }
    }
    void Viewer::gui(const osg::Array& array,std::size_t count,const osg::Texture2D* texture,const DrawContext& context)
    {
        if (!mTable) throw std::logic_error("WebCuda GUI outside stage");
        writableMaterialTable(mTable);
        appendGui(mPacket,array,count,context,mTable->encode(context,texture,true));
    }
}
