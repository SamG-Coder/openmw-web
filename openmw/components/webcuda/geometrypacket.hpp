#ifndef OPENMW_COMPONENTS_WEBCUDA_GEOMETRYPACKET_H
#define OPENMW_COMPONENTS_WEBCUDA_GEOMETRYPACKET_H
#include <cstdint>
#include <functional>
#include <map>
#include <vector>
#include "submission.hpp"
namespace WebCuda
{
    struct GeometryPacket
    {
        GeometryPacket(bool compact = false) : compactVertices(compact) {}
        bool compactVertices = false;
        std::uint32_t capturedVertexCount = 0;
        // 32 words per draw: first/count/source count/kind/mode/fallback.
        // Kind0: dense offsets6..8. Kind1: ten {offset,stride} streams8..27.
        // Kind2: source count is particles; offset6 holds raw17 per particle,
        // offset7 holds shared23. CUDA builds four corners per particle.
        // Streams: position4, color4, secondary3, normal3, tangent4, fog1, UV0..3 each4.
        std::vector<std::uint32_t> vertexLayouts;
        std::vector<float> vertexInputs;
        std::vector<std::uint32_t> vertexResources; // immutable version, input offset, word count
        std::map<std::uint32_t,std::uint32_t> vertexResourceOffsets; // capture-only deduplication
        std::size_t vertexCount() const { return compactVertices ? capturedVertexCount : vertices.size()/10; }
        std::vector<std::uint32_t> groundcoverRanges; // vertex, instance, parameter block
        std::vector<float> groundcoverInstances; // offset xyz, scale, rotation xyz
        std::vector<float> groundcoverParams; // view-to-invert16, view16, wind/time/player/stomp/fade (40)
        std::vector<std::uint32_t> textGradientRanges; // first vertex, count, color block
        std::vector<float> textGradientColors; // TL/BL/BR/TR RGBA per block
        std::vector<float> localTransforms; // 35 floats per draw: mode, raw local matrix16, text placement18
        std::vector<float> debugParams; // 16 floats per draw: kind, vertex-color flag, padding2, RGBA, translation3, padding, scale3, padding
        std::vector<float> secondaryColors; // RGB per vertex; compatibility color sum input
        std::vector<float> vertices; // position xyzw, RGBA, UV
        // View position (filled on GPU), model normal xyz, tangent xyzw, UV1-3.
        std::vector<float> attributes; // 34 floats per vertex; R/Q pairs for UV0..3 at 26..33; UV0 at 16, bitangent at 18, env UV at 21, unit view normal at 23
        std::vector<float> matrices; // model-view then projection; 32 floats per draw
        std::vector<float> uvMatrices; // texture unit zero, 16 floats per draw
        std::vector<std::uint32_t> texgen; // Four36-word generation descriptors per draw, matched to matrixIds.
        std::vector<std::uint32_t> fixedLighting; // 368 words per draw: compatibility light/material state, aligned with matrixIds
        // Optional inherited application transforms. Descriptor word3 is a
        // one-based offset: fixed lighting references an eight-offset table,
        // TexGen references a raw float-bit matrix16. Zero means no composition.
        std::vector<std::uint32_t> positionedState;
        std::vector<std::uint32_t> matrixIds;
        std::vector<std::uint32_t> triangles; // three indices, resolved material ID
        std::vector<std::uint32_t> polygonEdges; // outgoing edge bits 0..2 per triangle, excluding polygon triangulation diagonals
        std::vector<std::uint32_t> flatColors; // provoking vertex per triangle, UINT32_MAX for smooth color
        std::vector<std::uint32_t> morphRanges; // destination vertex, first offset record, count
        std::vector<float> morphOffsets; // offset xyz, weight
        std::vector<std::uint32_t> skinRanges; // vertex, first influence, count, transform
        std::vector<std::uint32_t> skinWeights; // bone index, float-bit weight
        std::vector<float> skinBones; // inverse bind and pose, 32 floats
        std::vector<std::uint32_t> ribbonRanges; // 13 words: first,count,vertex,triangle,matrix,skip,material,lineMaterial,width bits,normal xyz bits,flat color
        std::vector<float> ribbonParticles; // linked-list order: xyz,size,rgba,alpha,S
        std::vector<float> skinTransforms; // skin-to-skeleton and local, 32 floats
        std::vector<std::uint32_t> screenPrimitives; // 12 words: endpoints, output vertex, point flag, size/min/max/fade/attenuation xyz float bits, sprite flags
    };
    // Copy CPU scene data only. Transform, clip, shade and rasterize in .cu.
    // The caller resolves material state; unsupported geometry fails explicitly.
    void appendGeometry(GeometryPacket&, const osg::Geometry&, const DrawContext&, std::uint32_t material, std::uint32_t screenMaterial = ~std::uint32_t(0), std::uint32_t pointMaterial = ~std::uint32_t(0));
    void appendParticles(GeometryPacket&, const osgParticle::ParticleSystem&, const DrawContext&, std::uint32_t material, std::uint32_t screenMaterial = ~std::uint32_t(0), std::uint32_t pointMaterial = ~std::uint32_t(0));
    void appendGui(GeometryPacket&, const osg::Array&, std::size_t count, const DrawContext&, std::uint32_t material);

    using MaterialResolver = std::function<std::uint32_t(const DrawContext&, const osg::Texture2D*, bool gui)>;
    // Shared by the game viewer and standalone capture sink. Expanded points
    // and lines need non-polygon state even when their source inherits wireframe,
    // culling or polygon offset. The original state still supplies GPU inputs.
    void captureGeometry(GeometryPacket&, const osg::Geometry&, const DrawContext&, const MaterialResolver&, bool gui = false);
    void captureParticles(GeometryPacket&, const osgParticle::ParticleSystem&, const DrawContext&, const MaterialResolver&);

    class GeometrySink final : public SubmissionSink
    {
    public:
        // The material resolver and consumer share the material/texture table.
        // consume is synchronous: retain a copy if dispatch is asynchronous.
        using Resolve = MaterialResolver;
        using Consume = std::function<void(const osgUtil::RenderStage&, const GeometryPacket&)>;
        GeometrySink(Resolve resolve, Consume consume);
        void beginPass(const osgUtil::RenderStage&) override;
        void endPass(const osgUtil::RenderStage&) override;
        void geometry(const osg::Geometry&, const DrawContext&) override;
        void particles(const osgParticle::ParticleSystem&, const DrawContext&) override;
        void gui(const osg::Array&, std::size_t, const osg::Texture2D*, const DrawContext&) override;
    private:
        Resolve mResolve;
        Consume mConsume;
        GeometryPacket mPacket;
        bool mInPass = false;
    };
}
#endif
