#include "directwebgpu.hpp"

#include <stdexcept>
#include <algorithm>

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#endif

namespace WebCuda
{
    DirectWebGPU& DirectWebGPU::instance()
    {
        static DirectWebGPU value;
        return value;
    }

    bool DirectWebGPU::attachBrowserDevice()
    {
#ifdef __EMSCRIPTEN__
        if (ready())
            return true;
        if (mRequestStarted)
            return false;

        mRequestStarted = true;
        mInitializationError.clear();
        mInstance = wgpuCreateInstance(nullptr);
        if (!mInstance)
        {
            mInitializationError = "Unable to create WebGPU instance";
            return false;
        }

        mInstance.RequestAdapter(nullptr, wgpu::CallbackMode::AllowSpontaneous,
            [this](wgpu::RequestAdapterStatus status, wgpu::Adapter adapter, wgpu::StringView message)
            {
                if (status != wgpu::RequestAdapterStatus::Success || !adapter)
                {
                    mInitializationError = "WebGPU adapter request failed";
                    if (message.length)
                        mInitializationError += ": " + std::string(message.data, message.length);
                    return;
                }

                mAdapter = adapter;
                wgpu::DeviceDescriptor descriptor{};
                descriptor.SetUncapturedErrorCallback(
                    [this](const wgpu::Device&, wgpu::ErrorType, wgpu::StringView message)
                    {
                        mInitializationError = "WebGPU validation error";
                        if (message.length)
                            mInitializationError += ": " + std::string(message.data, message.length);
                    });

                mAdapter.RequestDevice(&descriptor, wgpu::CallbackMode::AllowSpontaneous,
                    [this](wgpu::RequestDeviceStatus deviceStatus, wgpu::Device device, wgpu::StringView deviceMessage)
                    {
                        if (deviceStatus != wgpu::RequestDeviceStatus::Success || !device)
                        {
                            mInitializationError = "WebGPU device request failed";
                            if (deviceMessage.length)
                                mInitializationError += ": " + std::string(deviceMessage.data, deviceMessage.length);
                            return;
                        }

                        mOwnedDevice = device;
                        mOwnedQueue = device.GetQueue();
                        mDevice = mOwnedDevice.Get();
                        mQueue = mOwnedQueue.Get();
                        try
                        {
                            finishDeviceSetup();
                        }
                        catch (const std::exception& error)
                        {
                            mInitializationError = error.what();
                            mDevice = nullptr;
                            mQueue = nullptr;
                            mOwnedQueue = {};
                            mOwnedDevice = {};
                        }
                    });
            });
        return false;
#else
        return false;
#endif
    }

#ifdef __EMSCRIPTEN__
    void DirectWebGPU::finishDeviceSetup()
    {
        if (!mDevice || !mQueue)
            throw std::runtime_error("WebGPU device did not expose a queue");

        WGPULimits limits{};
        if (wgpuDeviceGetLimits(mDevice, &limits) != WGPUStatus_Success
            || !limits.maxBufferSize || !limits.maxStorageBufferBindingSize
            || !limits.minStorageBufferOffsetAlignment)
            throw std::runtime_error("Unable to query direct WebGPU buffer limits");

        mBufferLimit = limits.maxBufferSize;
        mBindingLimit = limits.maxStorageBufferBindingSize;
        mStorageAlignment = limits.minStorageBufferOffsetAlignment;
        ++mGeneration;
    }
#endif

    bool DirectWebGPU::ready() const noexcept
    {
#ifdef __EMSCRIPTEN__
        return mDevice != nullptr && mQueue != nullptr;
#else
        return false;
#endif
    }

    void DirectWebGPU::shutdown()
    {
#ifdef __EMSCRIPTEN__
        ++mGeneration;
        for (const auto& upload : mFreeUploads)
            if (upload->buffer)
            {
                wgpuBufferDestroy(upload->buffer);
                wgpuBufferRelease(upload->buffer);
            }
        mFreeUploads.clear();
        mCachedBytes = 0;
        mBufferLimit = 0;
        mBindingLimit = 0;
        mDevice = nullptr;
        mQueue = nullptr;
        mOwnedQueue = {};
        mOwnedDevice = {};
        mAdapter = {};
        mInstance = {};
        mRequestStarted = false;
        mInitializationError.clear();
#endif
    }

#ifdef __EMSCRIPTEN__
    DirectWebGPU::UploadPtr DirectWebGPU::acquireUpload()
    {
        if (!ready())
            throw std::logic_error("Direct WebGPU device is not attached");
        std::unique_ptr<Upload> upload;
        if (!mFreeUploads.empty())
        {
            upload = std::move(mFreeUploads.back());
            mFreeUploads.pop_back();
            mCachedBytes -= upload->capacity + upload->bytes.capacity();
            ++mUploadReuses;
        }
        else
            upload = std::make_unique<Upload>();
        upload->bytes.clear();
        upload->generation = mGeneration;
        return UploadPtr(upload.release(), [this](Upload* value) { recycleUpload(value); });
    }

