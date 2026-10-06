#ifndef OPENMW_COMPONENTS_WEBCUDA_MATERIALTABLE_H
#define OPENMW_COMPONENTS_WEBCUDA_MATERIALTABLE_H
#include <memory>
#include <array>
#include <map>
#include <vector>
#include <functional>
#include <stdexcept>
#include <osg/Image>
#include <osg/Texture2D>
#include "materialstate.hpp"
#include "captureprofile.hpp"
namespace osg { class Shader; }
namespace WebCuda
{
    // Per-pass resource table. Reuses identical image contents and material
    // records within the pass. Cross-frame residency is handled separately.
    class MaterialTable
    {
    public:
        MaterialTable(std::uint32_t width, std::uint32_t height);
        using RenderTexture = std::function<std::uint32_t(const osg::Texture2D*)>;
        void setRenderTextureResolver(RenderTexture resolver) { mRenderTexture=std::move(resolver); }
        void setDepthOnly(bool value) { mDepthOnly=value; }
        void setFloatingColor(bool value) { mFloatingColor=value; }
        void setHasDepth(bool value) { mHasDepth=value; }
        void setSimulationTime(float value) { mSimulationTime=value; }
        const std::vector<std::uint32_t>& textureCopies() const { return mTextureCopies; }
        const std::vector<std::uint32_t>& textureResources() const { return mTextureResources; }
        const std::vector<std::uint32_t>& depthMipSources() const { return mDepthMipSources; }
        std::uint32_t encode(const DrawContext&, const osg::Texture2D* guiTexture = nullptr, bool gui = false);
        std::uint32_t encodeGlyph(const DrawContext&,const osg::Texture2D*,bool redCoverage,bool distanceField=false,float glyphDimension=32.f,float textureDimension=1024.f,const float* backdrop=nullptr);
        const std::vector<std::uint32_t>& materials() const { return mMaterials; }
        const std::vector<std::uint32_t>& texels() const { return mTexels; }
        // CPU words contain descriptors/images only. Render attachments occupy
        // a trailing GPU-only region whose addresses resolve in a snapshot.
        std::uint64_t texelWordCount() const { return std::uint64_t(mTexels.size())+mAttachmentWords; }
        const std::vector<std::uint32_t>& compressedBlocks() const { return mCompressedBlocks; }
        const std::vector<std::uint32_t>& textureDecodes() const { return mTextureDecodes; }
        const std::vector<std::uint32_t>& mipGenerations() const { return mMipGenerations; }
        const std::vector<float>& rasterParams() const { return mRasterParams; }
        const std::vector<std::uint32_t>& clusterRecords() const { return mClusterRecords; }
        const std::vector<std::uint32_t>& clusterMaterials() const { return mClusterMaterials; }
        const std::vector<float>& clusterLights() const { return mClusterLights; }
        const std::vector<float>& clusterProjections() const { return mClusterProjections; }
    private:
        friend std::shared_ptr<const MaterialTable> captureMaterialTable(std::shared_ptr<const MaterialTable>);
        std::uint32_t reserveAttachmentWords(std::uint64_t count);
        void resolveAttachmentAddresses();
        void resizeAtlas(std::size_t size) { CaptureScope scope(CapturePhase::AtlasResize);mTexels.resize(size); }
        void copyRaster(std::uint32_t material);
        std::uint32_t encodeResolved(const DrawContext&,const osg::StateSet&,const osg::Texture2D*,bool gui);
        std::uint32_t captureClusterLights(const DrawContext&,const osg::StateSet&);
        std::uint32_t encodeSky(const DrawContext&, const osg::StateSet&);
        std::uint32_t encodeShadow(const DrawContext&,const osg::StateSet&,const osg::Shader&,bool depthClipped=false);
        std::uint32_t encodeObjects(const DrawContext&,const osg::StateSet&,const osg::Shader&,bool terrain=false,bool composite=false,bool water=false,bool groundcover=false,bool unlit=false,bool bethesda=false);
        struct ImageRecord
        {
            osg::ref_ptr<const osg::Image> image;
            unsigned int modified;
            std::uint32_t offset,width,height,levels;
            bool floating=false;
        };
        std::uint32_t mWidth,mHeight;
        bool mDepthOnly=false;
        bool mFloatingColor=false;
        bool mHasDepth=true;
        float mSimulationTime=0;
        std::vector<std::uint32_t> mMaterials,mTexels{0xffffffff};
        std::uint32_t mAttachmentWords=0;
        bool mAttachmentsResolved=false;
        std::vector<std::uint32_t> mAttachmentDescriptors;
        std::vector<float> mRasterParams; // 50 words: raster4, blend RGBA4, stencil front/back7 each, normal mask, opaque fog pointer bits, sample coverage, coverage inversion, sample mask, multisample enable, glyph dimension, texture dimension, shadow enable/offset2/color4, polygon line width/point size, front/back offset factor/units, point min/max/fade/attenuation3, smooth/sprite flags
        // Decode records: source word offset, atlas word offset, width, height,
        // format. DXT1/3/5 and float/half image decoding runs in .cu.
        std::vector<std::uint32_t> mCompressedBlocks,mTextureDecodes;
        // source offset, destination offset, source width, source height
        std::vector<std::uint32_t> mMipGenerations;
        // target identity, atlas pixel offset, width, height
        std::vector<std::uint32_t> mTextureCopies,mDepthMipSources;
        // Immutable image version, atlas offset, complete mip-chain word count.
        // IDs survive material tables; render attachments never enter this list.
        std::vector<std::uint32_t> mTextureResources;
        // Ten words: first light, count, grid XYZ, near/far float bits,
        // projection index (bit31: raw light inputs follow the projection),
        // screen width/height float bits. Materials map material ID -> snapshot
        // ID. PointLight records contain 20 floats. Raw input blocks add view16,
        // radius scale, three reserved zeros and five fade floats per light;
        // projection pool entries remain aligned to 16 floats.
        std::vector<std::uint32_t> mClusterRecords,mClusterMaterials;
        std::vector<float> mClusterLights,mClusterProjections;
        std::map<std::vector<std::uint32_t>,std::uint32_t> mClusterSnapshots;
        RenderTexture mRenderTexture;
        std::map<std::pair<const osg::Texture2D*,std::uint64_t>,std::uint32_t> mFogImages;
        std::map<std::shared_ptr<const std::vector<std::uint32_t>>,std::uint32_t> mMapSources;
        std::map<std::shared_ptr<const std::vector<std::uint32_t>>,std::uint32_t> mTerrainBlendSources;
        std::map<std::array<std::uint32_t,4>,std::uint32_t> mMapImages;
        std::map<std::pair<const osg::Image*,unsigned int>,ImageRecord> mImages;
        // Attachment identity, dimensions, storage format, mip requirement -> offset/levels.
        std::map<std::array<std::uint32_t,5>,std::array<std::uint32_t,2>> mRenderImages;
        std::map<std::array<std::uint32_t,62>,std::uint32_t> mRecords;
        std::map<std::array<std::uint32_t,10>,std::uint32_t> mBorderDescriptors;
        std::map<std::array<std::uint32_t,44>,std::uint32_t> mTextureEnvironments;
        std::map<std::array<std::uint32_t,9>,std::uint32_t> mFogRecords;
    };

    std::shared_ptr<const MaterialTable> captureMaterialTable(std::shared_ptr<const MaterialTable>);

    // A submitted pass keeps its table immutable while browser dispatch is
    // pending. Ordinary draws in an unsubmitted table continue in place.
    inline MaterialTable& writableMaterialTable(std::shared_ptr<MaterialTable>& table)
    {
        if (!table) throw std::logic_error("Missing writable WebCuda material table");
        if (table.use_count()!=1) {
            CaptureScope scope(CapturePhase::MaterialCopy);
            table=std::make_shared<MaterialTable>(*table);
        }
        return *table;
    }
}
#endif
