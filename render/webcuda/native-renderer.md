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

Engine `f7c1bdb71a48` introduced terrain layer blend masks generated
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

The current WebGPU browser check compiles all 84 runtime kernels and passes 34
GPU output checks on the NVIDIA Blackwell adapter. Sixteen checks now execute
the production `MaterialPipeline`, including empty-camera preservation, selective
color/depth/stencil clears, partial viewports, trailing guards, 1x/4x sampling,
transformed/clipped geometry, blending and depth rejection. Terrain masks are
generated by `terrain-blend.cu`, sampled by the rasterizer, and checked again
after another pass overwrites the atlas and the residency cache restores them.
The old `validate.html` bookmark forwards to this current harness instead of
running its obsolete packet and kernel signatures.

The host now omits clear dispatches with a zero clear mask and raster dispatches
with no input triangles. These states occur in terrain composite, HUD and
sun-query cameras. Texture preparation, status checks and attachment resolves
still run. All 40 related host tests pass. That dispatch change did not alter
CUDA, the packet ABI or the `f7c1bdb71a48` engine binary.

The new pipeline checks are also wired into native validation when both **All
runtime kernels** and **Paged game renderer** are selected. Their native-browser
execution remains unverified. The WebGPU checks are controlled fixtures, not
full-game or refresh-rate acceptance. The main WebGPU raster pipeline took
324.58 seconds to compile in the first run and 245.94 seconds in the second;
these are startup compilation times, not frame rendering times.

The staged engine was then run in the Imperial Prison Ship at 1280x720 through
WebGPU. The saved report records 197 presentations, no renderer/pass error and
zero attempted legacy WebGL draws. Continued observation reached 979
presentations with the same guard/error result and zero retained packets at the
completed-frame boundary. The engine log confirms the loaded cell.

Across the last 120 scene frames in that report, medians are 55.878 ms capture,
70.693 ms renderer wall time and 133.610 ms between presentation submissions.
The diagnostic mode was enabled; these are not physical scanout measurements
or native CUDA timings. The result still falls well short of 60-180 Hz.
Material encoding accounts for 30.362 ms and geometry encoding for 11.577 ms
of capture. The report records zero copied scene bytes in the WASM-to-JS bridge,
15,306,904 bytes uploaded per frame and 952,972,204 bytes of allocated runtime
buffers. Allocated buffer capacity is not a process-RAM or VRAM residency reading.

The report and derived summary are saved at
`D:/OpenMW-local/webcuda-ship-2026-10-06.json` and
`D:/OpenMW-local/webcuda-ship-2026-10-06-summary.json`.

The exterior acceptance run exposed a missing route for OSG's unnamed default
GLES3 program from `StateSet::setGlobalDefaults`. It aborted scene capture
before GPU submission; the sole presented frame was startup work. The replacement
now recognizes the complete stock vertex/fragment sources and routes their
texture-times-vertex-color contract to the existing CUDA kernels. It follows the
`baseTexture` sampler, ignores inherited fixed-function `TexMat`, and retains
camera MVP and raster state. Modified sources and extra shader stages remain
unsupported rather than silently taking that route.

Material capture now resolves inherited draw state once and shares that snapshot
across texture layers, shadow samplers and screen-effect inputs. Each public draw
still resolves current state, including uniform edits and override/protected
inheritance. This removes repeated state-map allocation without a persistent
cache or moving rendering arithmetic out of CUDA.

The final WASM64 O3 comparison uses 640 draws, six inherited state layers,
49 uniforms, nine measured runs after two warmups, and changing alpha input on
every draw. Material, texture, raster, decode and resource packet checksums match.
One texture layer improves from 14.285 to 5.996 ms; five layers improve from
32.307 to 7.495 ms. These isolate material capture, not game FPS. Sources and
report are `D:/OpenMW-local/material-capture-benchmark.cpp`,
`D:/OpenMW-local/run-material-benchmark.ps1`, and
`D:/OpenMW-local/webcuda-material-state-reuse-benchmark.json`.

