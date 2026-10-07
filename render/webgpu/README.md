# OpenMW native WebGPU renderer

This branch replaces the active CUDA-authored software rasterizer with
standalone WGSL compute shaders and WebGPU vertex/fragment render pipelines.
`play/index.html` installs `installWebGPU()` from this directory before loading
the engine. The active path has no CUDA compiler, WebCuda SDK, NVRTC, CUDA
runtime, generated JSON kernel payload, or WebGL rendering dependency.

The `webcuda*` names on `Module` and the `WebCuda` C++ namespace remain the
existing **WASM scene-capture ABI**. They select the capture-only viewer and
transport retained packets; they do not select a CUDA backend here. Existing
engines built from the source branch can use this renderer without rebuilding
the engine just to change browser shaders.

## What changed

| Previous stage | Native WebGPU path |
| --- | --- |
| `.cu` compilation and generated JSON loading | Checked-in `.wgsl` files loaded directly by `runtime.js` |
| Seven reserved homogeneous clipping slots per triangle | One packed slot per input triangle; the hardware clips primitives |
| Clip compaction and allocation readback | Removed from the draw path |
| Tile counting, prefix sums, candidate scatter and sorting | Removed from the draw path |
| A compute thread loops over triangles for each pixel/sample | Vertex/fragment render pipelines draw ordered triangles |
| Software depth testing, blend equations and stencil operations | WebGPU render-pipeline state |
| GPU deformation, material/light preparation and image processing | Standalone WGSL compute shaders |
| External SDK resource management | Local WebGPU buffer, command, shader and resource management |

The WGSL shader files are the source of truth for this branch. Edit them
directly. The previous renderer under `render/webcuda` remains available as
reference, and its old tests remain separate. Its `.cu` compiler script is not
part of the new build or startup path.

## Renderer structure

`runtime.js` owns the WebGPU device, compute pipelines, binding layouts,
per-dispatch parameter snapshots and ordered command submissions. The C++
`DirectWebGPU` owner imports that same device and uploads dynamic frame data
through the WebGPU C API; the runtime retains texture/geometry residency uploads.
`kernel-manifest.js` supplies the binding/scalar ABI for the 77 retained compute
entry points; `shaders/prepare-triangles.wgsl` prepares identity triangle slots.

`pipeline.js` preserves the existing packet validation, persistent texture and
vertex caches, deformation, particle expansion, texture generation, lighting,
and camera preparation. It then submits packed vertices and material records to
`rasterizer.js`. The hardware renderer batches consecutive compatible material
runs without reordering transparent geometry. Ribbon ranges keep their
GPU-selected material without a geometry readback.

`shaders/material.wgsl` contains the vertex and fragment entry points and the
ported material calculations: texture sampling, fixed lighting, object and
terrain materials, sky, water, text, fog and alpha testing. Hardware interpolates
perspective varyings; triangles crossing the eye plane use a homogeneous basis
that remains defined at zero or negative vertex `w`. Camera and material depth
ranges remain separate from homogeneous clipping.

`shader-specialization.js` removes unselected fragment entry points and
unreachable helpers. Production material features remain uniform-driven, so
materials share shader modules for each entry point rather than compiling a
module for every feature combination. Helpers reachable through those dynamic
features remain in the shader. Fixed render state still selects cached pipeline
variants; no CUDA translation is involved.

`visibility-counter.js` preserves exact visible-sample counts for sun glare.
Native render passes accumulate surviving samples into a separate attachment,
then a compute reduction updates the existing query counters. Chunks contain
at most 1,024 triangles so the half-float attachment counts overlapping
fragments exactly, including each MSAA sample. This avoids depending on
occlusion-query implementations that return only zero or nonzero visibility.

`game-host.js` retains bounded frame submission, retained-WASM-packet lifetime,
camera/attachment order, post-processing, snapshots, readbacks and device-loss
handling. SDL's canvas receives input; a separate WebGPU canvas presents the
rendered frame.

### WASM frame submission

The current engine records camera state, retained scene descriptors, attachment
operations, image captures and effects into one fixed-width command stream in
WASM. `browserframe.cpp` makes one application handoff to `wasm-frame.js` when
the frame is complete. The separate begin-frame call performs bounded queue
admission before culling; image-result polling and startup/device recovery are
outside the frame command stream.