    void DirectWebGPU::submitUpload(Upload& upload)
    {
        if (!ready() || upload.generation != mGeneration)
            throw std::logic_error("Direct WebGPU frame belongs to a replaced device");
        const auto bytes = upload.bytes.size();
        if (!bytes)
            return;
        if (bytes > mBufferLimit)
            throw std::length_error("Direct WebGPU frame exceeds maxBufferSize");
        if (upload.capacity < bytes)
        {
            // Geometric growth amortizes both driver allocation and WASM staging
            // growth; never round a valid request beyond the adapter's limit.
            std::uint64_t capacity = std::max<std::uint64_t>(4096, upload.capacity);
            while (capacity < bytes && capacity <= mBufferLimit / 2)
                capacity *= 2;
            capacity = std::max<std::uint64_t>(bytes, std::min(capacity, mBufferLimit));
            const auto usage = static_cast<WGPUBufferUsage>(WGPUBufferUsage_CopyDst | WGPUBufferUsage_CopySrc
                | WGPUBufferUsage_Storage | WGPUBufferUsage_Vertex | WGPUBufferUsage_Index | WGPUBufferUsage_Indirect);
            auto replacement = createBuffer(capacity, usage, "OpenMW WASM frame upload");
            if (upload.buffer)
            {
                wgpuBufferDestroy(upload.buffer);
                wgpuBufferRelease(upload.buffer);
            }
            upload.buffer = replacement;
            upload.capacity = capacity;
            ++mBufferAllocations;
        }
        writeBuffer(upload.buffer, 0, upload.bytes.data(), bytes);
    }

    void DirectWebGPU::recycleUpload(Upload* value) noexcept
    {
        std::unique_ptr<Upload> upload(value);
        constexpr std::uint64_t cacheBudget = 256ull * 1024 * 1024;
        const auto cost = upload->capacity + upload->bytes.capacity();
        if (ready() && upload->generation == mGeneration && mFreeUploads.size() < 4
            && cost <= cacheBudget && mCachedBytes <= cacheBudget - cost)
        {
            try
            {
                upload->bytes.clear();
                mFreeUploads.push_back(std::move(upload));
                mCachedBytes += cost;
                return;
            }
            catch (...) {} // Releasing a frame must remain non-throwing.
        }
        if (upload && upload->buffer)
        {
            // Submitted GPU commands may still use this lease. Dropping our
            // reference is safe; explicit destroy is reserved for free leases.
            wgpuBufferRelease(upload->buffer);
        }
    }

    WGPUBuffer DirectWebGPU::createBuffer(std::uint64_t bytes, WGPUBufferUsage usage, const char* label) const
    {
        if (!ready())
            throw std::logic_error("Direct WebGPU device is not attached");
        if (!bytes)
            bytes = 4;
        if (bytes > mBufferLimit || bytes % 4)
            throw std::length_error("Invalid direct WebGPU buffer size");

        WGPUBufferDescriptor descriptor{};
        descriptor.size = bytes;
        descriptor.usage = usage;
        descriptor.mappedAtCreation = false;
        if (label)
        {
            descriptor.label.data = label;
            descriptor.label.length = WGPU_STRLEN;
        }

        auto buffer = wgpuDeviceCreateBuffer(mDevice, &descriptor);
        if (!buffer)
            throw std::runtime_error("Failed to create direct WebGPU buffer");
        return buffer;
    }

    void DirectWebGPU::writeBuffer(
        WGPUBuffer buffer, std::uint64_t offset, const void* data, std::size_t bytes) const
    {
        if (!ready() || !buffer)
            throw std::logic_error("Invalid direct WebGPU upload");
        if (!bytes)
            return;
        if (!data)
            throw std::invalid_argument("Direct WebGPU upload has no source data");
        if (offset % 4 || bytes % 4)
            throw std::invalid_argument("Direct WebGPU upload must be four-byte aligned");
        wgpuQueueWriteBuffer(mQueue, buffer, offset, data, bytes);
    }
#endif
}