All six WASM64 integration suites pass, including the real dependency's default
shader producer, edited-source rejection, sampler mutations, and UV/MVP capture.
The full incremental engine build/link passes. Engine `5e3aac5d0ae8` is staged;
HTTP range, MIME, isolation headers and served-module checks pass.

Before clipping compaction, that build advanced through Seyda Neen and its neighboring exterior cells
at 1280x720 through WebGPU. The saved report records 144 presentations, zero
aborted captures, zero legacy WebGL draw attempts and no renderer/pass errors.
All 120 sampled scene frames release their retained packets. Their medians are
117.772 ms capture, 231.180 ms renderer wall time and 360.277 ms between
presentation submissions, with debug instrumentation enabled. After saving this
report, the run stopped at frame 159 with `Invalid pipeline buffer size for
clippedAttributes`. The report covers the earlier successful window, not
sustained stability, visual fidelity or 60-180 Hz acceptance.

That exterior run exposed the resource bottleneck: 3,849,682,628 bytes of runtime
buffer capacity and a median 105,470,192 bytes uploaded per frame, compared with
66,493,608 bytes in the texture cache. These are allocated capacities, not a
process-RAM or measured VRAM residency total. The source reserves seven output
triangle slots for every input triangle, then allocates expanded vertex and
attribute storage for all seven. The report's main pass has 464,266 input
triangles and its reflection pass has 226,138. The allocation failure occurs
before the GPU can render the larger streamed scene. Native shared-memory
budget compatibility remains a separate acceptance boundary.

The report and derived summary are
`D:/OpenMW-local/webcuda-seyda-neen-2026-10-06.json` and
`D:/OpenMW-local/webcuda-seyda-neen-2026-10-06-summary.json`.


Large cameras now compact live clipping slots in `clip-compact.cu` before
allocating expanded attributes and vertices. Prefix counts and stable scatter
retain primitive order. The slot map redirects reads of original positions,
weights, material IDs, provoking colors and lighting; output indices remain
compact. Small passes below 4,096 input triangles retain bounded allocation
without the new sizing readback. All rendering calculations remain in `.cu`.

`clip-compact.test.cpp` compares all five production assembly kernels with the
uncompacted output over 4,781 reserved slots, including mixed clipping, fully
populated/empty inputs, block boundaries and slot zero. Every field and trailing
guard matches on both CPU and native RTX 5080 execution. The 43 host checks, six
frame-lifetime checks and five pacing/guard/target-ID checks pass. All 87 runtime
kernels compile in WebGPU; 36 GPU output checks pass, including 18 production
pipeline fixtures. Bundled NVRTC compiles 89 paged runtime/storage kernels.

Compile `render/webcuda/clip-compact.test.cpp` as C++17 or with NVCC
`-x cu -std=c++17 -O2 -arch=sm_120` to reproduce the assembly comparison.
Browser fixtures also exercise the 4,096-triangle threshold with surviving
triangles across prefix blocks and with every triangle rejected. Reports are
`D:/OpenMW-local/webcuda-clip-compaction-browser-validation.json` and
`D:/OpenMW-local/webcuda-clip-compaction-native-compile.json`. These controlled
checks do not establish native browser gameplay or refresh-rate performance.


The compacted WebGPU exterior run saved 423 presentations without renderer/pass
errors, aborted captures or legacy WebGL draws, passing the former frame-159
failure. The run subsequently reached 607 presentations with those counters
still clear before closing the test tab. At frame 165 its main pass contained 509,731 input triangles. Retained
runtime buffer capacity reached 1,925,634,524 bytes versus 3,849,682,628 in the
previous report; texture residency was 67,032,508 bytes. These are allocation
capacities, not measured RAM/VRAM residency or a native interop budget result.

