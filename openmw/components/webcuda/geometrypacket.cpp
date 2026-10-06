#include "geometrypacket.hpp"
#include "captureprofile.hpp"
#include "materialstate.hpp"
#include "shaderanalysis.hpp"
#include "deformation.hpp"
#include "vertexstreamcache.hpp"
#include <osg/UserDataContainer>
#include <cmath>
#include <cctype>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <utility>
#include <osg/Array>
#include <osg/Geometry>
#include <osg/Matrix>
#include <osg/TriangleIndexFunctor>
#include <osg/TexMat>
#include <osg/TexGen>
#include <osg/Program>
#include <osg/Shader>
#include <osg/Point>
#include <osg/PointSprite>
#include <osg/Fog>
#include <osg/ShadeModel>
#include <osg/LineWidth>
#include <osg/PolygonMode>
#include <osg/PrimitiveRestartIndex>
#include <osg/Light>
#include <osg/LightModel>
#include <osg/Material>
#include <osg/VertexAttribDivisor>
#include <sstream>
#include <map>
#include <osgParticle/ParticleSystem>
#include <osgParticle/ConnectedParticleSystem>
#include <unordered_set>

namespace WebCuda
{
    namespace
    {
        bool shaderNamed(const osg::StateSet& state,const std::string& suffix)
        {
            if(const auto* program=dynamic_cast<const osg::Program*>(state.getAttribute(osg::StateAttribute::PROGRAM)))
                for(unsigned int i=0;i<program->getNumShaders();++i) {
                    const auto& name=program->getShader(i)->getName();
                    if(name.size()>=suffix.size()&&name.compare(name.size()-suffix.size(),suffix.size(),suffix)==0)return true;
                }
            return false;
        }
        bool shaderUsesProjectionUniform(const osg::StateSet& state)
        {
            const auto* program=dynamic_cast<const osg::Program*>(state.getAttribute(osg::StateAttribute::PROGRAM));
            if(!program)return false;
            for(unsigned int i=0;i<program->getNumShaders();++i) {
                const auto* shader=program->getShader(i);
                if(shader->getType()!=osg::Shader::VERTEX)continue;
                const auto& source=shader->getShaderSource();
                if(compactShaderContains(source,"gl_Position=modelToClip(")
                    ||compactShaderContains(source,"gl_Position=viewToClip("))return true;
            }
            return false;
        }
        // Borrowed only during one synchronous geometry capture. Resolve types,
        // bindings and bounds once, not for every vertex (or color channel).
        // These readers unpack source data; they perform no rendering math.
        class VertexArrayReader
        {
        public:
            enum class Role { Vector, Color, SecondaryColor, Normal, Fog, Tangent };

            VertexArrayReader(const osg::Array* array, unsigned int count, unsigned int primitiveSet,
                Role role, const osg::Vec4& fallback = osg::Vec4(0,0,0,1)) : mArray(array),mConstant(fallback)
            {
                const bool perVertex = role==Role::Vector || role==Role::Tangent;
                if(!array || !count || (!perVertex && array->getBinding()==osg::Array::BIND_OFF))return;
                bool supported=false;
                switch(role) {
                    case Role::Vector:
                        supported=select<osg::FloatArray,1>(array)||select<osg::DoubleArray,1>(array)
                            ||select<osg::Vec2Array,2>(array)||select<osg::Vec3Array,3>(array)||select<osg::Vec4Array,4>(array)
                            ||select<osg::Vec2dArray,2>(array)||select<osg::Vec3dArray,3>(array)||select<osg::Vec4dArray,4>(array);
                        break;
                    case Role::Color:
                        supported=select<osg::Vec4Array,4>(array)||select<osg::Vec3Array,3>(array)
                            ||select<osg::Vec4dArray,4>(array)||select<osg::Vec3dArray,3>(array)
                            ||select<osg::Vec4ubArray,4,true>(array)||select<osg::Vec3ubArray,3,true>(array);
                        break;
                    case Role::SecondaryColor:
                        supported=select<osg::Vec3Array,3>(array)||select<osg::Vec3dArray,3>(array)
                            ||select<osg::Vec3ubArray,3,true>(array);
                        break;
                    case Role::Normal:
                        supported=select<osg::Vec3Array,3>(array)||select<osg::Vec3dArray,3>(array);
                        break;
                    case Role::Fog:
                        supported=select<osg::FloatArray,1>(array)||select<osg::DoubleArray,1>(array);
                        break;
                    case Role::Tangent:
                        supported=select<osg::Vec4Array,4>(array);
                        break;
                }
                if(!supported)throw std::runtime_error(std::string("Unsupported WebCuda ")+name(role)+" array");
                // OSG binds UV and tangent arrays per vertex even with BIND_OFF.
                const auto binding=perVertex?osg::Array::BIND_PER_VERTEX:array->getBinding();
                unsigned int index=0;
                if(binding==osg::Array::BIND_PER_VERTEX)index=count-1;
                else if(binding==osg::Array::BIND_PER_PRIMITIVE_SET)index=primitiveSet;
                else if(binding!=osg::Array::BIND_OVERALL)throw std::runtime_error("Unsupported WebCuda attribute binding");
                if(index>=array->getNumElements())throw std::runtime_error(std::string("Short WebCuda ")+name(role)+" array");
                if(binding!=osg::Array::BIND_PER_VERTEX) {
                    mConstant=mRead(mData,index);
                    mRead=nullptr;
                }
            }

            osg::Vec4 operator[](unsigned int vertex) const { return mRead?mRead(mData,vertex):mConstant; }
            std::size_t inputWords(unsigned int count,unsigned int components) const { return std::size_t(mRead?count:1u)*components; }

            void capture(GeometryPacket& draw, std::uint32_t* descriptor,
                unsigned int count, unsigned int components) const
            {
                auto& inputs=draw.vertexInputs;
                const auto records=mRead?count:1u;
                if(inputs.size()+std::uint64_t(records)*components>std::numeric_limits<std::uint32_t>::max())
                    throw std::runtime_error("Vertex input stream exceeds index range");
                descriptor[0]=static_cast<std::uint32_t>(inputs.size());descriptor[1]=mRead?components:0u;
                if(mRead) {
                    static thread_local VertexStreamCache cache;
                    if(const auto* entry=cache.capture(mArray,count,components,[&](unsigned int i){return (*this)[i];})) {
                        draw.vertexResources.insert(draw.vertexResources.end(),{entry->version,descriptor[0],static_cast<std::uint32_t>(entry->values.size())});
                        inputs.insert(inputs.end(),entry->values.begin(),entry->values.end());
                        return;
                    }
                }
                for(unsigned int i=0;i<records;i++) {
                    const auto value=(*this)[i];
                    for(unsigned int k=0;k<components;k++)inputs.push_back(value[k]);
                }
            }

