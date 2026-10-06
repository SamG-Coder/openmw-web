#include <cassert>
#include <cstdio>
#include <stdexcept>
#include <osg/Depth>
#include <osg/ClipControl>
#include <osg/BlendFunc>
#include <osg/AlphaFunc>
#include <osg/Scissor>
#include <osg/CullFace>
#include <cstring>
#include <osg/Image>
#include <osg/Texture2D>
#include <osg/Uniform>
#include <osg/DisplaySettings>
#include <osg/Program>
#include <osg/Shader>
#include <components/webcuda/materialstate.hpp>
#include <components/webcuda/shaderanalysis.hpp>
#include <components/webcuda/shaderdefines.hpp>
#include <string>
#include <sstream>
#include <random>
#include <components/sceneutil/depth.hpp>
int main() {
    // Compare the cached parser with the previous getline/map contract,
    // including duplicate keys, empty fields, carriage returns and embedded NUL.
    WebCuda::ShaderDefineCache defineCache;
    std::mt19937 definitionsRandom(7791);
    for(unsigned int trial=0;trial<300;trial++) {
        std::string text="same=first\nsame=last\n=empty key\nempty=\ncarriage=false\r\nignored line\n";
        for(unsigned int i=0;i<250;i++)text+="abc01=\n\r\0"[definitionsRandom()%10];
        WebCuda::ShaderDefines::Values expected;
        std::istringstream input(text);std::string line;
        while(std::getline(input,line)){const auto split=line.find('=');if(split!=std::string::npos)expected[line.substr(0,split)]=line.substr(split+1);}
        const auto parsed=defineCache.get(text);
        assert(parsed->values==expected&&parsed==defineCache.get(text));
        assert(defineCache.entryCount()<=256&&defineCache.retainedBytes()<=2u*1024u*1024u);
    }
    std::string metadata="classicFalloff=1\n";
    const auto initialDefines=defineCache.get(metadata);const auto* metadataAddress=metadata.data();
    metadata[metadata.find('1')]='0';
    const auto editedDefines=defineCache.get(metadata);
    assert(metadata.data()==metadataAddress&&initialDefines!=editedDefines);
    assert(initialDefines->enabled("classicFalloff")&&!editedDefines->enabled("classicFalloff"));
    WebCuda::ShaderDefineCache lru(8192,2);
    const auto a=lru.get("A=1"),b=lru.get("B=2");
    assert(lru.get("A=1")==a);lru.get("C=3");
    assert(lru.entryCount()==2&&lru.get("B=2")!=b&&b->value("B")=="2");
    WebCuda::ShaderDefineCache measure;
    measure.get("A=1");const auto entryBytes=measure.retainedBytes();
    WebCuda::ShaderDefineCache bounded(entryBytes*2-1);
    bounded.get("A=1");bounded.get("B=2");
    assert(bounded.entryCount()==1&&bounded.retainedBytes()<=entryBytes*2-1);
    const std::string large="large="+std::string(entryBytes*4,'x');
    const auto transient=bounded.get(large);
    assert(transient!=bounded.get(large)&&bounded.entryCount()==1);
    assert(transient->value("large").size()==entryBytes*4);
    const std::string features="diffuseMap=1\nnormalMap=1\nspecularMap=1\ndetailMap=1\nemissiveMap=1\nforcePPL=1\nalphaToCoverage=1\nlightingMethodClustered=1\n";
    using DC=WebCuda::ShaderDefineCache;
    const auto regular=defineCache.get(features),terrain=defineCache.get(features,DC::Terrain),
        composite=defineCache.get(features,DC::Terrain|DC::Composite),water=defineCache.get(features,DC::Water),
        grass=defineCache.get(features,DC::Groundcover),unlit=defineCache.get(features,DC::Unlit),
        bethesda=defineCache.get(features,DC::Bethesda);
    assert(regular->enabled("specularMap")&&!terrain->enabled("specularMap")&&terrain->terrainSpecular);
    assert(!terrain->vertexLighting&&!composite->vertexLighting&&!composite->enabled("alphaToCoverage")&&!composite->enabled("normalMap"));
    assert(!water->enabled("diffuseMap")&&!water->enabled("normalMap")&&!water->vertexLighting);
    assert(grass->enabled("normalMap")&&!grass->enabled("forcePPL")&&!grass->enabled("emissiveMap"));
    assert(!unlit->enabled("normalMap")&&!unlit->enabled("lightingMethodClustered")&&!unlit->vertexLighting);
    assert(bethesda->enabled("normalMap")&&bethesda->enabled("emissiveMap")&&!bethesda->enabled("specularMap"));
    osg::ref_ptr<osg::Shader> metadataShader=new osg::Shader(osg::Shader::FRAGMENT);
    assert(!WebCuda::shaderDefines(*metadataShader));
    metadataShader->setUserValue("webcuda.defines",17);assert(!WebCuda::shaderDefines(*metadataShader));
    metadataShader->setUserValue("webcuda.defines",metadata);
    const auto owned=WebCuda::shaderDefines(*metadataShader);
    osg::ref_ptr<osg::Shader> sameMetadata=new osg::Shader(osg::Shader::FRAGMENT);
    sameMetadata->setUserValue("webcuda.defines",metadata);
    assert(owned==WebCuda::shaderDefines(*sameMetadata));
    metadataShader->setUserValue("webcuda.defines",std::string("classicFalloff=1\n"));
    assert(WebCuda::shaderDefines(*metadataShader)->enabled("classicFalloff")&&!owned->enabled("classicFalloff"));
    metadataShader=nullptr;assert(owned->value("classicFalloff")=="0");
    std::puts("Shader define cache: 300 parser comparisons, exact edits, independent profiles, shared ownership and bounded LRU passed");
    // Exercise the real dependency producer, including unnamed shaders. An
    // edited stock source and extra stages must not inherit the stock route.
    const auto previousHint=osg::DisplaySettings::instance()->getShaderHint();
    osg::DisplaySettings::instance()->setShaderHint(osg::DisplaySettings::SHADER_GLES3);
    osg::ref_ptr<osg::StateSet> defaults=new osg::StateSet;defaults->setGlobalDefaults();
    osg::DisplaySettings::instance()->setShaderHint(previousHint);
    auto* defaultProgram=dynamic_cast<osg::Program*>(defaults->getAttribute(osg::StateAttribute::PROGRAM));
    assert(defaultProgram&&WebCuda::isBuiltinDefaultProgram(*defaultProgram));
    auto* defaultFragment=defaultProgram->getShader(1);
    const auto sourceBeforeEdit=defaultFragment->getShaderSource();
    std::string sourceAfterEdit=sourceBeforeEdit;
    const auto sample=sourceAfterEdit.find("texture(baseTexture, texCoord)");assert(sample!=std::string::npos);
    sourceAfterEdit.replace(sample,7,"ignored");
    defaultFragment->setShaderSource(sourceAfterEdit);
    assert(!WebCuda::isBuiltinDefaultProgram(*defaultProgram));
    defaultFragment->setShaderSource(sourceBeforeEdit);
    assert(WebCuda::isBuiltinDefaultProgram(*defaultProgram));
    osg::ref_ptr<osg::Shader> extra=new osg::Shader(osg::Shader::VERTEX,"void main() {}");
    defaultProgram->addShader(extra);assert(!WebCuda::isBuiltinDefaultProgram(*defaultProgram));
    defaultProgram->removeShader(extra);assert(WebCuda::isBuiltinDefaultProgram(*defaultProgram));
    // Differentially preserve the old compact-source recognition semantics,
    // including whitespace inside tokens, overlapping starts and source edits.
    const auto compact=[](const std::string& source) {
        std::string result;
        for(unsigned char c:source)if(!std::isspace(c))result+=static_cast<char>(c);
        return result;
    };
    const std::string token="gl_Position=modelToClip(";
    for(const std::string source:{"", "g", "gl_Position = modelToClip (", "ggl_Position=modelToClip(",
            "gl_Positi on = model To Clip (", "gl_Position=viewToClip(", "gl_Position=modelToClipX("}) {
        assert(WebCuda::compactShaderContains(source,token)==(compact(source).find(token)!=std::string::npos));
        assert(WebCuda::compactShaderEquals(source,token)==(compact(source)==token));
    }
    std::mt19937 random(541);
    const std::string alphabet="gl_Position=mdTCp( abc\t\r\n\v\f";
    for(unsigned int trial=0;trial<1000;trial++) {
        std::string source;
        for(unsigned int i=0,count=random()%600;i<count;i++)source+=alphabet[random()%alphabet.size()];
        if(trial%2==0)source.insert(random()%(source.size()+1),"gl_Position \n = modelToClip (");
        const auto expected=compact(source);
        assert(WebCuda::compactShaderContains(source,token)==(expected.find(token)!=std::string::npos));
        assert(WebCuda::compactShaderEquals(source,token)==(expected==token));
    }
    std::string edited="gl_Position=modelToClip(";
    assert(WebCuda::compactShaderEquals(edited,token));edited.back()='X';
    assert(!WebCuda::compactShaderContains(edited,token));
    using A=osg::StateAttribute;
    osg::ref_ptr<osg::StateSet> parent=new osg::StateSet,child=new osg::StateSet,protectedChild=new osg::StateSet;
    parent->setMode(GL_BLEND,A::ON|A::OVERRIDE); child->setMode(GL_BLEND,A::OFF);
    protectedChild->setMode(GL_BLEND,A::OFF|A::PROTECTED);
    osg::ref_ptr<osg::Depth> near=new osg::Depth(osg::Depth::LESS),far=new osg::Depth(osg::Depth::LEQUAL);
    parent->setAttribute(near,A::OVERRIDE);child->setAttribute(far);protectedChild->setAttribute(far,A::PROTECTED);
    osg::ref_ptr<osg::Texture2D> texture1=new osg::Texture2D,texture2=new osg::Texture2D;
    parent->setTextureAttribute(0,texture1,A::OVERRIDE); child->setTextureAttribute(0,texture2);
    protectedChild->setTextureAttribute(0,texture2,A::PROTECTED);
    parent->addUniform(new osg::Uniform("alpha",.25f),A::OVERRIDE);
    child->addUniform(new osg::Uniform("alpha",.75f));
    parent->setDefine("FEATURE","first",A::OVERRIDE);child->setDefine("FEATURE","second");
    WebCuda::DrawContext context;context.states={parent,child};
    auto state=WebCuda::resolveState(context);
    assert(state->getMode(GL_BLEND)&A::ON);
    assert(state->getAttribute(A::DEPTH)==near && state->getTextureAttribute(0,A::TEXTURE)==texture1);
    float alpha=0; state->getUniform("alpha")->get(alpha); assert(alpha==.25f);
    assert(state->getDefinePair("FEATURE")->first=="first");
    context.states.push_back(protectedChild);state=WebCuda::resolveState(context);
    assert(!(state->getMode(GL_BLEND)&A::ON));
    assert(state->getAttribute(A::DEPTH)==far && state->getTextureAttribute(0,A::TEXTURE)==texture2);
    assert(parent->getAttribute(A::DEPTH)==near); // resolver did not edit the scene
    osg::ref_ptr<osg::StateSet> raster=new osg::StateSet;
    raster->setAttributeAndModes(new osg::Depth(osg::Depth::GEQUAL,0,1,false),A::ON);
    raster->setAttributeAndModes(new osg::BlendFunc(GL_SRC_ALPHA,GL_ONE_MINUS_SRC_ALPHA,GL_ONE,GL_ONE_MINUS_SRC_ALPHA),A::ON);
    raster->setAttributeAndModes(new osg::AlphaFunc(osg::AlphaFunc::GREATER,.333f),A::ON);
    raster->setAttributeAndModes(new osg::Scissor(-2,1,6,4),A::ON);
    raster->setAttributeAndModes(new osg::CullFace(osg::CullFace::FRONT),A::ON);
    auto encoded=WebCuda::encodeRasterState(*raster,8,8);
    assert((encoded[3]&4)!=0 && (encoded[3]&8)==0 && (encoded[3]&2)!=0);
    assert((encoded[9]&15)==6 && ((encoded[9]>>4)&15)==4 && ((encoded[9]>>14)&3)==1);
    assert(encoded[10]==0x5154);
    float reference;std::memcpy(&reference,&encoded[4],4);assert(reference==.333f);
    assert(encoded[5]==0 && encoded[6]==3 && encoded[7]==4 && encoded[8]==4);
    osg::ref_ptr<osg::Image> image=new osg::Image;
    image->allocateImage(1,2,1,GL_RGB,GL_UNSIGNED_BYTE,4);
    image->data(0,0)[0]=10;image->data(0,0)[1]=20;image->data(0,0)[2]=30;
    image->data(0,1)[0]=40;image->data(0,1)[1]=50;image->data(0,1)[2]=60;
    auto pixels=WebCuda::copyTexturePixels(*image);
    assert(pixels.width==1 && pixels.height==2);
    assert(pixels.rgba[0]==0xff1e140a && pixels.rgba[1]==0xff3c3228);
    image->allocateImage(1,1,1,GL_ALPHA,GL_UNSIGNED_BYTE);
    image->data()[0]=64;pixels=WebCuda::copyTexturePixels(*image);assert(pixels.rgba[0]==0x40000000);
    image->allocateImage(1,1,1,GL_RGBA,GL_FLOAT);
    bool rejected=false;try{WebCuda::copyTexturePixels(*image);}catch(const std::runtime_error&){rejected=true;}
    assert(rejected);
    // The main reversed-Z camera clears depth to zero. AutoDepth must encode
    // its effective comparison, while ordinary shadow osg::Depth stays literal.
    osg::ref_ptr<osg::StateSet> depthState=new osg::StateSet;
    assert(!WebCuda::usesZeroToOneDepth(*depthState));
    depthState->setAttribute(new osg::ClipControl(osg::ClipControl::LOWER_LEFT,osg::ClipControl::ZERO_TO_ONE));
    assert(WebCuda::encodeRasterState(*depthState,8,8)[3]&8388608u);
    depthState->setAttribute(new osg::ClipControl(osg::ClipControl::LOWER_LEFT,osg::ClipControl::NEGATIVE_ONE_TO_ONE));
    assert(!(WebCuda::encodeRasterState(*depthState,8,8)[3]&8388608u));
    depthState->setAttributeAndModes(new SceneUtil::AutoDepth(osg::Depth::LEQUAL),A::ON);
    assert((WebCuda::encodeRasterState(*depthState,8,8)[9]&15)==3);
    SceneUtil::AutoDepth::setReversed(true);
    const osg::Depth::Function functions[]={osg::Depth::NEVER,osg::Depth::LESS,osg::Depth::EQUAL,
        osg::Depth::LEQUAL,osg::Depth::GREATER,osg::Depth::NOTEQUAL,osg::Depth::GEQUAL,osg::Depth::ALWAYS};
    const unsigned int reversedCodes[]={0,4,2,6,1,5,3,7};
    for(unsigned int i=0;i<8;++i) {
        depthState->setAttributeAndModes(new SceneUtil::AutoDepth(functions[i],0,1,false),A::ON);
        auto automatic=WebCuda::encodeRasterState(*depthState,8,8);
        assert((automatic[9]&15)==reversedCodes[i]);
        assert((automatic[3]&4)!=0 && (automatic[3]&8)==0);
        depthState->setAttributeAndModes(new osg::Depth(functions[i]),A::ON);
        auto literal=WebCuda::encodeRasterState(*depthState,8,8);
        assert((literal[9]&15)==i);
        assert((literal[3]&8)!=0);
    }
    std::puts("WebCuda material state: override/protected modes, attributes, textures, uniforms/defines and padded texture rows passed");
}