The last 120 captured scene frames released every packet and copied zero scene
bytes into separate JS arrays. Median capture was 90.067 ms, renderer wall time
177.732 ms, submission interval 278.355 ms, and uploads 83,743,624 bytes/frame.
Scene contents changed while streaming, so these windows are not a matched
before/after performance benchmark. Repeated capture and geometry upload are
the next priority; smooth 60-180 Hz gameplay is still unachieved. The report and
summary are `D:/OpenMW-local/webcuda-seyda-neen-compaction-2026-10-06.json` and
`D:/OpenMW-local/webcuda-seyda-neen-compaction-2026-10-06-summary.json`.
All 367 generated artifacts reproduce byte-for-byte with the unchanged tracked
SDK compiler/runtime files. Native standalone CUDA and compilation checks do
not replace a current native-browser exterior or lifecycle run.

## Pooled immutable image storage

The image cache previously created one native buffer and address table per
immutable image. The exterior report contains more than 650 cached images,
which cannot fit alpha.6's 256 shared-resource and 256 address-table limits,
even when their combined byte size fits. Each small shared allocation also
rounds up to 64 KiB.

`texture-residency.js` now suballocates image ranges from one lazily allocated
64 MiB buffer. The default pool uses one native page and one address table.
Image versions remain immutable, and copies use the saved pool offset when
restoring an image at a different atlas location. Eviction removes lookup
membership immediately, but its range becomes reusable only after the caller
completes the GPU queue and collects retirement. Adjacent free ranges merge;
fragmented space never permits an overlapping allocation. A miss that cannot
fit bypasses the cache until a later frame. Disposal releases the pool.

Cache reports distinguish `allocatedBytes` (retained pool capacity) from
`occupiedBytes` (live images plus ranges awaiting retirement). This change
manages host resource ownership; image decoding, mip generation, rendering and
the native GPU copy operation remain authored CUDA.

The 45 relevant host regressions and six frame-lifetime checks pass. A native
runtime regression captures and restores 700 images using two shared pages and
two address tables including the source atlas, checks all 1,400 copy offsets,
and preserves the 256-job batch limit. It uses the simulated interop API.
The browser WebGPU run compiles all 87 runtime kernels and passes 37 output
checks. Its new pooled-cache fixture compares all pixels and guards after
queuing atlas poisoning and relocating 700 variable-sized images. The same
fixture is wired into paged native validation but has not run in that browser.
Reports are `D:/OpenMW-local/webcuda-resident-arena-browser-validation.json`
and `D:/OpenMW-local/webcuda-resident-arena-*-tests.log`.

The exterior WebGPU regression saved 337 presentations with no renderer/pass
errors, aborted captures or legacy WebGL draws and subsequently reached 481
presentations with those counters still clear. The saved report exercised 232 cache evictions
and 787 stores while retaining exactly 67,108,864 bytes of pool capacity.
The saved snapshot holds 555 images occupying 66,278,972 bytes; an earlier
snapshot held 675 images. All last 120 completed scene frames released their
packets, and the transport copied zero scene bytes into separate JS arrays.
Retained runtime buffer capacity was 1,941,842,720 bytes. Median capture was
91.113 ms, renderer wall time 171.192 ms, submission interval 270.118 ms, and
uploads 81,695,358 bytes/frame. Scene streaming and debug instrumentation make
this a regression check, not a matched performance benchmark. Native browser
gameplay and smooth 60-180 Hz performance remain unverified. The report and
summary are `D:/OpenMW-local/webcuda-seyda-neen-pooled-2026-10-06.json` and
`D:/OpenMW-local/webcuda-seyda-neen-pooled-2026-10-06-summary.json`.

## Compact vertex inputs constructed in CUDA