        private:
            template<class Value, unsigned int Components, bool Normalized>
            static osg::Vec4 read(const void* data, unsigned int vertex)
            {
                const auto& value=static_cast<const Value*>(data)[vertex];
                osg::Vec4 result(0,0,0,1);
                if constexpr(Components==1)result.x()=static_cast<float>(value);
                else for(unsigned int k=0;k<Components;k++) {
                    if constexpr(Normalized)result[k]=value[k]/255.f;
                    else result[k]=static_cast<float>(value[k]);
                }
                return result;
            }
            template<class Array, unsigned int Components, bool Normalized=false>
            bool select(const osg::Array* array)
            {
                const auto* values=dynamic_cast<const Array*>(array);
                if(!values)return false;
                mData=values->empty()?nullptr:&(*values)[0];
                mRead=&read<typename Array::value_type,Components,Normalized>;
                return true;
            }
            static const char* name(Role role)
            {
                switch(role) {
                    case Role::Vector:return "vector";
                    case Role::Color:return "color";
                    case Role::SecondaryColor:return "secondary color";
                    case Role::Normal:return "normal";
                    case Role::Fog:return "fog coordinate";
                    case Role::Tangent:return "tangent";
                }
                return "vertex";
            }
            const void* mData=nullptr;
            const osg::Array* mArray=nullptr;
            osg::Vec4 (*mRead)(const void*,unsigned int)=nullptr;
            osg::Vec4 mConstant;
        };
        std::uint32_t capturePostMatrix(GeometryPacket& draw,const osg::Matrixd& matrix)
        {
            if(draw.positionedState.size()>std::numeric_limits<std::uint32_t>::max()-16)
                throw std::runtime_error("Positioned state exceeds packet range");
            const auto offset=static_cast<std::uint32_t>(draw.positionedState.size());
            for(unsigned int k=0;k<16;k++) {
                const float value=static_cast<float>(matrix.ptr()[k]);
                if(!std::isfinite(value))throw std::runtime_error("Non-finite positioned application transform");
                std::uint32_t word;std::memcpy(&word,&value,4);draw.positionedState.push_back(word);
            }
            return offset+1;
        }
        void fixedLighting(GeometryPacket& draw,const DrawContext& context,const osg::StateSet& state)
        {
            std::array<std::uint32_t,368> data{};
            if(!state.getAttribute(osg::StateAttribute::PROGRAM)&&(state.getMode(GL_LIGHTING)&osg::StateAttribute::ON)!=0) {
                auto scalar=[&](unsigned int offset,float value) {
                    if(!std::isfinite(value))throw std::runtime_error("Non-finite fixed lighting input");
                    std::memcpy(&data[offset],&value,4);
                };
                auto vector=[&](unsigned int offset,const osg::Vec4& value){for(unsigned int k=0;k<4;k++)scalar(offset+k,value[k]);};
                osg::ref_ptr<osg::LightModel> defaultModel=new osg::LightModel;
                const auto* model=dynamic_cast<const osg::LightModel*>(state.getAttribute(osg::StateAttribute::LIGHTMODEL));
                if(!model)model=defaultModel.get();
                data[1]=128u|(model->getTwoSided()?1u:0u)|(model->getLocalViewer()?2u:0u)
                    |(model->getColorControl()==osg::LightModel::SEPARATE_SPECULAR_COLOR?4u:0u)
                    |((state.getMode(GL_NORMALIZE)&osg::StateAttribute::ON)!=0?8u:0u)
                    |((state.getMode(0x803A)&osg::StateAttribute::ON)!=0?16u:0u);
                vector(4,model->getAmbientIntensity());
                osg::ref_ptr<osg::Material> defaultMaterial=new osg::Material;
                const auto* material=dynamic_cast<const osg::Material*>(state.getAttribute(osg::StateAttribute::MATERIAL));
                const bool explicitMaterial=material!=nullptr;if(!material)material=defaultMaterial.get();
                switch(material->getColorMode()) {
                    case osg::Material::OFF:data[2]=!explicitMaterial&&(state.getMode(GL_COLOR_MATERIAL)&osg::StateAttribute::ON)!=0?2u:0u;break;
                    case osg::Material::EMISSION:data[2]=1;break;
                    case osg::Material::AMBIENT_AND_DIFFUSE:data[2]=2;break;
                    case osg::Material::AMBIENT:data[2]=3;break;
                    case osg::Material::DIFFUSE:data[2]=4;break;
                    case osg::Material::SPECULAR:data[2]=5;break;
                    default:throw std::runtime_error("Unsupported fixed color material mode");
                }
                for(unsigned int face=0;face<2;face++) {
                    const auto side=face?osg::Material::BACK:osg::Material::FRONT;const auto offset=8+face*17;
                    vector(offset,material->getAmbient(side));vector(offset+4,material->getDiffuse(side));
                    vector(offset+8,material->getSpecular(side));vector(offset+12,material->getEmission(side));
                    scalar(offset+16,material->getShininess(side));
                }
                const osg::Matrixd identity=osg::Matrixd::identity();
                for(unsigned int index=0;index<8;index++) {
                    if((state.getMode(GL_LIGHT0+index)&osg::StateAttribute::ON)==0)continue;
                    data[0]|=1u<<index;
                    const auto* light=dynamic_cast<const osg::Light*>(state.getAttribute(osg::StateAttribute::LIGHT,index));
                    osg::ref_ptr<osg::Light> fallback;
                    const osg::Matrixd* application=&identity;
                    if(light) {
                        application=context.lightModelView[index];
                        if(!application)throw std::runtime_error("Fixed light lacks application matrix");
                    } else {
                        // GL defaults differ from osg::Light's authoring defaults.
                        fallback=new osg::Light(index);fallback->setAmbient(osg::Vec4(0,0,0,1));
                        fallback->setDiffuse(osg::Vec4(index==0?1.f:0.f,index==0?1.f:0.f,index==0?1.f:0.f,1));
                        fallback->setSpecular(fallback->getDiffuse());light=fallback.get();
                    }
                    const auto offset=48+index*40;
                    vector(offset,light->getPosition());vector(offset+4,light->getAmbient());
                    vector(offset+8,light->getDiffuse());vector(offset+12,light->getSpecular());
                    for(unsigned int k=0;k<3;k++)scalar(offset+16+k,light->getDirection()[k]);
                    scalar(offset+19,light->getConstantAttenuation());scalar(offset+20,light->getLinearAttenuation());
                    scalar(offset+21,light->getQuadraticAttenuation());scalar(offset+22,light->getSpotExponent());scalar(offset+23,light->getSpotCutoff());
                    for(unsigned int k=0;k<16;k++)scalar(offset+24+k,static_cast<float>(application->ptr()[k]));
                    if(context.lightModelViewPost[index]&&application!=&identity) {
                        if(!data[3]) {
                            data[3]=static_cast<std::uint32_t>(draw.positionedState.size()+1);
                            draw.positionedState.resize(draw.positionedState.size()+8,0);
                        }
                        const auto post=capturePostMatrix(draw,*context.lightModelViewPost[index]);
                        draw.positionedState[data[3]-1+index]=post;
                    }
                }
            }
            if(!state.getAttribute(osg::StateAttribute::PROGRAM)&&(state.getMode(0x8458)&osg::StateAttribute::ON)!=0)
                data[1]|=32u; // GL_COLOR_SUM, used for unlit secondary vertex color.
            for(unsigned int k=0;k<3;k++) {
                const float value=context.currentSecondaryColor[k];
                if(!std::isfinite(value))throw std::runtime_error("Non-finite current secondary color");
                std::memcpy(&data[42+k],&value,4);
            }
            draw.fixedLighting.insert(draw.fixedLighting.end(),data.begin(),data.end());
        }
        void matrices(GeometryPacket& draw, const DrawContext& context, const osg::StateSet& resolvedState, bool gui=false)
        {
            if (!context.modelView || !context.projection) throw std::runtime_error("Missing WebCuda draw matrices");
            // OSG uses row vectors; its contiguous matrix values are the correct
            // column-vector transpose when consumed as column-major in .cu.
            const auto* state=&resolvedState;
            draw.localTransforms.push_back(context.textPlacement?2.f:(context.localTransform?1.f:0.f));
            for(unsigned int k=0;k<16;k++)draw.localTransforms.push_back(context.localTransform?static_cast<float>(context.localTransform->ptr()[k]):0.f);
            for(unsigned int k=0;k<18;k++)draw.localTransforms.push_back(context.textPlacement?context.textPlacement[k]:0.f);
            if(gui)draw.fixedLighting.resize(368,0);else fixedLighting(draw,context,*state);
            std::array<float,16> debug{};
            if(!gui&&(shaderNamed(*state,"debug.vert")||shaderNamed(*state,"outline.vert"))) {
                const bool outline=shaderNamed(*state,"outline.vert");
                bool advanced=false,normalColor=false;
                auto boolean=[&](const char* name,bool& value) {
                    if(const auto* u=state->getUniform(name))if(!u->get(value))throw std::runtime_error("Invalid debug boolean uniform");
                };
                boolean("useAdvancedShader",advanced);boolean("useNormalAsColor",normalColor);
                debug[0]=outline?4.f:(advanced?(normalColor?3.f:2.f):1.f);
                osg::ref_ptr<osg::Material> fallback=new osg::Material;
                const auto* material=dynamic_cast<const osg::Material*>(state->getAttribute(osg::StateAttribute::MATERIAL));
                osg::Vec4 color=(material?material:fallback.get())->getDiffuse(osg::Material::FRONT);
                if(outline) {
                    color.set(0,0,0,0);
                    if(const auto* u=state->getUniform("color"))if(!u->get(color))throw std::runtime_error("Invalid outline color");
                } else if(advanced) {
                    osg::Vec3 rgb,translation,scale;
                    auto vector=[&](const char* name,osg::Vec3& value) {
                        if(const auto* u=state->getUniform(name))if(!u->get(value))throw std::runtime_error("Invalid debug vector uniform");
                    };
                    vector("color",rgb);vector("trans",translation);vector("scale",scale);
                    color.set(rgb.x(),rgb.y(),rgb.z(),1.f);
                    for(unsigned int k=0;k<3;k++){debug[8+k]=translation[k];debug[12+k]=scale[k];}
                } else {
                    int mode=0;if(const auto* u=state->getUniform("colorMode"))if(!u->get(mode))throw std::runtime_error("Invalid debug color mode");
                    debug[1]=mode==2||mode==4?1.f:0.f;
                }
                for(unsigned int k=0;k<4;k++)debug[4+k]=color[k];
                for(float value:debug)if(!std::isfinite(value))throw std::runtime_error("Non-finite debug shader input");
            }
            draw.debugParams.insert(draw.debugParams.end(),debug.begin(),debug.end());
            const osg::Matrixd identity=osg::Matrixd::identity();
            const auto* projection=shaderNamed(*state,"terrain_composite.vert")?&identity:context.projection;
            osg::Matrixd shaderProjection;
            if(!gui&&shaderUsesProjectionUniform(*state)) {
                // The camera projection is intentionally unreversed for CPU
                // culling. OpenMW vertex shaders render with this uniform.
                const auto* uniform=state->getUniform("projectionMatrix");
                osg::Matrixf value;
                if(!uniform||!uniform->get(value))throw std::runtime_error("Missing or invalid shader projectionMatrix");
                shaderProjection=value;projection=&shaderProjection;
            }
            for (auto* matrix : {context.modelView, projection})
                for (int i = 0; i < 16; ++i) draw.matrices.push_back(static_cast<float>(matrix->ptr()[i]));
            const bool fixed=!gui&&!state->getAttribute(osg::StateAttribute::PROGRAM);
            for(unsigned int unit=0;unit<4;unit++) {
                std::array<std::uint32_t,36> generation{};
                if(fixed) {
                    for(unsigned int coordinate=0;coordinate<4;coordinate++)
                        if((state->getTextureMode(unit,0x0C60+coordinate)&osg::StateAttribute::ON)!=0)generation[0]|=1u<<coordinate;
                    if(generation[0]) {
                        const auto* generator=dynamic_cast<const osg::TexGen*>(state->getTextureAttribute(unit,osg::StateAttribute::TEXGEN));
                        if(!generator)throw std::runtime_error("Default eye-linear TexGen requires captured plane state");
                        switch(generator->getMode()) {
                            case osg::TexGen::OBJECT_LINEAR:generation[1]=1;break;
                            case osg::TexGen::SPHERE_MAP:generation[1]=2;break;
                            case osg::TexGen::NORMAL_MAP:generation[1]=3;break;
                            case osg::TexGen::REFLECTION_MAP:generation[1]=4;break;
                            case osg::TexGen::EYE_LINEAR:generation[1]=5;break;
                            default:throw std::runtime_error("Unsupported TexGen mode");
                        }
                        if((generation[1]==2&&(generation[0]&12))||((generation[1]==3||generation[1]==4)&&(generation[0]&8)))
                            throw std::runtime_error("TexGen coordinate needs inherited generation mode");
                        if(generation[1]==5) {
                            const auto* applied=context.texgenModelView[unit];
                            if(!applied)throw std::runtime_error("Eye-linear TexGen lacks captured application matrix");
                            for(unsigned int k=0;k<16;k++) {
                                const float value=static_cast<float>(applied->ptr()[k]);
                                if(!std::isfinite(value))throw std::runtime_error("Non-finite TexGen application matrix");
                                std::memcpy(&generation[20+k],&value,4);
                            }
                            if(context.texgenModelViewPost[unit])
                                generation[3]=capturePostMatrix(draw,*context.texgenModelViewPost[unit]);
                        }
                        generation[2]=((state->getMode(GL_NORMALIZE)&osg::StateAttribute::ON)!=0?1u:0u)
                            |((state->getMode(0x803A)&osg::StateAttribute::ON)!=0?2u:0u);
                        for(unsigned int coordinate=0;coordinate<4;coordinate++)for(unsigned int component=0;component<4;component++) {
                            const float value=static_cast<float>(generator->getPlane(static_cast<osg::TexGen::Coord>(coordinate))[component]);
                            if(!std::isfinite(value))throw std::runtime_error("Non-finite TexGen plane");
                            std::memcpy(&generation[4+coordinate*4+component],&value,4);
                        }
                    }
                }
                draw.texgen.insert(draw.texgen.end(),generation.begin(),generation.end());
            }
            const auto* texmat=dynamic_cast<const osg::TexMat*>(state->getTextureAttribute(0,osg::StateAttribute::TEXMAT));
            bool useTextureMatrix=true;
            if(const auto* program=dynamic_cast<const osg::Program*>(state->getAttribute(osg::StateAttribute::PROGRAM))) {
                // OSG's default shader passes UV.xy directly. An inherited
                // fixed-function TexMat must not transform its coordinates.
                useTextureMatrix=!isBuiltinDefaultProgram(*program);
                for(unsigned int i=0;i<program->getNumShaders();++i) {
                    const auto& name=program->getShader(i)->getName();
                    if(name.size()>=8&&name.compare(name.size()-8,8,"sky.vert")==0) {
                        int pass=0;if(const auto* uniform=state->getUniform("pass"))uniform->get(pass);
                        useTextureMatrix=pass==2;
                    }
                }
            }
            const osg::Matrix textureMatrix=texmat&&useTextureMatrix?texmat->getMatrix():osg::Matrix::identity();
            for(int i=0;i<16;++i)draw.uvMatrices.push_back(static_cast<float>(textureMatrix.ptr()[i]));
        }
        void commit(GeometryPacket& packet, GeometryPacket& draw)
        {
            const std::size_t base = packet.vertexCount(), matrix = packet.matrices.size()/32, count=draw.vertexCount();
            if(packet.morphOffsets.size()/4+draw.morphOffsets.size()/4>std::numeric_limits<std::uint32_t>::max())
                throw std::runtime_error("Combined morph packet exceeds index range");
            if(packet.skinWeights.size()/2+draw.skinWeights.size()/2>std::numeric_limits<std::uint32_t>::max()
                ||packet.skinBones.size()/32+draw.skinBones.size()/32>std::numeric_limits<std::uint32_t>::max()
                ||packet.skinTransforms.size()/32+draw.skinTransforms.size()/32>std::numeric_limits<std::uint32_t>::max())throw std::runtime_error("Combined skin packet exceeds index range");
            if (base + count > std::numeric_limits<std::uint32_t>::max()
                || matrix >= std::numeric_limits<std::uint32_t>::max()) throw std::runtime_error("WebCuda packet is too large");
            for (float value : draw.vertices) if (!std::isfinite(value)) throw std::runtime_error("Non-finite WebCuda vertex");
            for (float value : draw.attributes) if (!std::isfinite(value)) throw std::runtime_error("Non-finite WebCuda attribute");
            for (float value : draw.vertexInputs) if (!std::isfinite(value)) throw std::runtime_error("Non-finite WebCuda vertex input");
            for (float value : draw.matrices) if (!std::isfinite(value)) throw std::runtime_error("Non-finite WebCuda matrix");
            for (float value : draw.uvMatrices) if (!std::isfinite(value)) throw std::runtime_error("Non-finite WebCuda UV matrix");
            for (std::size_t i=0; i<draw.triangles.size(); ++i)
                if (i%4 != 3) draw.triangles[i] += static_cast<std::uint32_t>(base);
            // Generated vertices inherit the current secondary color; ordinary
            // geometry supplies its explicit array before its generated tail.
            if(!draw.compactVertices) {
                const auto explicitSecondary=draw.secondaryColors.size();
                draw.secondaryColors.resize(count*3);
                for(std::size_t i=explicitSecondary;i<draw.secondaryColors.size();i++)
                    std::memcpy(&draw.secondaryColors[i],&draw.fixedLighting[42+i%3],4);
                for(float value:draw.secondaryColors)if(!std::isfinite(value))throw std::runtime_error("Non-finite secondary color");
            }
            if(packet.compactVertices) {
                std::array<std::uint32_t,32> layout{};
                const auto inputBase=packet.vertexInputs.size();
                const auto words=draw.compactVertices?draw.vertexInputs.size():count*47;
                if(inputBase+words>std::numeric_limits<std::uint32_t>::max())
                    throw std::runtime_error("Combined vertex input stream exceeds index range");
                if(draw.compactVertices) {
                    std::copy(draw.vertexLayouts.begin(),draw.vertexLayouts.end(),layout.begin());
                    const auto appendInput=[&](std::uint32_t offset,std::uint32_t length) {
                        std::uint32_t version=0;
                        for(std::size_t i=0;i<draw.vertexResources.size();i+=3)
                            if(draw.vertexResources[i+1]==offset){version=draw.vertexResources[i];break;}
                        if(version) {
                            const auto found=packet.vertexResourceOffsets.find(version);
                            if(found!=packet.vertexResourceOffsets.end())return found->second;
                        }
                        const auto destination=static_cast<std::uint32_t>(packet.vertexInputs.size());
                        packet.vertexInputs.insert(packet.vertexInputs.end(),draw.vertexInputs.begin()+offset,draw.vertexInputs.begin()+offset+length);
                        if(version) {
                            packet.vertexResources.insert(packet.vertexResources.end(),{version,destination,length});
                            packet.vertexResourceOffsets.emplace(version,destination);
                        }
                        return destination;
                    };
                    layout[5]=appendInput(layout[5],3);
                    const unsigned int widths[]={4,4,3,3,4,1,4,4,4,4};
                    for(unsigned int stream=0;stream<10;stream++)
                        layout[8+stream*2]=appendInput(layout[8+stream*2],layout[9+stream*2]?layout[2]*widths[stream]:widths[stream]);
                } else {
                    layout[2]=static_cast<std::uint32_t>(count);
                    layout[6]=static_cast<std::uint32_t>(inputBase);
                    layout[7]=layout[6]+static_cast<std::uint32_t>(draw.vertices.size());
                    layout[8]=layout[7]+static_cast<std::uint32_t>(draw.attributes.size());
                    packet.vertexInputs.insert(packet.vertexInputs.end(),draw.vertices.begin(),draw.vertices.end());
                    packet.vertexInputs.insert(packet.vertexInputs.end(),draw.attributes.begin(),draw.attributes.end());
                    packet.vertexInputs.insert(packet.vertexInputs.end(),draw.secondaryColors.begin(),draw.secondaryColors.end());
                }
                layout[0]=static_cast<std::uint32_t>(base);layout[1]=static_cast<std::uint32_t>(count);
                packet.vertexLayouts.insert(packet.vertexLayouts.end(),layout.begin(),layout.end());
                packet.capturedVertexCount=static_cast<std::uint32_t>(base+count);
            } else {
                packet.vertices.insert(packet.vertices.end(),draw.vertices.begin(),draw.vertices.end());
                packet.attributes.insert(packet.attributes.end(),draw.attributes.begin(),draw.attributes.end());
                packet.secondaryColors.insert(packet.secondaryColors.end(),draw.secondaryColors.begin(),draw.secondaryColors.end());
            }
            if(packet.groundcoverInstances.size()/7+draw.groundcoverInstances.size()/7>std::numeric_limits<std::uint32_t>::max()
                ||packet.groundcoverParams.size()/40+draw.groundcoverParams.size()/40>std::numeric_limits<std::uint32_t>::max())
                throw std::runtime_error("Combined groundcover packet exceeds index range");
            for(std::size_t i=0;i<draw.groundcoverRanges.size();i+=3) {
                draw.groundcoverRanges[i]+=static_cast<std::uint32_t>(base);
                draw.groundcoverRanges[i+1]+=static_cast<std::uint32_t>(packet.groundcoverInstances.size()/7);
                draw.groundcoverRanges[i+2]+=static_cast<std::uint32_t>(packet.groundcoverParams.size()/40);
            }
            packet.groundcoverRanges.insert(packet.groundcoverRanges.end(),draw.groundcoverRanges.begin(),draw.groundcoverRanges.end());
            packet.groundcoverInstances.insert(packet.groundcoverInstances.end(),draw.groundcoverInstances.begin(),draw.groundcoverInstances.end());
            packet.groundcoverParams.insert(packet.groundcoverParams.end(),draw.groundcoverParams.begin(),draw.groundcoverParams.end());
            if(packet.textGradientColors.size()/16+draw.textGradientColors.size()/16>std::numeric_limits<std::uint32_t>::max())
                throw std::runtime_error("Text gradient color index overflow");
            for(size_t i=0;i<draw.textGradientRanges.size();i+=3) {
                draw.textGradientRanges[i]+=static_cast<std::uint32_t>(base);
                draw.textGradientRanges[i+2]+=static_cast<std::uint32_t>(packet.textGradientColors.size()/16);
            }
            packet.textGradientRanges.insert(packet.textGradientRanges.end(),draw.textGradientRanges.begin(),draw.textGradientRanges.end());
            packet.textGradientColors.insert(packet.textGradientColors.end(),draw.textGradientColors.begin(),draw.textGradientColors.end());
            if(packet.positionedState.size()+draw.positionedState.size()>std::numeric_limits<std::uint32_t>::max())
                throw std::runtime_error("Combined positioned state exceeds packet range");
            const auto positionedBase=static_cast<std::uint32_t>(packet.positionedState.size());
            packet.positionedState.insert(packet.positionedState.end(),draw.positionedState.begin(),draw.positionedState.end());
            for(std::size_t d=0;d<draw.fixedLighting.size();d+=368)if(draw.fixedLighting[d+3]) {
                const auto table=draw.fixedLighting[d+3]-1;
                for(unsigned int light=0;light<8;light++)if(const auto post=draw.positionedState[table+light])
                    packet.positionedState[positionedBase+table+light]=post+positionedBase;
                draw.fixedLighting[d+3]+=positionedBase;
            }
            for(std::size_t d=0;d<draw.texgen.size();d+=36)if(draw.texgen[d+3])draw.texgen[d+3]+=positionedBase;
            packet.matrices.insert(packet.matrices.end(), draw.matrices.begin(), draw.matrices.end());
            packet.uvMatrices.insert(packet.uvMatrices.end(),draw.uvMatrices.begin(),draw.uvMatrices.end());
            packet.texgen.insert(packet.texgen.end(),draw.texgen.begin(),draw.texgen.end());
            packet.localTransforms.insert(packet.localTransforms.end(),draw.localTransforms.begin(),draw.localTransforms.end());
            packet.debugParams.insert(packet.debugParams.end(),draw.debugParams.begin(),draw.debugParams.end());
            packet.fixedLighting.insert(packet.fixedLighting.end(),draw.fixedLighting.begin(),draw.fixedLighting.end());
            packet.matrixIds.insert(packet.matrixIds.end(),count,static_cast<std::uint32_t>(matrix));
            packet.triangles.insert(packet.triangles.end(), draw.triangles.begin(), draw.triangles.end());
            draw.flatColors.resize(draw.triangles.size()/4,~std::uint32_t(0));
            for(auto& vertex:draw.flatColors)if(vertex!=~std::uint32_t(0))vertex+=static_cast<std::uint32_t>(base);
            packet.flatColors.insert(packet.flatColors.end(),draw.flatColors.begin(),draw.flatColors.end());
            draw.polygonEdges.resize(draw.triangles.size()/4,7u);
            packet.polygonEdges.insert(packet.polygonEdges.end(),draw.polygonEdges.begin(),draw.polygonEdges.end());
            for(std::size_t i=0;i<draw.morphRanges.size();i+=3) {
                draw.morphRanges[i]+=static_cast<std::uint32_t>(base);
                draw.morphRanges[i+1]+=static_cast<std::uint32_t>(packet.morphOffsets.size()/4);
            }
            packet.morphRanges.insert(packet.morphRanges.end(),draw.morphRanges.begin(),draw.morphRanges.end());
            packet.morphOffsets.insert(packet.morphOffsets.end(),draw.morphOffsets.begin(),draw.morphOffsets.end());
            for(std::size_t i=0;i<draw.skinRanges.size();i+=4) {
                draw.skinRanges[i]+=static_cast<std::uint32_t>(base);
                draw.skinRanges[i+1]+=static_cast<std::uint32_t>(packet.skinWeights.size()/2);
                draw.skinRanges[i+3]+=static_cast<std::uint32_t>(packet.skinTransforms.size()/32);
            }
            for(std::size_t i=0;i<draw.skinWeights.size();i+=2)draw.skinWeights[i]+=static_cast<std::uint32_t>(packet.skinBones.size()/32);
            packet.skinRanges.insert(packet.skinRanges.end(),draw.skinRanges.begin(),draw.skinRanges.end());
            packet.skinWeights.insert(packet.skinWeights.end(),draw.skinWeights.begin(),draw.skinWeights.end());
            packet.skinBones.insert(packet.skinBones.end(),draw.skinBones.begin(),draw.skinBones.end());
            packet.skinTransforms.insert(packet.skinTransforms.end(),draw.skinTransforms.begin(),draw.skinTransforms.end());
            for(std::size_t i=0;i<draw.screenPrimitives.size();i+=12)
                for(unsigned int k=0;k<3;k++)draw.screenPrimitives[i+k]+=static_cast<std::uint32_t>(base);
            packet.screenPrimitives.insert(packet.screenPrimitives.end(),draw.screenPrimitives.begin(),draw.screenPrimitives.end());
        }
        struct TriangleCollector
        {
            GeometryPacket* draw = nullptr;
            std::uint32_t material = 0;
            std::size_t sourceCount = 0;
            void operator()(unsigned int a, unsigned int b, unsigned int c)
            {
                const auto count = sourceCount;
                if (a>=count || b>=count || c>=count) throw std::runtime_error("WebCuda primitive index outside vertex array");
                draw->triangles.insert(draw->triangles.end(), {a,b,c,material});
            }
        };
    }

