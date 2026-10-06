# Native CUDA renderer

The standard backend compiles authored `.cu` to WGSL and runs it through
WebGPU. ChromiumRTXCuda alpha.6 can instead compile the same renderer with
NVRTC and execute native CUDA. C++ retains the engine and scene capture;
JavaScript manages resources, input, uploads, dispatch and presentation.

## Current evidence

Engine `8b2f378cabc7` renders the Imperial Prison Ship and HUD through both
backends. The native browser compiled all 83 runtime kernels and passed 20 GPU
raster, depth, storage, upload and presentation checks. The first native game
report presented two frames, then hit the shared allocation budget while
replacing its texture atlas. After the allocation fix, a user screenshot shows
the ship, HUD and 16 native presentations without the previous fatal error.

That sample reports 119.2 ms scene capture, 434.1 ms render wall time and
565.3 ms between presentation submissions. It does not establish playable
performance or 60-180 Hz pacing. The subsequent native submission coalescing
change needs a fresh browser run. Broad gameplay, scene transitions, device
loss and permission revocation during gameplay remain pending.

Engine `339095a75c39` removed per-draw compact GLSL
string construction during material/projection identification and reserves
known vertex-packet capacities before packing. All six WASM64 integration
suites and the full incremental engine build/link pass. A 20,000-call WASM64
source microbenchmark reduced projection checks from 244.619 to 38.4993 ms and
non-particle rejection from 213.019 to 0.806 ms. These isolate CPU routines;
they do not measure the new game's frame rate. The user requested code-led
analysis and automated checks instead of additional screenshot requests.

The latest staged engine is `61275df13d9f`. Its capture revision resolves
array types, bindings and bounds once per
draw and reuses one merged state through geometry or particle capture. Readers
borrow only for the synchronous call, so changed arrays, shader sources and
states are observed on the next draw. UVs retain OSG's per-vertex behavior even
with BIND_OFF; ordinary disabled attributes retain current-value fallback.
Byte color conversion, homogeneous position/UV components and unsupported
format rejection are preserved. No transforms or shading moved out of CUDA.

Host validation now scans large float arrays with direct loops and derives
particle flags while validating the 34-field vertex records. It retains the
finite-value, array-shape and flag checks without repeatedly scanning whole
attribute buffers through JavaScript callbacks. Fixed-light enablement is
collected while its descriptors are already being validated.

Isolated before/after medians on this PC (nine measured samples after warmup):

| Routine | Before | After |
| --- | ---: | ---: |
| WASM64 capture: 384 draws, 96 vertices each | 50.811 ms | 6.660 ms |
| WASM64 capture: 192 draws, 768 vertices each | 166.654 ms | 14.530 ms |
| JS validation: 147,456 vertices, 25.9 MB | 30.837 ms | 3.175 ms |
| JS validation with additional particle classification | 80.601 ms | 3.169 ms |

The WASM benchmark uses the same O3 toolchain and OSG libraries on both sides,
six inherited state layers and 48 uniforms. Vertex, attribute, secondary-color,
matrix, triangle and matrix-index byte checksums match. The JS benchmark uses
shared typed-array views in Node. These are synthetic CPU/host measurements;
they do not establish game FPS, GPU execution time or presentation pacing.
Reports and reproducible sources are under `D:/OpenMW-local/` as
`webcuda-geometry-capture-benchmark.json` / `geometry-capture-benchmark.cpp` and
`webcuda-packet-validation-benchmark.json` / `packet-validation-benchmark.mjs`.

## Running

Open the staged game in ChromiumRTXCuda with `?backend=native`. The normal
browser Native CUDA permission is required. If permission is not already
granted, the page displays an explicit enable button. Ordinary browsers use
the CUDA-authored WebGPU backend.

Both backends display through a WebGPU canvas. Native mode copies
CUDA-produced packed pixels directly from shared GPU buffers into the canvas
texture. It does not run WGSL shaders or read frame pixels back through JS for
presentation. Diagnostic samples and engine image/fog readbacks are separate.

