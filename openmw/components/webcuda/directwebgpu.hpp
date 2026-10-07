#ifndef OPENMW_COMPONENTS_WEBCUDA_DIRECTWEBGPU_H
#define OPENMW_COMPONENTS_WEBCUDA_DIRECTWEBGPU_H

#include <cstddef>
#include <cstdint>

#ifdef __EMSCRIPTEN__
#include <webgpu/webgpu.h>
#endif

namespace WebCuda
{
    // Transitional owner for the direct WASM -> WebGPU path. The browser device
    // is imported once from the bootstrapping JS host; all per-frame GPU work
    // can then be issued through webgpu.h without rebuilding scene packets in JS.
    class DirectWebGPU
    {
    public:
        static DirectWebGPU& instance();

        bool attachBrowserDevice();
        bool ready() const noexcept;
        void shutdown();

#ifdef __EMSCRIPTEN__
        WGPUDevice device() const noexcept { return mDevice; }
        WGPUQueue queue() const noexcept { return mQueue; }

        WGPUBuffer createBuffer(std::uint64_t bytes, WGPUBufferUsage usage, const char* label = nullptr) const;
        void writeBuffer(WGPUBuffer buffer, std::uint64_t offset, const void* data, std::size_t bytes) const;
#endif

    private:
        DirectWebGPU() = default;
        DirectWebGPU(const DirectWebGPU&) = delete;
        DirectWebGPU& operator=(const DirectWebGPU&) = delete;

#ifdef __EMSCRIPTEN__
        WGPUDevice mDevice = nullptr;
        WGPUQueue mQueue = nullptr;
#endif
    };
}

#endif