    static void appendGeometryRange(GeometryPacket& packet, const osg::Geometry& geometry,
        const DrawContext& context, const osg::StateSet& resolvedState,
        std::uint32_t material, std::uint32_t screenMaterial, std::uint32_t pointMaterial,
        unsigned int primitiveFirst, unsigned int primitiveCount, unsigned int groundcoverInstance=~0u)
    {
        if(screenMaterial==~std::uint32_t(0))screenMaterial=material;
        if(pointMaterial==~std::uint32_t(0))pointMaterial=screenMaterial;
        GeometryPacket draw;
        matrices(draw,context,resolvedState);
        const SkinInputs* skin=nullptr;
        if(const auto* metadata=geometry.getUserDataContainer())skin=dynamic_cast<const SkinInputs*>(metadata->getUserObject("webcuda.skin"));
        if(skin&&!skin->source)throw std::runtime_error("Skin snapshot has no source geometry");
        const auto& arrays=skin?*skin->source:geometry;
        const osg::Array* positions=arrays.getVertexArray();
        const MorphInputs* morph=nullptr;
        if(const auto* metadata=geometry.getUserDataContainer())morph=dynamic_cast<const MorphInputs*>(metadata->getUserObject("webcuda.morph"));
        if(morph)positions=morph->base;
        if(!positions||positions->getBinding()==osg::Array::BIND_OFF
            ||(!dynamic_cast<const osg::Vec2Array*>(positions)&&!dynamic_cast<const osg::Vec3Array*>(positions)
                &&!dynamic_cast<const osg::Vec4Array*>(positions)&&!dynamic_cast<const osg::Vec2dArray*>(positions)
                &&!dynamic_cast<const osg::Vec3dArray*>(positions)&&!dynamic_cast<const osg::Vec4dArray*>(positions)))
            throw std::runtime_error("Unsupported WebCuda position array");
        if(skin&&!dynamic_cast<const osg::Vec3Array*>(positions))throw std::runtime_error("Skin snapshot requires Vec3 source positions");
        const auto* geometryState=&resolvedState;
        const auto* shade=dynamic_cast<const osg::ShadeModel*>(geometryState->getAttribute(osg::StateAttribute::SHADEMODEL));
        const bool flatColor=!geometryState->getAttribute(osg::StateAttribute::PROGRAM)&&shade&&shade->getMode()==osg::ShadeModel::FLAT;
        osg::Vec4 defaultColor(context.currentColor[0],context.currentColor[1],context.currentColor[2],context.currentColor[3]);
#if !defined(OSG_GL_FIXED_FUNCTION_AVAILABLE) || defined(OSG_GL1_AVAILABLE)
        if(!context.hasCurrentColor)
            if(const auto* material=dynamic_cast<const osg::Material*>(geometryState->getAttribute(osg::StateAttribute::MATERIAL))) {
                // Direct packet callers do not have submission's retained state.
                defaultColor=material->getDiffuse(osg::Material::FRONT);
#if defined(OSG_GL_FIXED_FUNCTION_AVAILABLE) && defined(OSG_GL1_AVAILABLE)
                switch(material->getColorMode()) {
                    case osg::Material::AMBIENT:defaultColor=material->getAmbient(osg::Material::FRONT);break;
                    case osg::Material::SPECULAR:defaultColor=material->getSpecular(osg::Material::FRONT);break;
                    case osg::Material::EMISSION:defaultColor=material->getEmission(osg::Material::FRONT);break;
                    default:break;
                }
#endif
            }
#endif
        if(groundcoverInstance!=~0u) {
            if(skin||morph)throw std::runtime_error("Groundcover cannot also use skin/morph inputs");
            if(!context.view)throw std::runtime_error("Groundcover has no camera view matrix");
            const auto* offsets=dynamic_cast<const osg::Vec4Array*>(arrays.getVertexAttribArray(6));
            const auto* rotations=dynamic_cast<const osg::Vec3Array*>(arrays.getVertexAttribArray(7));
            if(!offsets||!rotations||groundcoverInstance>=offsets->size()||groundcoverInstance>=rotations->size())
                throw std::runtime_error("Groundcover instance array is missing or short");
            for(unsigned int unit:{6u,7u}) {
                const auto* divisor=dynamic_cast<const osg::VertexAttribDivisor*>(geometryState->getAttribute(osg::StateAttribute::VERTEX_ATTRIB_DIVISOR,unit));
                if(!divisor||divisor->getDivisor()!=1)throw std::runtime_error("Groundcover requires instance divisor one");
            }
            const auto& offset=(*offsets)[groundcoverInstance];const auto& rotation=(*rotations)[groundcoverInstance];
            draw.groundcoverInstances.insert(draw.groundcoverInstances.end(),{offset.x(),offset.y(),offset.z(),offset.w(),rotation.x(),rotation.y(),rotation.z()});
            // Transport the raw view matrix. Its inverse is evaluated in .cu.
            for(unsigned int copy=0;copy<2;copy++)for(unsigned int k=0;k<16;k++)
                draw.groundcoverParams.push_back(static_cast<float>(context.view->ptr()[k]));
            float wind=0.f;osg::Vec3 player;
            const auto* windUniform=geometryState->getUniform("windSpeed");
            const auto* playerUniform=geometryState->getUniform("playerPos");
            if(!windUniform||!windUniform->get(wind)||!playerUniform||!playerUniform->get(player))
                throw std::runtime_error("Groundcover shared uniforms are missing");
            std::map<std::string,std::string> defines;
            const auto* program=dynamic_cast<const osg::Program*>(geometryState->getAttribute(osg::StateAttribute::PROGRAM));
            for(unsigned int i=0;program&&i<program->getNumShaders();i++) {
                std::string metadata;if(!program->getShader(i)->getUserValue("webcuda.defines",metadata))continue;
                std::istringstream stream(metadata);std::string line;
                while(std::getline(stream,line)){const auto split=line.find('=');if(split!=std::string::npos)defines[line.substr(0,split)]=line.substr(split+1);}
            }
            const auto number=[&](const char* name) {
                const auto found=defines.find(name);if(found==defines.end())throw std::runtime_error(std::string("Missing groundcover define: ")+name);
                std::size_t end=0;const float value=std::stof(found->second,&end);
                if(end!=found->second.size()||!std::isfinite(value))throw std::runtime_error("Invalid groundcover numeric define");return value;
            };
            draw.groundcoverParams.insert(draw.groundcoverParams.end(),{wind,context.simulationTime,player.x(),player.y(),player.z(),
                number("groundcoverStompMode"),number("groundcoverStompIntensity"),number("groundcoverFadeEnd")});
            for(unsigned int i=0;i<positions->getNumElements();i++)draw.groundcoverRanges.insert(draw.groundcoverRanges.end(),{i,0u,0u});
        }
        const bool terrain=shaderNamed(*geometryState,"terrain.vert");
        const auto* fog=dynamic_cast<const osg::Fog*>(geometryState->getAttribute(osg::StateAttribute::FOG));
        const bool explicitFog=!geometryState->getAttribute(osg::StateAttribute::PROGRAM)
            &&(geometryState->getMode(GL_FOG)&osg::StateAttribute::ON)!=0
            &&fog&&fog->getFogCoordinateSource()==osg::Fog::FOG_COORDINATE;
        if(context.textGradient) {
            draw.textGradientRanges.insert(draw.textGradientRanges.end(),{0u,positions->getNumElements(),0u});
            draw.textGradientColors.insert(draw.textGradientColors.end(),context.textGradient,context.textGradient+16);
        }
        // The source vertex count is already known. Avoid repeatedly growing
        // and copying these three temporary arrays while encoding one draw.
        const auto sourceVertexCount=static_cast<std::size_t>(positions->getNumElements());
        if(!packet.compactVertices) {
            draw.vertices.reserve(sourceVertexCount*10);
            draw.attributes.reserve(sourceVertexCount*34);
            draw.secondaryColors.reserve(sourceVertexCount*3);
        }
        using Role=VertexArrayReader::Role;
        const auto inputVertexCount=positions->getNumElements();
        const VertexArrayReader positionValues(positions,inputVertexCount,primitiveFirst,Role::Vector);
        const VertexArrayReader colorValues(arrays.getColorArray(),inputVertexCount,primitiveFirst,Role::Color,defaultColor);
        const VertexArrayReader secondaryValues(arrays.getSecondaryColorArray(),inputVertexCount,primitiveFirst,Role::SecondaryColor,
            osg::Vec4(context.currentSecondaryColor[0],context.currentSecondaryColor[1],context.currentSecondaryColor[2],1));
        const VertexArrayReader normalValues(arrays.getNormalArray(),inputVertexCount,primitiveFirst,Role::Normal,
            osg::Vec4(context.currentNormal[0],context.currentNormal[1],context.currentNormal[2],1));
        const VertexArrayReader tangentValues(arrays.getTexCoordArray(7),inputVertexCount,primitiveFirst,Role::Tangent,osg::Vec4(0,0,0,0));
        const VertexArrayReader fogValues(explicitFog?arrays.getFogCoordArray():nullptr,inputVertexCount,primitiveFirst,Role::Fog,
            osg::Vec4(explicitFog?context.currentFogCoordinate:0.f,0,0,1));
        const std::array<VertexArrayReader,4> coordinates={
            VertexArrayReader(arrays.getTexCoordArray(0),inputVertexCount,primitiveFirst,Role::Vector),
            VertexArrayReader(arrays.getTexCoordArray(1),inputVertexCount,primitiveFirst,Role::Vector),
            VertexArrayReader(arrays.getTexCoordArray(2),inputVertexCount,primitiveFirst,Role::Vector),
            VertexArrayReader(arrays.getTexCoordArray(3),inputVertexCount,primitiveFirst,Role::Vector)};
        if(packet.compactVertices) {
            draw.compactVertices=true;draw.capturedVertexCount=inputVertexCount;
            draw.vertexLayouts.resize(32);auto* layout=draw.vertexLayouts.data();
            layout[2]=inputVertexCount;layout[3]=1;layout[4]=explicitFog?2u:(terrain?1u:0u);
            std::size_t words=3+positionValues.inputWords(inputVertexCount,4)+colorValues.inputWords(inputVertexCount,4)
                +secondaryValues.inputWords(inputVertexCount,3)+normalValues.inputWords(inputVertexCount,3)
                +tangentValues.inputWords(inputVertexCount,4)+fogValues.inputWords(inputVertexCount,1);
            for(const auto& coordinate:coordinates)words+=coordinate.inputWords(inputVertexCount,4);
            if(words>std::numeric_limits<std::uint32_t>::max())throw std::runtime_error("Vertex input stream exceeds index range");
            draw.vertexInputs.reserve(words);
            draw.vertexInputs.insert(draw.vertexInputs.end(),context.currentSecondaryColor,context.currentSecondaryColor+3);
            positionValues.capture(draw,layout+8,inputVertexCount,4);
            colorValues.capture(draw,layout+10,inputVertexCount,4);
            secondaryValues.capture(draw,layout+12,inputVertexCount,3);
            normalValues.capture(draw,layout+14,inputVertexCount,3);
            tangentValues.capture(draw,layout+16,inputVertexCount,4);
            fogValues.capture(draw,layout+18,inputVertexCount,1);
            for(unsigned int unit=0;unit<4;unit++)coordinates[unit].capture(draw,layout+20+unit*2,inputVertexCount,4);
        }
        for (unsigned int i=0; i<inputVertexCount && (!draw.compactVertices || (morph&&!morph->targets.empty())); ++i)
        {
            if(morph&&!morph->targets.empty()) {
                if(draw.morphOffsets.size()/4+morph->targets.size()>std::numeric_limits<std::uint32_t>::max())throw std::runtime_error("Morph packet exceeds index range");
                draw.morphRanges.insert(draw.morphRanges.end(),{i,static_cast<std::uint32_t>(draw.morphOffsets.size()/4),static_cast<std::uint32_t>(morph->targets.size())});
                for(const auto& target:morph->targets) {
                    if(!target.offsets||target.offsets->size()!=positions->getNumElements())throw std::runtime_error("Morph target size differs from base");
                    const auto& offset=(*target.offsets)[i];
                    for(float value:{offset.x(),offset.y(),offset.z(),target.weight})if(!std::isfinite(value))throw std::runtime_error("Non-finite morph input");
                    draw.morphOffsets.insert(draw.morphOffsets.end(),{offset.x(),offset.y(),offset.z(),target.weight});
                }
            }
            if(draw.compactVertices)continue;
            const auto p=positionValues[i];
            const auto color=colorValues[i];
            const auto secondary=secondaryValues[i];
            for(unsigned int k=0;k<3;k++)draw.secondaryColors.push_back(secondary[k]);
            const auto coordinate0=coordinates[0][i];
            const osg::Vec2 uv(coordinate0.x(),coordinate0.y());
            draw.vertices.insert(draw.vertices.end(),{p.x(),p.y(),p.z(),p.w(),color.r(),color.g(),color.b(),color.a(),uv.x(),uv.y()});
            std::array<float,34> attributes{};
            for(unsigned int unit=0;unit<4;unit++)attributes[27+unit*2]=1.f;
            const auto normal=normalValues[i];
            const auto tangent=tangentValues[i];
            for(unsigned int k=0;k<3;k++)attributes[3+k]=normal[k];
            for(unsigned int k=0;k<4;k++)attributes[6+k]=tangent[k];
            attributes[0]=terrain?1.f:0.f; // Input-only terrain basis flag; GPU overwrites with view position.
            if(explicitFog) {
                attributes[0]=-1.f;attributes[2]=fogValues[i].x();
            }
            for(unsigned int unit=1;unit<=3;++unit) {
                const auto coordinate=coordinates[unit][i];
                attributes[10+(unit-1)*2]=coordinate.x();attributes[11+(unit-1)*2]=coordinate.y();
                attributes[26+unit*2]=coordinate.z();attributes[27+unit*2]=coordinate.w();
            }
            attributes[16]=uv.x();attributes[17]=uv.y();
            attributes[26]=coordinate0.z();attributes[27]=coordinate0.w();
            draw.attributes.insert(draw.attributes.end(),attributes.begin(),attributes.end());
        }
        osg::TriangleIndexFunctor<TriangleCollector> collector;
        if(skin) {
            const auto matrix=[&](std::vector<float>& destination,const osg::Matrixf& value) {
                for(unsigned int k=0;k<16;++k){if(!std::isfinite(value.ptr()[k]))throw std::runtime_error("Non-finite skin matrix");destination.push_back(value.ptr()[k]);}
            };
            for(const auto& bone:skin->bones){matrix(draw.skinBones,bone.bind);matrix(draw.skinBones,bone.pose);}
            matrix(draw.skinTransforms,skin->skinToSkeleton);matrix(draw.skinTransforms,skin->transform);
            for(const auto& group:skin->groups) {
                const auto first=static_cast<std::uint32_t>(draw.skinWeights.size()/2);
                for(const auto& [bone,weight]:group.weights) {
                    if(bone>=skin->bones.size()||!std::isfinite(weight))throw std::runtime_error("Invalid skin influence");
                    if(!skin->bones[bone].valid)continue;
                    std::uint32_t bits;std::memcpy(&bits,&weight,4);draw.skinWeights.insert(draw.skinWeights.end(),{static_cast<std::uint32_t>(bone),bits});
                }
                const auto count=static_cast<std::uint32_t>(draw.skinWeights.size()/2)-first;
                for(auto vertex:group.vertices) {
                    if(vertex>=positions->getNumElements())throw std::runtime_error("Skin vertex exceeds source geometry");
                    draw.skinRanges.insert(draw.skinRanges.end(),{vertex,first,count,0});
                }
            }
        }
        collector.draw=&draw; collector.material=material;collector.sourceCount=positions->getNumElements();
        const auto* state=&resolvedState;
        const auto* point=dynamic_cast<const osg::Point*>(state->getAttribute(osg::StateAttribute::POINT));
        const auto* line=dynamic_cast<const osg::LineWidth*>(state->getAttribute(osg::StateAttribute::LINEWIDTH));
        unsigned int spriteFlags=0;
        // The built-in world programs use named UV varyings, not gl_TexCoord;
        // point-sprite replacement must not overwrite those shader outputs.
        if(!state->getAttribute(osg::StateAttribute::PROGRAM)
            &&(state->getMode(GL_POINT_SPRITE_ARB)&osg::StateAttribute::ON)!=0) {
            // Coordinate replacement is per texture unit, while origin is
            // global GL state. OSG applies texture attributes in unit order.
            for(unsigned int unit=0;unit<state->getTextureAttributeList().size();unit++) {
                const auto* sprite=dynamic_cast<const osg::PointSprite*>(state->getTextureAttribute(unit,osg::StateAttribute::POINTSPRITE));
                if(!sprite)continue;
                if(unit>3)throw std::runtime_error("Point sprite texture unit exceeds vertex UV packet");
                spriteFlags|=1u<<unit;
                if(sprite->getCoordOriginMode()==osg::PointSprite::LOWER_LEFT)spriteFlags|=16u;
                else if(sprite->getCoordOriginMode()==osg::PointSprite::UPPER_LEFT)spriteFlags&=~16u;
                else throw std::runtime_error("Invalid point sprite coordinate origin");
            }
        }
        auto bits=[](float value){if(!std::isfinite(value))throw std::runtime_error("Non-finite primitive size state");std::uint32_t result;std::memcpy(&result,&value,4);return result;};
        auto screen=[&](unsigned int a,unsigned int b,bool isPoint) {
            if(a>=positions->getNumElements()||b>=positions->getNumElements())throw std::runtime_error("Screen primitive index exceeds source geometry");
            const auto base=draw.vertexCount();
            if(base>std::numeric_limits<std::uint32_t>::max()-4u)throw std::runtime_error("Screen primitive exceeds vertex range");
            const float size=isPoint?(point?point->getSize():1.f):(line?line->getWidth():1.f);
            const osg::Vec3 attenuation=point?point->getDistanceAttenuation():osg::Vec3(1,0,0);
            if(size<=0)throw std::runtime_error("Non-positive primitive size");
            draw.screenPrimitives.insert(draw.screenPrimitives.end(),{a,b,static_cast<std::uint32_t>(base),isPoint?1u:0u,
                bits(size),bits(point?point->getMinSize():0.f),bits(point?point->getMaxSize():64.f),bits(point?point->getFadeThresholdSize():1.f),
                bits(attenuation.x()),bits(attenuation.y()),bits(attenuation.z()),(isPoint?spriteFlags:0u)
                    |((state->getMode(0x864F)&osg::StateAttribute::ON)!=0?32u:0u)
                    |(usesZeroToOneDepth(*state)?512u:0u)
                    |(((state->getMode(0x809D)&(osg::StateAttribute::ON|osg::StateAttribute::INHERIT))!=0)?64u:0u)
                    |(isPoint&&(state->getMode(GL_POINT_SMOOTH)&osg::StateAttribute::ON)!=0?128u:0u)
                    |(isPoint&&(state->getMode(GL_POINT_SPRITE_ARB)&osg::StateAttribute::ON)!=0?256u:0u)});
            if(draw.compactVertices)draw.capturedVertexCount+=4;
            else {draw.vertices.resize(draw.vertices.size()+40,0.f);draw.attributes.resize(draw.attributes.size()+136,0.f);}
            const auto v=static_cast<std::uint32_t>(base);
            const auto primitiveMaterial=isPoint?pointMaterial:screenMaterial;
            draw.triangles.insert(draw.triangles.end(),{v,v+1,v+2,primitiveMaterial,v,v+2,v+3,primitiveMaterial});
            draw.flatColors.resize(draw.triangles.size()/4,~std::uint32_t(0));
            if(flatColor&&!isPoint) {
                draw.flatColors[draw.flatColors.size()-2]=b;draw.flatColors.back()=b;
            }
        };
        for (unsigned int i=primitiveFirst; i<primitiveFirst+primitiveCount; ++i)
        {
            const auto* primitive=geometry.getPrimitiveSet(i);
            if (primitive->getNumInstances()>1&&groundcoverInstance==~0u) throw std::runtime_error("WebCuda instancing requires explicit instance data");
            const auto mode=primitive->getMode();
            const bool indexed=dynamic_cast<const osg::DrawElements*>(primitive)!=nullptr;
            const bool fixedRestart=(state->getMode(0x8D69)&osg::StateAttribute::ON)!=0;
            const bool restart=indexed&&(fixedRestart||(state->getMode(0x8F9D)&osg::StateAttribute::ON)!=0);
            unsigned int restartIndex=0;
            if(restart) {
                if(fixedRestart) {
                    if(dynamic_cast<const osg::DrawElementsUByte*>(primitive))restartIndex=0xffu;
                    else if(dynamic_cast<const osg::DrawElementsUShort*>(primitive))restartIndex=0xffffu;
                    else if(dynamic_cast<const osg::DrawElementsUInt*>(primitive))restartIndex=0xffffffffu;
                    else throw std::runtime_error("Unsupported restart index storage");
                } else if(const auto* attribute=dynamic_cast<const osg::PrimitiveRestartIndex*>(state->getAttribute(osg::StateAttribute::PRIMITIVERESTARTINDEX)))
                    restartIndex=attribute->getRestartIndex();
            }
            auto ranges=[&](const auto& consume) {
                auto range=[&](unsigned int first,unsigned int count) {
                    if(first>primitive->getNumIndices()||count>primitive->getNumIndices()-first)
                        throw std::runtime_error("Invalid primitive subrange");
                    if(!restart){consume(first,count);return;}
                    unsigned int begin=first;
                    for(unsigned int j=first;j<first+count;j++)if(primitive->index(j)==restartIndex) {
                        consume(begin,j-begin);begin=j+1u;
                    }
                    consume(begin,first+count-begin);
                };
                if(const auto* lengths=dynamic_cast<const osg::DrawArrayLengths*>(primitive)) {
                    unsigned int first=0;for(auto count:*lengths){if(count<0)throw std::runtime_error("Negative primitive count");range(first,count);first+=count;}
                }
#ifdef OSG_HAS_MULTIDRAWARRAYS
                else if(const auto* multi=dynamic_cast<const osg::MultiDrawArrays*>(primitive)) {
                    if(multi->getFirsts().size()!=multi->getCounts().size())throw std::runtime_error("Invalid multi-draw ranges");
                    unsigned int first=0;for(auto count:multi->getCounts()){if(count<0)throw std::runtime_error("Negative primitive count");range(first,count);first+=count;}
                }
#endif
                else range(0,primitive->getNumIndices());
            };
            if(mode==GL_POINTS||mode==GL_LINES||mode==GL_LINE_STRIP||mode==GL_LINE_LOOP) {
                auto range=[&](unsigned int first,unsigned int count) {
                    if(first>primitive->getNumIndices()||count>primitive->getNumIndices()-first)throw std::runtime_error("Invalid primitive subrange");
                    if(mode==GL_POINTS)for(unsigned int j=0;j<count;j++)screen(primitive->index(first+j),primitive->index(first+j),true);
                    else if(mode==GL_LINES)for(unsigned int j=1;j<count;j+=2)screen(primitive->index(first+j-1),primitive->index(first+j),false);
                    else {
                        for(unsigned int j=1;j<count;j++)screen(primitive->index(first+j-1),primitive->index(first+j),false);
                        if(mode==GL_LINE_LOOP&&count>1)screen(primitive->index(first+count-1),primitive->index(first),false);
                    }
                };
                ranges(range);
                continue;
            }
            switch (primitive->getMode())
            {
                case GL_TRIANGLES: case GL_TRIANGLE_STRIP: case GL_TRIANGLE_FAN:
                case GL_QUADS: case GL_QUAD_STRIP: case GL_POLYGON: break;
                default: throw std::runtime_error("Unsupported WebCuda primitive topology");
            }
            if (primitive->getNumInstances()>1&&groundcoverInstance==~0u) throw std::runtime_error("WebCuda instancing requires explicit instance data");
            if(!flatColor&&!restart&&mode!=GL_QUADS&&mode!=GL_QUAD_STRIP&&mode!=GL_POLYGON)primitive->accept(collector);
            else {
                auto range=[&](unsigned int first,unsigned int count) {
                    if(first>primitive->getNumIndices()||count>primitive->getNumIndices()-first)throw std::runtime_error("Invalid flat primitive subrange");
                    auto triangle=[&](unsigned int a,unsigned int b,unsigned int c,unsigned int provoking,unsigned int edges=7u) {
                        collector(primitive->index(first+a),primitive->index(first+b),primitive->index(first+c));
                        draw.polygonEdges.resize(draw.triangles.size()/4,7u);draw.polygonEdges.back()=edges;
                        if(flatColor) {
                            const auto vertex=primitive->index(first+provoking);
                            if(vertex>=positions->getNumElements())throw std::runtime_error("Invalid provoking vertex");
                            draw.flatColors.resize(draw.triangles.size()/4,~std::uint32_t(0));draw.flatColors.back()=vertex;
                        }
                    };
                    if(mode==GL_TRIANGLES)for(unsigned int j=2;j<count;j+=3)triangle(j-2,j-1,j,j);
                    else if(mode==GL_TRIANGLE_STRIP)for(unsigned int j=2;j<count;j++) {
                        if(j%2)triangle(j-2,j,j-1,j);else triangle(j-2,j-1,j,j);
                    }
                    else if(mode==GL_TRIANGLE_FAN||mode==GL_POLYGON)
                        for(unsigned int j=2;j<count;j++)triangle(0,j-1,j,mode==GL_POLYGON?0:j,
                            mode==GL_POLYGON?((j==2?1u:0u)|2u|(j+1==count?4u:0u)):7u);
                    else if(mode==GL_QUADS)for(unsigned int j=3;j<count;j+=4) {
                        triangle(j-3,j-2,j-1,j,3u);triangle(j-3,j-1,j,j,6u);
                    }
                    else if(mode==GL_QUAD_STRIP)for(unsigned int j=3;j<count;j+=2) {
                        triangle(j-3,j-2,j-1,j,5u);triangle(j-2,j,j-1,j,3u);
                    }
                };
                ranges(range);
            }
        }
        commit(packet,draw);
    }

