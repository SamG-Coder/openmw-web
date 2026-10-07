#include "browserframe.hpp"

#ifdef __EMSCRIPTEN__
#include <emscripten.h>

#include "browserbridge.hpp"
#include "nativewebgpu.hpp"

namespace WebCuda
{
    namespace
    {
        bool active = false;
        std::vector<std::uint32_t> commands;
        std::vector<unsigned int> tokens;
        DirectWebGPU::UploadPtr upload;
    }

    bool browserFrameActive() noexcept { return active; }

    void beginBrowserFrame()
    {
        if (active) throw std::logic_error("Nested WASM frame capture");
        commands.clear();
        commands.reserve(4096);
        commands.push_back(0x4f4d5747u);
        commands.push_back(1);
        tokens.clear();
        upload.reset();
        active = true;
    }

    std::vector<std::uint32_t>& browserCommandWords()
    {
        if (!active) throw std::logic_error("No active WASM frame capture");
        return commands;
    }

    void trackBrowserPass(unsigned int token)
    {
        if (!active) throw std::logic_error("WASM pass recorded outside a frame");
        tokens.push_back(token);
    }

    DirectWebGPU::UploadPtr browserFrameUpload()
    {
        if (!active) throw std::logic_error("WASM upload recorded outside a frame");
        if (!upload)
            upload = DirectWebGPU::instance().acquireUpload();
        return upload;
    }

    void finishBrowserFrame()
    {
        if (!active) throw std::logic_error("No WASM frame to submit");
        try
        {
            NativeWebGPURenderer::instance().submitFrame(commands);
        }
        catch (...)
        {
            for (const auto token : tokens) releaseBrowserPass(token);
            active = false;
            tokens.clear();
            upload.reset();
            commands.clear();
            throw;
        }

        for (const auto token : tokens) releaseBrowserPass(token);
        active = false;
        tokens.clear();
        upload.reset();
        commands.clear();
    }

    void abortBrowserFrame() noexcept
    {
        if (!active) return;
        active = false;
        for (const auto token : tokens) releaseBrowserPass(token);
        tokens.clear();
        commands.clear();
        upload.reset();
    }
}
#endif
