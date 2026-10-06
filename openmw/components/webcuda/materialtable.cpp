#include "materialtable.hpp"
#include "maptexture.hpp"
#include "fogtexture.hpp"
#include <limits>
#include <algorithm>
#include <cstring>
#include <cmath>
#include <stdexcept>
#include <osg/Program>
#include <osg/Shader>
#include <osg/Fog>
#include <osg/Material>
#include <sstream>
#include <osg/TexMat>
#include <osg/TexEnv>
#include <osg/TexEnvCombine>
#include <osg/PolygonOffset>
#include <osg/BlendColor>
#include <osg/Depth>
#include <osg/LineWidth>
#include <osg/Point>
#include <osg/PointSprite>
#include <osg/Multisample>
#include <osg/SampleMaski>
#include <osg/ColorMaski>
#include <osg/BufferIndexBinding>
#include <osg/BufferTemplate>
#include <osg/observer_ptr>
#include <components/sceneutil/clusteredlighting.hpp>
namespace WebCuda
{
    namespace
    {
        // Only the render-submission thread assigns IDs. Weak ownership avoids
        // keeping unloaded cells' images alive; IDs are never reused, including
        // when an allocator reuses a destroyed image's address.
        struct ImageVersions
        {
            osg::observer_ptr<const osg::Image> image;
            std::map<unsigned int,std::pair<unsigned int,std::uint32_t>> formats;
        };
        std::map<const osg::Image*,ImageVersions> imageVersions;
        std::uint32_t nextImageVersion=0;
        unsigned int imageVersionLookups=0;
        std::uint32_t imageVersion(const osg::Image* image,unsigned int format)
        {
            if(++imageVersionLookups%1024==0)
                for(auto it=imageVersions.begin();it!=imageVersions.end();)
                    if(!it->second.image.valid())it=imageVersions.erase(it);else ++it;
            auto& versions=imageVersions[image];
            if(!versions.image.valid()) {versions.image=image;versions.formats.clear();}
            auto& version=versions.formats[format];
            if(!version.second||version.first!=image->getModifiedCount()) {
                if(nextImageVersion==std::numeric_limits<std::uint32_t>::max())
                    throw std::runtime_error("WebCuda image version identity exhausted");
                version={image->getModifiedCount(),++nextImageVersion};
            }
            return version.second;
        }
    }
    std::uint32_t MaterialTable::reserveAttachmentWords(std::uint64_t count)
    {
        if(!count||mAttachmentsResolved||texelWordCount()+count>0x7fffffffu)
            throw std::runtime_error("GPU attachment atlas exceeds relocatable index range");
        const auto address=0x80000000u|mAttachmentWords;
        mAttachmentWords+=static_cast<std::uint32_t>(count);
        return address;
    }

    void MaterialTable::resolveAttachmentAddresses()
    {
        if(mAttachmentsResolved)throw std::logic_error("Attachment addresses already resolved");
        if(texelWordCount()>0x7fffffffu)throw std::runtime_error("GPU texture atlas exceeds index range");
        const auto base=static_cast<std::uint32_t>(mTexels.size());
        const auto resolve=[&](std::uint32_t address) {
            if(!(address&0x80000000u)||(address&0x7fffffffu)>=mAttachmentWords)
                throw std::logic_error("Invalid deferred attachment address");
            return base+(address&0x7fffffffu);
        };
        for(const auto descriptor:mAttachmentDescriptors)mTexels.at(descriptor)=resolve(mTexels.at(descriptor));
        for(std::size_t i=1;i<mTextureCopies.size();i+=4)mTextureCopies[i]=resolve(mTextureCopies[i]);
        for(std::size_t i=0;i<mDepthMipSources.size();i+=2)mDepthMipSources[i]=resolve(mDepthMipSources[i]);
        for(std::size_t i=0;i<mMipGenerations.size();i+=4)if(mMipGenerations[i]&0x80000000u) {
            mMipGenerations[i]=resolve(mMipGenerations[i]);
            mMipGenerations[i+1]=resolve(mMipGenerations[i+1]);
        }
        mAttachmentsResolved=true;
    }

    std::shared_ptr<const MaterialTable> captureMaterialTable(std::shared_ptr<const MaterialTable> source)
    {
        if(!source)throw std::invalid_argument("Missing material snapshot source");
        if(!source->mAttachmentWords||source->mAttachmentsResolved)return source;
        CaptureScope captureScope(CapturePhase::MaterialCopy);
        // Clone only CPU data and metadata. No shadow/RTT pixel storage exists
        // here to initialize, clone, or transport from the WASM heap.
        auto snapshot=std::make_shared<MaterialTable>(*source);
        snapshot->resolveAttachmentAddresses();
        return snapshot;
    }