    void appendGeometry(GeometryPacket& packet, const osg::Geometry& geometry,
        const DrawContext& context, std::uint32_t material, std::uint32_t screenMaterial, std::uint32_t pointMaterial)
    {
        CaptureScope captureScope(CapturePhase::GeometryEncode);
        const SkinInputs* skin=nullptr;
        if(const auto* metadata=geometry.getUserDataContainer())
            skin=dynamic_cast<const SkinInputs*>(metadata->getUserObject("webcuda.skin"));
        if(skin&&!skin->source)throw std::runtime_error("Skin snapshot has no source geometry");
        const auto& arrays=skin?*skin->source:geometry;
        const auto state=resolveState(context);
        if(shaderNamed(*state,"groundcover.vert")) {
            for(unsigned int p=0;p<geometry.getNumPrimitiveSets();p++) {
                const int count=geometry.getPrimitiveSet(p)->getNumInstances();
                if(count<0)throw std::runtime_error("Negative groundcover instance count");
                for(unsigned int instance=0;instance<static_cast<unsigned int>(std::max(1,count));instance++)
                    appendGeometryRange(packet,geometry,context,*state,material,screenMaterial,pointMaterial,p,1,instance);
            }
            return;
        }
        bool perPrimitiveSet=false;
        for(const auto* array:{arrays.getColorArray(),arrays.getSecondaryColorArray(),arrays.getNormalArray(),arrays.getFogCoordArray()})
            perPrimitiveSet|=array&&array->getBinding()==osg::Array::BIND_PER_PRIMITIVE_SET;
        if(perPrimitiveSet) {
            // Each set can assign different attributes to a shared source vertex.
            // Duplicate source inputs, not transformed results; deformation,
            // lighting and rasterization still run in the .cu pipeline.
            for(unsigned int i=0;i<geometry.getNumPrimitiveSets();++i)
                appendGeometryRange(packet,geometry,context,*state,material,screenMaterial,pointMaterial,i,1);
        } else appendGeometryRange(packet,geometry,context,*state,material,screenMaterial,pointMaterial,0,geometry.getNumPrimitiveSets());
    }