Camera order and state come from the C++ viewer. The JavaScript adapter decodes
those commands in order and invokes the existing render operations. It does not
derive camera matrices or copy the scene arrays into a separate JavaScript heap.
Pointers and counts are encoded as two 32-bit words and checked before creating
views, preserving wasm64 addresses above 4 GiB without signed bitwise truncation.

All directly bound dynamic input ranges for a frame share one C++-owned
`GPUBuffer`, aligned to the actual device storage-offset limit. One
`wgpuQueueWriteBuffer` snapshots the packed frame bytes. Staging vectors and GPU
allocations are reused after every referencing packet has been submitted or
discarded. Free CPU/GPU allocations have a combined 256 MiB cache budget and a
four-entry limit; active frame ownership is bounded by host admission.

Raw vertex streams and compressed textures are deliberately omitted from this
upload. Their existing residency caches upload only missing or changed ranges.
Preparation kernels that modify vertices, ribbon triangles, lighting or TexGen
descriptors use reusable GPU scratch, with GPU-to-GPU copies from packed inputs.
Read-only ranges bind directly; a writable binding must not alias the shared
packed buffer in the same WebGPU usage scope.

This is direct C API buffer creation/upload plus one application command
handoff. Emdawnwebgpu implements the C API on top of the browser WebGPU binding.
Shader/pipeline creation, preparation dispatches and render-pass encoding still
use the JavaScript renderer. One frame handoff is not a promise of one total
GPU submission or one total upload: residency misses, dispatch uniforms and
post-processing still have their own GPU work.

`?renderdebug=1` includes these cumulative fields under `transport` in the
renderer report:

| Field | Meaning |
| --- | --- |
| `frameSubmissions` | Ordered command streams accepted from WASM |
| `lastFrameCommands` | Camera/pass/effect commands in the last accepted stream |
| `directGpuUploads` | C API dynamic-frame uploads; at most one per stream |
| `directGpuBytes` | Packed bytes uploaded by C++, including alignment padding |
| `directGpuPasses` | Camera packets with directly bound GPU ranges |
| `directBufferAllocations` | GPU upload allocations, including growth |
| `directBufferReuses` | Frame leases acquired from the reuse pool |
| `retainedPasses` | WASM packets still owned by queued or encoding frames |

The existing immediate pass ABI remains available to older engines and the
standalone bridge fixtures. New engines use the batched path when the host
advertises `webgpuSubmitFrame`. Aborted/failed streams cancel pending prewarm
work before releasing WASM arrays; device generations prevent old allocations
from entering a replacement device's pool.

### Attachment compatibility

Supported camera attachments remain native WebGPU textures through rendering,
attachment resolution, sampling and presentation. Operations that still need
the compatibility buffer layout import/export their attachments on the GPU.
Pixel data does not round-trip through JavaScript for these conversions.
The regular attachment ABI is nine interleaved floats per pixel (RGBA, depth,
normal RGBA) followed by a separate stencil plane, with independent sample
planes for MSAA. Depth-only cameras use compact one-float storage.

Compatibility passes and preparation still have a cost. Source changes and
standalone validation do not establish a gameplay FPS result or speedup factor.

## Building the direct WASM path

The direct sources need `--use-port=emdawnwebgpu` during compilation **and**
linking. The Emscripten port supplies `webgpu/webgpu.h` and its implementation.
The relevant CMake source properties declare the compile option, and the
canonical linker supplies the same port. Ninja regenerates those source
commands even if `CMAKE_CXX_FLAGS` in an existing Windows cache predates the
direct path; deleting the build tree or rebuilding the dependency stack is
unnecessary.

After pulling, restart `OpenMW.WebHost` with F5 or
`dotnet run --project OpenMW.WebHost`. With the default automatic engine selection/build enabled,
the host fingerprints C++ and build inputs, runs the incremental build and mounts
the resulting engine. `/status` reports progress or the compiler error. An
explicit manual incremental build is:

```powershell
powershell -ExecutionPolicy Bypass -File .\wasm-build\build-local-windows.ps1
```

The CMake build tree, Emscripten toolchain and prebuilt dependency stack must
already exist. The first port use may download Emdawnwebgpu into the SDK cache.
Changing JavaScript/WGSL alone continues to use the existing engine; changing
the C++ command producer requires the incremental WASM rebuild.

