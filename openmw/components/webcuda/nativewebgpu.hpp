#ifndef OPENMW_COMPONENTS_WEBCUDA_NATIVEWEBGPU_H
#define OPENMW_COMPONENTS_WEBCUDA_NATIVEWEBGPU_H

#include <cstdint>
#include <vector>

#ifdef __EMSCRIPTEN__
#include <webgpu/webgpu_cpp.h>
#endif

namespace WebCuda
{
#ifdef __EMSCRIPTEN__
    class NativeWebGPURenderer
    {
    public:
        static NativeWebGPURenderer& instance();

        // Consumes the frame protocol entirely inside WASM.  No application
        // JavaScript is involved in command decoding or WebGPU submission.
        void submitFrame(const std::vector<std::uint32_t>& commands);
        void shutdown() noexcept;

    private:
        struct PassState
        {
            std::uint32_t clearMask = 0;
            float clearColor[4]{0.f, 0.f, 0.f, 1.f};
            float clearDepth = 1.f;
            std::uint32_t target = 0;
            int viewportX = 0;
            int viewportY = 0;
            std::uint32_t viewportWidth = 0;
            std::uint32_t viewportHeight = 0;
        };

        struct BufferSlot
        {
            wgpu::Buffer buffer;
            std::uint64_t capacity = 0;
            wgpu::BufferUsage usage = wgpu::BufferUsage::None;
        };

        NativeWebGPURenderer() = default;
        void ensureSurface(std::uint32_t width, std::uint32_t height);
        void ensurePipeline();
        void ensureBuffer(BufferSlot& slot, std::uint64_t bytes, const char* label, wgpu::BufferUsage usage);
        void upload(BufferSlot& slot, const void* data, std::uint64_t bytes, const char* label,
            wgpu::BufferUsage usage = wgpu::BufferUsage::Storage);
        void renderPass(unsigned int token, const PassState& state, std::uint32_t width,
            std::uint32_t height, const wgpu::TextureView& surfaceView, bool& touched);

        wgpu::Surface mSurface;
        wgpu::TextureFormat mSurfaceFormat = wgpu::TextureFormat::Undefined;
        std::uint32_t mWidth = 0;
        std::uint32_t mHeight = 0;
        wgpu::Texture mDepthTexture;
        wgpu::TextureView mDepthView;

        wgpu::BindGroupLayout mBindGroupLayout;
        wgpu::PipelineLayout mPipelineLayout;
        wgpu::RenderPipeline mPipeline;

        BufferSlot mLayouts;
        BufferSlot mInputs;
        BufferSlot mVertices;
        BufferSlot mMatrices;
        BufferSlot mMatrixIds;
        BufferSlot mTriangles;
        BufferSlot mMaterials;
        BufferSlot mTexels;
        BufferSlot mParams;
        BufferSlot mDummy;
    };
#endif
}

#endif
