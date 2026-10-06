#include "submission.hpp"
#include <osgText/Text>
#include "materialstate.hpp"
#include "deformation.hpp"
#include <osg/UserDataContainer>
#include <osg/Depth>
#include <osg/ColorMask>
#include <osg/TexGen>
#include <osg/Light>
#include <osg/Matrixd>
#include <array>
#include <cmath>
#include <osg/Array>
#include <osgParticle/ParticleSystem>
#include <osgParticle/ConnectedParticleSystem>

#include <algorithm>
#include <stdexcept>
#include <string>
#include <osg/Geometry>
#include <osg/DispatchCompute>
#include <osg/Program>
#include <osg/Shader>
#include <osg/Camera>
#include <osgUtil/RenderBin>
#include <osgUtil/RenderLeaf>
#include <osgUtil/RenderStage>
#include <osgUtil/StateGraph>

namespace WebCuda
{
    namespace
    {
        struct PositionalState
        {
            osg::ref_ptr<osg::StateSet> defaults=new osg::StateSet;
            std::array<const osg::TexGen*,4> applied{};
            std::array<osg::Matrixd,4> matrices;
            std::array<const osg::Light*,8> lights{};
            std::array<osg::Matrixd,8> lightMatrices;
            std::array<osg::Matrixd,4> postMatrices;
            std::array<osg::Matrixd,8> lightPostMatrices;
            std::array<bool,4> hasPost{};
            std::array<bool,8> hasLightPost{};
            void positioned(osgUtil::PositionalStateContainer* container,const osg::Matrix* post=nullptr)
            {
                if(!container)return;
                for(const auto& entry:container->getAttrMatrixList()) {
                    const auto* light=dynamic_cast<const osg::Light*>(entry.first.get());
                    if(!light)continue;
                    const int index=light->getLightNum();
                    if(index<0||index>=8)throw std::runtime_error("Fixed light index exceeds compatibility limit");
                    lightMatrices[index]=entry.second.valid()?osg::Matrixd(*entry.second):osg::Matrixd::identity();
                    hasLightPost[index]=post!=nullptr;
                    if(post)lightPostMatrices[index]=*post;
                    lights[index]=light;defaults->setAttribute(const_cast<osg::Light*>(light));
                }
                for(const auto& [unit,entries]:container->getTexUnitAttrMatrixListMap())for(const auto& entry:entries) {
                    const auto* generator=dynamic_cast<const osg::TexGen*>(entry.first.get());
                    if(!generator)continue;
                    if(unit>=4)throw std::runtime_error("Positioned TexGen exceeds transported UV sets");
                    matrices[unit]=entry.second.valid()?osg::Matrixd(*entry.second):osg::Matrixd::identity();
                    hasPost[unit]=post!=nullptr;
                    if(post)postMatrices[unit]=*post;
                    applied[unit]=generator;
                    defaults->setTextureAttribute(unit,const_cast<osg::TexGen*>(generator));
                }
            }
            void capture(DrawContext& context)
            {
                const auto state=resolveState(context);
                for(unsigned int index=0;index<8;index++) {
                    const auto* light=dynamic_cast<const osg::Light*>(state->getAttribute(osg::StateAttribute::LIGHT,index));
                    if(light!=lights[index]) {
                        if(!context.modelView)throw std::runtime_error("Light application has no model-view matrix");
                        lightMatrices[index]=*context.modelView;lights[index]=light;hasLightPost[index]=false;
                    }
                    context.lightModelView[index]=&lightMatrices[index];
                    context.lightModelViewPost[index]=hasLightPost[index]?&lightPostMatrices[index]:nullptr;
                }
                for(unsigned int unit=0;unit<4;unit++) {
                    const auto* generator=dynamic_cast<const osg::TexGen*>(state->getTextureAttribute(unit,osg::StateAttribute::TEXGEN));
                    // OSG caches attribute identity: changing only model-view
                    // does not reapply the stored eye-plane equations.
                    if(generator!=applied[unit]) {
                        if(!context.modelView)throw std::runtime_error("TexGen application has no model-view matrix");
                        matrices[unit]=*context.modelView;applied[unit]=generator;hasPost[unit]=false;
                    }
                    context.texgenModelView[unit]=&matrices[unit];
                    context.texgenModelViewPost[unit]=hasPost[unit]?&postMatrices[unit]:nullptr;
                }
            }
        };
        void captureCurrentColor(DrawContext& context,SubmissionSink& sink)
        {
            auto& current=sink.currentAttributes;
            const auto state=resolveState(context);
            const auto* material=dynamic_cast<const osg::Material*>(state->getAttribute(osg::StateAttribute::MATERIAL));
            // OSG creates the default attribute on first application, then
            // restores that default when an explicit material leaves the stack.
            if(material&&!current.defaultMaterial)current.defaultMaterial=new osg::Material;
            if(!material)material=current.defaultMaterial.get();
            if(material!=current.material.get()) {
                // Fixed-function profiles without GL1 do not change current
                // color in Material::apply. GLES/emulated profiles use diffuse.
#if !defined(OSG_GL_FIXED_FUNCTION_AVAILABLE) || defined(OSG_GL1_AVAILABLE)
                osg::Vec4 color=material->getDiffuse(osg::Material::FRONT);
#if defined(OSG_GL_FIXED_FUNCTION_AVAILABLE) && defined(OSG_GL1_AVAILABLE)
                switch(material->getColorMode()) {
                    case osg::Material::AMBIENT:color=material->getAmbient(osg::Material::FRONT);break;
                    case osg::Material::SPECULAR:color=material->getSpecular(osg::Material::FRONT);break;
                    case osg::Material::EMISSION:color=material->getEmission(osg::Material::FRONT);break;
                    default:break;
                }
#endif
                for(unsigned int k=0;k<4;k++) {
                    if(!std::isfinite(color[k]))throw std::runtime_error("Non-finite material current color");
                    current.color[k]=color[k];
                }
#endif
                current.material=material;
            }
            std::copy(current.color,current.color+4,context.currentColor);
            context.hasCurrentColor=true;
        }
        void retainCurrentAttributes(const osg::Geometry& geometry,SubmissionSink& sink)
        {
            const SkinInputs* skin=nullptr;
            if(const auto* metadata=geometry.getUserDataContainer())
                skin=dynamic_cast<const SkinInputs*>(metadata->getUserObject("webcuda.skin"));
            if(skin&&!skin->source)throw std::runtime_error("Skin snapshot has no source geometry");
            const auto& arrays=skin?*skin->source:geometry;
            // OSG dispatches OVERALL once, and PER_PRIMITIVE_SET before each
            // primitive set. Array draws leave the corresponding GL current
            // value unspecified; retain our last explicitly dispatched value.
            const auto index=[&](const osg::Array* array)->int {
                if(!array)return -1;
                if(array->getBinding()==osg::Array::BIND_OVERALL)return 0;
                if(array->getBinding()==osg::Array::BIND_PER_PRIMITIVE_SET&&geometry.getNumPrimitiveSets())
                    return static_cast<int>(geometry.getNumPrimitiveSets()-1);
                return -1;
            };
            if(const auto* array=arrays.getColorArray()) {
                const int i=index(array);
                if(i>=0) {
                    if(static_cast<unsigned int>(i)>=array->getNumElements())throw std::runtime_error("Short current color array");
                    osg::Vec4 color(1,1,1,1);
                    if(const auto* values=dynamic_cast<const osg::Vec4Array*>(array))color=(*values)[i];
                    else if(const auto* values=dynamic_cast<const osg::Vec3Array*>(array))
                        for(unsigned int k=0;k<3;k++)color[k]=(*values)[i][k];
                    else if(const auto* values=dynamic_cast<const osg::Vec4dArray*>(array))
                        for(unsigned int k=0;k<4;k++)color[k]=static_cast<float>((*values)[i][k]);
                    else if(const auto* values=dynamic_cast<const osg::Vec3dArray*>(array))
                        for(unsigned int k=0;k<3;k++)color[k]=static_cast<float>((*values)[i][k]);
                    else if(const auto* values=dynamic_cast<const osg::Vec4ubArray*>(array))
                        for(unsigned int k=0;k<4;k++)color[k]=(*values)[i][k]/255.f;
                    else if(const auto* values=dynamic_cast<const osg::Vec3ubArray*>(array))
                        for(unsigned int k=0;k<3;k++)color[k]=(*values)[i][k]/255.f;
                    else throw std::runtime_error("Unsupported current color array");
                    for(unsigned int k=0;k<4;k++) {
                        if(!std::isfinite(color[k]))throw std::runtime_error("Non-finite current color");
                        sink.currentAttributes.color[k]=color[k];
                    }
                }
            }
            if(const auto* array=arrays.getSecondaryColorArray()) {
                const int i=index(array);
                if(i>=0) {
                    if(static_cast<unsigned int>(i)>=array->getNumElements())throw std::runtime_error("Short current secondary color array");
                    for(unsigned int k=0;k<3;k++) {
                        float value;
                        if(const auto* values=dynamic_cast<const osg::Vec3Array*>(array))value=(*values)[i][k];
                        else if(const auto* values=dynamic_cast<const osg::Vec3dArray*>(array))value=static_cast<float>((*values)[i][k]);
                        else if(const auto* values=dynamic_cast<const osg::Vec3ubArray*>(array))value=(*values)[i][k]/255.f;
                        else throw std::runtime_error("Unsupported current secondary color array");
                        if(!std::isfinite(value))throw std::runtime_error("Non-finite current secondary color");
                        sink.currentAttributes.secondaryColor[k]=value;
                    }
                }
            }
            if(const auto* array=arrays.getNormalArray()) {
                const int i=index(array);
                if(i>=0) {
                    if(static_cast<unsigned int>(i)>=array->getNumElements())throw std::runtime_error("Short current normal array");
                    for(unsigned int k=0;k<3;k++) {
                        float value;
                        if(const auto* values=dynamic_cast<const osg::Vec3Array*>(array))value=(*values)[i][k];
                        else if(const auto* values=dynamic_cast<const osg::Vec3dArray*>(array))value=static_cast<float>((*values)[i][k]);
                        else throw std::runtime_error("Unsupported current normal array");
                        if(!std::isfinite(value))throw std::runtime_error("Non-finite current normal");
                        sink.currentAttributes.normal[k]=value;
                    }
                }
            }
            if(const auto* array=arrays.getFogCoordArray()) {
                const int i=index(array);
                if(i>=0) {
                    if(static_cast<unsigned int>(i)>=array->getNumElements())throw std::runtime_error("Short current fog array");
                    float value;
                    if(const auto* values=dynamic_cast<const osg::FloatArray*>(array))value=(*values)[i];
                    else if(const auto* values=dynamic_cast<const osg::DoubleArray*>(array))value=static_cast<float>((*values)[i]);
                    else throw std::runtime_error("Unsupported current fog array");
                    if(!std::isfinite(value))throw std::runtime_error("Non-finite current fog coordinate");
                    sink.currentAttributes.fogCoordinate=value;
                }
            }
        }
        void submitParticles(const osgParticle::ParticleSystem& particles,SubmissionSink& sink,const DrawContext& context)
        {
            osgParticle::ParticleSystem::ScopedReadLock lock(*particles.getReadWriteMutex());
            particles.notifyExternalDraw(sink.frameNumber());
            if(particles.numParticles()==0)return;
            if(dynamic_cast<const osgParticle::ConnectedParticleSystem*>(&particles)) {
                sink.particles(particles,context);return;
            }
            const auto resolved=resolveState(context);
            const auto* inherited=dynamic_cast<const osg::Depth*>(resolved->getAttribute(osg::StateAttribute::DEPTH));
            osg::ref_ptr<osg::Depth> depth=inherited?new osg::Depth(*inherited):new osg::Depth;
            depth->setWriteMask(false);
            osg::ref_ptr<osg::StateSet> colorState=new osg::StateSet;
            colorState->setAttribute(depth,osg::StateAttribute::ON|osg::StateAttribute::OVERRIDE|osg::StateAttribute::PROTECTED);
            auto color=context;color.states.push_back(colorState);sink.particles(particles,color);
            if(particles.getDoublePassRendering()) {
                osg::ref_ptr<osg::StateSet> depthState=new osg::StateSet;
                depthState->setAttribute(new osg::ColorMask(false,false,false,false),
                    osg::StateAttribute::ON|osg::StateAttribute::OVERRIDE|osg::StateAttribute::PROTECTED);
                auto pass=context;pass.states.push_back(depthState);sink.particles(particles,pass);
            }
        }
        void submitLeaf(const osgUtil::RenderLeaf& leaf, SubmissionSink& sink,
            const std::vector<const osg::StateSet*>& inherited,const osg::Matrixd* view,PositionalState& planes,const CustomRenderBin* replay=nullptr)
        {
            if (!leaf.getDrawable()) return;
            DrawContext context;
            context.projection = leaf._projection.get();
            context.modelView = leaf._modelview.get();
            context.view = view;
            context.simulationTime=sink.simulationTime();
            context.states = inherited;
            std::vector<const osg::StateSet*> ancestry;
            for (auto* graph = leaf._parent; graph; graph = graph->_parent)
                if (graph->_stateset) ancestry.push_back(graph->_stateset.get());
            context.states.insert(context.states.end(), ancestry.rbegin(), ancestry.rend());

            const osg::Drawable& drawable = *leaf.getDrawable();
            if(replay&&!replay->acceptReplayWebCuda(drawable,context))return;
            osg::ref_ptr<osg::StateSet> callbackState;
            if(const auto* callback=drawable.getDrawCallback()) {
                const auto* capture=dynamic_cast<const CustomDrawCallback*>(callback);
                if(!capture)throw std::runtime_error("WebCuda drawable callback has no capture handler");
                callbackState=capture->captureWebCudaState();
                if(callbackState)context.states.push_back(callbackState.get());
            }
            planes.capture(context);
            captureCurrentColor(context,sink);
            for(unsigned int k=0;k<3;k++) {
                context.currentSecondaryColor[k]=sink.currentAttributes.secondaryColor[k];
                context.currentNormal[k]=sink.currentAttributes.normal[k];
                context.particleNormal[k]=sink.currentAttributes.normal[k];
            }
            context.currentFogCoordinate=sink.currentAttributes.fogCoordinate;
            if(dynamic_cast<const osg::DispatchCompute*>(&drawable)) {
                const auto state=resolveState(context);
                const auto* program=dynamic_cast<const osg::Program*>(state->getAttribute(osg::StateAttribute::PROGRAM));
                bool clusterCompute=false;
                if(program&&program->getNumShaders()==1) {
                    const auto* shader=program->getShader(0);const auto& name=shader->getName();
                    for(const std::string suffix:{"core/lighting/cluster.comp","core/lighting/cull.comp"})
                        clusterCompute|=shader->getType()==osg::Shader::COMPUTE&&name.size()>=suffix.size()
                            &&name.compare(name.size()-suffix.size(),suffix.size(),suffix)==0;
                }
                if(!clusterCompute)throw std::runtime_error("Untranslated WebCuda compute drawable");
                // Material submission captures the same CPU light snapshot.
                // Its .cu cluster jobs run before consumers in each GPU pass.
                return;
            }
            if (const auto* custom = dynamic_cast<const CustomDrawable*>(&drawable))
                custom->submitWebCuda(sink, context);
            else if (const auto* particles = dynamic_cast<const osgParticle::ParticleSystem*>(&drawable))
                submitParticles(*particles,sink,context);
            else if(const auto* text=dynamic_cast<const osgText::Text*>(&drawable))sink.text(*text,context);
            else if (const osg::Geometry* geometry = drawable.asGeometry()) {
                sink.geometry(*geometry, context);
                retainCurrentAttributes(*geometry,sink);
            }
            else
                throw std::runtime_error("WebCuda submission requires a handler for "
                    + std::string(drawable.libraryName()) + "::" + drawable.className());
        }