Engine `8de8326b631d` captures per-vertex source streams and per-draw constants
instead of constructing the full 47-float vertex/attribute/secondary-color
record on the CPU for ordinary geometry. `vertex-input.cu` expands those inputs
into mutable GPU working buffers before morphing, skinning, particle expansion,
transformation and shading. Generated screen-primitive space retains its exact
initial state. GUI and particle records use the same transport with a dense
descriptor; their existing CUDA rendering paths remain intact.

Source arrays are captured afresh on every draw, including in-place changes
without an OSG dirty notification. Constant/overall/per-primitive bindings,
double/byte source conversion, homogeneous UV coordinates, current values and
source selection for morph/skin retain the existing behavior. The browser borrows
the compact arrays directly from retained WASM storage. It validates counts,
strides, matrix ownership, reserved words and ranges before any GPU allocation.
It does not expand records in JavaScript.

The 49 related host regressions, six frame-lifetime checks and six WASM64
integration suites pass. The real OSG producer emits 31 fixtures with 6,414
vertices, including multiple workgroups, mixed dense/stream layouts, generated
line vertices, GUI, particles, morph/skin and source mutation. The production
CUDA kernel reproduces every field bit-for-bit against the original dense
capture in WASM and on the RTX 5080, with trailing guards intact. Browser WebGPU
compiles 88 runtime kernels and passes 39 GPU output checks, including both
compact encodings through the production transform, clip and raster pipeline.
Bundled NVRTC compiles all 90 paged runtime/storage kernels. The full engine
rebuild/link and HTTP staging checks pass, and all 371 generated files reproduce
exactly with the unchanged tracked SDK compiler/runtime.

An isolated WASM64 O3 comparison alternates dense and compact capture for 192
draws of 768 vertices, with nine measured samples after two warmups:

| Input profile | Dense vertex transport | Compact vertex transport | Dense capture | Compact capture |
| --- | ---: | ---: | ---: | ---: |
| Position, normal, UV | 28,311,552 bytes | 7,123,200 bytes | 11.182 ms | 6.392 ms |
| Color, tangent, four UV sets | 28,311,552 bytes | 18,904,320 bytes | 12.984 ms | 13.385 ms |

Both include the vertex-to-draw map and compare equivalent captured data.
The second profile reduces bytes but has a small CPU capture regression in this
sample. These are isolated capture measurements, not gameplay FPS. Expanded
GPU working buffers still exist; compact transport does not imply a matching
reduction in physical VRAM usage. Persistent cross-frame geometry residency,
native browser gameplay and physical refresh-rate acceptance remain pending.

The rebuilt WebGPU game reached 551 exterior presentations without a renderer
error, aborted capture or legacy draw attempt. Its saved report at presentation
450 contains 120 completed scene frames, all with their retained packets released.
Those samples have medians of 35,368,198 uploaded bytes, 113,214,690 captured scene
bytes, 77.253 ms capture, 140.945 ms renderer wall time and 227.740 ms presentation
submission interval. Geometry encoding accounts for a median 26.309 ms and
material encoding 32.043 ms. The immutable texture pool remains bounded at
64 MiB with 524 resident images and 290 evictions at the saved observation.
Runtime buffer capacity is 1,982,659,104 bytes, including the expanded working
buffers and compact input storage; it is not measured VRAM or process RSS.
These debug/streaming samples are not a matched performance benchmark against
the previous run. They demonstrate reduced transfer volume, not smooth gameplay.
The report and summary are
`D:/OpenMW-local/webcuda-seyda-neen-vertex-input-2026-10-06.json` and
`D:/OpenMW-local/webcuda-seyda-neen-vertex-input-2026-10-06-summary.json`.

Set `WEBCUDA_VERTEX_FIXTURES` to an output file before running
`wasm-build/test-webcuda-submission.ps1` to export the producer fixtures.
Compile `render/webcuda/vertex-input.test.cpp` with NVCC using
`-x cu -std=c++17 -O2 -arch=sm_120`, then pass that fixture file to the executable.
The `-arch` value is specific to this PC's GPU. Reports are
`D:/OpenMW-local/webcuda-vertex-input-{submission-tests,cuda}.log`,
`D:/OpenMW-local/webcuda-vertex-input-browser-validation.json`,
`D:/OpenMW-local/webcuda-vertex-input-native-compile.json` and
`D:/OpenMW-local/webcuda-vertex-input-benchmark.json`.