`?renderdebug=1` shows timing and a **Save renderer report** button. Reports
include live and peak shared allocation counts, growth reuse, the largest
buffers, submitted native batches and coalesced logical batches. Allocation
counts do not measure physical RAM/VRAM residency. Timings are wall-clock and
submission observations, not GPU timestamps or physical display scanout.

## Storage and lifetime

Alpha.6 allows 2 GiB of shared allocations, at most 256 shared resources, and
256 MiB per resource. `native-runtime.js` splits logical arrays into 64 MiB
pages. CUDA-owned address tables and authored `native-pages.cuh` and
`native-storage.cu` handle indexing and copies. Device addresses stay native;
JavaScript handles only opaque resources.

Every indirectly accessed shared page is explicitly bound in the same native
batch, allowing the browser to fence all access. Logical scratch-buffer growth
retains complete prefix pages and a separate table for each live version. It
allocates and copies only the partial tail, then frees pages after the last
version retires. These are mutable scratch aliases, not immutable copies.
Previous consumers must be submitted before writing a replacement.

Physical budgeting counts reused pages once and includes retired storage until
release finishes. A failed reservation leaves the old buffer owned and live.
Consecutive native submissions share a fence cycle until execution starts or
an upload, readback, allocation, presentation or destruction closes the group.
The 256-job batch limit includes page-table binding jobs, and every split binds
its pages again. Each invocation preserves its resource and scalar snapshot.

`OpenMW texels` is the combined texture/sampling atlas, including rendered
depth and color attachments. It is not a single Morrowind asset. An 8192-square
32-bit shadow plane needs 256 MiB in the depth target and again in the sampling
atlas. The default is now 2048: 16 MiB per copy. `?shadowres=8192` explicitly
requests the larger map. Saved game settings keep their usual precedence.

## Validation

`webcuda/validate-native.html` offers **All runtime kernels** and **Paged game
renderer** checks. In addition to raster and large-buffer fixtures, the current
source includes a new growth/retirement fixture awaiting native browser
execution. Compiler checks and fixtures are separate from full-game acceptance.

Run host regressions from the repository root:

```powershell
node --test render/webcuda/packet-validation.test.mjs render/webcuda/native-runtime.test.mjs render/webcuda/texture-residency.test.mjs render/webcuda/atlas-upload.test.mjs render/webcuda/bounded-batch.test.mjs
node --experimental-vm-modules --test render/webcuda/game-host-lifetime.test.mjs
.\wasm-build\test-webcuda-submission.ps1
```

The native host suite covers the reported allocation total and 294 MB atlas
request, growth lifetimes and failure cleanup, transfer ordering, coalesced
dispatches, actual batch-limit splitting and disposal. It uses a simulated
interop API and does not claim GPU or browser execution.

Regenerate CUDA artifacts through `wasm-build/compile-webcuda.mjs`; generated
WGSL and native JSON are outputs and must not be edited by hand. Native source
lowering changes the buffer ABI to paged indexing without replacing rendering
math. `wasm-build/check-native-cuda.py --paged` checks all 83 runtime kernels
and the two native storage kernels with the browser's bundled NVRTC.

The source checkpoint was also checked with all ten standalone CPU kernel
suites, 35 host/lifecycle/pacing checks, the six WASM64 integration suites and
the full engine build. All 351 generated artifacts reproduce byte-for-byte
with WebCuda SDK commit `d6b9de81a68c1ced62144d325fdc701dd368b6ea`;
the SDK's tracked compiler/runtime files were unchanged. The SDK remains an
external dependency. All 85 paged runtime/storage kernels passed the bundled
NVRTC compiler check. This does not repeat the earlier browser GPU checks or
establish sustained native gameplay performance.

For local serving, `/webcuda/` must expose this directory and `/webcuda-sdk/`
must expose the SDK checkout, alongside the matching WASM64 engine artifacts,
`frame-pump.js`, `streamfs.js` and the page stamped by
`wasm-build/stage-webcuda-page.py`. The local `.local-runtime/` tree, dependency
builds and retail game files are ignored. This branch is a source development
checkpoint; the upstream Docker/release packaging has not been updated to
install the renderer and SDK mounts.
