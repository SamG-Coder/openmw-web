#include "materialstate.hpp"
#include "shaderanalysis.hpp"
#include <components/sceneutil/depth.hpp>
#include <osg/Program>
#include <osg/Shader>
#include <cctype>
#include <string>
#include <limits>
#include <algorithm>
#include <cstring>
#include <cmath>
#include <stdexcept>
#include <osg/AlphaFunc>
#include <osg/BlendFunc>
#include <osg/Capability>
#include <osg/BlendEquation>
#include <osg/ColorMask>
#include <osg/CullFace>
#include <osg/Depth>
#include <osg/ClipControl>
#include <osg/FrontFace>
#include <osg/PolygonMode>
#include <osg/Scissor>
#include <osg/Image>
#include <osg/Stencil>
#include <osg/StencilTwoSided>
#include <osg/LogicOp>
namespace WebCuda
{
    bool usesZeroToOneDepth(const osg::StateSet& state)
    {
        const auto* clip=dynamic_cast<const osg::ClipControl*>(state.getAttribute(osg::StateAttribute::CLIPCONTROL));
        return clip && clip->getDepthMode()==osg::ClipControl::ZERO_TO_ONE;
    }
    bool isBuiltinDefaultProgram(const osg::Program& program)
    {
        // StateSet::setGlobalDefaults installs these unnamed OSG shaders in
        // GLES3/GL3 profiles. Match the complete stock sources, not a prefix or
        // an empty name: edited/default-looking programs must still be rejected.
        if(program.getNumShaders()!=2)return false;
        constexpr std::string_view vertex="//gl3_VertexShader#ifdefGL_ESprecisionhighpfloat;#endif"
            "invec4osg_Vertex;invec4osg_Color;invec4osg_MultiTexCoord0;"
            "uniformmat4osg_ModelViewProjectionMatrix;outvec2texCoord;outvec4vertexColor;"
            "voidmain(void){gl_Position=osg_ModelViewProjectionMatrix*osg_Vertex;"
            "texCoord=osg_MultiTexCoord0.xy;vertexColor=osg_Color;}";
        constexpr std::string_view fragment="//gl3_FragmentShader#ifdefGL_ESprecisionhighpfloat;#endif"
            "uniformsampler2DbaseTexture;invec2texCoord;invec4vertexColor;outvec4color;"
            "voidmain(void){color=vertexColor*texture(baseTexture,texCoord);}";
        bool haveVertex=false,haveFragment=false;
        for(unsigned int i=0;i<2;++i) {
            const auto* shader=program.getShader(i);
            const std::string_view source=shader->getShaderSource();
            const auto line=source.find('\n');
            if(line==std::string_view::npos)return false;
            const auto version=source.substr(0,line);
            if(!compactShaderEquals(version,"#version300es")&&!compactShaderEquals(version,"#version330core"))return false;
            const auto body=source.substr(line+1);
            if(shader->getType()==osg::Shader::VERTEX&&compactShaderEquals(body,vertex))haveVertex=true;
            else if(shader->getType()==osg::Shader::FRAGMENT&&compactShaderEquals(body,fragment))haveFragment=true;
            else return false;
        }
        return haveVertex&&haveFragment;
    }
    bool isBuiltinParticleProgram(const osg::Program& program)
    {
        const auto compact=[](const std::string& text) {
            std::string result;
            for(unsigned char c:text)if(!std::isspace(c))result+=static_cast<char>(c);
            return result;
        };
        static const auto vertex=compact(R"(
            uniform float visibilityDistance;
            varying vec3 basic_prop;
            void main(void) {
                basic_prop = gl_MultiTexCoord0.xyz;
                vec4 ecPos = gl_ModelViewMatrix * gl_Vertex;
                float ecDepth = -ecPos.z;
                if (visibilityDistance > 0.0) {
                    if (ecDepth <= 0.0 || ecDepth >= visibilityDistance) basic_prop.x = -1.0;
                }
                gl_Position = ftransform(); gl_ClipVertex = ecPos;
                vec4 color = gl_Color; color.a *= basic_prop.z;
                gl_FrontColor = color; gl_BackColor = gl_FrontColor;
            }
        )");
        static const auto fragment=compact(R"(
            uniform sampler2D baseTexture;
            varying vec3 basic_prop;
            void main(void) {
                if (basic_prop.x < 0.0) discard;
                gl_FragColor = gl_Color * texture2D(baseTexture, gl_TexCoord[0].xy);
            }
        )");
        if(program.getNumShaders()!=2)return false;
        bool haveVertex=false,haveFragment=false;
        for(unsigned int i=0;i<2;i++) {
            const auto* shader=program.getShader(i);
            if(shader->getType()==osg::Shader::VERTEX&&compactShaderEquals(shader->getShaderSource(),vertex))haveVertex=true;
            else if(shader->getType()==osg::Shader::FRAGMENT&&compactShaderEquals(shader->getShaderSource(),fragment))haveFragment=true;
            else return false;
        }
        return haveVertex&&haveFragment;
    }