## Immutable vertex stream residency

Engine `92c47a9a3f5b` reuses converted source arrays and shares identical stream
versions within each captured pass. The cache compares the source bytes on every
use, rather than trusting OSG dirty counts. In-place edits receive new version
IDs; old retained packets keep their original contents. Weak source references
prevent stale versions from surviving source-object address reuse. Constants and
small streams remain inline. The cache retains at most 64 MiB of raw/converted
array payload and 8,192 entries, plus metadata and a temporary replacement entry.

The browser receives `vertexResources` triples (immutable version, word offset,
word count) alongside the compact inputs. A separate 32 MiB GPU arena restores
cached streams into the current pass's input buffer, so cache hits skip host
uploads even when another camera has overwritten that buffer or stream offsets
have changed. Cache retirement waits for queue completion before reusing ranges.
The existing immutable buffer allocator is shared with texture residency, with
separate version namespaces and arenas. Each cache needs one native page/table,
independent of its number of entries. Rendering still runs in the unchanged
authored CUDA kernels, starting with construction of fresh mutable records.

The 51 related host checks, six frame-lifetime checks and six WASM64 integration
suites pass. Tests cover dirty-only notifications, undirtied source edits, finite
input rejection, weak source lifetime, budget eviction, per-pass deduplication,
borrowed bridge views and queue ownership. All 32 producer fixtures (9,486
vertices) match the dense reference bit-for-bit in WASM and on the RTX 5080.
Browser WebGPU compiles 88 runtime kernels and passes 43 GPU output checks,
including 24 production-pipeline checks. Dense and stream inputs change rendered
color when scratch is overwritten, then restore the original output from the
resident arena at new offsets. Native interop simulations cover both 700-image
and 700-vertex-stream pools and the 256-job submission limit. They do not prove
current native-browser gameplay. CUDA sources and generated artifacts are
unchanged; the full engine rebuild and HTTP staging checks pass.

The same alternating WASM64 O3 capture benchmark uses 192 draws of 768 vertices,
shared source arrays and a position edit on each draw. Nine samples after two
warmups include stream descriptors and version records in the byte counts:

| Input profile | Dense transport | Cached compact transport | Dense capture | Cached compact capture |
| --- | ---: | ---: | ---: | ---: |
| Position, normal, UV | 28,311,552 bytes | 3,018,264 bytes | 10.834 ms | 4.137 ms |
| Color, tangent, four UV sets | 28,311,552 bytes | 3,027,504 bytes | 13.827 ms | 6.673 ms |

These are isolated capture measurements. Raw source comparison, per-pass packet
construction, matrices, topology and dynamic deformation data still consume CPU
work. Cached source payloads remain in captured packets so GPU eviction and
device replacement can recover without a separate engine upload handshake.
The GPU arena adds up to 32 MiB; this change reduces transfers, not necessarily
total memory. Reports are `D:/OpenMW-local/webcuda-vertex-residency-validation.json`,
`D:/OpenMW-local/webcuda-vertex-residency-benchmark.json`,
`D:/OpenMW-local/webcuda-vertex-residency-submission-tests.log` and
`D:/OpenMW-local/webcuda-vertex-residency-cuda.log`.