    void appendParticles(GeometryPacket& packet, const osgParticle::ParticleSystem& system,
        const DrawContext& context, std::uint32_t material, std::uint32_t screenMaterial, std::uint32_t pointMaterial)
    {
        CaptureScope captureScope(CapturePhase::GeometryEncode);
        const auto state=resolveState(context);
        if(screenMaterial==~std::uint32_t(0))screenMaterial=material;
        if(pointMaterial==~std::uint32_t(0))pointMaterial=screenMaterial;
        if(const auto* ribbon=dynamic_cast<const osgParticle::ConnectedParticleSystem*>(&system)) {
            GeometryPacket draw;matrices(draw,context,*state);
            std::vector<float> particles;
            std::unordered_set<const osgParticle::Particle*> visited;
            const auto* particle=ribbon->getStartParticle();
            while(particle) {
                if(!visited.insert(particle).second)throw std::runtime_error("Cyclic ribbon particle links");
                const auto& pos=particle->getPosition();const auto& color=particle->getCurrentColor();
                particles.insert(particles.end(),{pos.x(),pos.y(),pos.z(),particle->getCurrentSize(),
                    color.r(),color.g(),color.b(),color.a(),particle->getCurrentAlpha(),particle->getSTexCoord()});
                const int next=particle->getNextParticle();
                if(next==osgParticle::Particle::INVALID_INDEX)break;
                if(next<0||next>=system.numParticles())throw std::runtime_error("Ribbon particle link is out of range");
                particle=system.getParticle(next);
            }
            const std::size_t count=particles.size()/10;
            if(count<2)return;
            for(float value:particles)if(!std::isfinite(value))throw std::runtime_error("Non-finite ribbon particle");
            const std::size_t vertex=packet.vertexCount(),triangle=packet.triangles.size()/4,matrix=packet.matrices.size()/32;
            if(count>std::numeric_limits<std::uint32_t>::max()/4||vertex+4*(count-1)>std::numeric_limits<std::uint32_t>::max()
                ||triangle+2*(count-1)>std::numeric_limits<std::uint32_t>::max()
                ||packet.ribbonParticles.size()/10+count>std::numeric_limits<std::uint32_t>::max())
                throw std::runtime_error("Ribbon packet exceeds index range");
            // Reserve worst-case segments. GPU selection collapses skipped
            // segments to degenerate triangles without moving other draws.
            draw.vertices.resize((count-1)*4*10,0.f);draw.attributes.resize((count-1)*4*34,0.f);
            for(std::size_t segment=0;segment<count-1;segment++) {
                const auto v=static_cast<std::uint32_t>(segment*4);
                draw.triangles.insert(draw.triangles.end(),{v,v+1,v+2,material,v,v+2,v+3,material});
                // ConnectedParticleSystem emits a quad strip. Preserve each
                // segment's perimeter when CUDA selects polygon LINE/POINT;
                // the triangulation diagonal is not an original polygon edge.
                draw.polygonEdges.insert(draw.polygonEdges.end(),{3u,6u});
            }
            const auto* line=dynamic_cast<const osg::LineWidth*>(state->getAttribute(osg::StateAttribute::LINEWIDTH));
            const auto* shade=dynamic_cast<const osg::ShadeModel*>(state->getAttribute(osg::StateAttribute::SHADEMODEL));
            const bool flat=!state->getAttribute(osg::StateAttribute::PROGRAM)&&shade&&shade->getMode()==osg::ShadeModel::FLAT;
            const float width=line?line->getWidth():1.f;
            if(!std::isfinite(width)||width<=0.f)throw std::runtime_error("Invalid ribbon line width");
            const auto bits=[](float value){std::uint32_t result;std::memcpy(&result,&value,4);return result;};
            commit(packet,draw);
            packet.ribbonRanges.insert(packet.ribbonRanges.end(),{static_cast<std::uint32_t>(packet.ribbonParticles.size()/10),
                static_cast<std::uint32_t>(count),static_cast<std::uint32_t>(vertex),static_cast<std::uint32_t>(triangle),
                static_cast<std::uint32_t>(matrix),const_cast<osgParticle::ConnectedParticleSystem*>(ribbon)->getMaxNumberOfParticlesToSkip(),
                material,screenMaterial,bits(width),bits(context.particleNormal[0]),bits(context.particleNormal[1]),bits(context.particleNormal[2]),(flat?1u:0u)|((state->getMode(0x864F)&osg::StateAttribute::ON)!=0?2u:0u)|(usesZeroToOneDepth(*state)?4u:0u)});
            packet.ribbonParticles.insert(packet.ribbonParticles.end(),particles.begin(),particles.end());
            return;
        }

        // The caller holds the particle system's read lock. Pack simulation
        // state only; billboard axes, rotation, size and opacity run in .cu.
        const bool shaderParticles=system.getUseShaders();
        if(shaderParticles) {
            const auto* program=dynamic_cast<const osg::Program*>(state->getAttribute(osg::StateAttribute::PROGRAM));
            if(!program||!isBuiltinParticleProgram(*program)||!system.getUseVertexArray())
                throw std::runtime_error("Custom particle shaders require their own WebCuda implementation");
        }
        GeometryPacket draw;
        matrices(draw,context,*state);
        const int detail=system.getLevelOfDetail();
        if (detail<=0) throw std::runtime_error("Invalid particle level of detail");
        const auto* point=dynamic_cast<const osg::Point*>(state->getAttribute(osg::StateAttribute::POINT));
        const auto* line=dynamic_cast<const osg::LineWidth*>(state->getAttribute(osg::StateAttribute::LINEWIDTH));
        const auto& axisX=system.getAlignVectorX();
        const auto& axisY=system.getAlignVectorY();
        const float mode=system.getParticleAlignment()==osgParticle::ParticleSystem::BILLBOARD
            ? (system.getParticleScaleReferenceFrame()==osgParticle::ParticleSystem::LOCAL_COORDINATES?2.f:3.f):4.f;
        for(int i=0;i<system.numParticles();i+=detail)
        {
            const auto& particle=*system.getParticle(i);
            if (!particle.isAlive()) continue;
            if (!shaderParticles && system.getSortMode()!=osgParticle::ParticleSystem::NO_SORT && system.getVisibilityDistance()>0
                && (particle.getDepth()<0 || particle.getDepth()>system.getVisibilityDistance())) continue;
            const bool isPoint=shaderParticles||particle.getShape()==osgParticle::Particle::POINT;
            const bool isLine=!shaderParticles&&particle.getShape()==osgParticle::Particle::LINE;
            const auto& p=particle.getPosition(); const auto& color=particle.getCurrentColor();
            const auto& angle=particle.getAngle();
            const auto base=static_cast<std::uint32_t>(draw.vertices.size()/10);
            for(unsigned int corner=0;corner<4;++corner)
            {
                const float u=(corner==1||corner==2)?1.f:0.f, v=corner>=2?1.f:0.f;
                draw.vertices.insert(draw.vertices.end(),{p.x(),p.y(),p.z(),1.f,
                    color.r(),color.g(),color.b(),color.a(),particle.getSTexCoord()+u*particle.getSTexTile(),
                    particle.getTTexCoord()+v*particle.getTTexTile()});
                std::array<float,34> a{};
                for(unsigned int unit=0;unit<4;unit++)a[27+unit*2]=1.f;
                a[0]=mode;a[1]=u*2.f-1.f;a[2]=v*2.f-1.f;
                for(unsigned int k=0;k<3;++k){a[3+k]=axisX[k];a[6+k]=axisY[k];a[10+k]=angle[k];}
                a[9]=particle.getCurrentAlpha();a[13]=particle.getCurrentSize();a[14]=static_cast<float>(detail);
                if(isPoint||isLine) {
                    a[0]=isPoint?5.f:6.f;
                    a[15]=isPoint?(point?point->getSize():1.f):(line?line->getWidth():1.f);
                    for(unsigned int k=0;k<3;k++)a[10+k]=isLine?particle.getVelocity()[k]
                        :(point?point->getDistanceAttenuation()[k]:(k==0?1.f:0.f));
                    a[18]=point?point->getMinSize():1.f;a[19]=point?point->getMaxSize():64.f;
                    a[20]=point?point->getFadeThresholdSize():1.f;
                    if(!std::isfinite(a[15])||a[15]<=0.f||!std::isfinite(a[18])||!std::isfinite(a[19])
                        ||a[18]<0.f||a[19]<a[18]||!std::isfinite(a[20])||a[20]<0.f)
                        throw std::runtime_error("Invalid point/line particle raster size");
                    draw.vertices[draw.vertices.size()-2]=isPoint?0.5f:u;
                    draw.vertices.back()=isPoint?0.5f:u;
                }
                if(shaderParticles) {
                    a[0]=8.f;a[24]=system.getVisibilityDistance();
                    if(const auto* visibility=state->getUniform("visibilityDistance"))
                        if(!visibility->get(a[24]))throw std::runtime_error("Invalid particle visibility distance");
                    draw.vertices[draw.vertices.size()-2]=u;draw.vertices.back()=1.f-v;
                }
                a[25]=((state->getMode(0x864F)&osg::StateAttribute::ON)!=0?1.f:0.f)
                    +(usesZeroToOneDepth(*state)?16.f:0.f)
                    +((state->getMode(0x809D)&(osg::StateAttribute::ON|osg::StateAttribute::INHERIT))!=0?2.f:0.f)
                    +((state->getMode(GL_POINT_SMOOTH)&osg::StateAttribute::ON)!=0?4.f:0.f)
                    +((state->getMode(GL_POINT_SPRITE_ARB)&osg::StateAttribute::ON)!=0?8.f:0.f);
                a[16]=draw.vertices[draw.vertices.size()-2];a[17]=draw.vertices.back();
                for(unsigned int k=0;k<3;k++)a[21+k]=context.particleNormal[k];
                draw.attributes.insert(draw.attributes.end(),a.begin(),a.end());
            }
            const auto particleMaterial=isPoint?pointMaterial:(isLine?screenMaterial:material);
            draw.triangles.insert(draw.triangles.end(),{base,base+1,base+2,particleMaterial,base,base+2,base+3,particleMaterial});
        }
        commit(packet,draw);
    }