    std::uint32_t MaterialTable::encodeGlyph(const DrawContext& context,const osg::Texture2D* texture,bool redCoverage,bool distanceField,float glyphDimension,float textureDimension,const float* backdrop)
    {
        CaptureScope captureScope(CapturePhase::MaterialEncode);
        const auto base=encode(context,texture,true);
        std::array<std::uint32_t,12> record;
        std::copy_n(mMaterials.begin()+base*12,12,record.begin());
        record[3]|=524288u|(redCoverage?1048576u:0u)|(distanceField?2097152u:0u);
        const auto id=static_cast<std::uint32_t>(mMaterials.size()/12);
        mMaterials.insert(mMaterials.end(),record.begin(),record.end());copyRaster(base);
        mRasterParams[id*50u+28u]=glyphDimension;mRasterParams[id*50u+29u]=textureDimension;
        if(backdrop)std::copy_n(backdrop,7,mRasterParams.begin()+id*50u+30u);
        return id;
    }
    void MaterialTable::copyRaster(std::uint32_t material)
    {
        std::array<float,50> params;std::copy_n(mRasterParams.begin()+material*50,50,params.begin());
        mRasterParams.insert(mRasterParams.end(),params.begin(),params.end());
    }
    MaterialTable::MaterialTable(std::uint32_t width,std::uint32_t height):mWidth(width),mHeight(height)
    {
        if(!width || !height)throw std::invalid_argument("WebCuda material table needs a nonempty target");
    }
    std::uint32_t MaterialTable::encode(const DrawContext& context,const osg::Texture2D* guiTexture,bool gui)
    {
        CaptureScope captureScope(CapturePhase::MaterialEncode);
        if(mAttachmentsResolved)throw std::logic_error("Cannot extend a captured material snapshot");
        auto state=resolveState(context);
        // MyGUI has an explicit unlit texture/color contract. World GLSL programs
        // require a corresponding .cu material implementation, never a fallback.
        if(!gui)if(const auto* program=dynamic_cast<const osg::Program*>(state->getAttribute(osg::StateAttribute::PROGRAM))) {
            if(isBuiltinParticleProgram(*program)) {
                if(!context.particleDraw)throw std::runtime_error("Particle program requires particle vertex inputs");
                int unit=0;
                if(const auto* uniform=state->getUniform("baseTexture"))
                    if(!uniform->get(unit))throw std::runtime_error("Invalid particle texture unit");
                if(unit<0)throw std::runtime_error("Invalid particle texture unit");
                const auto* texture=dynamic_cast<const osg::Texture2D*>(state->getTextureAttribute(unit,osg::StateAttribute::TEXTURE));
                if(!texture)throw std::runtime_error("Built-in particle shader requires a 2D texture");
                return encode(context,texture,true);
            }
            bool debugVertex=false,debugFragment=false,outlineVertex=false,outlineFragment=false;
            bool skyVertex=false,skyFragment=false;
            bool groundcoverVertex=false;const osg::Shader* groundcoverFragment=nullptr;
            bool unlitVertex=false;const osg::Shader* unlitFragment=nullptr;
            bool bethesdaVertex=false;const osg::Shader* bethesdaFragment=nullptr;
            bool objectVertex=false;const osg::Shader* objectFragment=nullptr;
            bool terrainVertex=false,compositeVertex=false;const osg::Shader* terrainFragment=nullptr;const osg::Shader* compositeFragment=nullptr;
            bool shadowVertex=false;const osg::Shader* shadowFragment=nullptr;
            bool waterVertex=false;const osg::Shader* waterFragment=nullptr;
            bool depthVertex=false;const osg::Shader* depthFragment=nullptr;
            for(unsigned int i=0;i<program->getNumShaders();++i) {
                const auto* shader=program->getShader(i);const auto& name=shader->getName();
                auto ends=[&](const std::string& suffix){return name.size()>=suffix.size()&&name.compare(name.size()-suffix.size(),suffix.size(),suffix)==0;};
                debugVertex|=shader->getType()==osg::Shader::VERTEX&&ends("debug.vert");
                debugFragment|=shader->getType()==osg::Shader::FRAGMENT&&ends("debug.frag");
                outlineVertex|=shader->getType()==osg::Shader::VERTEX&&ends("outline.vert");
                outlineFragment|=shader->getType()==osg::Shader::FRAGMENT&&ends("outline.frag");
                skyVertex|=shader->getType()==osg::Shader::VERTEX&&ends("sky.vert");
                skyFragment|=shader->getType()==osg::Shader::FRAGMENT&&ends("sky.frag");
                groundcoverVertex|=shader->getType()==osg::Shader::VERTEX&&ends("groundcover.vert");
                if(shader->getType()==osg::Shader::FRAGMENT&&ends("groundcover.frag"))groundcoverFragment=shader;
                unlitVertex|=shader->getType()==osg::Shader::VERTEX&&ends("bs/nolighting.vert");
                if(shader->getType()==osg::Shader::FRAGMENT&&ends("bs/nolighting.frag"))unlitFragment=shader;
                bethesdaVertex|=shader->getType()==osg::Shader::VERTEX&&ends("bs/default.vert");
                if(shader->getType()==osg::Shader::FRAGMENT&&ends("bs/default.frag"))bethesdaFragment=shader;
                objectVertex|=shader->getType()==osg::Shader::VERTEX&&ends("objects.vert");
                if(shader->getType()==osg::Shader::FRAGMENT&&ends("objects.frag"))objectFragment=shader;
                terrainVertex|=shader->getType()==osg::Shader::VERTEX&&ends("terrain.vert");
                compositeVertex|=shader->getType()==osg::Shader::VERTEX&&ends("terrain_composite.vert");
                if(shader->getType()==osg::Shader::FRAGMENT&&ends("terrain.frag"))terrainFragment=shader;
                if(shader->getType()==osg::Shader::FRAGMENT&&ends("terrain_composite.frag"))compositeFragment=shader;
                shadowVertex|=shader->getType()==osg::Shader::VERTEX&&ends("shadowcasting.vert");
                if(shader->getType()==osg::Shader::FRAGMENT&&ends("shadowcasting.frag"))shadowFragment=shader;
                waterVertex|=shader->getType()==osg::Shader::VERTEX&&ends("water.vert");
                if(shader->getType()==osg::Shader::FRAGMENT&&ends("water.frag"))waterFragment=shader;
                depthVertex|=shader->getType()==osg::Shader::VERTEX&&ends("depthclipped.vert");
                if(shader->getType()==osg::Shader::FRAGMENT&&ends("depthclipped.frag"))depthFragment=shader;
            }
            if(program->getNumShaders()==2&&((debugVertex&&debugFragment)||(outlineVertex&&outlineFragment)))
                return encode(context,nullptr,true); // GPU vertex kernel supplies the untextured fragment color.
            if(skyVertex&&skyFragment&&program->getNumShaders()==2)return encodeSky(context,*state);
            if(groundcoverVertex&&groundcoverFragment&&program->getNumShaders()==2)return encodeObjects(context,*state,*groundcoverFragment,false,false,false,true);
            if(unlitVertex&&unlitFragment&&program->getNumShaders()==2)return encodeObjects(context,*state,*unlitFragment,false,false,false,false,true);
            if(bethesdaVertex&&bethesdaFragment&&program->getNumShaders()==2)return encodeObjects(context,*state,*bethesdaFragment,false,false,false,false,false,true);
            if(objectVertex&&objectFragment&&program->getNumShaders()==2)return encodeObjects(context,*state,*objectFragment);
            if(terrainVertex&&terrainFragment&&program->getNumShaders()==2)return encodeObjects(context,*state,*terrainFragment,true);
            if(compositeVertex&&compositeFragment&&program->getNumShaders()==2)return encodeObjects(context,*state,*compositeFragment,true,true);
            if(shadowVertex&&shadowFragment&&program->getNumShaders()==2)return encodeShadow(context,*state,*shadowFragment);
            if(waterVertex&&waterFragment&&program->getNumShaders()==2)return encodeObjects(context,*state,*waterFragment,false,false,true);
            if(depthVertex&&depthFragment&&program->getNumShaders()==2)return encodeShadow(context,*state,*depthFragment,true);
            throw std::runtime_error("WebCuda world shader material translation is not connected yet");
        }
        auto record=encodeRasterState(*state,mWidth,mHeight);
        if(mFloatingColor)record[3]&=~256u;
        if(!mHasDepth)record[3]&=~12u;
        if(mDepthOnly)record[9]|=15u<<17;
        const osg::Texture2D* texture=guiTexture;
        std::array<const osg::Texture2D*,4> fixedTextures{};
        unsigned int firstUnit=4;
        if(!gui) {
            for(unsigned int unit=0;unit<state->getNumTextureAttributeLists();++unit) {
                const auto mode=state->getTextureMode(unit,GL_TEXTURE_2D);
                if(mode!=osg::StateAttribute::INHERIT && !(mode&osg::StateAttribute::ON))continue;
                const auto* attribute=state->getTextureAttribute(unit,osg::StateAttribute::TEXTURE);
                if(!attribute)continue;
                const auto* active=dynamic_cast<const osg::Texture2D*>(attribute);
                if(!active)throw std::runtime_error("WebCuda non-2D texture needs a material implementation");
                if(unit>=fixedTextures.size())throw std::runtime_error("Fixed-function texture unit exceeds transported UV sets");
                fixedTextures[unit]=active;
                if(firstUnit==4)firstUnit=unit;
            }
            texture=firstUnit<4?fixedTextures[firstUnit]:nullptr;
        }
        if(texture) {
            const auto s=texture->getWrap(osg::Texture::WRAP_S),t=texture->getWrap(osg::Texture::WRAP_T);
            auto wrap=[](osg::Texture::WrapMode mode)->unsigned int {
                if(mode==osg::Texture::CLAMP_TO_EDGE||mode==osg::Texture::CLAMP)return 0;
                if(mode==osg::Texture::REPEAT)return 1;
                if(mode==osg::Texture::MIRROR)return 2;
                if(mode==osg::Texture::CLAMP_TO_BORDER)return 3;
                throw std::runtime_error("Unsupported texture wrap mode");
            };
            const auto min=texture->getFilter(osg::Texture::MIN_FILTER),mag=texture->getFilter(osg::Texture::MAG_FILTER);
            auto filter=[](osg::Texture::FilterMode mode)->unsigned int {
                switch(mode) {
                    case osg::Texture::NEAREST:return 0;case osg::Texture::LINEAR:return 1;
                    case osg::Texture::NEAREST_MIPMAP_NEAREST:return 2;case osg::Texture::LINEAR_MIPMAP_NEAREST:return 3;
                    case osg::Texture::NEAREST_MIPMAP_LINEAR:return 4;case osg::Texture::LINEAR_MIPMAP_LINEAR:return 5;
                    default:throw std::runtime_error("Unsupported WebCuda texture filter");
                }
            };
            if(mag!=osg::Texture::NEAREST&&mag!=osg::Texture::LINEAR)throw std::runtime_error("Invalid magnification filter");
            unsigned int levels=1;
            bool floatingImage=false;
            const auto* image=texture->getImage();
            const auto renderTarget=mRenderTexture?mRenderTexture(texture):0;
            if(renderTarget) {
                const unsigned int stride=(renderTarget&0x20000000u)?4u:1u;
                const auto width=texture->getTextureWidth(),height=texture->getTextureHeight();
                if(width<=0||height<=0)throw std::runtime_error("Invalid WebCuda render texture dimensions");
                const bool mipmapped=filter(min)>=2;
                std::array<std::uint32_t,5> key{renderTarget,static_cast<std::uint32_t>(width),static_cast<std::uint32_t>(height),
                    static_cast<std::uint32_t>(texture->getInternalFormat()),mipmapped?1u:0u};
                auto resource=mRenderImages.find(key);
                // A full chain can serve a later base-only sampler too.
                if(resource==mRenderImages.end()&&!mipmapped) {
                    auto full=key;full[4]=1;resource=mRenderImages.find(full);
                }
                if(resource==mRenderImages.end()) {
                const auto offset=reserveAttachmentWords(std::uint64_t(width)*height*stride);
                mTextureCopies.insert(mTextureCopies.end(),{renderTarget,offset,static_cast<std::uint32_t>(width),static_cast<std::uint32_t>(height)});
                if(renderTarget&0x80000000u) {
                    unsigned int depthBits=24;
                    const auto format=texture->getInternalFormat();
                    if(format==0x81A5)depthBits=16;
                    else if(format==0x8CAC||format==0x8CAD)depthBits=0;
                    else if(format!=0x81A6&&format!=0x88F0&&format!=GL_DEPTH_COMPONENT)
                        throw std::runtime_error("Unsupported depth mip storage format");
                    mDepthMipSources.insert(mDepthMipSources.end(),{offset,depthBits});
                }
                unsigned int w=width,h=height,previous=offset;
                while(mipmapped&&(w>1||h>1)) {
                    const auto dw=std::max(1u,w/2),dh=std::max(1u,h/2);
                    const auto destination=reserveAttachmentWords(std::uint64_t(dw)*dh*stride);
                    mMipGenerations.insert(mMipGenerations.end(),{previous,destination,w,h});
                    previous=destination;w=dw;h=dh;++levels;
                }
                resource=mRenderImages.emplace(key,std::array<std::uint32_t,2>{offset,levels}).first;
                }
                record[0]=resource->second[0];record[1]=width;record[2]=height;record[3]|=1;levels=resource->second[1];
            } else if(const auto* fog=dynamic_cast<const FogTexture*>(texture)) {
                const auto width=fog->getTextureWidth(),height=fog->getTextureHeight();
                const auto key=std::make_pair(texture,fog->revision);
                auto cached=mFogImages.find(key);
                if(cached==mFogImages.end()) {
                    const std::uint64_t count=std::uint64_t(width)*height,words=1u+count+fog->brushes.size()*3u;
                    if(width<=0||height<=0||count!=fog->saved.size()||mTexels.size()+count>std::numeric_limits<std::uint32_t>::max()
                        ||mCompressedBlocks.size()+words>std::numeric_limits<std::uint32_t>::max())throw std::runtime_error("Invalid fog texture capture");
                    const auto source=static_cast<std::uint32_t>(mCompressedBlocks.size()),destination=static_cast<std::uint32_t>(mTexels.size());
                    mCompressedBlocks.push_back(static_cast<unsigned int>(fog->brushes.size()));
                    mCompressedBlocks.insert(mCompressedBlocks.end(),fog->saved.begin(),fog->saved.end());
                    for(const auto& brush:fog->brushes)for(const float value:brush){std::uint32_t bits;std::memcpy(&bits,&value,4);mCompressedBlocks.push_back(bits);}
                    resizeAtlas(mTexels.size()+count);
                    mTextureDecodes.insert(mTextureDecodes.end(),{source,destination,static_cast<unsigned int>(width),static_cast<unsigned int>(height),258u});
                    cached=mFogImages.emplace(key,destination).first;
                }
                record[0]=cached->second;record[1]=width;record[2]=height;record[3]|=1;
            } else if(const auto* map=dynamic_cast<const MapTexture*>(texture)) {
                const auto width=map->getTextureWidth(),height=map->getTextureHeight();
                if(width<=0||height<=0||!map->data||map->data->size()<1027u)
                    throw std::runtime_error("Invalid CUDA map texture inputs");
                if(std::uint64_t((*map->data)[0])*(*map->data)[2]!=static_cast<unsigned int>(width)
                    ||std::uint64_t((*map->data)[1])*(*map->data)[2]!=static_cast<unsigned int>(height))
                    throw std::runtime_error("Map texture dimensions changed independently of source");
                auto sourceEntry=mMapSources.find(map->data);
                if(sourceEntry==mMapSources.end()) {
                    const auto& inputs=*map->data;
                    const std::uint64_t cx=inputs[0],cy=inputs[1],cell=inputs[2];
                    if(!cx||!cy||!cell||cx*cell!=static_cast<unsigned int>(width)||cy*cell!=static_cast<unsigned int>(height)
                        ||cx*cy>(std::numeric_limits<std::uint32_t>::max()-1027u)/81u||inputs.size()!=1027u+cx*cy*81u)
                        throw std::runtime_error("Map dimensions do not match land samples");
                    for(unsigned int i=3;i<1027;i++) {
                        float value;std::memcpy(&value,&inputs[i],4);
                        if(!std::isfinite(value))throw std::runtime_error("Non-finite map palette input");
                    }
                    for(std::size_t i=1027;i<inputs.size();i++)if(inputs[i]>255u)throw std::runtime_error("Invalid map land sample");
                    if(mCompressedBlocks.size()+inputs.size()>std::numeric_limits<std::uint32_t>::max())throw std::runtime_error("Map input atlas overflow");
                    const auto offset=static_cast<std::uint32_t>(mCompressedBlocks.size());
                    mCompressedBlocks.insert(mCompressedBlocks.end(),inputs.begin(),inputs.end());
                    sourceEntry=mMapSources.emplace(map->data,offset).first;
                }
                const std::array<std::uint32_t,4> key{sourceEntry->second,static_cast<unsigned int>(width),static_cast<unsigned int>(height),map->alphaOnly?1u:0u};
                auto generated=mMapImages.find(key);
                if(generated==mMapImages.end()) {
                    if(mTexels.size()+std::uint64_t(width)*height>std::numeric_limits<std::uint32_t>::max())throw std::runtime_error("Map output atlas overflow");
                    const auto destination=static_cast<std::uint32_t>(mTexels.size());
                    resizeAtlas(mTexels.size()+static_cast<std::size_t>(width)*height);
                    mTextureDecodes.insert(mTextureDecodes.end(),{key[0],destination,key[1],key[2],map->alphaOnly?257u:256u});
                    generated=mMapImages.emplace(key,destination).first;
                }
                record[0]=generated->second;record[1]=width;record[2]=height;record[3]|=1;
            } else {
            if(!image)throw std::runtime_error("WebCuda texture has no image or registered render target");
            const unsigned int internalFormat=texture->getInternalFormatMode()==osg::Texture::USE_USER_DEFINED_FORMAT
                ?texture->getInternalFormat():image->getInternalTextureFormat();
            const auto imageKey=std::make_pair(image,internalFormat);
            auto found=mImages.find(imageKey);
            if(found==mImages.end() || found->second.modified!=image->getModifiedCount()) {
                if(!image->data() || image->s()<=0 || image->t()<=0 || image->r()!=1)
                    throw std::runtime_error("WebCuda requires a populated 2D image");
                const auto width=static_cast<std::uint32_t>(image->s()),height=static_cast<std::uint32_t>(image->t());
                const auto pixelFormat=image->getPixelFormat();
                const bool byteCompatible=image->getDataType()==GL_UNSIGNED_BYTE&&(
                    ((pixelFormat==GL_RGBA||pixelFormat==GL_BGRA)&&(internalFormat==GL_RGBA||internalFormat==GL_RGBA8))
                    ||((pixelFormat==GL_RGB||pixelFormat==GL_BGR)&&(internalFormat==GL_RGB||internalFormat==GL_RGB8))
                    ||(pixelFormat==GL_LUMINANCE&&(internalFormat==GL_LUMINANCE||internalFormat==0x8040))
                    ||(pixelFormat==GL_LUMINANCE_ALPHA&&(internalFormat==GL_LUMINANCE_ALPHA||internalFormat==0x8045))
                    ||(pixelFormat==GL_ALPHA&&(internalFormat==GL_ALPHA||internalFormat==0x803C)));
                const bool compressedSRGB=image->isCompressed()&&(internalFormat>=0x8C4C&&internalFormat<=0x8C4F);
                const bool floating=compressedSRGB||(!image->isCompressed()&&!byteCompatible);
                const auto dataType=image->getDataType();
                const bool packed=dataType==GL_UNSIGNED_SHORT_5_6_5||dataType==GL_UNSIGNED_SHORT_5_6_5_REV
                    ||dataType==GL_UNSIGNED_SHORT_4_4_4_4||dataType==GL_UNSIGNED_SHORT_4_4_4_4_REV
                    ||dataType==GL_UNSIGNED_SHORT_5_5_5_1||dataType==GL_UNSIGNED_SHORT_1_5_5_5_REV
                    ||dataType==GL_UNSIGNED_INT_8_8_8_8||dataType==GL_UNSIGNED_INT_8_8_8_8_REV;
                if(floating&&!image->isCompressed()&&!packed&&image->getDataType()!=GL_FLOAT&&image->getDataType()!=0x140B
                    &&image->getDataType()!=0x8D61&&image->getDataType()!=GL_UNSIGNED_BYTE
                    &&image->getDataType()!=GL_BYTE&&image->getDataType()!=GL_UNSIGNED_SHORT
                    &&image->getDataType()!=GL_SHORT&&image->getDataType()!=GL_UNSIGNED_INT&&image->getDataType()!=GL_INT)
                    throw std::runtime_error("Unsupported image component data type");
                const bool depthImage=pixelFormat==GL_DEPTH_COMPONENT;
                const unsigned int stride=floating&&!depthImage?4u:1u;
                std::uint64_t pixelCount=0;
                unsigned int levelWidth=width,levelHeight=height;
                levels=0;
                do {pixelCount+=std::uint64_t(levelWidth)*levelHeight;++levels;
                    if(levelWidth==1&&levelHeight==1)break;
                    levelWidth=std::max(1u,levelWidth/2);levelHeight=std::max(1u,levelHeight/2);
                }while(true);
                if(mTexels.size()+pixelCount*stride>std::numeric_limits<std::uint32_t>::max())
                    throw std::runtime_error("WebCuda texture atlas exceeds index range");
                ImageRecord resource{image,image->getModifiedCount(),static_cast<std::uint32_t>(mTexels.size()),width,height,levels,floating&&!depthImage};
                resizeAtlas(mTexels.size()+pixelCount*stride);
                levelWidth=width;levelHeight=height;
                unsigned int destination=resource.offset,previous=resource.offset,previousWidth=width,previousHeight=height;
                for(unsigned int level=0;level<levels;++level) {
                if(level>=image->getNumMipmapLevels()) {
                    mMipGenerations.insert(mMipGenerations.end(),{previous,destination,previousWidth,previousHeight});
                } else {
                if(image->isCompressed()) {
                    unsigned int format=0;
                    switch(image->getPixelFormat()) {
                        case 0x83F0:case 0x8C4C:format=2;break; // GL_COMPRESSED_RGB_S3TC_DXT1_EXT
                        case 0x83F1:case 0x8C4D:format=1;break; // GL_COMPRESSED_RGBA_S3TC_DXT1_EXT
                        case 0x83F2:case 0x8C4E:format=3;break; // GL_COMPRESSED_RGBA_S3TC_DXT3_EXT
                        case 0x83F3:case 0x8C4F:format=5;break; // GL_COMPRESSED_RGBA_S3TC_DXT5_EXT
                        default:throw std::runtime_error("Unsupported WebCuda block compression format");
                    }
                    const auto words=std::uint64_t((levelWidth+3)/4)*((levelHeight+3)/4)*(format<=2?2:4);
                    if(image->getMipmapOffset(level)+words*4>image->getTotalSizeInBytesIncludingMipmaps()
                        || mCompressedBlocks.size()+words>std::numeric_limits<std::uint32_t>::max())
                        throw std::runtime_error("Invalid WebCuda compressed texture size");
                    const auto offset=static_cast<std::uint32_t>(mCompressedBlocks.size());
                    mCompressedBlocks.resize(mCompressedBlocks.size()+words);
                    std::memcpy(mCompressedBlocks.data()+offset,image->getMipmapData(level),words*4);
                    if(compressedSRGB)format|=65536u|((format==2?3u:4u)<<8)|(3u<<12);
                    mTextureDecodes.insert(mTextureDecodes.end(),{offset,destination,levelWidth,levelHeight,format});
                } else {
                    osg::ref_ptr<osg::Image> levelImage=new osg::Image;
                    levelImage->setImage(levelWidth,levelHeight,1,image->getInternalTextureFormat(),image->getPixelFormat(),
                        image->getDataType(),const_cast<unsigned char*>(image->getMipmapData(level)),osg::Image::NO_DELETE,image->getPacking());
                    if(level==0)levelImage->setRowLength(image->getRowLength());
                    if(floating) {
                        unsigned int format=0,channels=0;
                        switch(image->getPixelFormat()) {
                            case GL_RGBA:case 0x8C42:format=6;channels=4;break;
                            case GL_RGB:case 0x8C40:format=7;channels=3;break;
                            case 0x8227:format=8;channels=2;break; // GL_RG
                            case GL_RED:case GL_DEPTH_COMPONENT:format=9;channels=1;break;
                            case GL_LUMINANCE:format=10;channels=1;break;
                            case GL_LUMINANCE_ALPHA:format=11;channels=2;break;
                            case GL_ALPHA:format=12;channels=1;break;
                            case GL_BGRA:format=13;channels=4;break;
                            case GL_BGR:format=14;channels=3;break;
                            default:throw std::runtime_error("Unsupported floating image pixel format "+std::to_string(image->getPixelFormat())+" in "+image->getFileName());
                        }
                        unsigned int componentBytes=4,componentFamily=0;
                        switch(image->getDataType()) {
                            case GL_FLOAT:break;
                            case 0x140B:case 0x8D61:componentFamily=1;componentBytes=2;break;
                            case GL_UNSIGNED_BYTE:componentFamily=2;componentBytes=1;break;
                            case GL_UNSIGNED_SHORT:componentFamily=3;componentBytes=2;break;
                            case GL_BYTE:componentFamily=4;componentBytes=1;break;
                            case GL_SHORT:componentFamily=5;componentBytes=2;break;
                            case GL_UNSIGNED_INT:componentFamily=6;break;
                            case GL_INT:componentFamily=7;break;
                            case GL_UNSIGNED_SHORT_5_6_5:componentFamily=8;componentBytes=2;break;
                            case GL_UNSIGNED_SHORT_5_6_5_REV:componentFamily=9;componentBytes=2;break;
                            case GL_UNSIGNED_SHORT_4_4_4_4:componentFamily=10;componentBytes=2;break;
                            case GL_UNSIGNED_SHORT_4_4_4_4_REV:componentFamily=11;componentBytes=2;break;
                            case GL_UNSIGNED_SHORT_5_5_5_1:componentFamily=12;componentBytes=2;break;
                            case GL_UNSIGNED_SHORT_1_5_5_5_REV:componentFamily=13;componentBytes=2;break;
                            case GL_UNSIGNED_INT_8_8_8_8:componentFamily=14;break;
                            case GL_UNSIGNED_INT_8_8_8_8_REV:componentFamily=15;break;
                            default:throw std::runtime_error("Unsupported image component type");
                        }
                        if(packed&&((componentFamily<=9&&(format!=7&&format!=14))
                            ||(componentFamily>=10&&(format!=6&&format!=13))))
                            throw std::runtime_error("Packed image type does not match pixel layout");
                        format+=componentFamily*16;
                        const std::uint64_t rowBytes=std::uint64_t(levelWidth)*(packed?1:channels)*componentBytes;
                        const auto words=(rowBytes*levelHeight+3)/4;
                        const auto rowStep=levelImage->getRowStepInBytes();
                        const auto end=std::uint64_t(image->getMipmapOffset(level))+std::uint64_t(levelHeight-1)*rowStep+rowBytes;
                        if(end>image->getTotalSizeInBytesIncludingMipmaps()||mCompressedBlocks.size()+words>std::numeric_limits<std::uint32_t>::max())
                            throw std::runtime_error("Invalid floating image byte range");
                        const auto offset=static_cast<std::uint32_t>(mCompressedBlocks.size());
                        mCompressedBlocks.resize(mCompressedBlocks.size()+words,0);
                        auto* bytes=reinterpret_cast<unsigned char*>(mCompressedBlocks.data()+offset);
                        for(unsigned int y=0;y<levelHeight;y++)
                            std::memcpy(bytes+y*rowBytes,levelImage->data(0,y),rowBytes);
                        unsigned int storage=0,destinationChannels=0;
                        switch(internalFormat) {
                            case 0x8CAC:destinationChannels=9;storage=0;break; // DEPTH_COMPONENT32F, scalar atlas
                            case 0x81A5:destinationChannels=9;storage=1;break; // DEPTH_COMPONENT16
                            case GL_DEPTH_COMPONENT:case 0x81A6:destinationChannels=9;storage=2;break;
                            case GL_RGBA:case GL_RGBA8:destinationChannels=4;break;
                            case GL_RGB:case GL_RGB8:destinationChannels=3;break;
                            case 0x1903:case 0x8229:destinationChannels=1;break;
                            case 0x8227:case 0x822B:destinationChannels=2;break;
                            case GL_LUMINANCE:case 0x8040:destinationChannels=5;break;
                            case GL_LUMINANCE_ALPHA:case 0x8045:destinationChannels=6;break;
                            case GL_ALPHA:case 0x803C:destinationChannels=7;break;
                            case 0x8049:case 0x804B:destinationChannels=8;break; // INTENSITY / INTENSITY8
                            case 0x822A:destinationChannels=1;storage=4;break; // R16
                            case 0x822C:destinationChannels=2;storage=4;break; // RG16
                            case 0x8054:destinationChannels=3;storage=4;break; // RGB16
                            case 0x805B:destinationChannels=4;storage=4;break; // RGBA16
                            case 0x8042:destinationChannels=5;storage=4;break; // LUMINANCE16
                            case 0x8048:destinationChannels=6;storage=4;break; // LUMINANCE16_ALPHA16
                            case 0x803E:destinationChannels=7;storage=4;break; // ALPHA16
                            case 0x804D:destinationChannels=8;storage=4;break; // INTENSITY16
                            case 0x8F94:destinationChannels=1;storage=5;break; // R8_SNORM
                            case 0x8F95:destinationChannels=2;storage=5;break;
                            case 0x8F96:destinationChannels=3;storage=5;break;
                            case 0x8F97:destinationChannels=4;storage=5;break;
                            case 0x8F98:destinationChannels=1;storage=6;break; // R16_SNORM
                            case 0x8F99:destinationChannels=2;storage=6;break;
                            case 0x8F9A:destinationChannels=3;storage=6;break;
                            case 0x8F9B:destinationChannels=4;storage=6;break;
                            case 0x822D:destinationChannels=1;storage=1;break;
                            case 0x822F:destinationChannels=2;storage=1;break;
                            case GL_RGB16F_ARB:destinationChannels=3;storage=1;break;
                            case GL_RGBA16F_ARB:destinationChannels=4;storage=1;break;
                            case 0x822E:destinationChannels=1;storage=2;break;
                            case 0x8230:destinationChannels=2;storage=2;break;
                            case GL_RGB32F_ARB:destinationChannels=3;storage=2;break;
                            case GL_RGBA32F_ARB:destinationChannels=4;storage=2;break;
                            case 0x8C40:case 0x8C41:destinationChannels=3;storage=3;break; // SRGB/SRGB8
                            case 0x8C42:case 0x8C43:destinationChannels=4;storage=3;break; // SRGB_ALPHA/SRGB8_ALPHA8
                            default:throw std::runtime_error("Unsupported floating image internal storage format");
                        }
                        format|=65536u|(destinationChannels<<8)|(storage<<12);
                        mTextureDecodes.insert(mTextureDecodes.end(),{offset,destination,levelWidth,levelHeight,format});
                    } else {
                        auto pixels=copyTexturePixels(*levelImage);
                        std::copy(pixels.rgba.begin(),pixels.rgba.end(),mTexels.begin()+destination);
                    }
                }
                }
                previous=destination;previousWidth=levelWidth;previousHeight=levelHeight;
                destination+=levelWidth*levelHeight*stride;
                levelWidth=std::max(1u,levelWidth/2);levelHeight=std::max(1u,levelHeight/2);
                }
                mTextureResources.insert(mTextureResources.end(),{imageVersion(image,internalFormat),resource.offset,
                    static_cast<std::uint32_t>(pixelCount*stride)});
                found=mImages.insert_or_assign(imageKey,resource).first;
            }
            record[0]=found->second.offset;record[1]=found->second.width;record[2]=found->second.height;
            record[3]|=1;
            levels=found->second.levels;floatingImage=found->second.floating;
            }
            record[3]|=512;
            record[11]=(levels-1)|(filter(min)<<5)|((mag==osg::Texture::LINEAR?1u:0u)<<8)|(wrap(s)<<9)|(wrap(t)<<11);
            if(s==osg::Texture::CLAMP)record[11]|=1u<<30;
            if(t==osg::Texture::CLAMP)record[11]|=1u<<31;
            if((renderTarget&0x80000000u)||(image&&image->getPixelFormat()==GL_DEPTH_COMPONENT))record[11]|=8192;
            if((renderTarget&0x20000000u)||floatingImage)record[11]|=32768;
            const auto& swizzle=texture->getSwizzle();
            if(swizzle!=osg::Vec4i(GL_RED,GL_GREEN,GL_BLUE,GL_ALPHA)) {
                record[11]|=1u<<28;
                for(unsigned int channel=0;channel<4;channel++) {
                    unsigned int code;
                    switch(swizzle[channel]) {
                        case GL_RED:code=0;break;case GL_GREEN:code=1;break;
                        case GL_BLUE:code=2;break;case GL_ALPHA:code=3;break;
                        case GL_ZERO:code=4;break;case GL_ONE:code=5;break;
                        default:throw std::runtime_error("Unsupported texture channel swizzle");
                    }
                    record[11]|=code<<(16+channel*3);
                }
            }
            const float minimumLOD=texture->getMinLOD(),maximumLOD=texture->getMaxLOD(),biasLOD=texture->getLODBias();
            if(!std::isfinite(minimumLOD)||!std::isfinite(maximumLOD)||!std::isfinite(biasLOD))
                throw std::runtime_error("Non-finite texture LOD state");
            const bool limitedLOD=maximumLOD>=minimumLOD;
            const float anisotropy=texture->getMaxAnisotropy();
            if(!std::isfinite(anisotropy)||anisotropy<1.f)throw std::runtime_error("Invalid texture anisotropy");
            if(renderTarget||s==osg::Texture::CLAMP_TO_BORDER||t==osg::Texture::CLAMP_TO_BORDER
                ||s==osg::Texture::CLAMP||t==osg::Texture::CLAMP||limitedLOD||biasLOD!=0.f||anisotropy>1.f) {
                // Indirection keeps border state independent of shared image storage.
                std::array<std::uint32_t,10> descriptor{record[0]};
                std::memcpy(&descriptor[9],&anisotropy,4);
                const float lodState[]{limitedLOD?minimumLOD:-1000.f,limitedLOD?maximumLOD:1000.f,biasLOD};
                for(unsigned int k=0;k<3;k++)std::memcpy(&descriptor[6+k],&lodState[k],4);
                const unsigned int internal=texture->getInternalFormatMode()==osg::Texture::USE_USER_DEFINED_FORMAT
                    ?texture->getInternalFormat():(image?image->getInternalTextureFormat():texture->getInternalFormat());
                switch(internal) {
                    case 0x1903:case 0x8229:case 0x822A:case 0x822D:case 0x822E:descriptor[5]=1;break;
                    case 0x8227:case 0x822B:case 0x822C:case 0x822F:case 0x8230:descriptor[5]=2;break;
                    case GL_RGB:case GL_RGB8:case 0x8054:case GL_RGB16F_ARB:case GL_RGB32F_ARB:
                    case 0x8C40:case 0x8C41:case 0x83F0:case 0x8C4C:descriptor[5]=3;break;
                    case GL_LUMINANCE:case 0x8040:case 0x8042:descriptor[5]=4;break;
                    case GL_LUMINANCE_ALPHA:case 0x8045:case 0x8048:descriptor[5]=5;break;
                    case GL_ALPHA:case 0x803C:case 0x803E:descriptor[5]=6;break;
                    case 0x8049:case 0x804B:case 0x804D:descriptor[5]=7;break;
                    default:break;
                }
                if(internal>=0x8F94&&internal<=0x8F9B)descriptor[5]=16u|((internal-0x8F94+1u)%4u);
                if(internal==0x822D||internal==0x822F||internal==GL_RGB16F_ARB||internal==GL_RGBA16F_ARB)descriptor[5]|=32u;
                if(internal==0x822E||internal==0x8230||internal==GL_RGB32F_ARB||internal==GL_RGBA32F_ARB)descriptor[5]|=48u;
                if(internal==0x8CAC||internal==0x8CAD)descriptor[5]=49u; // Float32 depth, red component.
                const auto& border=texture->getBorderColor();
                for(unsigned int channel=0;channel<4;channel++) {
                    const float value=border[channel];
                    if(!std::isfinite(value))throw std::runtime_error("Non-finite texture border color");
                    std::memcpy(&descriptor[channel+1],&value,sizeof(value));
                }
                auto found=mBorderDescriptors.find(descriptor);
                if(found==mBorderDescriptors.end()) {
                    if(mTexels.size()>std::numeric_limits<std::uint32_t>::max()-descriptor.size())
                        throw std::runtime_error("Texture border descriptor exceeds atlas range");
                    const auto offset=static_cast<std::uint32_t>(mTexels.size());
                    mTexels.insert(mTexels.end(),descriptor.begin(),descriptor.end());
                    if(renderTarget)mAttachmentDescriptors.push_back(offset);
                    found=mBorderDescriptors.emplace(descriptor,offset).first;
                }
                record[0]=found->second;
                record[11]|=1u<<29;
            }
            if(s==osg::Texture::REPEAT)record[3]|=16;
            if(min==osg::Texture::LINEAR)record[3]|=32;
        }
        if(texture&&!gui) {
            // Link stages in texture-unit order. Recursive host encoding only
            // acquires image/sampler resources; stage arithmetic stays in .cu.
            unsigned int next=0;
            for(int unit=3;unit>=0;--unit) {
            texture=fixedTextures[unit];
            if(!texture)continue;
            auto stage=record;
            if(static_cast<unsigned int>(unit)!=firstUnit) {
                const auto id=encode(context,texture,true);
                std::copy_n(mMaterials.begin()+id*12,12,stage.begin());
            }
            std::array<std::uint32_t,44> environment{stage[0]};
            environment[3]=next;
            environment[24]=stage[1];environment[25]=stage[2];
            environment[26]=stage[11];environment[27]=unit;
            const auto* texmat=dynamic_cast<const osg::TexMat*>(state->getTextureAttribute(unit,osg::StateAttribute::TEXMAT));
            const bool replaced=context.pointDraw&&(state->getMode(0x8861)&osg::StateAttribute::ON)!=0
                &&state->getTextureAttribute(unit,osg::StateAttribute::POINTSPRITE);
            const osg::Matrix matrix=texmat&&!replaced?texmat->getMatrix():osg::Matrix::identity();
            for(unsigned int k=0;k<16;k++) {
                const float value=static_cast<float>(matrix.ptr()[k]);
                if(!std::isfinite(value))throw std::runtime_error("Non-finite fixed-function texture matrix");
                std::memcpy(&environment[28+k],&value,4);
            }
            const auto* attribute=state->getTextureAttribute(unit,osg::StateAttribute::TEXENV);
            if(const auto* env=dynamic_cast<const osg::TexEnv*>(attribute)) {
                switch(env->getMode()) {
                    case osg::TexEnv::MODULATE:break;
                    case osg::TexEnv::REPLACE:environment[1]=1;break;
                    case osg::TexEnv::DECAL:environment[1]=2;break;
                    case osg::TexEnv::BLEND:environment[1]=3;break;
                    case osg::TexEnv::ADD:environment[1]=4;break;
                    default:throw std::runtime_error("Unsupported texture environment mode");
                }
                for(unsigned int channel=0;channel<4;channel++) {
                    const float value=std::clamp(env->getColor()[channel],0.f,1.f);
                    if(!std::isfinite(value))throw std::runtime_error("Non-finite texture environment color");
                    std::memcpy(&environment[4+channel],&value,4);
                }
            } else if(const auto* combine=dynamic_cast<const osg::TexEnvCombine*>(attribute)) {
                environment[1]=5;
                auto operation=[](int value)->unsigned int {
                    switch(value) {
                        case osg::TexEnvCombine::REPLACE:return 0;case osg::TexEnvCombine::MODULATE:return 1;
                        case osg::TexEnvCombine::ADD:return 2;case osg::TexEnvCombine::ADD_SIGNED:return 3;
                        case osg::TexEnvCombine::INTERPOLATE:return 4;case osg::TexEnvCombine::SUBTRACT:return 5;
                        case osg::TexEnvCombine::DOT3_RGB:return 6;case osg::TexEnvCombine::DOT3_RGBA:return 7;
                        default:throw std::runtime_error("Unsupported texture combine operation");
                    }
                };
                auto source=[&](int value)->unsigned int {
                    if(value>=0x84C0&&value<0x84C4) {
                        const auto referenced=static_cast<unsigned int>(value-0x84C0);
                        if(!fixedTextures[referenced])throw std::runtime_error("Texture combiner references a disabled unit");
                        return 4+referenced;
                    }
                    switch(value) {
                        case osg::TexEnvCombine::TEXTURE:return 0;
                        case osg::TexEnvCombine::PRIMARY_COLOR:return 1;case osg::TexEnvCombine::CONSTANT:return 2;
                        case osg::TexEnvCombine::PREVIOUS:return 3;
                        default:throw std::runtime_error("Texture combiner source exceeds transported texture units");
                    }
                };
                auto operand=[](int value)->unsigned int {
                    switch(value) {
                        case GL_SRC_COLOR:return 0;case GL_ONE_MINUS_SRC_COLOR:return 1;
                        case GL_SRC_ALPHA:return 2;case GL_ONE_MINUS_SRC_ALPHA:return 3;
                        default:throw std::runtime_error("Unsupported texture combine operand");
                    }
                };
                auto scale=[](float value)->unsigned int {
                    if(value!=1.f&&value!=2.f&&value!=4.f)throw std::runtime_error("Invalid texture combine scale");
                    return static_cast<unsigned int>(value);
                };
                environment[8]=operation(combine->getCombine_RGB());environment[9]=operation(combine->getCombine_Alpha());
                if(environment[9]>5)throw std::runtime_error("Dot texture combine is only valid for RGB");
                environment[10]=scale(combine->getScale_RGB());environment[11]=scale(combine->getScale_Alpha());
                const int sources[]{combine->getSource0_RGB(),combine->getSource1_RGB(),combine->getSource2_RGB(),
                    combine->getSource0_Alpha(),combine->getSource1_Alpha(),combine->getSource2_Alpha()};
                const int operands[]{combine->getOperand0_RGB(),combine->getOperand1_RGB(),combine->getOperand2_RGB(),
                    combine->getOperand0_Alpha(),combine->getOperand1_Alpha(),combine->getOperand2_Alpha()};
                for(unsigned int i=0;i<6;i++) {
                    const auto offset=i<3?12+i:18+i-3;
                    environment[offset]=source(sources[i]);environment[offset+3]=operand(operands[i]);
                    if(i>=3&&environment[offset+3]<2)throw std::runtime_error("Invalid alpha combine operand");
                }
                for(unsigned int channel=0;channel<4;channel++) {
                    const float raw=combine->getConstantColor()[channel];
                    if(!std::isfinite(raw))throw std::runtime_error("Non-finite combine constant");
                    const float value=std::clamp(raw,0.f,1.f);std::memcpy(&environment[4+channel],&value,4);
                }
            } else if(attribute)throw std::runtime_error("Unsupported texture environment attribute");
            const auto* image=texture->getImage();
            const auto format=texture->getInternalFormatMode()==osg::Texture::USE_USER_DEFINED_FORMAT
                ?texture->getInternalFormat():(image?image->getInternalTextureFormat():texture->getInternalFormat());
            // Base-format rules determine whether alpha or RGB participates.
            switch(format) {
                case GL_RGB:case GL_RGB8:case GL_RGB16F_ARB:case GL_RGB32F_ARB:case 0x8054:case 0x8F96:case 0x8F9A:case GL_LUMINANCE:case 0x8040:case 0x8042:
                case 0x8C40:case 0x8C41:case 0x83F0:case 0x8C4C:environment[2]=1;break;
                case GL_ALPHA:case 0x803C:case 0x803E:environment[2]=2;break;
                case 0x8049:case 0x804B:case 0x804D:environment[2]=3;break;
                default:break;
            }
            auto found=mTextureEnvironments.find(environment);
            if(found==mTextureEnvironments.end()) {
                if(mTexels.size()>std::numeric_limits<std::uint32_t>::max()-environment.size())throw std::runtime_error("Texture environment exceeds atlas range");
                const auto offset=static_cast<std::uint32_t>(mTexels.size());
                mTexels.insert(mTexels.end(),environment.begin(),environment.end());
                found=mTextureEnvironments.emplace(environment,offset).first;
            }
            next=found->second;
            }
            record[0]=next;record[3]|=16384u;
        }
        std::array<float,50> params{0,0,0,1,0,0,0,0};
        params[37]=1.f;params[38]=1.f;
        if(const auto* line=dynamic_cast<const osg::LineWidth*>(state->getAttribute(osg::StateAttribute::LINEWIDTH)))params[37]=line->getWidth();
        params[49]=((state->getMode(GL_POINT_SMOOTH)&osg::StateAttribute::ON)!=0?1.f:0.f)
            +((state->getMode(0x8861)&osg::StateAttribute::ON)!=0?2.f:0.f)
            +((state->getMode(GL_LINE_SMOOTH)&osg::StateAttribute::ON)!=0?128.f:0.f);
        if(!state->getAttribute(osg::StateAttribute::PROGRAM)&&(static_cast<unsigned int>(params[49])&2u)!=0u) {
            unsigned int spriteFlags=static_cast<unsigned int>(params[49]);
            for(unsigned int unit=0;unit<state->getTextureAttributeList().size();unit++) {
                const auto* sprite=dynamic_cast<const osg::PointSprite*>(state->getTextureAttribute(unit,osg::StateAttribute::POINTSPRITE));
                if(!sprite)continue;
                if(unit>3)throw std::runtime_error("Polygon point sprite texture unit exceeds UV packet");
                spriteFlags|=1u<<(unit+2u);
                if(sprite->getCoordOriginMode()==osg::PointSprite::LOWER_LEFT)spriteFlags|=64u;
                else if(sprite->getCoordOriginMode()==osg::PointSprite::UPPER_LEFT)spriteFlags&=~64u;
                else throw std::runtime_error("Invalid polygon point sprite origin");
            }
            params[49]=static_cast<float>(spriteFlags);
        }
        params[43]=0.f;params[44]=64.f;params[45]=1.f;params[46]=1.f;
        if(const auto* point=dynamic_cast<const osg::Point*>(state->getAttribute(osg::StateAttribute::POINT))) {
            params[38]=point->getSize();params[43]=point->getMinSize();params[44]=point->getMaxSize();
            params[45]=point->getFadeThresholdSize();
            for(unsigned int k=0;k<3;k++)params[46+k]=point->getDistanceAttenuation()[k];
        }
        for(unsigned int k=43;k<49;k++)if(!std::isfinite(params[k])||params[k]<0.f)
            throw std::runtime_error("Invalid polygon point parameters");
        if(params[44]<params[43])throw std::runtime_error("Invalid polygon point size range");
        if(!std::isfinite(params[37])||!std::isfinite(params[38])||params[37]<=0.f||params[38]<=0.f)
            throw std::runtime_error("Invalid polygon line/point size");
        if(const auto* offset=dynamic_cast<const osg::PolygonOffset*>(state->getAttribute(osg::StateAttribute::POLYGONOFFSET))) {
            for(unsigned int face=0;face<2;face++) {
                const unsigned int mode=(record[9]>>(27u+face*2u))&3u;
                const auto capability=mode==1u?GL_POLYGON_OFFSET_LINE:mode==2u?GL_POLYGON_OFFSET_POINT:GL_POLYGON_OFFSET_FILL;
                if((state->getMode(capability)&osg::StateAttribute::ON)!=0) {
                    params[39+face*2]=offset->getFactor();params[40+face*2]=offset->getUnits();
                }
            }
        }
        // Sample coverage is shader input; sample selection remains GPU work.
        params[24]=1.f;
        params[26]=65535.f; // Supported targets have at most 16 samples.
        if((state->getMode(0x8E51)&osg::StateAttribute::ON)!=0)
            if(const auto* mask=dynamic_cast<const osg::SampleMaski*>(state->getAttribute(osg::StateAttribute::SAMPLEMASKI)))
                params[26]=static_cast<float>(mask->getMask()&65535u);
        // Unlike most GL capabilities, MULTISAMPLE defaults to enabled.
        const auto multisampleMode=state->getMode(0x809D);
        params[27]=(multisampleMode&osg::StateAttribute::INHERIT)!=0
            ||(multisampleMode&osg::StateAttribute::ON)!=0?1.f:0.f;
        if((state->getMode(0x80A0)&osg::StateAttribute::ON)!=0) {
            if(const auto* samples=dynamic_cast<const osg::Multisample*>(state->getAttribute(osg::StateAttribute::MULTISAMPLE))) {
                if(!std::isfinite(samples->getCoverage()))throw std::runtime_error("Non-finite sample coverage");
                params[24]=std::clamp(samples->getCoverage(),0.f,1.f);
                params[25]=samples->getInvert()?1.f:0.f;
            }
        }
        if(!gui&&(state->getMode(GL_FOG)&osg::StateAttribute::ON)!=0) {
            osg::ref_ptr<osg::Fog> defaultFog=new osg::Fog;
            const auto* fog=dynamic_cast<const osg::Fog*>(state->getAttribute(osg::StateAttribute::FOG));
            if(!fog)fog=defaultFog.get();
            std::array<std::uint32_t,9> data{};
            switch(fog->getMode()) {
                case osg::Fog::LINEAR:data[0]=0;break;
                case osg::Fog::EXP:data[0]=1;break;
                case osg::Fog::EXP2:data[0]=2;break;
                default:throw std::runtime_error("Unsupported fog mode");
            }
            if(fog->getUseRadialFog())data[0]|=4;
            if(fog->getFogCoordinateSource()==osg::Fog::FOG_COORDINATE) {
                data[0]|=8;
                if(context.particleDraw) {
                    // Particle drawables leave the current fog coordinate unchanged.
                    // Keep it separate from overloaded particle vertex attributes.
                    if(!std::isfinite(context.currentFogCoordinate))throw std::runtime_error("Non-finite particle fog coordinate");
                    data[0]|=16;
                    std::memcpy(&data[8],&context.currentFogCoordinate,4);
                }
            } else if(fog->getFogCoordinateSource()!=osg::Fog::FRAGMENT_DEPTH)
                throw std::runtime_error("Invalid fog coordinate source");
            if(fog->getDensity()<0)throw std::runtime_error("Negative fog density");
            const float values[]{fog->getDensity(),fog->getStart(),fog->getEnd(),fog->getColor().r(),fog->getColor().g(),fog->getColor().b(),fog->getColor().a()};
            for(unsigned int i=0;i<7;i++) {
                if(!std::isfinite(values[i]))throw std::runtime_error("Non-finite fog parameter");
                const float value=i>=3?std::clamp(values[i],0.f,1.f):values[i];std::memcpy(&data[i+1],&value,4);
            }
            auto found=mFogRecords.find(data);
            if(found==mFogRecords.end()) {
                if(mTexels.size()>std::numeric_limits<std::uint32_t>::max()-data.size())throw std::runtime_error("Fog descriptor exceeds atlas range");
                const auto offset=static_cast<std::uint32_t>(mTexels.size());
                mTexels.insert(mTexels.end(),data.begin(),data.end());found=mFogRecords.emplace(data,offset).first;
            }
            // Opaque pointer bits: no floating-point arithmetic may touch this slot.
            std::memcpy(&params[23],&found->second,4);record[3]|=32768u;
        }
        // Indexed mask 1 belongs to the normal attachment. A non-indexed
        // ColorMask affects all attachments; indexed mask 0 affects only color.
        const auto* normalMask=dynamic_cast<const osg::ColorMask*>(state->getAttribute(osg::StateAttribute::COLORMASK,1));
        if(!normalMask) {
            const auto* global=state->getAttribute(osg::StateAttribute::COLORMASK);
            if(!dynamic_cast<const osg::ColorMaski*>(global))normalMask=dynamic_cast<const osg::ColorMask*>(global);
        }
        if(normalMask)params[22]=(!normalMask->getRedMask()?1u:0u)|(!normalMask->getGreenMask()?2u:0u)
            |(!normalMask->getBlueMask()?4u:0u)|(!normalMask->getAlphaMask()?8u:0u);
        const auto stencil=encodeStencilState(*state);std::copy(stencil.begin(),stencil.end(),params.begin()+8);
        if(const auto* blend=dynamic_cast<const osg::BlendColor*>(state->getAttribute(osg::StateAttribute::BLENDCOLOR)))
            for(unsigned int channel=0;channel<4;channel++)params[4+channel]=std::clamp(blend->getConstantColor()[channel],0.f,1.f);
        if((state->getMode(GL_POLYGON_OFFSET_FILL)&osg::StateAttribute::ON)!=0)
            if(const auto* offset=dynamic_cast<const osg::PolygonOffset*>(state->getAttribute(osg::StateAttribute::POLYGONOFFSET))) {params[0]=offset->getFactor();params[1]=offset->getUnits();}
        if(const auto* depth=dynamic_cast<const osg::Depth*>(state->getAttribute(osg::StateAttribute::DEPTH))) {params[2]=std::clamp(float(depth->getZNear()),0.f,1.f);params[3]=std::clamp(float(depth->getZFar()),0.f,1.f);}
        if(context.screenPrimitiveDraw)record[3]|=4194304u;
        std::array<std::uint32_t,62> key{};std::copy(record.begin(),record.end(),key.begin());std::memcpy(key.data()+12,params.data(),sizeof(params));
        auto found=mRecords.find(key);
        if(found!=mRecords.end())return found->second;
        if(mMaterials.size()/12>=std::numeric_limits<std::uint32_t>::max())throw std::runtime_error("WebCuda material table overflow");
        auto id=static_cast<std::uint32_t>(mMaterials.size()/12);
        mMaterials.insert(mMaterials.end(),record.begin(),record.end());mRasterParams.insert(mRasterParams.end(),params.begin(),params.end());mRecords.emplace(key,id);
        return id;
    }
    std::uint32_t MaterialTable::captureClusterLights(const DrawContext& context,const osg::StateSet& state)
    {
        const auto* binding=dynamic_cast<const osg::ShaderStorageBufferBinding*>(state.getAttribute(osg::StateAttribute::SHADERSTORAGEBUFFERBINDING,2));
        using LightBuffer=osg::BufferTemplate<std::vector<SceneUtil::PointLight>>;
        const auto* buffer=binding?dynamic_cast<const LightBuffer*>(binding->getBufferData()):nullptr;
        if(!buffer||!context.projection)throw std::runtime_error("Missing clustered light snapshot inputs");
        const auto& lights=buffer->getData();const auto bytes=lights.size()*sizeof(SceneUtil::PointLight);
        if(binding->getOffset()<0||binding->getSize()<0)throw std::runtime_error("Negative clustered buffer range");
        const auto offset=static_cast<std::size_t>(binding->getOffset());
        const auto size=binding->getSize()?static_cast<std::size_t>(binding->getSize()):bytes;
        if(offset>bytes||size>bytes-offset||offset%sizeof(SceneUtil::PointLight)||size%sizeof(SceneUtil::PointLight))
            throw std::runtime_error("Invalid clustered buffer range");
        const auto count=size/sizeof(SceneUtil::PointLight),first=offset/sizeof(SceneUtil::PointLight);
        if(count>std::numeric_limits<std::uint32_t>::max())throw std::runtime_error("Clustered light count overflow");
        osg::Vec3 grid;osg::Vec2 screen;float nearDistance=0.f,farDistance=0.f;
        const auto* gu=state.getUniform("gridSize");const auto* su=state.getUniform("screenRes");
        const auto* nu=state.getUniform("near");const auto* fu=state.getUniform("clusterFar");
        if(!gu||!gu->get(grid)||!su||!su->get(screen)||!nu||!nu->get(nearDistance)||!fu||!fu->get(farDistance))
            throw std::runtime_error("Missing clustered camera uniforms");
        if(!std::isfinite(nearDistance)||!std::isfinite(farDistance)||nearDistance<=0.f||farDistance<=nearDistance)
            throw std::runtime_error("Invalid clustered camera depth range");
        auto bits=[](float value) {
            if(!std::isfinite(value))throw std::runtime_error("Non-finite clustered light input");
            std::uint32_t result;std::memcpy(&result,&value,4);return result;
        };
        std::vector<std::uint32_t> key(10);key[1]=static_cast<std::uint32_t>(count);
        for(unsigned int axis=0;axis<3;axis++) {
            const double value=grid[axis];
            if(!std::isfinite(value)||value<1||value>std::numeric_limits<std::uint32_t>::max()||std::floor(value)!=value)
                throw std::runtime_error("Invalid clustered grid dimensions");
            key[2+axis]=static_cast<std::uint32_t>(value);
        }
        key[5]=bits(nearDistance);key[6]=bits(farDistance);
        for(unsigned int axis=0;axis<2;axis++) {
            if(screen[axis]<=0.f)throw std::runtime_error("Invalid clustered screen dimensions");
            key[8+axis]=bits(screen[axis]);
        }
        std::vector<float> projection,packed;projection.reserve(16);packed.reserve(count*20);
        for(unsigned int i=0;i<16;i++) {
            const float value=static_cast<float>(context.projection->ptr()[i]);projection.push_back(value);key.push_back(bits(value));
        }
        for(std::size_t i=first;i<first+count;i++) {
            const auto& light=lights[i];
            if(light.mRadius<0.f)throw std::runtime_error("Negative clustered light radius");
            for(const auto* vector:{&light.mPosition,&light.mDiffuse,&light.mAmbient,&light.mSpecular})
                for(unsigned int k=0;k<4;k++){packed.push_back((*vector)[k]);key.push_back(bits((*vector)[k]));}
            for(float value:{light.mConstant,light.mLinear,light.mQuadratic,light.mRadius}) {
                packed.push_back(value);key.push_back(bits(value));
            }
        }
        if(const auto found=mClusterSnapshots.find(key);found!=mClusterSnapshots.end())return found->second;
        if(mClusterRecords.size()/10>=std::numeric_limits<std::uint32_t>::max()
            ||mClusterLights.size()/20+count>std::numeric_limits<std::uint32_t>::max())throw std::runtime_error("Clustered snapshot table overflow");
        const auto id=static_cast<std::uint32_t>(mClusterRecords.size()/10);
        std::array<std::uint32_t,10> record;std::copy_n(key.begin(),10,record.begin());
        record[0]=static_cast<std::uint32_t>(mClusterLights.size()/20);record[7]=id;
        mClusterRecords.insert(mClusterRecords.end(),record.begin(),record.end());
        mClusterLights.insert(mClusterLights.end(),packed.begin(),packed.end());
        mClusterProjections.insert(mClusterProjections.end(),projection.begin(),projection.end());
        mClusterSnapshots.emplace(std::move(key),id);return id;
    }
    std::uint32_t MaterialTable::encodeObjects(const DrawContext& context,const osg::StateSet& state,const osg::Shader& fragment,bool terrain,bool composite,bool water,bool groundcover,bool unlit,bool bethesda)
    {
        std::string variant;
        if(!fragment.getUserValue("webcuda.defines",variant))throw std::runtime_error("Objects shader lacks WebCuda variant metadata");
        std::map<std::string,std::string> defines;
        std::istringstream input(variant);std::string line;
        while(std::getline(input,line)) {auto split=line.find('=');if(split!=std::string::npos)defines[line.substr(0,split)]=line.substr(split+1);}
        auto enabled=[&](const char* name){const auto found=defines.find(name);return found!=defines.end()&&found->second!="0"&&found->second!="false";};
        if(water)for(const char* name:{"diffuseMap","normalMap","darkMap","detailMap","decalMap","emissiveMap","specularMap","envMap","bumpMap","glossMap","parallax","diffuseParallax","adjustCoverage"})defines[name]="0";
        if(groundcover)for(const char* name:{"darkMap","detailMap","decalMap","emissiveMap","specularMap","envMap","bumpMap","glossMap","blendMap",
            "parallax","diffuseParallax","adjustCoverage","forcePPL","softParticles","particleOcclusion","skyBlending","simpleLighting","particle","preLightEnv","additiveBlending"})defines[name]="0";
        if(unlit) {
            bool falloff=false;
            if(const auto* uniform=state.getUniform("useFalloff"))if(!uniform->get(falloff))throw std::runtime_error("Invalid unlit falloff enable");

            // This shader has only diffuse color; inherited object material maps
            // and lighting defines must not activate absent shader operations.
            for(const char* name:{"normalMap","specularMap","darkMap","detailMap","decalMap","emissiveMap","envMap","bumpMap","glossMap","blendMap",
                "parallax","diffuseParallax","preLightEnv","lightingMethodClustered","particleOcclusion"})defines[name]="0";
        }
        if(bethesda) {
            // bs/default owns diffuse, normal and multiplicative emission only.
            for(const char* name:{"specularMap","darkMap","detailMap","decalMap","envMap","bumpMap","glossMap","blendMap",
                "parallax","diffuseParallax","preLightEnv","softParticles","particleOcclusion","simpleLighting","particle"})defines[name]="0";
        }
        const bool vertexLighting=!bethesda&&!unlit&&!water&&!composite&&!enabled("normalMap")&&!enabled("specularMap")&&!enabled("forcePPL");
        const bool terrainSpecular=terrain&&enabled("specularMap");
        if(terrain) {defines["diffuseMap"]="1";defines["diffuseMapUV"]="0";defines["normalMapUV"]="0";defines["specularMap"]="0";}
        if(composite)for(const char* name:{"darkMap","detailMap","decalMap","emissiveMap","normalMap","envMap","bumpMap","glossMap",
            "parallax","diffuseParallax","adjustCoverage","alphaToCoverage"})defines[name]="0";


        const bool clustered=!unlit&&!composite&&enabled("lightingMethodClustered");
        const auto clusterSnapshot=clustered?captureClusterLights(context,state):0u;
        auto integer=[&](const char* name,int fallback){int v=fallback;if(const auto* u=state.getUniform(name))if(!u->get(v))throw std::runtime_error(std::string("Invalid object uniform: ")+name);return v;};
        const osg::Texture2D* texture=nullptr;
        if(enabled("diffuseMap")) {
            const auto unit=integer("diffuseMap",0);
            if(unit<0)throw std::runtime_error("Invalid object texture unit");
            texture=dynamic_cast<const osg::Texture2D*>(state.getTextureAttribute(unit,osg::StateAttribute::TEXTURE));
            if(!texture)throw std::runtime_error("Object diffuse texture is absent");
        }
        const auto id=encode(context,texture,true);
        std::array<std::uint32_t,12> record;std::copy_n(mMaterials.begin()+id*12,12,record.begin());
        const auto count=unlit||clustered||composite||enabled("simpleLighting")||(enabled("particle")&&!enabled("particlePointLighting"))?0:integer("PointLightCount",0);
        if(count<0||count>1024)throw std::runtime_error("Invalid object light count");
        std::vector<std::uint32_t> data(352+count*16);
        data[0]=record[0];data[1]=record[1];data[2]=record[2];data[3]=record[11];
        data[4]=(enabled("classicFalloff")?1:0)|(enabled("clamp")?2:0)|(enabled("radialFog")?4:0)|(enabled("exponentialFog")?8:0)|(enabled("additiveBlending")?16:0);
        data[5]=integer("colorMode",0);data[6]=count;data[7]=352;
        if(enabled("alphaToCoverage")) {
            data[4]|=134217728u;
            // The shader alphaTest has already applied the comparison/remap.
            record[9]=(record[9]&~240u)|(7u<<4);
        }
        if(unlit)data[4]|=268435456u;
        if(bethesda) {
            data[4]|=536870912u;
            bool tree=false;if(const auto* u=state.getUniform("useTreeAnim"))if(!u->get(tree))throw std::runtime_error("Invalid Bethesda tree alpha input");
            if(tree)data[4]|=1073741824u;
        }
        if(vertexLighting)data[4]|=8388608;
        if(groundcover){data[4]|=67108864;data[5]=0;}
        if(clustered)data[4]|=16777216;
        if(clustered&&(enabled("simpleLighting")||(enabled("particle")&&!enabled("particlePointLighting"))))data[4]|=33554432;
        if(terrain)data[4]|=4096;
        if(terrainSpecular)data[4]|=8192;
        if(composite)data[4]|=16384;
        if(enabled("reverseZ"))data[4]|=65536;
        if(enabled("reconstructNormalZ"))data[4]|=256;
        if(enabled("preLightEnv"))data[4]|=2048;
        if(enabled("parallax")) {
            if(!enabled("normalMap"))throw std::runtime_error("Parallax requires a normal/height map");
            data[4]|=512;
        }
        if(enabled("diffuseParallax")) {
            if(!enabled("diffuseMap"))throw std::runtime_error("Diffuse parallax requires a diffuse/height map");
            data[4]|=1024;
        }
        if(enabled("adjustCoverage"))data[4]|=64;
        if(enabled("useGPUShader4"))data[4]|=128;
        data[51]=defines.count("alphaFunc")?static_cast<unsigned int>(std::stoul(defines["alphaFunc"],nullptr,0))-512:7;
        if(data[51]>7)throw std::runtime_error("Invalid object alpha function");
        auto scalar=[&](unsigned int offset,float value){std::memcpy(&data[offset],&value,4);};
        auto vec=[&](unsigned int offset,const osg::Vec4& value){for(unsigned int k=0;k<4;++k)scalar(offset+k,value[k]);};
        auto uniform=[&](unsigned int offset,const char* name,const osg::Vec4& fallback){osg::Vec4 v=fallback;if(const auto* u=state.getUniform(name))if(!u->get(v))throw std::runtime_error(std::string("Invalid vector uniform: ")+name);vec(offset,v);};
        auto number=[&](unsigned int offset,const char* name,float fallback){float v=fallback;if(const auto* u=state.getUniform(name))if(!u->get(v))throw std::runtime_error(std::string("Invalid scalar uniform: ")+name);scalar(offset,v);};
        if(unlit) {
            bool falloff=false;if(const auto* u=state.getUniform("useFalloff"))u->get(falloff);
            // Unlit disables darkMap, so its descriptor stores the falloff varying inputs.
            data[80]=falloff?1u:0u;
            uniform(81,"falloffParams",osg::Vec4());
        }
        osg::ref_ptr<osg::Material> fallback=new osg::Material;
        auto* material=dynamic_cast<const osg::Material*>(state.getAttribute(osg::StateAttribute::MATERIAL));if(!material)material=fallback.get();
        vec(8,material->getAmbient(osg::Material::FRONT));vec(12,material->getDiffuse(osg::Material::FRONT));
        vec(16,material->getSpecular(osg::Material::FRONT));vec(20,material->getEmission(osg::Material::FRONT));
        if(groundcover) {
            // Groundcover multiplies raw diffuse+ambient light by its texture,
            // independent of mesh material color and without specular/emission.
            vec(8,osg::Vec4(1,1,1,1));vec(12,osg::Vec4(1,1,1,1));
            vec(16,osg::Vec4(0,0,0,0));vec(20,osg::Vec4(0,0,0,0));
        }
        uniform(24,"sun_position",osg::Vec4(0,0,1,0));uniform(28,"sun_ambient",osg::Vec4());
        uniform(32,"sun_diffuse",osg::Vec4());uniform(36,"sun_specular",osg::Vec4());
        uniform(73,"envMapColor",osg::Vec4());
        osg::Vec2 lumaBias(0,0);
        if(const auto* u=state.getUniform("envMapLumaBias"))if(!u->get(lumaBias))throw std::runtime_error("Invalid environment luma bias");
        scalar(77,lumaBias.x());scalar(78,lumaBias.y());
        osg::Matrix2 bumpMatrix;
        if(const auto* u=state.getUniform("bumpMapMatrix"))if(!u->get(bumpMatrix))throw std::runtime_error("Invalid bump matrix");
        for(unsigned int k=0;k<4;++k)scalar(320+k,bumpMatrix.ptr()[k]);
        if(groundcover) {
            const auto fade=[&](const char* name) {
                const auto found=defines.find(name);if(found==defines.end())throw std::runtime_error(std::string("Missing groundcover fade: ")+name);
                std::size_t end=0;const float value=std::stof(found->second,&end);
                if(end!=found->second.size()||!std::isfinite(value))throw std::runtime_error("Invalid groundcover fade");return value;
            };
            const float start=fade("groundcoverFadeStart"),end=fade("groundcoverFadeEnd");
            if(start<0.f||end<=start)throw std::runtime_error("Invalid groundcover fade interval");
            scalar(320,start);scalar(321,end);
        }
        if(const auto* fog=dynamic_cast<const osg::Fog*>(state.getAttribute(osg::StateAttribute::FOG))) {
            data[4]|=32;vec(40,fog->getColor());scalar(44,fog->getStart());scalar(45,fog->getEnd());
        }
        scalar(46,material->getShininess(osg::Material::FRONT));number(47,"emissiveMult",1);number(48,"specStrength",1);number(49,"alphaRef",0);
        if(terrain){scalar(47,1);scalar(48,1);data[51]=7;}
        if(composite)data[4]&=~32u;
        if(auto found=state.getDefineList().find("FORCE_OPAQUE");found!=state.getDefineList().end())data[50]=found->second.first!="0";
        if(terrain||groundcover)data[50]=0;
        if(!composite&&!enabled("disableNormals")&&(terrain?enabled("writeNormals"):(groundcover||state.getDefineList().find("FORCE_OPAQUE")==state.getDefineList().end())))data[4]|=131072;
        uniform(68,"clipPlane",osg::Vec4(0,0,0,1));
        osg::Matrixf inverseView;inverseView.makeIdentity();
        if(const auto* u=state.getUniform("osg_ViewMatrixInverse")) {
            if(!u->get(inverseView))throw std::runtime_error("Invalid inverse view matrix");
        } else if(context.view) {
            inverseView=*context.view;data[4]|=32768; // Raw view matrix; inverse is computed in .cu.
        } else if(!composite)throw std::runtime_error("World material has no camera view matrix");
        for(unsigned int k=0;k<16;++k)scalar(52+k,inverseView.ptr()[k]);
        const auto* lights=state.getUniform("LightBuffer");
        if(count&&(!lights||lights->getNumElements()<static_cast<unsigned int>(count)))throw std::runtime_error("Missing object light buffer");
        const char* layers[]={"darkMap","detailMap","decalMap","emissiveMap","normalMap","specularMap","diffuseMap","envMap","bumpMap","glossMap","blendMap"};
        for(unsigned int layer=0;layer<11;++layer)if(enabled(layers[layer])) {
            const auto unit=integer(layers[layer],0);
            if(unit<0)throw std::runtime_error("Invalid object layer texture unit");
            auto* layerTexture=dynamic_cast<const osg::Texture2D*>(state.getTextureAttribute(unit,osg::StateAttribute::TEXTURE));
            if(!layerTexture)throw std::runtime_error("Missing object layer texture");
            const auto layerId=encode(context,layerTexture,true),offset=layer==10?328:80+layer*24;
            data[offset]=mMaterials[layerId*12];data[offset+1]=mMaterials[layerId*12+1];data[offset+2]=mMaterials[layerId*12+2];data[offset+3]=mMaterials[layerId*12+11];
            const std::string uvKey=std::string(layers[layer])+"UV";
            const auto uv=terrain?0:(defines.count(uvKey)?std::stoul(defines[uvKey]):0);
            if(uv>3)throw std::runtime_error("Object layer UV set exceeds current attribute packet");
            data[offset+4]=uv;data[72]|=1u<<layer;
            const auto matrixUnit=terrain&&layer==10?1:uv;
            const auto* texmat=dynamic_cast<const osg::TexMat*>(state.getTextureAttribute(matrixUnit,osg::StateAttribute::TEXMAT));
            const osg::Matrix matrix=texmat?texmat->getMatrix():osg::Matrix::identity();
            for(unsigned int k=0;k<16;++k)scalar(offset+8+k,matrix.ptr()[k]);
        }
        for(int light=0;light<count;++light) {osg::Matrixf value;if(!lights->getElement(light,value))throw std::runtime_error("Invalid object light matrix");for(unsigned int k=0;k<16;++k)scalar(352+light*16+k,value.ptr()[k]);}
        if(!composite&&enabled("shadows_enabled")) {
            data[325]=static_cast<unsigned int>(data.size());
            number(326,"shadowFadeStart",0);number(327,"maximumShadowMapDistance",0);
            std::istringstream indices(defines["shadow_texture_unit_list"]);std::string index;
            while(std::getline(indices,index,',')) {
                if(index.empty())continue;
                const auto ordinal=std::stoul(index);
                if(ordinal>31||data[324]>=32)throw std::runtime_error("Shadow cascade index outside supported range");
                const std::string name="shadowTexture"+index;
                const auto unit=integer(name.c_str(),-1);
                if(unit<0)throw std::runtime_error("Missing shadow sampler binding");
                const auto* shadowTexture=dynamic_cast<const osg::Texture2D*>(state.getTextureAttribute(unit,osg::StateAttribute::TEXTURE));
                if(!shadowTexture||!shadowTexture->getShadowComparison())throw std::runtime_error("Shadow texture requires comparison sampling");
                const auto shadowId=encode(context,shadowTexture,true);
                const auto offset=static_cast<unsigned int>(data.size());data.resize(data.size()+40);
                data[offset]=mMaterials[shadowId*12];data[offset+1]=mMaterials[shadowId*12+1];data[offset+2]=mMaterials[shadowId*12+2];data[offset+3]=mMaterials[shadowId*12+11];
                if(!(data[offset+3]&8192))throw std::runtime_error("Shadow sampler has no registered floating depth target");
                data[offset+4]=static_cast<unsigned int>(shadowTexture->getShadowCompareFunc())-GL_NEVER;
                if(data[offset+4]>7)throw std::runtime_error("Invalid shadow comparison");
                data[offset+5]=(enabled("perspectiveShadowMaps")?1u:0u)|(enabled("useShadowDebugOverlay")?2u:0u)|(enabled("limitShadowMapDistance")?4u:0u);
                const auto depthFormat=shadowTexture->getInternalFormat();
                if(depthFormat==0x8CAC||depthFormat==0x8CAD)data[offset+5]|=8u;
                scalar(offset+6,enabled("disableNormalOffsetShadows")?0.f:std::stof(defines["shadowNormalOffset"]));data[offset+7]=ordinal%3;
                const auto matrix=[&](const std::string& name,unsigned int destination) {
                    osg::Matrixf value;const auto* uniform=state.getUniform(name);
                    // ShadowManager disables shadows with a constant ALWAYS
                    // comparison texture and deliberately supplies no matrices.
                    // Preserve that sampler; only its unused transform defaults.
                    if(!uniform&&shadowTexture->getShadowCompareFunc()==osg::Texture::ALWAYS)value.makeIdentity();
                    else if(!uniform||!uniform->get(value))throw std::runtime_error("Missing shadow matrix: "+name);
                    for(unsigned int k=0;k<16;++k)scalar(destination+k,value.ptr()[k]);
                };
                matrix("shadowSpaceMatrix"+index,offset+8);
                if(enabled("perspectiveShadowMaps"))matrix("validRegionMatrix"+index,offset+24);
                ++data[324];
            }
        }
        const bool soft=!terrain&&!composite&&enabled("softParticles")&&state.getDefineList().find("FORCE_OPAQUE")==state.getDefineList().end();
        const bool occlusion=!terrain&&!composite&&enabled("particleOcclusion");
        bool disableSkyBlending=false;
        if(const auto* uniform=state.getUniform("webcudaDisableSkyBlending"))
            if(!uniform->get(disableSkyBlending))throw std::runtime_error("Invalid camera sky blending state");
        const bool skyBlend=!composite&&enabled("skyBlending")&&!disableSkyBlending;
        const auto distortionDefine=state.getDefineList().find("DISTORTION");
        const bool distortion=!unlit&&!groundcover&&!terrain&&!water&&enabled("diffuseMap")&&distortionDefine!=state.getDefineList().end()&&distortionDefine->second.first!="0";
        if(soft||occlusion||skyBlend||distortion) {
            const auto offset=static_cast<unsigned int>(data.size());data[79]=offset;data.resize(data.size()+48);
            const auto textureRecord=[&](const char* name,unsigned int destination) {
                const auto unit=integer(name,-1);if(unit<0)throw std::runtime_error(std::string("Missing screen effect sampler: ")+name);
                const auto* texture=dynamic_cast<const osg::Texture2D*>(state.getTextureAttribute(unit,osg::StateAttribute::TEXTURE));
                if(!texture)throw std::runtime_error(std::string("Missing screen effect texture: ")+name);
                const auto material=encode(context,texture,true);
                data[destination]=mMaterials[material*12];data[destination+1]=mMaterials[material*12+1];data[destination+2]=mMaterials[material*12+2];data[destination+3]=mMaterials[material*12+11];
            };
            if(soft) {
                data[4]|=262144;textureRecord("opaqueDepthTex",offset);
                if(!(data[offset+3]&8192))throw std::runtime_error("Soft particles require a floating depth texture");
                number(offset+4,"near",1);number(offset+5,"far",10000);number(offset+6,"particleSize",1);number(offset+8,"softFalloffDepth",1);
                bool fade=false;if(const auto* u=state.getUniform("particleFade"))if(!u->get(fade))throw std::runtime_error("Invalid particleFade");data[offset+7]=fade;
            }
            if(occlusion) {
                data[4]|=524288;textureRecord("orthoDepthMap",offset+12);
                if(!(data[offset+15]&8192))throw std::runtime_error("Particle occlusion requires a floating depth texture");
                osg::Matrixf matrix;const auto* uniform=state.getUniform("depthSpaceMatrix");
                if(!uniform||!uniform->get(matrix))throw std::runtime_error("Missing particle depth-space matrix");
                for(unsigned int k=0;k<16;++k)scalar(offset+16+k,matrix.ptr()[k]);
            }
            if(skyBlend) {
                data[4]|=1048576;textureRecord("sky",offset+32);
                number(offset+36,"far",10000);number(offset+37,"skyBlendingStart",0);
            }
            if(distortion) {
                data[4]|=4194304;textureRecord("opaqueDepthTex",offset+40);
                number(offset+44,"distortionStrength",0);
                const auto ratio=defines.find("distorionRTRatio");scalar(offset+45,ratio==defines.end()?1.f:std::stof(ratio->second));
                if(!(data[offset+43]&8192))throw std::runtime_error("Distortion requires a floating depth texture");
            }
        }
        if(water) {
            const auto offset=static_cast<unsigned int>(data.size());data[321]=offset;data[4]|=2097152;data.resize(data.size()+96);
            const auto textureRecord=[&](const char* name,unsigned int destination) {
                const auto unit=integer(name,-1);if(unit<0)throw std::runtime_error(std::string("Missing water sampler: ")+name);
                const auto* texture=dynamic_cast<const osg::Texture2D*>(state.getTextureAttribute(unit,osg::StateAttribute::TEXTURE));
                if(!texture)throw std::runtime_error(std::string("Missing water texture: ")+name);
                const auto material=encode(context,texture,true);
                data[destination]=mMaterials[material*12];data[destination+1]=mMaterials[material*12+1];data[destination+2]=mMaterials[material*12+2];data[destination+3]=mMaterials[material*12+11];
            };
            textureRecord("normalMap",offset);textureRecord("reflectionMap",offset+4);textureRecord("rippleMap",offset+16);
            if(enabled("waterRefraction")){textureRecord("refractionMap",offset+8);textureRecord("refractionDepthMap",offset+12);}
            number(offset+20,"osg_SimulationTime",mSimulationTime);number(offset+21,"near",1);number(offset+22,"far",10000);number(offset+23,"rainIntensity",0);
            data[offset+24]=(enabled("waterRefraction")?1:0)|(enabled("sunlightScattering")?2:0)|(enabled("wobblyShores")?4:0)|(enabled("reflectionBlurEnabled")?8:0);
            const auto defineNumber=[&](const char* name,float fallback){const auto found=defines.find(name);return found==defines.end()?fallback:std::stof(found->second);};
            scalar(offset+25,defineNumber("reflectionBlur",0));scalar(offset+26,defineNumber("rippleMapSize",1024));scalar(offset+27,defineNumber("rippleMapWorldScale",2.5));
            data[offset+28]=static_cast<unsigned int>(defineNumber("rainRippleDetail",0));
            // The legacy doSpecularLighting implementation returns zero for
            // water point lights. Clustered lighting has its own guarded path.
            for(const auto& entry:{std::pair<const char*,unsigned int>{"nodePosition",32},{"playerPos",36}}) {
                osg::Vec3f value;const auto* u=state.getUniform(entry.first);
                if(!u||!u->get(value))throw std::runtime_error(std::string("Missing water position: ")+entry.first);
                for(unsigned int k=0;k<3;++k)scalar(offset+entry.second+k,value[k]);
            }
            if(!context.modelView)throw std::runtime_error("Water requires model-view matrix");
            for(unsigned int k=0;k<16;++k){scalar(offset+40+k,context.modelView->ptr()[k]);scalar(offset+56+k,context.modelView->ptr()[k]);}
            data[51]=7;data[50]=0;
        }
        if(mTexels.size()+data.size()>std::numeric_limits<std::uint32_t>::max())throw std::runtime_error("WebCuda object table overflow");
        record[0]=static_cast<std::uint32_t>(mTexels.size());record[3]|=2048;
        mTexels.insert(mTexels.end(),data.begin(),data.end());
        const auto result=static_cast<std::uint32_t>(mMaterials.size()/12);
        mMaterials.insert(mMaterials.end(),record.begin(),record.end());copyRaster(id);
        if(clustered)mClusterMaterials.insert(mClusterMaterials.end(),{result,clusterSnapshot});
        return result;
    }
    std::uint32_t MaterialTable::encodeShadow(const DrawContext& context,const osg::StateSet& state,const osg::Shader& fragment,bool depthClipped)
    {
        std::string variant;if(!fragment.getUserValue("webcuda.defines",variant))throw std::runtime_error("Shadow material has no variant metadata");
        std::map<std::string,std::string> defines;std::istringstream input(variant);std::string line;
        while(std::getline(input,line)){const auto split=line.find('=');if(split!=std::string::npos)defines[line.substr(0,split)]=line.substr(split+1);}
        const bool alphaCoverage=!depthClipped&&defines.count("alphaToCoverage")&&defines["alphaToCoverage"]!="0"&&defines["alphaToCoverage"]!="false";
        auto boolean=[&](const char* name,bool fallback){bool value=fallback;if(const auto* u=state.getUniform(name))if(!u->get(value))throw std::runtime_error(std::string("Invalid shadow uniform: ")+name);return value;};
        int colorMode=0;if(const auto* u=state.getUniform("colorMode"))if(!u->get(colorMode))throw std::runtime_error("Invalid shadow color mode");
        const bool textured=depthClipped||boolean("useDiffuseMapForShadowAlpha",true);
        const osg::Texture2D* texture=nullptr;
        if(textured) {
            int unit=0;if(const auto* u=state.getUniform("diffuseMap"))if(!u->get(unit))throw std::runtime_error("Invalid shadow sampler");
            if(unit<0)throw std::runtime_error("Invalid shadow texture unit");
            texture=dynamic_cast<const osg::Texture2D*>(state.getTextureAttribute(unit,osg::StateAttribute::TEXTURE));
            if(!texture)throw std::runtime_error("Missing shadow alpha texture");
        }
        const auto id=encode(context,texture,true);std::array<std::uint32_t,12> record;
        std::copy_n(mMaterials.begin()+id*12,12,record.begin());
        std::array<std::uint32_t,10> data{};
        data[0]=record[0];data[1]=record[1];data[2]=record[2];data[3]=record[11];
        float alphaRef=0;if(const auto* u=state.getUniform("alphaRef"))if(!u->get(alphaRef))throw std::runtime_error("Invalid shadow alpha reference");
        std::memcpy(&data[4],&alphaRef,4);data[5]=colorMode==2;
        osg::ref_ptr<osg::Material> fallback=new osg::Material;
        const auto* material=dynamic_cast<const osg::Material*>(state.getAttribute(osg::StateAttribute::MATERIAL));if(!material)material=fallback.get();
        const float alpha=material->getDiffuse(osg::Material::FRONT).a();std::memcpy(&data[6],&alpha,4);
        data[7]=(boolean("useTreeAnim",false)?1u:0u)|(boolean("alphaTestShadows",true)?2u:0u)|(alphaCoverage?4u:0u);
        if(alphaCoverage)record[9]=(record[9]&~240u)|(7u<<4);
        data[8]=defines.count("alphaFunc")?static_cast<unsigned int>(std::stoul(defines["alphaFunc"],nullptr,0))-512:7;
        if(data[8]>7)throw std::runtime_error("Invalid shadow alpha function");
        if(depthClipped) {
            const float threshold=0.499f;std::memcpy(&data[4],&threshold,4);data[7]=0;data[8]=6;
            record[9]|=15u<<17;record[9]=(record[9]&~240u)|(7u<<4);
        }
        if(mTexels.size()+data.size()>std::numeric_limits<std::uint32_t>::max())throw std::runtime_error("Shadow material table overflow");
        record[0]=static_cast<std::uint32_t>(mTexels.size());record[3]|=4096;
        mTexels.insert(mTexels.end(),data.begin(),data.end());
        const auto result=static_cast<std::uint32_t>(mMaterials.size()/12);mMaterials.insert(mMaterials.end(),record.begin(),record.end());copyRaster(id);return result;
    }
    std::uint32_t MaterialTable::encodeSky(const DrawContext& context,const osg::StateSet& state)
    {
        auto integer=[&](const char* name,int fallback) {int value=fallback;if(const auto* u=state.getUniform(name))
            if(!u->get(value))throw std::runtime_error(std::string("Invalid sky integer: ")+name);return value;};
        const int pass=integer("pass",-1);
        if(pass<0||pass>6)throw std::runtime_error("Invalid WebCuda sky pass");
        if(pass==5&&!context.queryId)throw std::runtime_error("Sky query has no query identity");
        auto texture=[&](const char* sampler)->const osg::Texture2D* {
            const int unit=integer(sampler,0);if(unit<0)throw std::runtime_error("Invalid sky texture unit");
            const auto* attribute=state.getTextureAttribute(unit,osg::StateAttribute::TEXTURE);
            auto* result=dynamic_cast<const osg::Texture2D*>(attribute);
            if(!result)throw std::runtime_error(std::string("Missing sky texture: ")+sampler);return result;
        };
        const bool textured=pass>=1&&pass<=5;
        const auto diffuseId=encode(context,textured?texture("diffuseMap"):nullptr,true);
        std::array<std::uint32_t,12> record;
        std::copy_n(mMaterials.begin()+diffuseId*12,12,record.begin());
        std::array<std::uint32_t,30> shader{};
        shader[0]=record[0];shader[1]=record[1];shader[2]=record[2];shader[3]=record[11];shader[8]=pass;
        if(pass==3) {
            const auto maskId=encode(context,texture("maskMap"),true);
            shader[4]=mMaterials[maskId*12];shader[5]=mMaterials[maskId*12+1];shader[6]=mMaterials[maskId*12+2];shader[7]=mMaterials[maskId*12+11];
        }
        float opacity=1;if(const auto* u=state.getUniform("opacity"))if(!u->get(opacity))throw std::runtime_error("Invalid sky opacity");
        std::memcpy(&shader[9],&opacity,4);
        if(pass==5)shader[9]=context.queryId;
        auto vector=[&](const char* name,unsigned int offset) {
            osg::Vec4 value(0,0,0,0);if(const auto* u=state.getUniform(name))if(!u->get(value))throw std::runtime_error(std::string("Invalid sky vector: ")+name);
            for(unsigned int i=0;i<4;i++){const float component=value[i];std::memcpy(&shader[offset+i],&component,4);}
        };
        vector("moonBlend",10);vector("atmosphereFade",14);vector("skyMaterialEmission",18);vector("skyMaterialDiffuse",22);
        if(const auto* fog=dynamic_cast<const osg::Fog*>(state.getAttribute(osg::StateAttribute::FOG)))
            for(unsigned int i=0;i<4;i++){const float component=fog->getColor()[i];std::memcpy(&shader[26+i],&component,4);}
        if(mTexels.size()+shader.size()>std::numeric_limits<std::uint32_t>::max())throw std::runtime_error("WebCuda sky table overflow");
        record[0]=static_cast<std::uint32_t>(mTexels.size());record[3]|=1024;
        mTexels.insert(mTexels.end(),shader.begin(),shader.end());
        const auto id=static_cast<std::uint32_t>(mMaterials.size()/12);
        mMaterials.insert(mMaterials.end(),record.begin(),record.end());copyRaster(diffuseId);return id;
    }
}
