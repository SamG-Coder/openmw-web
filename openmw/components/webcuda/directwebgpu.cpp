#include "directwebgpu.hpp"

#include <stdexcept>

#ifdef __EMSCRIPTEN__
#include <emscripten.h>

EM_JS(WGPUDevice, omw_webgpu_import_boot_device, (), {
    if (!Module.webcudaJsDevice)
        return 0;
    if (typeof WebGPU === 'undefined' || typeof WebGPU.importJsDevice !== 'function')
        throw new Error('Emdawnwebgpu object interop is unavailable');
    return WebGPU.importJsDevice(Module.webcudaJsDevice);
});
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
        if (mDevice)
            return true;

        mDevice = omw_webgpu_import_boot_device();
        if (!mDevice)
            return false;

        mQueue = wgpuDeviceGetQueue(mDevice);
        if (!mQueue)
        {
            wgpuDeviceRelease(mDevice);
            mDevice = nullptr;
            return false;
        }
        return true;
#else
        return false;
#endif
    }

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
        if (mQueue)
        {
            wgpuQueueRelease(mQueue);
            mQueue = nullptr;
        }
        if (mDevice)
        {
            wgpuDeviceRelease(mDevice);
            mDevice = nullptr;
        }
#endif
    }

#ifdef __EMSCRIPTEN__
    WGPUBuffer DirectWebGPU::createBuffer(std::uint64_t bytes, WGPUBufferUsage usage, const char* label) const
    {
        if (!ready())
            throw std::logic_error("Direct WebGPU device is not attached");
        if (!bytes)
            bytes = 4;

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
        wgpuQueueWriteBuffer(mQueue, buffer, offset, data, bytes);
    }
#endif
}
