#include "browserframe.hpp"

#ifdef __EMSCRIPTEN__
#include <emscripten.h>

extern "C" void omw_webcuda_release_pass(unsigned int token);

EM_JS_DEPS(omw_webgpu_frame_deps, "$WebGPU");
EM_JS(int, omw_webgpu_submit_frame, (const unsigned int* commands, std::size_t wordCount,
    WGPUBuffer directBuffer, std::size_t directBytes, unsigned int allocations, unsigned int reuses), {
    try {
        const submit = Module['webgpuSubmitFrame'];
        if (typeof submit !== 'function') throw Error('The batched WASM WebGPU host is not installed');
        const gpuBuffer = directBuffer ? WebGPU.getJsObject(Number(directBuffer)) : null;
        submit(HEAPU32.buffer, Number(commands), Number(wordCount), gpuBuffer, Number(directBytes),
            token => _omw_webcuda_release_pass(token));
        const stats = Module['webcudaTransportStats'];
        stats.directBufferAllocations = allocations;
        stats.directBufferReuses = reuses;
        return 1;
    } catch (error) {
        Module['webgpuSubmissionError'] = String(error?.stack ?? error);
        console.error('WASM WebGPU frame submission failed:', error);
        return 0;
    }
});

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
        auto lease = DirectWebGPU::instance().acquireUpload();
        commands.clear();
        commands.reserve(4096);
        // Magic, protocol version. Every following command has an opcode and
        // its complete word length, including that two-word command header.
        commands.push_back(0x4f4d5747u);
        commands.push_back(1);
        tokens.clear();
        upload = std::move(lease);
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
        return upload;
    }

    void finishBrowserFrame()
    {
        if (!active) throw std::logic_error("No WASM frame to submit");
        auto& direct = DirectWebGPU::instance();
        // All dynamic camera ranges occupy one immutable frame allocation.
        // Exactly one C API writeBuffer snapshots these bytes for the GPU.
        direct.submitUpload(*upload);
        if (!omw_webgpu_submit_frame(commands.data(), commands.size(), upload->buffer,
            upload->bytes.size(), direct.bufferAllocations(), direct.uploadReuses()))
            throw std::runtime_error("WASM WebGPU frame submission failed; see the browser error log");
        active = false;
        tokens.clear();
        upload.reset();
        commands.clear();
    }

    void abortBrowserFrame() noexcept
    {
        if (!active) return;
        active = false;
        for (const auto token : tokens) omw_webcuda_release_pass(token);
        tokens.clear();
        commands.clear();
        upload.reset();
    }
}
#endif
