#ifndef OPENMW_COMPONENTS_WEBCUDA_GEOMETRYPACKETSTORAGE_H
#define OPENMW_COMPONENTS_WEBCUDA_GEOMETRYPACKETSTORAGE_H
// SPDX-License-Identifier: GPL-3.0-or-later
// CPU capture storage only: no GPU work, geometry cache or transport ABI changes.
#include <array>
#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <tuple>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

namespace WebCuda
{
    struct GeometryPacketData
    {
        bool compactVertices = false;
        std::uint32_t capturedVertexCount = 0;
        unsigned int currentSecondaryByteComponents = 0; // Capture-only format for current secondary color.
        // 32 words per draw: first/count/source count/kind/mode/fallback.
        // Kind0: dense offsets6..8. Kind1: ten {offset,stride} streams8..27.
        // Kind2: source count is particles; offset6 holds raw17 per particle,
        // offset7 holds shared23. CUDA builds four corners per particle.
        // Kind3: source count is GUI vertices; offset6 holds raw9 (XYZ,
        // RGBA bytes as floats, UV), offset7 holds shared secondary color3.
        // Words28/29/30: byte channel counts for primary/secondary/fallback.
        // Primary is kind1 only (0/3/4); secondary is 0/3 for all kinds except
        // GUI; fallback is kind1 only (0/3). Word31 stays reserved.
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

        auto buffers() noexcept { return std::tie(
            vertexLayouts, vertexInputs, vertexResources, groundcoverRanges,
            groundcoverInstances, groundcoverParams, textGradientRanges, textGradientColors,
            localTransforms, debugParams, secondaryColors, vertices,
            attributes, matrices, uvMatrices, texgen,
            fixedLighting, positionedState, matrixIds, triangles,
            polygonEdges, flatColors, morphRanges, morphOffsets,
            skinRanges, skinWeights, skinBones, ribbonRanges,
            ribbonParticles, skinTransforms, screenPrimitives
        ); }
        auto buffers() const noexcept { return std::tie(
            vertexLayouts, vertexInputs, vertexResources, groundcoverRanges,
            groundcoverInstances, groundcoverParams, textGradientRanges, textGradientColors,
            localTransforms, debugParams, secondaryColors, vertices,
            attributes, matrices, uvMatrices, texgen,
            fixedLighting, positionedState, matrixIds, triangles,
            polygonEdges, flatColors, morphRanges, morphOffsets,
            skinRanges, skinWeights, skinBones, ribbonRanges,
            ribbonParticles, skinTransforms, screenPrimitives
        ); }

        std::size_t capacityBytes() const noexcept
        {
            return std::apply([](const auto&... buffer) {
                return (std::size_t(0) + ... + (buffer.capacity()
                    * sizeof(typename std::decay_t<decltype(buffer)>::value_type)));
            }, buffers());
        }
        void clearForReuse() noexcept
        {
            std::apply([](auto&... buffer) { (buffer.clear(), ...); }, buffers());
            vertexResourceOffsets.clear();
            capturedVertexCount=0;
            currentSecondaryByteComponents=0;
        }
    };

    struct GeometryPacketPoolStats
    {
        std::uint64_t acquisitions=0, reuses=0, returns=0, discarded=0;
        std::size_t pooledBytes=0, pooledPackets=0;
    };

    class GeometryPacketBufferPool
    {
    public:
        static constexpr std::size_t MaxPackets=16;
        explicit GeometryPacketBufferPool(std::size_t budget=32u*1024u*1024u) noexcept : mBudget(budget) {}
        GeometryPacketBufferPool(const GeometryPacketBufferPool&)=delete;
        GeometryPacketBufferPool& operator=(const GeometryPacketBufferPool&)=delete;

        // Called only for a freshly constructed, empty packet. The free list
        // contains empty vectors with capacity, never live packet contents.
        void acquire(GeometryPacketData& destination, bool compact) noexcept
        {
            ++mStats.acquisitions;
            for(std::size_t i=mCount;i>0;--i)
            {
                if(mFree[i-1].compactVertices!=compact)continue;
                const auto bytes=mFree[i-1].capacityBytes();
                --mCount;
                if(i-1!=mCount)std::swap(mFree[i-1],mFree[mCount]);
                std::swap(destination,mFree[mCount]);
                mStats.pooledBytes-=bytes;
                mStats.pooledPackets=mCount;
                ++mStats.reuses;
                break;
            }
            destination.compactVertices=compact;
        }

        // Destruction is the ownership boundary: a retained WASM pass keeps its
        // vectors until the browser explicitly releases that pass. No live heap
        // view can be reused. This path allocates nothing, even during unwinding.
        void release(GeometryPacketData& source) noexcept
        {
            // Capture and browser release normally share one thread. A packet
            // explicitly handed to another thread is freed there, not returned
            // into the origin thread's cache while it might be in use.
            if(std::this_thread::get_id()!=mOwner)return;
            const auto bytes=source.capacityBytes();
            if(!bytes)return;
            if(mCount==MaxPackets || bytes>mBudget-mStats.pooledBytes)
            {
                ++mStats.discarded;
                return;
            }
            source.clearForReuse();
            std::swap(mFree[mCount++],source);
            mStats.pooledBytes+=bytes;
            mStats.pooledPackets=mCount;
            ++mStats.returns;
        }
        GeometryPacketPoolStats stats() const noexcept { return mStats; }
    private:
        const std::thread::id mOwner=std::this_thread::get_id();
        std::size_t mBudget, mCount=0;
        std::array<GeometryPacketData,MaxPackets> mFree;
        GeometryPacketPoolStats mStats;
    };

    // Kept alive by outstanding packets as well as the thread-local owner.
    // That avoids accessing a destroyed TLS pool when a retained pass is freed
    // at shutdown. Pools never contain owners or references back to packets.
    inline const std::shared_ptr<GeometryPacketBufferPool>& geometryPacketBufferPool()
    {
        static thread_local const auto pool=std::make_shared<GeometryPacketBufferPool>();
        return pool;
    }

    struct GeometryPacketStorage : GeometryPacketData
    {
        explicit GeometryPacketStorage(bool compact=false) : mPool(geometryPacketBufferPool())
        {
            mPool->acquire(*this,compact);
        }
        GeometryPacketStorage(const GeometryPacketStorage&)=default;
        GeometryPacketStorage& operator=(const GeometryPacketStorage&)=default;
        GeometryPacketStorage(GeometryPacketStorage&&) noexcept=default;
        GeometryPacketStorage& operator=(GeometryPacketStorage&& other) noexcept
        {
            if(this!=&other)
            {
                if(mPool)mPool->release(*this);
                GeometryPacketData::operator=(std::move(other));
                mPool=std::move(other.mPool);
            }
            return *this;
        }
        ~GeometryPacketStorage() { if(mPool)mPool->release(*this); }
        static GeometryPacketPoolStats poolStats() { return geometryPacketBufferPool()->stats(); }
    private:
        std::shared_ptr<GeometryPacketBufferPool> mPool;
    };
}
#endif
