#ifndef OPENMW_COMPONENTS_WEBCUDA_BROWSERBRIDGE_H
#define OPENMW_COMPONENTS_WEBCUDA_BROWSERBRIDGE_H
#include "geometrypacket.hpp"
#include "materialtable.hpp"
#include "directwebgpu.hpp"
#include <vector>
namespace WebCuda
{
#ifdef __EMSCRIPTEN__
    struct RetainedPass
    {
        GeometryPacket geometry;
        std::shared_ptr<const MaterialTable> table;
        DirectWebGPU::UploadPtr directUpload;
        std::vector<unsigned int> directRanges;
        std::size_t directBytes = 0;
    };

    const RetainedPass* retainedBrowserPass(unsigned int token) noexcept;
    void releaseBrowserPass(unsigned int token) noexcept;
#endif
    // Transfers geometry ownership and retains an immutable material snapshot.
    // The synchronous consumer receives shared-WASM views and an idempotent
    // release() callback. It must release accepted packets after its last CPU
    // read/upload, including abort/error/disposal paths. Rejection releases here.
    // Callers must detach a shared material table before modifying it again.
    bool submitBrowserPass(GeometryPacket, std::shared_ptr<MaterialTable>, std::uint32_t width, std::uint32_t height);
}
#endif
