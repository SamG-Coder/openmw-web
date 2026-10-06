// Optional before/after check against a saved, unmodified material.cu.
// Put reference-material.cu on the compiler's include path and define
// WEBCUDA_REFERENCE_RASTER. Each backend compares against its own arithmetic.
#ifdef WEBCUDA_REFERENCE_RASTER
namespace WebCudaReference {
#include "reference-material.cu"
}
#define WEBCUDA_REFERENCE_ENTRY WebCudaReference::raster_material
constexpr bool comparePreviousRaster = true;
#else
#define WEBCUDA_REFERENCE_ENTRY raster_material
constexpr bool comparePreviousRaster = false;
#endif
