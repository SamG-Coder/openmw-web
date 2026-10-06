#include <cassert>
#include <cstdio>
#include <stdexcept>
#include <cstring>
#include <osg/BlendFunc>
#include <osg/Program>
#include <osg/Shader>
#include <osg/DisplaySettings>
#include <components/webcuda/materialtable.hpp>
int main() {
    osg::ref_ptr<osg::Image> image=new osg::Image;
    image->allocateImage(2,1,1,GL_RGBA,GL_UNSIGNED_BYTE);
    for(int i=0;i<8;i++)image->data()[i]=static_cast<unsigned char>(i*30);
    osg::ref_ptr<osg::Texture2D> texture=new osg::Texture2D(image);
    texture->setWrap(osg::Texture::WRAP_S,osg::Texture::CLAMP_TO_EDGE);
    texture->setWrap(osg::Texture::WRAP_T,osg::Texture::CLAMP_TO_EDGE);
    texture->setFilter(osg::Texture::MIN_FILTER,osg::Texture::LINEAR);
    texture->setFilter(osg::Texture::MAG_FILTER,osg::Texture::LINEAR);
    osg::ref_ptr<osg::StateSet> state=new osg::StateSet;
    state->setTextureAttributeAndModes(0,texture,osg::StateAttribute::ON);
    WebCuda::DrawContext context;context.states={state};
    WebCuda::MaterialTable table(16,16);
    // Resolve sampler indirection without assuming atlas addresses: LOD/border
    // descriptors are separate from the versioned image storage.
    auto pixelsAt=[](const WebCuda::MaterialTable& owner,unsigned int id) {
        auto offset=owner.materials()[id*12];
        if(owner.materials()[id*12+11]&(1u<<29))offset=owner.texels().at(offset);
        return offset;
    };
    auto first=table.encode(context,texture,true);
    const auto initialSize=table.texels().size();
    auto again=table.encode(context,texture,true);
    assert(first==0 && again==first && table.materials().size()==12 && table.texels().size()==initialSize);
    assert(table.materials()[1]==2 && table.materials()[2]==1);
    assert((table.materials()[3]&(1|32))==(1|32));
    const auto originalVersion=table.textureResources().at(0);
    assert(originalVersion && table.textureResources().size()==3);
    WebCuda::MaterialTable laterFrame(16,16);
    laterFrame.encode(context,texture,true);
    assert(laterFrame.textureResources().at(0)==originalVersion);
    const auto oldOffset=pixelsAt(table,first),oldPixel=table.texels().at(oldOffset);
    assert(oldPixel==0x5a3c1e00u);
    image->data()[0]=255;image->dirty();
    auto changed=table.encode(context,texture,true);
    assert(changed!=first && table.texels().at(oldOffset)==oldPixel);
    assert(table.texels().at(pixelsAt(table,changed))==0x5a3c1effu);
    assert(table.textureResources().size()==6 && table.textureResources()[3]!=originalVersion);
    const auto changedVersion=table.textureResources()[3];
    WebCuda::MaterialTable changedFrame(16,16);
    changedFrame.encode(context,texture,true);
    assert(changedFrame.textureResources()[0]==changedVersion);
    osg::ref_ptr<osg::Texture2D> srgbTexture=new osg::Texture2D(image);
    srgbTexture->setInternalFormat(0x8C43);
    changedFrame.encode(context,srgbTexture,true);
    assert(changedFrame.textureResources().size()==6 && changedFrame.textureResources()[3]!=changedVersion);
    auto solidGui=table.encode(context,nullptr,true);
    assert((table.materials()[solidGui*12+3]&1)==0);
    assert(table.encode(context,texture,true)==changed);
    // The stock default program follows its sampler uniform even when the
    // fixed-function texture mode is OFF. Each draw sees uniform mutations.
    const auto previousHint=osg::DisplaySettings::instance()->getShaderHint();
    osg::DisplaySettings::instance()->setShaderHint(osg::DisplaySettings::SHADER_GLES3);
    osg::ref_ptr<osg::StateSet> defaultState=new osg::StateSet;defaultState->setGlobalDefaults();
    osg::DisplaySettings::instance()->setShaderHint(previousHint);
    defaultState->setTextureAttribute(3,texture);defaultState->setTextureMode(3,GL_TEXTURE_2D,osg::StateAttribute::OFF);
    auto* defaultSampler=defaultState->getUniform("baseTexture");defaultSampler->set(3);
    WebCuda::DrawContext defaultContext;defaultContext.states={defaultState};
    WebCuda::MaterialTable defaultTable(16,16);
    const auto texturedDefault=defaultTable.encode(defaultContext);
    assert(texturedDefault==defaultTable.encode(defaultContext,texture,true));
    defaultSampler->set(0);
    assert(defaultTable.encode(defaultContext)!=texturedDefault);
    defaultSampler->set(-1);
    bool badSampler=false;try{defaultTable.encode(defaultContext);}catch(const std::runtime_error&){badSampler=true;}
    assert(badSampler);
    // An empty Program restores compatibility state; a real unknown shader
    // still must not silently route to an unrelated renderer.
    const auto compatible=table.encode(context);
    state->setAttribute(new osg::Program);
    assert(table.encode(context)==compatible);
    osg::ref_ptr<osg::Program> unknown=new osg::Program;
    unknown->addShader(new osg::Shader(osg::Shader::VERTEX,"void main() {}"));
    state->setAttribute(unknown);
    bool rejected=false;try{table.encode(context);}catch(const std::runtime_error&){rejected=true;}assert(rejected);
    assert(table.encode(context,texture,true)==changed);
    texture->setFilter(osg::Texture::MIN_FILTER,osg::Texture::LINEAR_MIPMAP_LINEAR);
    const auto mip=table.encode(context,texture,true);
    assert((table.materials()[mip*12+11]&31u)==1u);
    assert(!table.mipGenerations().empty());
    texture->setFilter(osg::Texture::MIN_FILTER,osg::Texture::LINEAR);
    osg::ref_ptr<osg::Image> compressed=new osg::Image;
    const unsigned int words[]={0x001ff800,0};
    auto* bytes=new unsigned char[8];std::memcpy(bytes,words,8);
    compressed->setImage(4,4,1,0x83f1,0x83f1,GL_UNSIGNED_BYTE,bytes,osg::Image::USE_NEW_DELETE);
    texture->setImage(compressed);
    WebCuda::MaterialTable compressedTable(16,16);
    auto compressedMaterial=compressedTable.encode(context,texture,true);
    assert(compressedTable.compressedBlocks().size()==2 && compressedTable.compressedBlocks()[0]==words[0]);
    assert(compressedTable.textureDecodes().size()==5 && compressedTable.textureDecodes()[4]==1);
    const auto decoded=compressedTable.textureDecodes()[1];
    assert(pixelsAt(compressedTable,compressedMaterial)==decoded && decoded+16<=compressedTable.texels().size());
    const auto compressedSize=compressedTable.texels().size();
    assert(compressedTable.encode(context,texture,true)==compressedMaterial && compressedTable.compressedBlocks().size()==2);
    assert(compressedTable.texels().size()==compressedSize);
    osg::ref_ptr<osg::Image> depthImage=new osg::Image;
    depthImage->allocateImage(1,1,1,GL_DEPTH_COMPONENT,GL_FLOAT);
    const unsigned int infinity=0x7f800000u;std::memcpy(depthImage->data(),&infinity,4);
    osg::ref_ptr<osg::Texture2D> depthTexture=new osg::Texture2D(depthImage);
    depthTexture->setInternalFormat(0x8CAC);
    depthTexture->setFilter(osg::Texture::MIN_FILTER,osg::Texture::NEAREST);
    WebCuda::MaterialTable depthTable(16,16);
    const auto depthMaterial=depthTable.encode(context,depthTexture,true);
    const auto sampler=depthTable.materials()[depthMaterial*12+11];
    assert((sampler&8192u)!=0 && (sampler&32768u)==0);
    assert(depthTable.textureDecodes().size()==5);
    assert(depthTable.textureDecodes()[4]==(65536u|(9u<<8)|9u));
    assert(depthTable.compressedBlocks()[0]==infinity);
    assert(depthTable.encode(context,depthTexture,true)==depthMaterial);
    // Interior disabled-shadow state intentionally has no shadow matrices.
    osg::ref_ptr<osg::StateSet> shadowState=new osg::StateSet;
    osg::ref_ptr<osg::Program> objects=new osg::Program;
    osg::ref_ptr<osg::Shader> vertex=new osg::Shader(osg::Shader::VERTEX),fragment=new osg::Shader(osg::Shader::FRAGMENT);
    vertex->setName("objects.vert");fragment->setName("objects.frag");
    fragment->setUserValue("webcuda.defines",std::string("shadows_enabled=1\nshadow_texture_unit_list=0\ndisableNormalOffsetShadows=1\n"));
    objects->addShader(vertex);objects->addShader(fragment);shadowState->setAttribute(objects);
    depthTexture->setShadowComparison(true);depthTexture->setShadowCompareFunc(osg::Texture::ALWAYS);
    shadowState->setTextureAttribute(15,depthTexture);
    shadowState->addUniform(new osg::Uniform("shadowTexture0",15));
    osg::Matrixd view;view.makeIdentity();
    WebCuda::DrawContext shadowContext;shadowContext.states={shadowState};shadowContext.view=&view;
    WebCuda::MaterialTable shadowTable(16,16);
    const auto shadowMaterial=shadowTable.encode(shadowContext);
    const auto base=shadowTable.materials()[shadowMaterial*12];
    assert(shadowTable.texels()[base+324]==1);
    const auto cascade=base+shadowTable.texels()[base+325];
    assert(shadowTable.texels()[cascade+4]==7);
    for(unsigned k=0;k<16;k++)assert(shadowTable.texels()[cascade+8+k]==(k%5==0?0x3f800000u:0u));
    depthTexture->setShadowCompareFunc(osg::Texture::LEQUAL);
    rejected=false;try{shadowTable.encode(shadowContext);}catch(const std::runtime_error& e){rejected=std::string(e.what()).find("Missing shadow matrix")!=std::string::npos;}assert(rejected);
    // Offscreen map/preview cameras explicitly disable the global sky variant.
    fragment->setUserValue("webcuda.defines",std::string("skyBlending=1\n"));
    rejected=false;try{shadowTable.encode(shadowContext);}catch(const std::runtime_error& e){rejected=std::string(e.what()).find("Missing screen effect sampler: sky")!=std::string::npos;}assert(rejected);
    osg::ref_ptr<osg::Uniform> disableSky=new osg::Uniform("webcudaDisableSkyBlending",true);
    shadowState->addUniform(disableSky);
    const auto noSky=shadowTable.encode(shadowContext);
    assert((shadowTable.texels()[shadowTable.materials()[noSky*12]+4]&1048576u)==0);
    disableSky->set(false);
    rejected=false;try{shadowTable.encode(shadowContext);}catch(const std::runtime_error& e){rejected=std::string(e.what()).find("Missing screen effect sampler: sky")!=std::string::npos;}assert(rejected);
    shadowState->addUniform(new osg::Uniform("sky",0));
    shadowState->setTextureAttribute(0,texture);
    const auto withSky=shadowTable.encode(shadowContext);
    assert((shadowTable.texels()[shadowTable.materials()[withSky*12]+4]&1048576u)!=0);
    // Shadow/RTT pixels are GPU outputs: snapshots contain only CPU metadata,
    // even for a full 8192-square depth mip chain.
    auto attachments=std::make_shared<WebCuda::MaterialTable>(16,16);
    osg::ref_ptr<osg::Texture2D> shadow=new osg::Texture2D, color=new osg::Texture2D;
    shadow->setTextureSize(8192,8192);shadow->setInternalFormat(0x81A6);
    color->setTextureSize(4,4);color->setInternalFormat(GL_RGBA32F_ARB);
    for(auto* target:{shadow.get(),color.get()}) {
        target->setFilter(osg::Texture::MIN_FILTER,osg::Texture::LINEAR_MIPMAP_LINEAR);
        target->setFilter(osg::Texture::MAG_FILTER,osg::Texture::LINEAR);
        target->setWrap(osg::Texture::WRAP_S,osg::Texture::CLAMP_TO_EDGE);
        target->setWrap(osg::Texture::WRAP_T,osg::Texture::CLAMP_TO_EDGE);
    }
    attachments->setRenderTextureResolver([&](const osg::Texture2D* target) {
        return target==shadow.get()?0x80000001u:target==color.get()?0x20000002u:0u;
    });
    WebCuda::DrawContext attachmentContext;
    const auto shadowId=attachments->encode(attachmentContext,shadow,true);
    std::uint64_t shadowWords=0;
    for(unsigned int size=8192;size;size/=2)shadowWords+=std::uint64_t(size)*size;
    const auto firstSnapshot=WebCuda::captureMaterialTable(attachments);
    assert(firstSnapshot->textureResources().empty());
    const auto firstPrefix=firstSnapshot->texels();
    assert(firstPrefix.size()<64 && firstSnapshot->texelWordCount()==firstPrefix.size()+shadowWords);
    assert(pixelsAt(*firstSnapshot,shadowId)==firstPrefix.size());
    assert(firstSnapshot->textureCopies()[1]==firstPrefix.size());
    assert(firstSnapshot->depthMipSources()[0]==firstPrefix.size() && firstSnapshot->depthMipSources()[1]==24);
    std::uint64_t mipOffset=firstPrefix.size();
    for(std::size_t i=0;i<firstSnapshot->mipGenerations().size();i+=4) {
        const auto& chain=firstSnapshot->mipGenerations();
        assert(chain[i]==mipOffset);
        mipOffset+=std::uint64_t(chain[i+2])*chain[i+3];
        assert(chain[i+1]==mipOffset);
    }
    assert(mipOffset+1==firstSnapshot->texelWordCount());
    assert(WebCuda::captureMaterialTable(firstSnapshot)==firstSnapshot);
    const auto colorId=attachments->encode(attachmentContext,color,true);
    assert(attachments->encode(attachmentContext,shadow,true)==shadowId);
    const auto secondSnapshot=WebCuda::captureMaterialTable(attachments);
    const auto secondPrefix=secondSnapshot->texels().size();
    assert(secondPrefix<64 && secondPrefix>firstPrefix.size());
    assert(secondSnapshot->texelWordCount()==secondPrefix+shadowWords+(16+4+1)*4);
    assert(pixelsAt(*secondSnapshot,shadowId)==secondPrefix);
    assert(pixelsAt(*secondSnapshot,colorId)==secondPrefix+shadowWords);
    assert(secondSnapshot->textureCopies()[5]==secondPrefix+shadowWords);
    assert(firstSnapshot->texels()==firstPrefix && firstSnapshot->textureCopies().size()==4);
    WebCuda::MaterialTable resolvedCopy(*secondSnapshot);
    rejected=false;try{resolvedCopy.encode(attachmentContext);}catch(const std::logic_error&){rejected=true;}assert(rejected);
    std::puts("WebCuda material table: texture reuse, dirty-image versioning, compact GPU attachment snapshots, mip relocation and unsupported-state rejection passed");
}