    void appendGui(GeometryPacket& packet, const osg::Array& array, std::size_t count,
        const DrawContext& context, std::uint32_t material)
    {
        CaptureScope captureScope(CapturePhase::GeometryEncode);
        if (count%3 || count>array.getTotalDataSize()/24 || (count && !array.getDataPointer()))
            throw std::runtime_error("Invalid MyGUI WebCuda batch");
        GeometryPacket draw;
        const auto state=resolveState(context);
        matrices(draw,context,*state,true);
        const auto* bytes=static_cast<const unsigned char*>(array.getDataPointer());
        for (std::size_t i=0;i<count;++i)
        {
            float position[3],uv[2];
            std::memcpy(position,bytes+i*24,12);
            std::memcpy(uv,bytes+i*24+16,8);
            const auto* color=bytes+i*24+12;
            draw.vertices.insert(draw.vertices.end(),{position[0],position[1],position[2],1,
                color[0]/255.f,color[1]/255.f,color[2]/255.f,color[3]/255.f,uv[0],uv[1]});
            const auto attributeBase=draw.attributes.size();
            draw.attributes.insert(draw.attributes.end(),34,0.f);
            draw.attributes[attributeBase+16]=uv[0];draw.attributes[attributeBase+17]=uv[1];
            for(unsigned int unit=0;unit<4;unit++)draw.attributes[attributeBase+27+unit*2]=1.f;
            if (i%3==0) draw.triangles.insert(draw.triangles.end(),{
                static_cast<std::uint32_t>(i),static_cast<std::uint32_t>(i+1),static_cast<std::uint32_t>(i+2),material});
        }
        commit(packet,draw);
    }

