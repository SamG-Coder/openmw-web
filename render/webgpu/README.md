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

`runtime.js` owns the WebGPU device, buffer uploads, compute pipelines, binding
layouts, per-dispatch parameter snapshots and ordered command submissions.
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

`shader-specialization.js` uses immutable material flags to remove inactive WGSL
branches and unreachable helpers before pipeline compilation. Pipelines and
shader variants are cached. This keeps a simple draw from compiling every
water, terrain, sky and generated-line calculation; no CUDA translation is
involved.

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

### Attachment compatibility

The existing engine transport uses GPU buffers for image atlases, camera
attachments and compute post-processing. The render path imports those
attachments into native WebGPU textures, draws, then exports the results back
on the GPU. Pixel data does not round-trip through JavaScript for this bridge.
The regular attachment ABI is nine interleaved floats per pixel (RGBA, depth,
normal RGBA) followed by a separate stencil plane, with independent sample
planes for MSAA. Depth-only cameras use compact one-float storage.

These compatibility passes have a cost. Further performance work can keep
attachments and sampled images as native textures throughout post-processing.
This conversion does not establish a gameplay FPS result or a speedup factor.

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

All **75 Node regression tests** passed for this change across the runtime,
host/packet lifetime, resource residency, shader specialization, visibility
counter, staging and frame-pump suites below.

Run JavaScript host, lifetime, packet, residency and submission regressions:

```sh
node --experimental-vm-modules --test render/webgpu/*.test.mjs
node --test wasm-build/webgpu-staging.test.mjs wasm-build/frame-pump.test.mjs
```

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

For this change, Dawn with a Vulkan SwiftShader device validated all **79 WGSL
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
