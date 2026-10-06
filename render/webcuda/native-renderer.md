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

The latest staged engine is `f7c1bdb71a48`. Terrain layer blend masks now generate
in `terrain-blend.cu` for the WebCuda viewer. The engine captures immutable land
records instead of painting alpha images on the CPU. Morrowind's doubled texture
grid and ESM4's ordered opacity records retain their original layer order and
shared-edge rules. Layers share one source payload, and generated images use the
existing GPU texture/mipmap residency cache. The ordinary non-WebCuda renderer
keeps its original terrain path.

The real WASM64 terrain producer and material table produce 123 reference images
covering both formats, missing cells, duplicate layers, borders, chunk sizes and
opacity limits. Original and relocated packets pass 246 exact image comparisons
in WASM and another 246 on the RTX 5080, against the original CPU-painted masks,
with output guards intact. All 246 packets also pass host range validation.
Single-layer terrain omits masks in 19 cases. The generated paged kernel compiles
with ChromiumRTXCuda alpha.6's bundled NVRTC. All six WASM integration suites,
39 related host checks, six frame-lifetime checks and five pacing/guard checks
pass; the full engine rebuild/link and HTTP staging checks also pass. This does
not verify browser execution of this new kernel or establish gameplay FPS.

Reproduce the terrain producer comparison with
`wasm-build/test-webcuda-terrain.ps1`. It writes packets to
`D:/OpenMW-local/webcuda-tests/terrain-blend-fixtures.bin`; the NVCC build of
`render/webcuda/terrain-blend.test.cpp` consumes that file for the GPU comparison.

Engine `61275df13d9f` introduced the capture revision that resolves
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

Small-pass tile summaries, occlusion query results and existing diagnostic
samples now collect in a bounded GPU buffer before one readback at the frame
boundary. Each GPU copy snapshots its source before another pass can reuse
that storage. Results exceeding the 64 KiB collection budget use ordinary
ordered reads. Validation and mapping failures still prevent presentation;
queued GPU work drains before retained WASM packets or buffers are released.

Tile sizing defers only when the full mathematical upper bound fits either
the small-pass allocation allowance or existing candidate storage. A previous
frame's measured list size is insufficient proof when geometry moves. Larger
unproven passes still read the exact count before scattering or rasterizing.
In a controlled native-runtime test, 64 small pass snapshots use one readback
and one native submission instead of 64 of each, with identical dispatch/copy
ordering and total readback bytes. This isolates host scheduling with simulated
interop; actual browser submission totals and game FPS remain unmeasured.

The CUDA tile binner now intersects triangle coverage bounds with the material
scissor before counting or scattering references. Empty/offscreen scissors,
culling both faces, and multisample states that reject every sample produce no
references. Unsigned scissor extents clamp before addition, preserving the
rasterizer's behavior even for `UINT_MAX` extents. Unused clipping slots still
exit before fetching material state. The rasterizer and draw order are unchanged.

`tile-pruning.test.cpp` compares compact lists with an all-triangle reference
through the production material rasterizer. All 1,440 cases pass bit-for-bit on
both the CPU and a standalone native CUDA GPU run: color, depth and stencil,
fill/line/point modes, both windings, 1/2/4/8/16 samples, partial tiles, sample
mask/coverage controls and scissor edge cases. A controlled 1024-square case
with two screen triangles and a one-pixel scissor reduces tile references from
8,192 to two. This is a work-count reduction, not a measured game speedup.
Each backend compares its own reference; this does not assert bit identity
between CPU and GPU floating-point calculations.
The regenerated paged binner also passes the browser's bundled NVRTC compiler.
These checks do not exercise browser interop or full-game behavior.

Filled triangles now also reject tiles lying wholly outside any triangle edge.
Previously every tile in the rectangular bounds reached the rasterizer, where
each sample repeated triangle setup before discovering it was outside. The
CUDA binner evaluates the most permissive corner for each edge, with a margin
of 256 float epsilons times the squared coordinate scale. Ambiguous facing,
near-edge tiles, line modes and point modes retain their conservative bounds.
No packet layout, resource allocation or host-side rendering math changed.

`tile-coverage.test.cpp` adds 360 exact color/depth/stencil comparisons on both
CPU and native GPU, including near-collinear triangles, both windings, tiny and
partial targets, dimensions up to 8,193 pixels, and edges at and immediately
either side of multisample positions. Incrementing stencil on every covered
sample prevents later triangles from hiding missing coverage. The existing
1,440-case pruning suite also passes on both CPU and GPU with this revision.

Isolated RTX 5080 raster measurements at 1280x720, with 96 triangles:

| Synthetic geometry | Rectangle-list references | Edge-tested references | GPU raster before | GPU raster after |
| --- | ---: | ---: | ---: | ---: |
| Random triangles | 84,358 | 27,750 | 2.479 ms | 1.894 ms |
| Long thin triangles | 345,600 | 12,384 | 3.798 ms | 1.677 ms |

