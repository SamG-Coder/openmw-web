#ifndef OPENMW_COMPONENTS_WEBCUDA_DIRECTWEBGPU_H
#define OPENMW_COMPONENTS_WEBCUDA_DIRECTWEBGPU_H

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>
#include <string>

#ifdef __EMSCRIPTEN__
#include <webgpu/webgpu.h>
#include <webgpu/webgpu_cpp.h>
#endif

namespace WebCuda
{
    // Imports the browser device once and owns the frame upload allocations.
    // A lease is returned only after all commands referencing it have been
    // submitted (or discarded), so later queue writes cannot overwrite a frame.
    class DirectWebGPU
    {
    public:
        static DirectWebGPU& instance();

        bool attachBrowserDevice();
        bool ready() const noexcept;
        void shutdown();

#ifdef __EMSCRIPTEN__
        struct Upload
        {
            WGPUBuffer buffer = nullptr;
            std::vector<unsigned char> bytes;
            std::uint64_t capacity = 0;
            std::uint64_t generation = 0;
        };
        using UploadPtr = std::shared_ptr<Upload>;

        WGPUDevice device() const noexcept { return mDevice; }
        WGPUQueue queue() const noexcept { return mQueue; }
        const wgpu::Instance& instanceObject() const noexcept { return mInstance; }
        const wgpu::Adapter& adapterObject() const noexcept { return mAdapter; }
        const wgpu::Device& deviceObject() const noexcept { return mOwnedDevice; }
        const wgpu::Queue& queueObject() const noexcept { return mOwnedQueue; }
        const std::string& initializationError() const noexcept { return mInitializationError; }

        UploadPtr acquireUpload();
        void submitUpload(Upload&);
        std::uint64_t bufferLimit() const noexcept { return mBufferLimit; }
        std::uint64_t bindingLimit() const noexcept { return mBindingLimit; }
        std::uint32_t storageAlignment() const noexcept { return mStorageAlignment; }
        std::uint32_t bufferAllocations() const noexcept { return mBufferAllocations; }
        std::uint32_t uploadReuses() const noexcept { return mUploadReuses; }

        WGPUBuffer createBuffer(std::uint64_t bytes, WGPUBufferUsage usage, const char* label = nullptr) const;
        void writeBuffer(WGPUBuffer buffer, std::uint64_t offset, const void* data, std::size_t bytes) const;
#endif

    private:
        DirectWebGPU() = default;
        DirectWebGPU(const DirectWebGPU&) = delete;
        DirectWebGPU& operator=(const DirectWebGPU&) = delete;

#ifdef __EMSCRIPTEN__
        void recycleUpload(Upload*) noexcept;
        void finishDeviceSetup();
        wgpu::Instance mInstance;
        wgpu::Adapter mAdapter;
        wgpu::Device mOwnedDevice;
        wgpu::Queue mOwnedQueue;
        bool mRequestStarted = false;
        std::string mInitializationError;
        WGPUDevice mDevice = nullptr;
        WGPUQueue mQueue = nullptr;
        std::vector<std::unique_ptr<Upload>> mFreeUploads;
        std::uint64_t mGeneration = 0;
        std::uint64_t mBufferLimit = 0;
        std::uint64_t mBindingLimit = 0;
        std::uint64_t mCachedBytes = 0;
        std::uint32_t mStorageAlignment = 256;
        std::uint32_t mBufferAllocations = 0;
        std::uint32_t mUploadReuses = 0;
#endif
    };
}

#endif
