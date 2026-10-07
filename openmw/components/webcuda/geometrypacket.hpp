#ifndef OPENMW_COMPONENTS_WEBCUDA_GEOMETRYPACKET_H
#define OPENMW_COMPONENTS_WEBCUDA_GEOMETRYPACKET_H
#include <cstdint>
#include <functional>
#include <map>
#include <vector>
#include "submission.hpp"
#include "geometrypacketstorage.hpp"
namespace WebCuda
{
    struct GeometryPacket : GeometryPacketStorage
    {
        GeometryPacket(bool compact = false) : GeometryPacketStorage(compact) {}
    };
    // Copy CPU scene data only. Transform, clip, shade and rasterize on the GPU.
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