        void submitLocalLeaves(osgUtil::RenderBin& bin,SubmissionSink& sink,
            const std::vector<const osg::StateSet*>& inherited,const osg::Matrixd* view,
            PositionalState& planes,const CustomRenderBin* replay=nullptr)
        {
            // Both normal submission and replay must consume whichever list
            // the selected RenderBin sort populated, in OSG's draw order.
            for(const auto* leaf:bin.getRenderLeafList())submitLeaf(*leaf,sink,inherited,view,planes,replay);
            for(const auto* graph:bin.getStateGraphList())
                for(const auto& leaf:graph->_leaves)submitLeaf(*leaf,sink,inherited,view,planes,replay);
        }

        void replayBin(osgUtil::RenderBin& bin,SubmissionSink& sink,
            std::vector<const osg::StateSet*> inherited,const osg::Matrixd* view,PositionalState& planes,const CustomRenderBin* replay,bool root)
        {
            if(!root&&bin.getStateSet())inherited.push_back(bin.getStateSet());
            auto& bins=bin.getRenderBinList();auto next=bins.begin();
            for(;next!=bins.end()&&next->first<0;++next)replayBin(*next->second,sink,inherited,view,planes,replay,false);
            submitLocalLeaves(bin,sink,inherited,view,planes,replay);
            for(;next!=bins.end();++next)replayBin(*next->second,sink,inherited,view,planes,replay,false);
        }
        void submitBin(osgUtil::RenderBin& bin, SubmissionSink& sink,
            std::vector<const osg::StateSet*> inherited,const osg::Matrixd* view,PositionalState& planes)
        {
            if (bin.getStateSet()) inherited.push_back(bin.getStateSet());
            auto* callback=dynamic_cast<CustomRenderBin*>(bin.getDrawCallback());
            if(bin.getDrawCallback()&&!callback)throw std::runtime_error("WebCuda render-bin callback has no submission handler");
            if(callback&&!callback->shouldSubmitWebCuda(sink))return;
            if(callback)if(const auto* state=callback->beginWebCuda(sink))inherited.push_back(state);
            auto& bins = bin.getRenderBinList();
            auto next = bins.begin();
            for (; next != bins.end() && next->first < 0; ++next)
                submitBin(*next->second, sink, inherited,view,planes);

            // RenderBin::sort() chooses either fine-grained leaf order or coarse
            // state-graph order. Match drawImplementation without making GL calls.
            submitLocalLeaves(bin,sink,inherited,view,planes);

            for (; next != bins.end(); ++next) submitBin(*next->second, sink, inherited,view,planes);
            if(callback)if(const auto* state=callback->beginReplayWebCuda(sink)) {
                auto replayStates=inherited;replayStates.push_back(state);
                if(callback->replaySubtreeWebCuda())replayBin(bin,sink,replayStates,view,planes,callback,true);
                else submitLocalLeaves(bin,sink,replayStates,view,planes,callback);
                callback->endReplayWebCuda(sink);
            }
            if(callback)callback->endWebCuda(sink);
        }
    }

    void submitStage(osgUtil::RenderStage& stage, SubmissionSink& sink,
        const std::vector<const osg::StateSet*>& inherited,const osg::Matrixd* view)
    {
        stage.sort();
        // CullVisitor records the composed view here for relative RTT cameras.
        // The raw Camera matrix alone would omit its inherited transform.
        if(const auto* initial=stage.getInitialViewMatrix())view=initial;
        else if(const auto* camera=stage.getCamera())view=&camera->getViewMatrix();
        for (const auto& entry : stage.getPreRenderList()) submitStage(*entry.second, sink, inherited,view);
        sink.beginPass(stage);
        PositionalState planes;
        planes.positioned(stage.getInheritedPositionalStateContainer(),&stage.getInheritedPositionalStateContainerMatrix());
        planes.positioned(stage.getPositionalStateContainer());
        auto states=inherited;states.insert(states.begin(),planes.defaults.get());
        submitBin(stage, sink, states,view,planes);
        sink.endPass(stage);
        for (const auto& entry : stage.getPostRenderList()) submitStage(*entry.second, sink, inherited,view);
    }
}