    GeometrySink::GeometrySink(Resolve resolve, Consume consume)
        : mResolve(std::move(resolve)), mConsume(std::move(consume))
    {
        if (!mResolve || !mConsume) throw std::invalid_argument("WebCuda geometry sink requires material resolution and a consumer");
    }
    void GeometrySink::beginPass(const osgUtil::RenderStage&)
    {
        if (mInPass) throw std::logic_error("Nested WebCuda pass");
        mPacket = {};
        mInPass = true;
    }
    void GeometrySink::endPass(const osgUtil::RenderStage& stage)
    {
        if (!mInPass) throw std::logic_error("WebCuda pass was not started");
        mInPass = false;
        mConsume(stage,mPacket);
    }
    void captureGeometry(GeometryPacket& packet,const osg::Geometry& geometry,const DrawContext& sourceContext,
        const MaterialResolver& resolve,bool gui)
    {
        auto context=sourceContext;ResolvedStateScope resolved(context);
        bool screen=false;
        for(unsigned int i=0;i<geometry.getNumPrimitiveSets();i++) {
            const auto mode=geometry.getPrimitiveSet(i)->getMode();
            screen=screen||mode==GL_POINTS||mode==GL_LINES||mode==GL_LINE_STRIP||mode==GL_LINE_LOOP;
        }
        const auto material=resolve(context,nullptr,gui);
        if(!screen){appendGeometry(packet,geometry,context,material);return;}
        osg::ref_ptr<osg::StateSet> screenState=new osg::StateSet;
        screenState->setMode(GL_CULL_FACE,osg::StateAttribute::OFF|osg::StateAttribute::OVERRIDE|osg::StateAttribute::PROTECTED);
        screenState->setMode(GL_POLYGON_OFFSET_FILL,osg::StateAttribute::OFF|osg::StateAttribute::OVERRIDE|osg::StateAttribute::PROTECTED);
        screenState->setAttribute(new osg::PolygonMode(osg::PolygonMode::FRONT_AND_BACK,osg::PolygonMode::FILL),osg::StateAttribute::OVERRIDE|osg::StateAttribute::PROTECTED);
        auto screenContext=context;screenContext.screenPrimitiveDraw=true;screenContext.states.push_back(screenState);
        ResolvedStateScope screenResolved(screenContext);
        const auto screenMaterial=resolve(screenContext,nullptr,gui);
        auto pointContext=screenContext;pointContext.pointDraw=true;
        appendGeometry(packet,geometry,context,material,screenMaterial,resolve(pointContext,nullptr,gui));
    }
    void captureParticles(GeometryPacket& packet,const osgParticle::ParticleSystem& system,const DrawContext& sourceContext,
        const MaterialResolver& resolve)
    {
        auto context=sourceContext;ResolvedStateScope resolved(context);
        // Expanded point/line triangles represent non-polygon primitives.
        // Polygon culling and polygon-fill offset must not apply to them.
        osg::ref_ptr<osg::StateSet> screenState=new osg::StateSet;
        screenState->setMode(GL_CULL_FACE,osg::StateAttribute::OFF|osg::StateAttribute::OVERRIDE|osg::StateAttribute::PROTECTED);
        screenState->setMode(GL_POLYGON_OFFSET_FILL,osg::StateAttribute::OFF|osg::StateAttribute::OVERRIDE|osg::StateAttribute::PROTECTED);
        screenState->setAttribute(new osg::PolygonMode(osg::PolygonMode::FRONT_AND_BACK,osg::PolygonMode::FILL),osg::StateAttribute::OVERRIDE|osg::StateAttribute::PROTECTED);
        auto particleContext=context;particleContext.particleDraw=true;
        auto screenContext=particleContext;screenContext.screenPrimitiveDraw=true;screenContext.states.push_back(screenState);
        ResolvedStateScope screenResolved(screenContext);
        const auto material=resolve(particleContext,nullptr,false);
        const auto screenMaterial=resolve(screenContext,nullptr,false);
        auto pointMaterial=screenMaterial;
        if(!dynamic_cast<const osgParticle::ConnectedParticleSystem*>(&system)) {
            bool points=system.getUseShaders();
            for(int i=0;!points&&i<system.numParticles();i++)
                points=system.getParticle(i)->isAlive()&&system.getParticle(i)->getShape()==osgParticle::Particle::POINT;
            if(points) {
                auto pointContext=screenContext;pointContext.pointDraw=true;
                pointMaterial=resolve(pointContext,nullptr,false);
            }
        }
        appendParticles(packet,system,particleContext,material,screenMaterial,pointMaterial);
    }
    void GeometrySink::geometry(const osg::Geometry& geometry,const DrawContext& context)
    {
        if (!mInPass) throw std::logic_error("WebCuda geometry outside pass");
        captureGeometry(mPacket,geometry,context,mResolve);
    }
    void GeometrySink::particles(const osgParticle::ParticleSystem& system,const DrawContext& context)
    {
        if (!mInPass) throw std::logic_error("WebCuda particles outside pass");
        captureParticles(mPacket,system,context,mResolve);
    }
    void GeometrySink::gui(const osg::Array& array, std::size_t count, const osg::Texture2D* texture,
        const DrawContext& context)
    {
        if (!mInPass) throw std::logic_error("WebCuda GUI outside pass");
        auto draw=context;ResolvedStateScope resolved(draw);
        appendGui(mPacket,array,count,draw,mResolve(draw,texture,true));
    }
}
