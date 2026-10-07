#ifndef OPENMW_COMPONENTS_WEBCUDA_BROWSERFRAME_H
#define OPENMW_COMPONENTS_WEBCUDA_BROWSERFRAME_H

#include "directwebgpu.hpp"
#include <cstring>
#include <limits>
#include <stdexcept>

namespace WebCuda
{
#ifdef __EMSCRIPTEN__
    // Fixed-width command ABI, decoded by render/webgpu/wasm-frame.js. Addresses
    // and size_t values use two words, never a JS bitwise pointer conversion.
    enum class BrowserOpcode : std::uint32_t
    {
        PassState = 1, Pass, ResolveAttachment, RetireTarget, DepthIsolation,
        Debug, Bloom, Luminance, Distort, Adjust, Resolve, CaptureDepth,
        ColorTarget, Ripples, Snapshot, CaptureImage, CaptureTimings, ShaderStats
    };

    bool browserFrameActive() noexcept;
    void beginBrowserFrame();
    void finishBrowserFrame();
    void abortBrowserFrame() noexcept;
    void trackBrowserPass(unsigned int token);
    DirectWebGPU::UploadPtr browserFrameUpload();
    std::vector<std::uint32_t>& browserCommandWords();

    class BrowserCommand
    {
    public:
        explicit BrowserCommand(BrowserOpcode opcode)
            : mWords(browserCommandWords()), mStart(mWords.size())
        {
            mWords.push_back(static_cast<std::uint32_t>(opcode));
            mWords.push_back(0);
        }
        ~BrowserCommand() { mWords[mStart + 1] = static_cast<std::uint32_t>(mWords.size() - mStart); }
        BrowserCommand(const BrowserCommand&) = delete;
        BrowserCommand& operator=(const BrowserCommand&) = delete;
        BrowserCommand& u32(std::uint32_t value) { mWords.push_back(value); return *this; }
        BrowserCommand& i32(std::int32_t value) { return u32(static_cast<std::uint32_t>(value)); }
        BrowserCommand& u64(std::uint64_t value) { return u32(value & 0xffffffffu).u32(value >> 32); }
        BrowserCommand& f32(float value)
        {
            std::uint32_t bits;
            std::memcpy(&bits, &value, sizeof(bits));
            return u32(bits);
        }
        BrowserCommand& f64(double value)
        {
            std::uint64_t bits;
            std::memcpy(&bits, &value, sizeof(bits));
            return u64(bits);
        }
        template<class T> BrowserCommand& words(const T* values, std::size_t count)
        {
            static_assert(sizeof(T) == 4);
            if (count > std::numeric_limits<std::uint32_t>::max() - mWords.size())
                throw std::length_error("WASM frame command is too large");
            const auto start = mWords.size();
            mWords.resize(start + count);
            if (count) std::memcpy(mWords.data() + start, values, count * sizeof(T));
            return *this;
        }
        template<class T> BrowserCommand& view(const std::vector<T>& values)
        {
            static_assert(sizeof(T) == 4);
            return u64(reinterpret_cast<std::uintptr_t>(values.data())).u64(values.size());
        }
    private:
        std::vector<std::uint32_t>& mWords;
        std::size_t mStart;
    };
#endif
}
#endif