    namespace {
        unsigned int compareCode(unsigned int value) {
            if(value<GL_NEVER || value>GL_ALWAYS)throw std::runtime_error("Unsupported WebCuda compare function");
            return value-GL_NEVER;
        }
        unsigned int factorCode(unsigned int value) {
            if(value==GL_ZERO)return 0;if(value==GL_ONE)return 1;
            if(value>=GL_SRC_COLOR && value<=GL_SRC_ALPHA_SATURATE)return value-GL_SRC_COLOR+2;
            if(value==GL_CONSTANT_COLOR)return 11;
            if(value==GL_ONE_MINUS_CONSTANT_COLOR)return 12;
            if(value==GL_CONSTANT_ALPHA)return 13;
            if(value==GL_ONE_MINUS_CONSTANT_ALPHA)return 14;
            throw std::runtime_error("WebCuda dual-source blending requires a second fragment output");
        }
        unsigned int equationCode(unsigned int value) {
            switch(value) {
                case GL_FUNC_ADD:return 0;case GL_FUNC_SUBTRACT:return 1;case GL_FUNC_REVERSE_SUBTRACT:return 2;
                case GL_MIN:return 3;case GL_MAX:return 4;
                default:throw std::runtime_error("Unsupported WebCuda blend equation");
            }
        }
    }
    std::array<float,14> encodeStencilState(const osg::StateSet& state)
    {
        std::array<float,14> result{7,0,255,255,0,0,0,7,0,255,255,0,0,0};
        auto operation=[](unsigned int value)->float {
            switch(value) {
                case GL_KEEP:return 0;case GL_ZERO:return 1;case GL_REPLACE:return 2;
                case GL_INCR:return 3;case GL_DECR:return 4;case GL_INVERT:return 5;
                case GL_INCR_WRAP:return 6;case GL_DECR_WRAP:return 7;
                default:throw std::runtime_error("Unsupported stencil operation");
            }
        };
        auto pack=[&](unsigned int face,unsigned int function,int reference,unsigned int readMask,unsigned int writeMask,
            unsigned int fail,unsigned int depthFail,unsigned int pass) {
            const auto offset=face*7;
            result[offset]=static_cast<float>(compareCode(function));result[offset+1]=static_cast<float>(reference);
            result[offset+2]=static_cast<float>(readMask&255u);result[offset+3]=static_cast<float>(writeMask&255u);
            result[offset+4]=operation(fail);result[offset+5]=operation(depthFail);result[offset+6]=operation(pass);
        };
        const auto* attribute=state.getAttribute(osg::StateAttribute::STENCIL);
        if(const auto* stencil=dynamic_cast<const osg::StencilTwoSided*>(attribute)) {
            for(unsigned int side=0;side<2;side++) {
                const auto face=side==0?osg::StencilTwoSided::FRONT:osg::StencilTwoSided::BACK;
                pack(side,stencil->getFunction(face),stencil->getFunctionRef(face),stencil->getFunctionMask(face),stencil->getWriteMask(face),
                    stencil->getStencilFailOperation(face),stencil->getStencilPassAndDepthFailOperation(face),stencil->getStencilPassAndDepthPassOperation(face));
            }
        } else if(const auto* stencil=dynamic_cast<const osg::Stencil*>(attribute)) {
            for(unsigned int side=0;side<2;side++)pack(side,stencil->getFunction(),stencil->getFunctionRef(),stencil->getFunctionMask(),stencil->getWriteMask(),
                stencil->getStencilFailOperation(),stencil->getStencilPassAndDepthFailOperation(),stencil->getStencilPassAndDepthPassOperation());
        } else if(attribute)throw std::runtime_error("Unsupported stencil state attribute");
        return result;
    }
    std::array<std::uint32_t,12> encodeRasterState(const osg::StateSet& state,
        std::uint32_t width,std::uint32_t height,bool normalizedTarget)
    {
        auto enabled=[&](unsigned int mode){return (state.getMode(mode)&osg::StateAttribute::ON)!=0;};

        std::array<std::uint32_t,12> result{};
        result[3]=128|(normalizedTarget?256:0)|(enabled(GL_STENCIL_TEST)?8192:0);result[7]=width;result[8]=height;
        if(enabled(0x864F))result[3]|=262144u; // GL_DEPTH_CLAMP
        if(usesZeroToOneDepth(state))result[3]|=8388608u;
        // Compatibility sample controls. Coverage selection itself runs in .cu.
        if(enabled(0x809E))result[3]|=65536u; // GL_SAMPLE_ALPHA_TO_COVERAGE
        if(enabled(0x809F))result[3]|=131072u; // GL_SAMPLE_ALPHA_TO_ONE
        unsigned int depthFunction=GL_LESS,alphaFunction=GL_ALWAYS;
        if(enabled(GL_DEPTH_TEST)) {
            result[3]|=4|8;
            if(auto* depth=dynamic_cast<const osg::Depth*>(state.getAttribute(osg::StateAttribute::DEPTH))) {
                depthFunction=depth->getFunction();
                // AutoDepth applies the comparison reversal at draw time; its
                // stored osg::Depth function is still the unreversed value.
                if(const auto* automatic=dynamic_cast<const SceneUtil::AutoDepth*>(depth))
                    depthFunction=automatic->getEffectiveFunction();
                if(!depth->getWriteMask())result[3]&=~8u;
            }
        }
        float reference=0;
        if(enabled(GL_ALPHA_TEST))
            if(auto* alpha=dynamic_cast<const osg::AlphaFunc*>(state.getAttribute(osg::StateAttribute::ALPHAFUNC))) {
                alphaFunction=alpha->getFunction();reference=alpha->getReferenceValue();
                if(std::isnan(reference))throw std::runtime_error("Invalid alpha reference");
            }
        std::memcpy(&result[4],&reference,4);
        result[9]=compareCode(depthFunction)|(compareCode(alphaFunction)<<4);
        if(enabled(GL_COLOR_LOGIC_OP)) {
            unsigned int operation=GL_COPY;
            if(const auto* logic=dynamic_cast<const osg::LogicOp*>(state.getAttribute(osg::StateAttribute::LOGICOP)))operation=logic->getOpcode();
            if(operation<GL_CLEAR||operation>GL_SET)throw std::runtime_error("Invalid color logic operation");
            result[9]|=(1u<<25)|((operation-GL_CLEAR)<<21);
        }
        if(auto* mask=dynamic_cast<const osg::ColorMask*>(state.getAttribute(osg::StateAttribute::COLORMASK)))
            result[9]|=(!mask->getRedMask()<<17)|(!mask->getGreenMask()<<18)|(!mask->getBlueMask()<<19)|(!mask->getAlphaMask()<<20);
        auto blendEnabled=[&](unsigned int attachment) {
            const auto type=static_cast<osg::StateAttribute::Type>(osg::StateAttribute::CAPABILITY+GL_BLEND);
            const auto* attribute=state.getAttribute(type,attachment);
            if(dynamic_cast<const osg::Disablei*>(attribute))return false;
            if(dynamic_cast<const osg::Enablei*>(attribute))return true;
            return enabled(GL_BLEND);
        };
        const bool colorBlend=blendEnabled(0),normalBlend=blendEnabled(1);
        if(colorBlend)result[3]|=2;
        if(normalBlend)result[9]|=1u<<26;
        if(colorBlend||normalBlend) {
            unsigned int sr=GL_ONE,dr=GL_ZERO,sa=GL_ONE,da=GL_ZERO;
            if(auto* blend=dynamic_cast<const osg::BlendFunc*>(state.getAttribute(osg::StateAttribute::BLENDFUNC))) {
                sr=blend->getSourceRGB();dr=blend->getDestinationRGB();sa=blend->getSourceAlpha();da=blend->getDestinationAlpha();
            }
            result[10]=factorCode(sr)|(factorCode(dr)<<4)|(factorCode(sa)<<8)|(factorCode(da)<<12);
            if(auto* equation=dynamic_cast<const osg::BlendEquation*>(state.getAttribute(osg::StateAttribute::BLENDEQUATION)))
                result[9]|=equationCode(equation->getEquationRGB())<<8|equationCode(equation->getEquationAlpha())<<11;
        }
        if(enabled(GL_CULL_FACE)) {
            unsigned int mode=GL_BACK;
            if(auto* cull=dynamic_cast<const osg::CullFace*>(state.getAttribute(osg::StateAttribute::CULLFACE)))mode=cull->getMode();
            unsigned int code=mode==GL_FRONT?1:mode==GL_BACK?2:mode==GL_FRONT_AND_BACK?3:0;
            if(!code)throw std::runtime_error("Invalid WebCuda cull mode");
            result[9]|=code<<14;
        }
        // Face orientation also selects two-sided lighting and stencil state
        // when culling is disabled. Always transport the effective winding.
        if(auto* front=dynamic_cast<const osg::FrontFace*>(state.getAttribute(osg::StateAttribute::FRONTFACE)))
            if(front->getMode()==osg::FrontFace::CLOCKWISE)result[9]|=65536;
        if(const auto* polygon=dynamic_cast<const osg::PolygonMode*>(state.getAttribute(osg::StateAttribute::POLYGONMODE))) {
            for(unsigned int face=0;face<2;face++) {
                const auto mode=polygon->getMode(face==0?osg::PolygonMode::FRONT:osg::PolygonMode::BACK);
                const unsigned int code=mode==osg::PolygonMode::FILL?0u:mode==osg::PolygonMode::LINE?1u:mode==osg::PolygonMode::POINT?2u:3u;
                if(code==3u)throw std::runtime_error("Invalid polygon mode");
                result[9]|=code<<(27u+face*2u);
            }
        }
        if(enabled(GL_SCISSOR_TEST)) {
            if(auto* scissor=dynamic_cast<const osg::Scissor*>(state.getAttribute(osg::StateAttribute::SCISSOR))) {
                if(scissor->width()<0 || scissor->height()<0)throw std::runtime_error("Invalid WebCuda scissor");
                // Preserve signed bottom-left origins as uint bits. CUDA owns
                // framebuffer intersection and the top-left conversion.
                result[3]|=16777216u;
                result[5]=static_cast<std::uint32_t>(scissor->x());result[6]=static_cast<std::uint32_t>(scissor->y());
                result[7]=static_cast<std::uint32_t>(scissor->width());result[8]=static_cast<std::uint32_t>(scissor->height());
            }
        }
        return result;
    }
    ResolvedStateScope::ResolvedStateScope(DrawContext& context)
        :mContext(context),mPrevious(context.resolvedState),mStack(context.states),mState(resolveState(context))
    {
        context.resolvedState=this;
    }
    ResolvedStateScope::~ResolvedStateScope() { mContext.resolvedState=mPrevious; }