The rebuilt exterior WebGPU run saved 767 presentations with no renderer/pass
error, aborted capture or legacy draw attempt. Its vertex arena held 3,090
streams in 32 MiB after 4,319 evictions, 1,428,028 hits and 14,580,402,740 bytes
restored on the GPU. All 120 sampled completed scene frames released their
retained packets. Median uploads were 23,550,070 bytes/frame; capture was
110.195 ms, renderer wall time 163.967 ms and presentation submission interval
275.745 ms. Material encoding accounted for 44.337 ms and geometry 32.793 ms.
This scene streamed more geometry than the preceding compact-input run, so the
timing difference is not a controlled comparison or a frame-rate improvement.
The latest large camera passes contain 245,423 and 371,711 triangles.

Saved live buffer capacity is 2,001,943,328 bytes; an earlier in-flight DOM
observation showed 2,664,260,640 bytes. These totals can include resources awaiting
retirement and are not physical VRAM/RSS or proof of native allocation-budget
acceptance. Smooth 60-180 Hz play, broader gameplay and current native-browser
execution remain incomplete. The report and summary are
`D:/OpenMW-local/webcuda-seyda-neen-vertex-residency-2026-10-07.json` and
`D:/OpenMW-local/webcuda-seyda-neen-vertex-residency-2026-10-07-summary.json`.

## Raster pixels grouped by tile

`raster_material` now traverses the pixels of each 16x16 tile consecutively.
Row-major traversal put neighboring lanes on different candidate lists; those
lanes could take different triangle/material branches within the same warp.
The authored CUDA helper changes invocation-to-pixel mapping only. It retains
the original candidate order, coverage, interpolation, depth, stencil, queries,
blending and storage calculations. Partial edge tiles enumerate only real
pixels, so dispatch counts, buffer sizes and the engine ABI remain unchanged.
Warps in complete tile rows share a candidate list; partial tile boundaries may
still split a warp. This adds no allocation or host-to-GPU transfer.

The reference is the unmodified native source from `69d54372`. Both CPU and
RTX 5080 CUDA runs pass all 1,800 exact color/depth/stencil comparisons across
the existing pruning and coverage fixtures, including 1/2/4/8/16 samples and
partial edge tiles. A separate bijection check covers 147 dimensions, including
8192x8192, and verifies warp coherence for complete tiles. The material,
texture-filter and storage-conversion reference checks also pass. All 59 host
checks and all 90 paged runtime/storage NVRTC compilations pass. All 371
generated artifacts reproduce exactly with the unchanged SDK commit recorded
above; the served raster artifacts match these files.

The browser WebGPU check compiles 88 runtime kernels and passes 45 GPU output
checks, including 24 production-pipeline checks. New 35x19 fixtures use distinct
tile materials, partial rows/columns, alpha blending, one/four sample planes,
sample masks, a two-dimensional dispatch and trailing guards. Driver creation
of the raster pipeline takes 315.49 seconds in this run, following 0.05 seconds
of WGSL validation. This remains a separate startup cost. The report is
`D:/OpenMW-local/webcuda-raster-tile-order-browser-validation.json`.

The existing alternating native benchmark uses identical compact candidate
lists, 1280x720 output, 96 triangles, three warmups and nine measured samples:

| Synthetic geometry | Tile references | Previous raster | Tile traversal |
| --- | ---: | ---: | ---: |
| Random triangles | 27,750 | 2.113 ms | 1.923 ms |
| Long thin triangles | 12,384 | 1.995 ms | 1.237 ms |

These reductions (9.0% and 38.0%) measure only raster kernel time. They do not
establish whole-game frame rate, native browser performance or 60-180 Hz
presentation. CPU material/geometry capture and the remaining GPU frame work
still need optimization. This shader-only change reuses engine `92c47a9a3f5b`.
Reports are `D:/OpenMW-local/webcuda-raster-tile-order-{cpu,cuda,host}.log`,
`D:/OpenMW-local/webcuda-raster-tile-order-native-compile.json` and
`D:/OpenMW-local/webcuda-raster-tile-order-artifacts.json`.