## Running with an existing local engine

Keep your existing engine files in `.local-runtime/e/<engine-version>/`, then
run from the repository root:

```powershell
python wasm-build/stage-webgpu-page.py <engine-version>
```

For another web root:

```powershell
python wasm-build/stage-webgpu-page.py <engine-version> --destination D:/OpenMW-local/runtime
```

The script copies the renderer and WGSL to a directory identified by their
content hash and installs the page last. It requires the existing
`openmw.js`, `openmw.wasm` and `openmw.data` for the supplied engine version.
The old `stage-webcuda-page.py` command forwards to this script on this branch.
No `webcuda-sdk` mount or `WEBCUDA_ROOT` setting is needed.

The Docker runtime includes the new renderer. `version-engine.sh` hashes and
versions the renderer, WGSL, engine and startup scripts together, so a
shader-only change gets a new immutable URL. The source development server can
serve `/webgpu/` from `render/webgpu` directly. Existing HTTPS and cross-origin
isolation requirements for the WASM engine still apply.

## Compatibility boundaries

WebGPU render attachments support the implemented **1x and 4x sample paths**.
Select no antialiasing or 4x MSAA. Other requested sample counts fail explicitly.
Optional depth-clamp and texture-format features are enabled only when the
adapter provides them; unsupported requested combinations produce a renderer
error.

Legacy OpenGL polygon LINE/POINT modes, framebuffer logic operations and
disabling multisampling for an individual draw inside a multisampled attachment
require additional native implementations. They are rejected rather than
silently rendered with different state. Expanded ordinary/particle point and
line quads use the triangle path. Full visual equivalence for all compatibility
states is not claimed.

## Validation

The direct-frame change passes **160 Node regression tests** across the
runtime, host/packet lifetime, resource residency, command decoding, actual
EM_JS pointer boundaries, shader specialization, visibility counters, staging
and frame-pump suites below.

Run JavaScript host, lifetime, packet, residency and submission regressions:

```sh
node --experimental-vm-modules --test render/webgpu/*.test.mjs
node --test wasm-build/webgpu-staging.test.mjs wasm-build/frame-pump.test.mjs play/frame-pump-performance.test.mjs
```

A native C++ probe also exercised the actual `directwebgpu.cpp` and
`browserframe.cpp` with the pinned WebGPU header and mocked GPU/browser calls.
Ten lifecycle/serialization scenarios passed with AddressSanitizer and UBSan,
including reuse, retained-frame separation, growth, device replacement and
abort/rejection cleanup. These checks are not an Emscripten link or GPU execution.
The Windows dependency stack and SDK are not present in the editing environment;
the full engine build and RTX 5080 gameplay verification remain target-machine
checks.

`gpu-check.mjs` compiles the actual WGSL and exercises synthetic scenes on a
WebGPU device, including pixel readback. It can use the optional Dawn `webgpu`
Node package; this package is for validation only and is not used in browsers.
Set `OPENMW_WEBGPU_MODULE` to the package's `index.js` when it is installed
outside this checkout, then run:

```sh
node render/webgpu/gpu-check.mjs
```

Use `--kernels-only` to compile all retained compute shaders and check identity
triangle assembly without running the raster tests.

Earlier renderer validation, before the direct-frame transport change, used
Dawn with a Vulkan SwiftShader device to validate all **79 WGSL
source modules**, compiled all **78 production compute pipelines**, and passed
all **28 GPU readback checks**, with no skips or uncaptured GPU errors. Coverage
includes textures, perspective and eye-plane clipping, depth, ordered blending,
alpha tests, channel masks, culling, scissor, stencil, normals, fog, sky, exact
visibility counts, 1x/4x samples, and the actual `MaterialPipeline` preparation,
partial viewport, empty-camera clear and MSAA resolve paths. SwiftShader is a
software GPU implementation; these results establish shader/API behavior, not
physical-GPU performance.

The repository does not contain the staged engine dependency stack, engine
binaries or retail game data. Standalone shader/renderer checks do not prove
Morrowind gameplay, complete visual parity or frame pacing. Verify the actual
game on the target machine: loading and character creation, interiors and
exteriors, water/weather/shadows, menus/HUD/maps, animated actors and particles,
save/load, resize and device recovery. Use `?renderdebug` for per-frame renderer
diagnostics.