    osg::ref_ptr<const osg::StateSet> resolveState(const DrawContext& context)
    {
        if(const auto* scope=context.resolvedState;scope&&scope->mStack==context.states)return scope->mState;
        osg::ref_ptr<osg::StateSet> result = new osg::StateSet;
        for (const auto* state : context.states) if (state) result->merge(*state);
        // OSG Program::apply uses an empty shader list to disable the inherited
        // program. Normalize only after merging so OVERRIDE/PROTECTED still
        // select the effective program before the CUDA compatibility route.
        if(const auto* program=dynamic_cast<const osg::Program*>(result->getAttribute(osg::StateAttribute::PROGRAM)))
            if(program->getNumShaders()==0)result->removeAttribute(osg::StateAttribute::PROGRAM);
        return result;
    }
    TexturePixels copyTexturePixels(const osg::Image& image)
    {
        if (!image.data() || image.s()<=0 || image.t()<=0 || image.r()!=1)
            throw std::runtime_error("WebCuda texture requires a populated 2D image");
        if (image.isCompressed() || image.getDataType()!=GL_UNSIGNED_BYTE || image.isMipmap())
            throw std::runtime_error("WebCuda texture requires compressed/mip/HDR decoding support");
        const auto format = image.getPixelFormat();
        switch (format) {
            case GL_RGBA: case GL_RGB: case GL_BGRA: case GL_BGR:
            case GL_LUMINANCE: case GL_LUMINANCE_ALPHA: case GL_ALPHA: break;
            default: throw std::runtime_error("Unsupported WebCuda texture pixel format");
        }
        TexturePixels result;
        result.width=image.s(); result.height=image.t();
        if (std::uint64_t(result.width)*result.height > std::numeric_limits<std::uint32_t>::max())
            throw std::runtime_error("WebCuda texture is too large");
        result.rgba.reserve(std::size_t(result.width)*result.height);
        for (std::uint32_t y=0; y<result.height; ++y)
            for (std::uint32_t x=0; x<result.width; ++x) {
                const auto* pixel=image.data(x,y); // honors OSG row padding
                std::uint32_t r=255,g=255,b=255,a=255;
                if (format==GL_RGB || format==GL_RGBA) { r=pixel[0];g=pixel[1];b=pixel[2]; }
                else if (format==GL_BGR || format==GL_BGRA) { b=pixel[0];g=pixel[1];r=pixel[2]; }
                else if (format==GL_LUMINANCE || format==GL_LUMINANCE_ALPHA) r=g=b=pixel[0];
                if (format==GL_RGBA || format==GL_BGRA) a=pixel[3];
                else if (format==GL_LUMINANCE_ALPHA) a=pixel[1];
                else if (format==GL_ALPHA) {r=g=b=0;a=pixel[0];}
                result.rgba.push_back(r | (g<<8) | (b<<16) | (a<<24));
            }
        return result;
    }
}