The exterior WebGPU smoke run records 267 presentations without renderer/pass
errors, aborted captures or legacy draw attempts. All 120 sampled completed
scene frames release their retained packets. Median capture is 102.647 ms,
renderer wall time 146.185 ms and presentation submission interval 262.610 ms;
material encoding accounts for 50.513 ms and geometry encoding 28.055 ms.
Uploads are 22,570,418 bytes/frame and saved runtime buffer capacity is
2,000,025,888 bytes. This is a streaming debug scene, not a matched performance
comparison or a physical VRAM/RSS measurement. Native-browser gameplay and
60-180 Hz presentation remain unverified. The report and summary are
`D:/OpenMW-local/webcuda-seyda-neen-raster-tile-order-2026-10-07.json` and
`D:/OpenMW-local/webcuda-seyda-neen-raster-tile-order-2026-10-07-summary.json`.

## Reused shader-variant metadata

Engine `1bc7a744621a` reuses parsed shader-variant metadata across draws and
passes. The old material path copied the `webcuda.defines` string and rebuilt a
map for every object and shadow draw. A content-keyed cache now owns the parsed
map and applies the material profile once. Ordinary objects, terrain, composite
maps, water, groundcover and Bethesda profiles retain their previous feature
selection order, including the pre-terrain specular/vertex-lighting selectors.
Numeric rendering still runs in the unchanged authored CUDA kernels.

The cache compares complete metadata strings, so same-length edits, shader
replacement and hot reload cannot reuse a stale metadata entry. It does not
retain shader objects. Callers hold immutable shared results while the cache
evicts old entries. Each capture thread retains at most 256 entries and 2 MiB of accounted
strings, values and container bookkeeping; allocator overhead, a newly parsed
entry and results still held by callers are outside that accounting. Oversized
metadata is parsed for its current call without entering the cache. Uniforms,
textures, inherited raster state and material packet snapshots remain per draw.

All six WASM64 integration suites and 59 host checks pass. Cache checks include
300 comparisons against the old parser, duplicate/empty fields, carriage
returns, embedded NUL, same-address edits, missing/wrong metadata types,
profile isolation, ownership after eviction and byte/entry limits. Material
fixtures also change alpha uniforms and object/shadow metadata between draws
while checking that previously captured packets retain their values. The full
engine rebuild and HTTP range/isolation/MIME staging checks pass. CUDA sources,
generated artifacts and SDK source are unchanged.

The reusable `material-capture.bench.cpp` compares packet checksums with the
preceding material encoder from `39846f74`. All ten cases match. Each case uses
640 draws, 16 shader variants, six state layers, two warmups and nine measured
WASM64 O3 samples. Old/new process order alternates by case:

| Material case | Previous capture | Cached metadata |
| --- | ---: | ---: |
| Objects, one layer | 9.436 ms | 7.038 ms |
| Objects, multiple layers | 10.951 ms | 8.340 ms |
| Terrain | 11.517 ms | 7.796 ms |
| Terrain composite | 9.235 ms | 7.632 ms |
| Groundcover | 10.371 ms | 7.549 ms |
| Bethesda unlit | 9.852 ms | 7.014 ms |
| Bethesda default | 10.672 ms | 8.683 ms |
| Water | 11.314 ms | 7.807 ms |
| Shadow casting | 8.103 ms | 5.615 ms |
| Depth clipped | 9.741 ms | 5.519 ms |

These are isolated capture measurements, not gameplay FPS. Run
`wasm-build/benchmark-material-capture.ps1 -BaselineSource <saved-materialtable.cpp>`
with the previous source outside the checkout. The report is
`D:/OpenMW-local/material-define-benchmark/report.json`; integration and build
logs are `D:/OpenMW-local/webcuda-shader-define-cache-tests.log` and
`D:/OpenMW-local/webcuda-shader-define-cache-engine-link.log`.

