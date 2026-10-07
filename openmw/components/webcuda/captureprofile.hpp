#ifndef OPENMW_COMPONENTS_WEBCUDA_CAPTUREPROFILE_H
#define OPENMW_COMPONENTS_WEBCUDA_CAPTUREPROFILE_H
#include <array>
#include <chrono>
#include <cstddef>
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#include "shaderanalysis.hpp"
#endif

namespace WebCuda
{
    // Diagnostic counters for the single render-submission thread. Nested
    // material encoding counts once in the inclusive material total; atlas
    // allocation time is also reported separately as a subset of that total.
    enum class CapturePhase : std::size_t { MaterialCopy, MaterialEncode, GeometryEncode, AtlasResize, Count };
    struct CaptureProfile
    {
        static constexpr auto Count=static_cast<std::size_t>(CapturePhase::Count);
        bool enabled=false;
        std::array<double,Count*2> values{}; // milliseconds, then outer call counts
        std::array<unsigned int,Count> depth{};
    };
    inline CaptureProfile captureProfile;
    inline void beginCaptureProfile(bool enabled)
    {
        captureProfile={};captureProfile.enabled=enabled;
#ifdef __EMSCRIPTEN__
        // Opt-in CPU counters only. No GPU readback, queue wait, or per-vertex
        // JS callback; report cumulative shader-analysis reuse once per accepted frame.
        if(enabled)
        {
            const auto stats=ShaderAnalysisDetail::cache().stats();
            EM_ASM({
                Module.webcudaShaderAnalysisStats = { hits: $0, misses: $1, bypasses: $2 };
            }, static_cast<double>(stats.hits), static_cast<double>(stats.misses),
                static_cast<double>(stats.bypasses));
        }
#endif
    }
    class CaptureScope
    {
    public:
        explicit CaptureScope(CapturePhase phase):mPhase(static_cast<std::size_t>(phase)),mEnabled(captureProfile.enabled)
        {
            if(mEnabled&&captureProfile.depth[mPhase]++==0) {
                mStart=Clock::now();mOuter=true;
                ++captureProfile.values[CaptureProfile::Count+mPhase];
            }
        }
        ~CaptureScope()
        {
            if(mEnabled) {
                --captureProfile.depth[mPhase];
                if(mOuter)captureProfile.values[mPhase]+=std::chrono::duration<double,std::milli>(Clock::now()-mStart).count();
            }
        }
        CaptureScope(const CaptureScope&)=delete;
        CaptureScope& operator=(const CaptureScope&)=delete;
    private:
        using Clock=std::chrono::steady_clock;
        std::size_t mPhase;
        bool mEnabled,mOuter=false;
        Clock::time_point mStart;
    };
}
#endif