These are medians of nine CUDA event samples after three warmups, with test
order alternating. Both sides execute the same production raster kernel on
direct CUDA buffers; only their candidate lists differ. Binning, browser
interop, host capture and presentation are outside the timer. They establish
less GPU raster work in these fixtures, not the game's new frame rate. The
paged kernel passes bundled NVRTC compilation; generated WebGPU artifacts
are refreshed but this revision has not been run through browser WebGPU.

Filled samples now pass their coverage and top-left edge tests before computing
interpolation weights and gradients. The old order performed those divisions
for samples that would immediately be discarded. The surviving-sample arithmetic,
polygon line/point path, depth/stencil behavior and packet ABI are unchanged.
All rendering arithmetic remains in `material.cu`.

An optional prior-kernel mode in the coverage/pruning fixtures compares against
the unmodified rasterizer from commit `b3abd17b`. All 1,800 color/depth/stencil
comparisons pass exactly on both CPU and native GPU. The material/depth CPU suite,
39 related host checks and the paged raster kernel's bundled NVRTC compilation
also pass. Generated WGSL/native artifacts are refreshed and served; engine
`f7c1bdb71a48` remains current because no engine or host ABI changed.

Paired RTX 5080 medians, with identical compact candidate lists on both sides:

| Synthetic geometry | Shared tile references | Previous raster | Coverage-first raster |
| --- | ---: | ---: | ---: |
| Random triangles | 27,750 | 2.379 ms | 1.906 ms |
| Long thin triangles | 12,384 | 1.648 ms | 1.642 ms |

These use 1280x720, 96 triangles, nine CUDA-event measurements after three
warmups and alternating test order. The random fixture improves by about 20%;
the thin fixture is effectively unchanged. Neither measures browser overhead,
full-game FPS or variable-refresh presentation.

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
node --test render/webcuda/frame-readbacks.test.mjs render/webcuda/pipeline-readbacks.test.mjs render/webcuda/packet-validation.test.mjs render/webcuda/native-runtime.test.mjs render/webcuda/texture-residency.test.mjs render/webcuda/atlas-upload.test.mjs render/webcuda/bounded-batch.test.mjs
node --experimental-vm-modules --test render/webcuda/game-host-lifetime.test.mjs
node --test wasm-build/frame-pump.test.mjs render/webcuda/legacy-draw-guard.test.mjs render/webcuda/target-id.test.mjs
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

The subsequent readback scheduling change passes 46 host checks: 35 renderer
and storage checks, six frame-lifetime checks, and five pacing/guard/target-ID
checks. They include overwritten scratch buffers, mixed result types, staging
overflow, singular-camera and mapping failures, exact-sizing stalls, retained
capacity bounds, and presentation gating. This JavaScript-only change uses
the existing CUDA copy kernel and leaves engine and generated artifacts intact.
The local server serves the matching pipeline, host and new collector module.

For the tile-pruning regression, compile `render/webcuda/tile-pruning.test.cpp`
with ordinary C++17 or with NVCC using `-x cu -std=c++17 -O3 --use_fast_math
--extra-device-vectorization` and the target GPU architecture. This PC uses
`-arch=sm_120`. NVCC on Windows requires an x64 Visual Studio developer command
prompt. Both builds execute the same fixture; the NVCC build launches the real
production CUDA kernels. Current compiler/run logs and executables are under
`D:/OpenMW-local/webcuda-tests/tile-pruning-*`; the paged compiler report is
`D:/OpenMW-local/webcuda-tile-pruning-native-compile.json`.

Build `render/webcuda/tile-coverage.test.cpp` with the same commands and flags.
Its NVCC build accepts `--benchmark` for the two isolated raster measurements.
The CPU build runs correctness checks only. Current logs are
`D:/OpenMW-local/webcuda-tests/tile-coverage-{cpu,gpu}.log`; the paged compiler
report is `D:/OpenMW-local/webcuda-tile-coverage-native-compile.json`.

To compare raster revisions, save the preceding artifact's `native.source`
from `generated/raster_material.native.json` as `reference-material.cu` outside
the tracked source tree. Build the coverage/pruning fixtures with
`-DWEBCUDA_REFERENCE_RASTER` and add that directory to the include path. In this
mode the coverage benchmark uses identical compact lists for both kernels;
without the flag it retains the all-triangle/rectangular-list binning checks.
Current comparison logs are
`D:/OpenMW-local/webcuda-tests/raster-{coverage,pruning}-reference-{cpu,gpu}.log`.
The baseline for this change used the original `b3abd17b` material source with
its unchanged helper headers. The compiler report is
`D:/OpenMW-local/webcuda-raster-coverage-native-compile.json`.

For local serving, `/webcuda/` must expose this directory and `/webcuda-sdk/`
must expose the SDK checkout, alongside the matching WASM64 engine artifacts,
`frame-pump.js`, `streamfs.js` and the page stamped by
`wasm-build/stage-webcuda-page.py`. The local `.local-runtime/` tree, dependency
builds and retail game files are ignored. This branch is a source development
checkpoint; the upstream Docker/release packaging has not been updated to
install the renderer and SDK mounts.