The rebuilt exterior run records 304 WebGPU presentations with no renderer/pass
errors, aborted captures or legacy draw attempts. All 120 sampled completed
scene frames release their retained packets. Median capture is 104.788 ms,
material encoding 46.779 ms, geometry encoding 31.671 ms, renderer wall time
145.012 ms and presentation submission interval 255.942 ms. Uploads are
25,083,370 bytes/frame and captured scene data is 189,566,870 bytes/frame.
Saved buffer capacity is 1,998,756,384 bytes. Different streaming workloads
prevent a matched comparison with the previous run; these totals also do not
measure physical VRAM/RSS or current native-browser performance. Smooth
60-180 Hz play remains incomplete. The report and summary are
`D:/OpenMW-local/webcuda-seyda-neen-shader-define-cache-2026-10-07.json` and
`D:/OpenMW-local/webcuda-seyda-neen-shader-define-cache-2026-10-07-summary.json`.

## Shared game draw capture

Engine `5c1d2efa4bbd` routes the real viewer and the standalone capture sink
through the same geometry/particle submission functions. Source review found
that the viewer's duplicated path omitted `screenPrimitiveDraw` and the
polygon-fill override for expanded points and lines. Text decorations had
the same omission. The CUDA clip kernel uses that marker to retain wide
footprints after their centres have been clipped; the raster kernel uses it
to select front stencil state for non-polygon primitives. Inherited wireframe
and polygon offset must also not apply to their generated support triangles.

Mixed point/line/polygon draws now use the corresponding material variant.
Point particles additionally select a point material so fixed-function sprite
coordinate replacement bypasses the texture matrix. Lines and polygon
particles retain their texture matrices. Connected particles still transport
separate ribbon and thin-line materials, allowing CUDA to make the existing
view-dependent selection. Source state remains unchanged and is captured
again for later draws. This change adds no rendering math outside `.cu`.

All seven WASM64 integration suites pass. The new `draw-capture.test.cpp`
exercises ordinary and mixed topology, untextured decoration capture, point
particles, connected ribbons, compact/dense input equivalence and later state
mutation. It feeds the captured material records into the authored CUDA clip
body and verifies both retained non-polygon footprints and normal polygon
clipping. The full engine build and HTTP range/isolation/MIME checks pass.
CUDA sources, generated kernels, browser host code and the SDK are unchanged.
Logs are `D:/OpenMW-local/webcuda-shared-draw-capture-tests.log`,
`D:/OpenMW-local/webcuda-shared-draw-capture-kernel-test.log`,
`D:/OpenMW-local/webcuda-shared-draw-capture-engine-link.log` and
`D:/OpenMW-local/webcuda-shared-draw-capture-stage.json`.

The rebuilt Seyda Neen WebGPU run records 296 presentations, no renderer/pass
errors, no aborted captures and no legacy draw attempts. All 120 sampled
completed scene frames release their packets. Median capture is 86.528 ms,
material encoding 33.625 ms, geometry encoding 28.043 ms, renderer wall time
142.003 ms and presentation submission interval 235.448 ms. The streaming
workload differs from previous runs, so these are health observations, not a
matched performance comparison. Reported buffer capacity is 2,002,736,416
bytes, which is not physical VRAM/RSS. Smooth 60-180 Hz play and current native
browser gameplay remain unverified. Reports are
`D:/OpenMW-local/webcuda-seyda-neen-shared-draw-capture-2026-10-07.json` and
`D:/OpenMW-local/webcuda-seyda-neen-shared-draw-capture-2026-10-07-summary.json`.

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
node --test render/webcuda/frame-readbacks.test.mjs render/webcuda/pipeline-readbacks.test.mjs render/webcuda/packet-validation.test.mjs render/webcuda/vertex-input.test.mjs render/webcuda/native-runtime.test.mjs render/webcuda/texture-residency.test.mjs render/webcuda/atlas-upload.test.mjs render/webcuda/bounded-batch.test.mjs render/webcuda/terrain-blend-inputs.test.mjs
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
