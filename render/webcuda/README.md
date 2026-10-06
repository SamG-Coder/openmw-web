# OpenMW WebCuda renderer replacement

The target is the full `.cu -> WebCuda -> WGSL -> WebGPU` rendering path.
C++ retains gameplay, assets and scene submission; JavaScript owns GPU resources,
dispatch and presentation. Rendering arithmetic belongs in `.cu`.

## Current implementation status

The replacement remains unfinished. Engine `8b2f378cabc7` visibly renders the
Imperial Prison Ship and HUD through the CUDA-authored WebGPU and native CUDA
backends. Broad gameplay, resilience and 60-180 Hz pacing remain unverified.
After fixing native atlas growth and reducing default shadow storage, the user
confirmed visible native gameplay; frame times are still too high. Native
submission coalescing has passed host regressions and awaits a browser check.

The latest local engine is `f7c1bdb71a48`. Terrain blend masks now generate in
CUDA from immutable land inputs. Geometry capture and host validation
now avoid repeated state/type checks and full-buffer callback scans. The build
and regression suites pass; isolated benchmarks are in the native-renderer
notes. This source branch is a development checkpoint, not a packaged release.
The CUDA rasterizer now rejects uncovered filled samples before computing
interpolation weights and gradients. Exact comparisons against the preceding
kernel and isolated native timings are recorded in the same notes.

See [native-renderer.md](native-renderer.md) for the current native path, memory
limits, evidence and test commands, and `implementation-priorities.json` for
current priorities. The chronological notes below describe historical source
states and can contain superseded ABI sizes and validation claims.

The new `WebCuda::Viewer` is selected by `Module.webcudaEnabled`. It replaces the
base constructor's renderer and supplies a renderer factory for other cameras.
It brackets the entire rendering traversal with accepted/committed frame calls,
including loading-screen traversals. Its renderer culls and submits OSG draw
packets without invoking SceneView's GL draw routine. MyGUI submits its current
CPU batches through an explicit custom-drawable interface.

The browser entry point initializes `game-host.js` before loading the engine by
default. No query parameter is required, and initialization failures stop startup
instead of falling back to WebGL. The old `?renderer=webcuda` URL still works.
This remains a development build: unsupported materials fail explicitly.
The host accepts one frame at a time, renders camera passes in order, preserves
attachments between passes, and presents only the completed screen attachment.
It uses a separate WebGPU canvas over SDL's input canvas. No WebGL framebuffer
is copied into that presentation canvas. GL setup code remains in the engine;
zero-GL-draw acceptance still needs real gameplay verification.

## Implemented source paths

- `submission`: camera ordering, sorted bins, inherited OSG state, geometry and
  explicit custom drawable submission. Render-bin state insertion ordering needs
  an audit against OSG's stack semantics.
- `geometrypacket`: packed positions, vertex colors, UV0, model/view/projection
  and texture matrices; triangle conversion and MyGUI vertex extraction.
- `materialstate`: OSG override/protected resolution, depth/alpha comparisons,
  separate blend factors/equations, culling, scissor and normalized targets.
- `materialtable`: per-pass image/material deduplication, dirty-image versions,
  byte-format textures, DXT payloads, and registered render-texture references.
- `browserbridge`: owned typed arrays copied using MEMORY64-safe pointer handling.
- `viewer`: synchronous frame capture, clear state, color camera attachments,
  render-texture identities and feedback rejection. MRT/depth texture attachments,
  subviewports, mip attachments and image readbacks remain unsupported.
- `geometry.cu`, `clip.cu`, `assemble.cu`: transforms, six-plane homogeneous
  clipping, attribute reconstruction and texture-coordinate transforms.
- `tiles.cu`: conservative ordered candidate bins. Current tile-wide scans and
  overflow readback need replacement for production scene sizes.
- `material.cu`: unlit texture/color rasterization, top-left coverage,
  perspective interpolation, depth, alpha, blending, culling and scissor;
  independent camera clears, output packing and render-texture row conversion.
- `dxt.cu`: DXT1 RGB/RGBA, DXT3 and DXT5 into shared atlas ranges.
- `pipeline.js`, `game-host.js`: allocations/uploads, ordered kernel dispatch,
  off-screen targets, bounded submission and direct canvas presentation.
  Kernels flatten a 2D block grid to support dispatches beyond 65,535 groups.

## Remaining implementation

Sky atmosphere/night/cloud/moon/sun/sunglare materials now have a source port using the original sky uniforms. Basic objects.vert/frag variants now capture material colors, sun and point lights, alpha/fog/clip settings and evaluate lighting in .cu. Advanced object variants remain explicitly rejected. Sky visibility queries and other world programs remain pending. Complete
transport, object materials, terrain layers, fog, sky, shadows, particles,
water, skinning/morphing and post-processing are required. Authored texture mip chains, GPU generation of missing levels, perspective-derivative LOD, nearest/bilinear/trilinear filtering and independent clamp/repeat/mirror wrapping are now implemented in source but untested. Remaining sampler work includes border/anisotropic behavior.
Other vertex formats and
primitive topologies, stencil/polygon offset also remain. Partial color masks are now encoded and applied in source.
Persistent geometry/texture residency and scalable GPU bin allocation are needed
before performance claims. Device loss currently stops with an error; automatic
recreation and recovery are not implemented.

## Validation boundary

Earlier source revisions passed CPU kernel checks, six wasm64 submission/state
suites, a full engine build/link, 20 browser GPU checks, and a controlled OSG
unlit triangle probe. Those results do **not** validate this newer implementation
pass. The probe is not Morrowind. The newest DXT-textured probe source, frame host,
attachments, texture transforms and 2D dispatch changes await the deferred tests.

After implementation, regenerate all WGSL from `.cu` (never edit it by hand):

```powershell
$env:WEBCUDA_ROOT = 'D:\cuda-webshader'
node wasm-build/compile-webcuda.mjs
.\wasm-build\test-webcuda-submission.ps1
.\wasm-build\build-webcuda-probe.ps1
```

Then rebuild/link the engine, run browser validation and actual Morrowind:
character creation, movement/input, interiors/exteriors, weather/water, menus,
HUD, maps, previews and saves. Verify no WebGL draw calls for the new backend,
compare rendering with the original and measure frame-time distributions across
60-180 Hz. Build success and controlled probe pixels are separate acceptance
boundaries from gameplay and performance.

## Local build

The user authorized building on this PC, overriding the original maintainer's
server-only workflow. Emscripten 6.0.1, MSYS2 and dependencies are under
`D:\OpenMW-local`, `C:\msys64` and the ignored `deps`/`build-wasm64` directories.
Use `wasm-build/bootstrap-windows.ps1` and `-DBoost_COMPILER=clang` for configure.
`wasm-build/link-openmw.sh` stages preload files so linking does not rewrite the
tracked `fsroot` tree. Steam game assets remain outside the source release.
The latest untested attribute ABI adds 16 floats per vertex (view position, normal, tangent and additional UVs), transformed and clipped by attributes.cu. raster_material now takes attributes as its eighth storage binding. Direct test harnesses still need the new binding/signature when the deferred testing phase starts. Object lighting currently evaluates per fragment; matching original vertex-lit interpolation remains a visual-fidelity task.

Latest layer implementation (untested): attributes now use 21 floats, preserving raw UV0 and a GPU-transformed bitangent. Object payloads have a 248-word header with seven 24-word descriptors for dark/detail/decal/emissive/normal/specular/diffuse maps, each carrying its UV routing, texture matrix and sampler. Shading now includes these layers, tangent-space normal mapping, specular-map shininess, and coverage scaling on diffuse/dark alpha. Earlier ABI sizes in historical notes are superseded. UV sets 0-3 are currently transported for texture layers; additional UV formats/sets remain work.

Parallax source integration (untested): normal-map alpha and diffuse-map alpha height paths use the original 0.04 scale / -0.02 bias in .cu. UV offsets affect diffuse and normal sampling, including screen-space offset differences for mip selection. Diffuse-parallax alpha handling follows the shader's opaque height-channel rule before material/dark alpha. Environment/bump/gloss, terrain/shadow/water/particle/query coverage and production performance remain unfinished.

Environment/bump/gloss source integration (untested): attributes now contain 23 floats; environment UV is generated on the GPU before clipping for vertex-reflection variants. Normal-mapped variants calculate reflection per pixel, including parallax normal sampling. Environment mip derivatives include changing reflection and bump coordinates. Bump luminance, gloss modulation and pre/post-light environment contribution are in .cu. Object payload now has a 328-word header and ten texture descriptors before lights. This supersedes older ABI notes; no compile or runtime acceptance has been performed for this implementation pass.

Terrain source integration (untested): terrain and terrain_composite material families now encode diffuse/normal/parallax/blend textures, terrain tangent construction and diffuse-alpha specular convention. Composite positions use model-view directly and shading is unlit. Blend UV uses raw UV0 with texture matrix 1. Object/terrain payload header is now 352 words; blend descriptor starts at 328. Terrain shadow and normal-output/MRT acceptance remains pending, along with the other full-renderer work and all deferred validation.

Camera uniform source integration (untested): DrawContext now carries the render stage's composed initial view matrix, including relative RTT camera transforms. Missing OSG inverse-view uniforms are computed by camera.cu with partial-pivot matrix inversion; singular matrices fail before rasterization via the existing bin-readback status. Explicit inverse-view uniforms are preserved. Depth/normal target transport and remaining full-renderer features are still pending.

Depth-target source transport (untested): depth attachments have distinct resource IDs and retain float precision in the texture atlas. GPU copy_depth preserves loaded depth across camera attachments; depth_to_texture exports float depth with the expected UV origin. Depth-only passes suppress color clears and writes. This provides transport for shadow/water sampling but does not complete their material shaders or normal/MRT targets. No tests/builds have been run for this pass.

Shadow-caster source implementation (untested): shadowcasting.vert/frag now maps to .cu alpha-tested depth writes, including vertex/material alpha, texture alpha and translucent-shadow rejection. Custom depth ranges and polygon slope/unit bias are encoded per material. Raster parameters share the tail of the attribute GPU buffer to retain eight storage bindings; raster_offset is a new dispatch scalar. Bias units currently use the 24-bit default; floating-depth-format-specific bias remains pending. Shadow receiving, full frame effects and deferred validation are still incomplete.

Shadow-reception source integration (untested): cascades carry depth comparison settings, shadow/valid-region matrices, normal offset and fade/debug state. .cu comparison filtering operates on individual depth taps before blending and attenuates directional diffuse/specular light while preserving ambient. Binary depth borders are supported. Attributes now use 26 floats; unit view normals survive clipping for shadow offset, and consumed tangent-handedness storage becomes the terrain distance varying. Cascade records follow the lighting records without changing the 352-word header. Full-renderer acceptance remains unproven.

Normal-target source integration (untested): color attachment 1 can receive object/terrain encoded normals and be sampled by later passes. Target storage now uses nine floats per pixel: color RGBA, depth, normal RGBA. Shared normal attachments are preserved by .cu copies, and normal texture export remains on the GPU. The deferred test phase must update old five-float fixtures and verify attachment aliasing, clear/load behavior and accepted-fragment writes. Water, particles, queries, remaining raster/format coverage and production performance are still incomplete.

Implementation-pass update (unbuilt/untested): NIF particle drawables now submit
simulation state through the WebCuda sink. `particles.cu::expand_particles`
expands billboard/fixed quads and applies rotation, scale and alpha before the
common vertex transforms. The draw callback updates OSG's particle frame/delta
bookkeeping and supplies colour/depth pass state. Point/line particles and OSG
shader-simulation mode remain explicit unsupported cases.

The object header stays 352 words and attributes stay 26 floats. Header word79
now points to a **40-word screen-effect extension**, after lights and shadow
cascades: soft-particle depth descriptor0..3 and parameters4..8; occlusion depth
descriptor12..15 and matrix16..31; sky texture descriptor32..35, far36 and
skyBlendingStart37. Feature bits262144/524288/1048576 select these effects.
This supersedes the earlier 32-word particle extension. Sky blending executes
after fog in the .cu rasterizer. Generated kernels and previous validation
results do not cover these changes. Tests remain deferred until the complete
implementation pass, as requested.

Further implementation-pass update (unbuilt/untested): floating RGBA camera
attachments use target-kind bit0x20000000, leaving29 bits for target identity.
Sampler bit32768 selects four float-bit words per atlas texel. Float mip/export
kernels preserve signed values; floating attachment materials disable normalized
colour clamping. RGBA16F is currently stored at32-bit precision; exact half-float
rounding is still a format-fidelity task.

RipplesSurface now has a WebCuda custom submission path. Its dedicated camera
registers the persistent floating ripple texture. A frame-ordered ripple command
copies disturbance positions/offset/time from WASM and dispatches ripple_blob
and ripple_simulate from ripples.cu. The next material texture copy can sample
that updated target. Paused commands still initialize a zero-filled target.
The existing water reflection/refraction shader itself remains to be ported.
No generated artifacts, builds or test results were refreshed for these changes.

Water source update (unbuilt/untested): object feature2097152 selects water;
header321 points to a96-word extension after lights/shadows/screen effects.
Descriptors0/4/8/12/16 are normal/reflection/refraction/depth/ripples. Scalars20-28
hold time, near, far, rain, options, reflection blur, ripple extent/scale, and rain
detail. Node/player positions start32/36. Matrix40 is GPU-inverted model-view;
56 retains its original value. The normal object inverse-view remains separate.

water.cu is included by material.cu and expanded by the WebCuda compile script.
It contains the base water surface, six animated wave layers, simulated ripple
normals, Fresnel reflection/refraction, reflection blur, sun specularity, sunlight
scattering and shoreline wobble. Shared fog/shadow code surrounds this shader.
Rain and point-light variants currently reject explicitly; normal-map derivative
LOD also remains unfinished. This is not a complete or tested water renderer.

Water rain update (unbuilt/untested): rain detail0/1/2 equations and rain
specularity are now ported in water.cu, and the rain rejection was removed.
The previous water point-light rejection was also removed: the original legacy
lighting implementation intentionally returns zero from doSpecularLighting;
clustered lighting remains explicitly unsupported rather than silently mapped.
The six base wave samples now use coordinate footprints propagated through the
choppiness chain to choose texture mips. Shore-only extra samples and RTT samples
still useLOD0, and exact fragment-quad derivative equivalence is unverified.
No tests/builds or generated artifacts were refreshed.

Render-bin implementation update (unbuilt/untested): CustomRenderBin now brackets
sorted bin submission. Unknown draw callbacks fail explicitly. First-person
DepthClearCallback splits the camera packet, saves scene depth, clears depth via
clear_depth.cu entry in material.cu, draws the viewmodel with depth writes, then
restores scene depth. Resumed packets use clearMask0. Browser depth scopes are
nested and validated. This handles viewmodel colour isolation; its separate
postprocess-friendly depth accumulation still needs implementation. Rig/morph
geometry inspection also confirms their current deformation occurs during CPU
culling, which remains to be moved into the requested .cu path.

Morph source update (unbuilt/untested): WebCuda culling snapshots base positions,
target offsets and weights via MorphInputs metadata and skips CPU render-position
blending. GeometryPacket/bridge now carry morphRanges uint3(destination,first,count)
and morphOffsets float4(xyz,weight). deformation.cu morph_vertices runs before the
common transforms, with a single writer per destination. The host validates
ranges, finiteness and duplicate destinations. CPU primitive-functor query
positions require reconciliation in this mode; skeletal skinning remains CPU.
No builds/tests or generated artifacts were refreshed.

Skinning source update (unbuilt/untested): WebCuda RigGeometry culling captures
SkinInputs and bypasses CPU render-position/normal/tangent deformation. Packet
arrays are skinRanges uint4(vertex,first,count,transform), skinWeights
uint2(bone,float-bit-weight), skinBones float32(bind,pose), and skinTransforms
float32(skinToSkeleton,local). skin_vertices in deformation.cu owns matrix
composition, weighted transforms and attribute deformation. Dispatch order is
morph, skin, particles, then common transforms. Host validation rejects invalid
indices, non-finite values and duplicate destination writers.
Morph and rig primitive-functor calls now reconstruct query-only CPU positions
from cull snapshots, without uploading those temporary geometries. This resolves
the previously documented stale query-position path in source; it has not been
built or tested. Bone/matrix equivalence and real animation remain unverified.

Postprocess resolve update (unbuilt/untested): PingPongCanvas now explicitly
submits final scene copy or its sole internal_distortion pass. Viewer queues a
resolve between camera packet segments; the host dispatches resolve_scene from
postprocess.cu. It bilinearly samples float RGBA attachments, applies the original
0.14 distortion offset and sampled occlusion blend, and supports output resizing.
General FX chains, multiview, explicit destination FBOs and non-unit UV scaling
remain explicit unsupported cases. Distortion-bin target production is still
pending; a connected resolve is not proof of complete post-processing.

Stage/distortion source update (unbuilt/untested): Viewer now registers the actual
RenderStage FBO attachments assigned by PingPongCull, before consulting the
camera attachment map. Packed depth/stencil textures provide the depth channel;
stencil operations remain incomplete and multisample resolves reject explicitly.
The screen-effect extension is NOW48words, superseding40: descriptor40..43 is
opaque depth for distortion, strength44, RTT ratio45. Feature4194304 implements
DISTORTION object output (alpha threshold, signed offsets, depth occlusion),
skipping ordinary fog/soft-alpha/force-opaque/debug output adjustments. Distortion
bin target switching and opaque-depth capture still need connection.

Opaque-depth source update (unbuilt/untested): TransparentDepthBinCallback now
captures scene depth before transparent rendering on the matching primary camera.
Viewer registers the opaque depth texture and splits the packet; the browser
queues copy_depth into a separate persistent attachment before resumed draws.
Dimension and alias checks guard the copy. Optional alpha-clipped transparent
postpass still rejects explicitly and must be implemented separately. No build
or runtime result establishes that soft particles/distortion now work in game.

Distortion target update (unbuilt/untested): DistortionCallback now switches to
its colour-only attachment through a nested WebCuda target scope, clears it,
submits its bin, and restores the parent camera without repeating clears.
Material depth test/write is disabled on the colour-only target. The callback
runs only for its matching primary scene camera. Per-frame tracking prevents
using missing/stale distortion offsets when an empty bin has no callback.
The distortion chain is now connected in source, not yet compiled or verified.

Transparent depth replay update (unbuilt/untested): the optional postpass now
replays its sorted leaf list with the depthclipped program into the preserved
opaque-depth texture. Particle-mask geometry and material alpha below0.5 are
excluded. The existing .cu alpha raster path implements texture*passthrough alpha
with GEQUAL0.499 and masked color output. Nested target scopes now support
loading depth-only targets. This removes the earlier explicit postpass rejection
in source; runtime equivalence and gameplay remain unverified.

First-person post-depth update (unbuilt/untested): after isolated colour drawing,
DepthClearCallback restores scene depth and replays its sorted subtree into the
PostProcessor opaque-depth texture with colour masked. Subtree replay covers
state-graph and child-bin order; transparent-depth callback continues to replay
only its original sorted leaf list. Parent target state is restored afterward.
Cameras without a PostProcessor skip the extra replay after restoring depth.
Child-effect feedback, target semantics and actual viewmodel rendering still
need the deferred build/runtime checks.


### Sun visibility query implementation (source only)

Sky pass 5 now samples the sun alpha mask in `material.cu`, applies the existing
raster depth/scissor/coverage rules and atomically counts surviving samples. It
writes no colour, normals or depth. The counts buffer has a material-sized tail
following the tile counts and camera status word; each sky query material uses
its material index there. Sky payload word 9 stores the query identity for pass
5 (other sky passes retain opacity there).

The viewer assigns monotonically increasing identities to weakly referenced
query geometry/camera pairs. The host reads completed GPU counts and publishes
all query results from an accepted frame together. Sun glare reads this cache
on subsequent culls. Dead identities cannot be reused; host results expire after
120 accepted frames without a new sample. This connects sun glare only, not
arbitrary OSG occlusion-culling nodes.

Implementation-first work remains in progress. These changes have not been
compiled or tested; generated kernels and the installed runtime are still stale.
All validation remains deferred until the implementation pass is complete.


### Screen-space particle expansion (source only)

POINT and LINE particle simulation records now reach authored `.cu` kernels.
`expand_particles` prepares opacity and velocity-normalized line displacement.
The new `project_particles` dispatch runs after vertex/attribute transforms and
before UV transforms and triangle clipping. It expands points using point size,
distance attenuation, limits and fade threshold. Lines receive homogeneous
six-plane endpoint clipping, width in pixels, and clipped endpoint UV/view
position interpolation. Point centres are rejected outside the clip volume.

This is implementation progress, not verified raster parity. Exact OpenGL line
diamond/endpoint rules, smooth point/line coverage, primitive-specific culling
and derived line-lighting varyings remain to be completed. General point/line
`osg::Geometry` topology and shader-simulated particles also remain. No shader
regeneration, compilation or tests have run for this change.


### Particle primitive-state follow-up (source only)

Particle submission now resolves a separate material for screen-space points
and lines. Its protected state disables face culling and polygon-fill depth
bias, while quad particles retain their original material and state. Mixed
particle systems preserve their original draw order. Clipped line endpoints now
also recompute the position-dependent sphere-map varying in `.cu` after the
endpoint view position changes.

These edits are unbuilt and untested. Exact line edge/endpoint rules, smoothing,
point/line-specific depth bias and generic point/line geometry still need work.


### Float image upload implementation (source only)

Float and half-float image data now uses four float-bit atlas words per texel.
The host copies raw source rows (respecting OSG row stride) and records source
and destination ranges. `float-image.cu` performs half conversion and channel
mapping for RGBA, RGB, RG, RED, luminance, luminance-alpha, alpha, BGRA and BGR.
Decode tags 6..14 select float32 layouts in that order; tags 22..30 select the
same half layouts. Existing DXT tags retain their meaning. Each supplied mip is
decoded on the GPU; missing mips use the existing floating-point `.cu` filter.
The floating sampler flag is retained when image records are reused.

Generated artifacts are stale; this implementation has not been built or tested.
Texture internal-format conversion/rounding (including float source uploaded to
normalized storage), sRGB, integer/depth image imports and other format cases
still need implementation or review before full renderer completion.


### Triangle-driven binning implementation (source only)

The production pipeline now dispatches one `.cu` thread per clipped triangle.
Each thread computes pixel-centre bounds and appends its triangle ID only to
intersected 16x16 tiles. A separate GPU heap sort restores ascending submission
order in each tile, preserving the renderer's blend/depth order despite atomic
insertion. GPU occupancy reduction returns an eight-byte maximum/status record
instead of copying the entire tile-count array to JavaScript. Overflow still
causes allocation growth and a complete bin retry before rasterization. The
previous capacity is retained as the next pass's initial sizing hint.

The old exhaustive binner remains available for the existing reference harness;
the production pipeline calls the new entries. Shader generation and tests are
still deferred. No performance gain has been measured. Fixed per-tile allocation,
the allocation readback, dense-tile sort cost, and broader frame pacing/resource
residency work remain; compact GPU lists are not implemented by this change.


### Compact triangle-list follow-up (source only)

Production binning now counts intersected triangle/tile references, computes
exclusive offsets in `.cu`, allocates the resulting candidate size, and scatters
and sorts triangle IDs on the GPU. This replaces fixed per-tile capacity and its
overflow retry loop. The candidate buffer starts with `tile_count+1` offsets;
each offset points to that tile's packed triangle IDs. `capacity == 0` selects
this layout in the material rasterizer and tile sorter. Positive capacity keeps
the old fixed-stride layout available to reference harnesses.

The prefix kernel checks the complete allocation against device buffer limits
before scatter. Its summary also carries the camera status word; the host reads
eight bytes for allocation. Count clearing leaves camera/query status storage
untouched. The first prefix implementation uses one GPU lane for the tile scan.

No kernels were regenerated or compiled, and no tests/benchmarks were run.
Allocation readback, prefix parallelization, sort cost, resource residency and
frame pacing remain performance work. Compact storage alone does not establish
playability or refresh-rate smoothness.


### Blocked prefix scan follow-up (source only)

Compact bin offsets now use three `.cu` stages: independent scans of 256-tile
blocks, a checked scan of block totals, and parallel addition of block bases.
Only one value per 256 tiles participates in the serial stage. Local sums detect
overflow before addition; the global stage validates total allocation size and
propagates camera status. Failed summaries prevent offset finalization and host
scatter submission. Kernel registrations and production dispatches were updated.

This supersedes the single-lane full-tile prefix implementation above. No
compilation, tests, or benchmarks have run; allocation readback and other pending
renderer/performance work remain.


### Constant blend-colour implementation (source only)

The material encoder now captures OSG BlendColor and encodes CONSTANT_COLOR,
ONE_MINUS_CONSTANT_COLOR, CONSTANT_ALPHA and ONE_MINUS_CONSTANT_ALPHA as blend
factor codes 11..14. The authored `.cu` blend function evaluates these factors
for RGB and alpha independently, alongside the existing blend equations.

**Raster parameter ABI is now eight floats per material:** polygon factor,
polygon units, depth near, depth far, then constant RGBA. Material cache keys and
specialized material copies include all eight values. Missing host-side raster
parameters default to the expanded layout. Earlier four-float descriptions and
test fixtures need updating during the deferred validation pass.

No shader generation, compilation or tests were run. Dual-source blending and
other unfinished render-state/renderer features remain outside this change.


### Built-in adjustments postprocess (source only)

PingPongCanvas now recognizes the single-pass built-in `adjustments` technique,
reads its current gamma/contrast values from the technique uniform definitions,
and emits a host command after scene resolve. The authored `adjust_scene` kernel
applies contrast about 0.5 and gamma to RGB in place, preserving alpha, depth and
normals. Multiple adjustments retain their order. Masked techniques remain
skipped. A distortion stage before adjustments is supported; distortion after
adjustments still explicitly requires intermediate-target implementation.

Negative gamma bases (undefined by the original GLSL pow) deterministically
become black. Gamma zero uses a deterministic limiting case. Full arbitrary FX,
bloom/luminance, intermediate precision/scale parity and general target routing
remain unfinished. These source changes have not been generated, compiled or
tested; no runtime acceptance or exact visual parity is claimed.


### Ordered distortion/adjustment follow-up (source only)

The supported postprocess effects now retain their full selected order, including
adjustments followed by distortion and repeated distortion stages. The first
distortion can remain fused with scene resolve. Later distortion commands copy
the current GPU attachment to a reusable GPU snapshot buffer, then run the
existing `.cu` resolve sampler into the destination. This avoids sampling from
an attachment while writing it. No pixels are read to the CPU. Empty distortion
bins still skip the effect instead of reusing stale offsets.

Ordering is now connected, but intermediate scene/output resolution and storage
precision parity still need work. This does not add bloom, luminance, arbitrary
FX or their render-target graph. Source is uncompiled/untested; generated
artifacts and installed runtime are unchanged.


### Scene luminance implementation (source only)

LuminanceCalculator now submits a WebCuda command when PingPongCanvas requests
average luminance for a supported active effect chain. It derives the original
power-of-two luminance dimensions, scale and exposure speed. The viewer forwards
source identity, viewport size and simulation time. Authored `.cu` stages compute
encoded logarithmic luminance (weights 0.2126/0.7152/0.0722, epsilon0.004, range
-9..4), reduce its mip pyramid, and adapt exposure in persistent GPU history.
The original encoded-luminance warm-up behavior is retained. Dropped frames do
not update GPU history; the next accepted time supplies the elapsed interval.

This connects calculation, not all consumers. Bloom/generalFX still need their
sampling paths wired to that history. Intermediate R16F rounding, first-frame
timing, viewport/resize cases and exposure continuity need final implementation
review and tests. No compilation, shader generation or tests have run.


### Bloom kernel implementation (not dispatched yet)

Authored `.cu` stages now mirror the built-in `bloomlinear.omwfx` extraction,
horizontal/vertical Gaussian sampling and final gamma-space dither/clamp plus
linear-light combine. Extraction uses the shader's near/far depth formulas,
sky factor and threshold; blur uses nearest sampling and resolution-dependent
radius; combine uses bilinear bloom sampling and simulation-time scrambling.
Kernels are registered for future generation/loading, but PingPongCanvas still
rejects bloom until parameter and intermediate-target dispatch is connected.

This built-in bloom does not consume average luminance (confirmed from its
source). Luminance is a separate facility for other FX. RGB16F intermediate
rounding, resolution/routing parity, execution and visual validation remain.
No shader generation, build or tests were run.


### Bloom dispatch connection (source only)

PingPongCanvas now accepts built-in bloomlinear's four-pass layout and preserves
its order among supported adjustments/distortion effects. Fx StateUpdater uses
plain uniforms in WebCuda mode, including when its native configuration selects
UBOs. The bloom encoder reads actual near/far, resolution, simulation time and
reverse-Z plus current user controls. The viewer resolves the scene depth target
and transports an owned parameter snapshot to the browser.

The browser snapshots the current colour attachment on the GPU, allocates
quarter-resolution extraction/horizontal/vertical buffers, dispatches all four
`.cu` bloom stages, and writes the result back without CPU pixel reads. This
supersedes the earlier note that bloom is not dispatched. RGB16F intermediate
rounding, scene/output resolution parity, custom target/layout variations and
complete execution/visual validation remain. No generation, build or tests ran.


### Postprocess half-float precision (source only)

A shared authored `precision.cuh` now implements float/half bit conversion with
round-to-nearest-even, subnormal, signed-zero, overflow and NaN handling. Float
image import uses its half expansion helper. Bloom extraction and both blur
stages round RGB stores to half precision; luminance encoding, each reduction
level and adapted history likewise round to R16F precision. Buffers retain the
existing float32 transport layout, storing values after that rounding step.
The compiler script expands the authored include before WebCuda translation.

This removes the deliberate full-precision intermediate approximation for those
postprocess stages. It is not a tested parity claim: conversion edge cases,
backend handling of subnormals, final target formats and all runtime behavior
remain unverified. No generation, compilation or tests were run.


### Postprocess chain resolution follow-up (source only)

The host now consumes contiguous supported effect commands as one ordered chain.
Intermediate stages alternate between two scene-sized GPU buffers; the final
stage alone targets output resolution. A leading distortion remains the first
actual stage, and a plain copy is emitted only when the chain has no effects.
Adjustments now sample a separate source at their destination resolution before
applying contrast/gamma, including alpha sampling. Bloom and distortion likewise
receive explicit input and output dimensions. This removes the previous
output-sized in-place effects and repeated snapshot copies.

Ordinary intermediate target-format rounding, arbitrary FX, custom targets and
viewport cases still need work. This source refactor is not compiled or tested;
shader generation and all validation remain deferred.


### Postprocess attachment storage (source only)

Scene resolve now transports both the scene texture's internal format and the
actual destination format (RGBA8 for the presentation attachment). A `.cu`
storage step follows every supported effect: intermediate results use the scene
format and the final result uses the destination format. Supported R/RG/RGB/RGBA
UNORM8, binary16 and binary32 layouts clamp/round or preserve values as appropriate;
missing colour channels receive texture-sampling defaults. Depth/normals are
untouched. This makes final colour storage happen before subsequent UI blending.

Other colour formats, sRGB conversion, exact normalized rounding parity and all
runtime behavior remain unverified. No shaders were generated and no build or
tests ran. The compiler/host ABI for scene-resolve now includes both formats.


### Explicit postprocess destination connection (source only)

PingPongCanvas can now route its supported effect chain into an explicit FBO
containing one base-level, single-sample Texture2D colour attachment. It enters
the existing nested target stack, resolves/renders into that texture, then
restores the parent target. Source/distortion/depth aliasing is rejected before
submission. Unsupported attachment layouts still fail explicitly. The destination
format reaches the existing `.cu` postprocess storage conversion.

Viewer target classification now recognizes R/RG/RGB as well as RGBA 16F/32F
colour formats, retaining float atlas storage for later texture sampling.
General raster writes still need complete per-format conversion; this change
connects postprocess destination handling. Multisample/layered/mip/MRT destination
layouts and all execution checks remain pending. No build or tests were run.


### Raster attachment precision connection (source only)

Camera and nested-target state now transport colour internal format. Shared host
metadata maps supported formats to channel count and storage class, while a
shared authored `.cu` helper performs actual conversion. `raster_material`
converts each fragment's blended result before the next fragment reads it;
`clear_attachment` applies the same format rules. Encoded normal attachment
writes/clears round to normalized RGBA8. Postprocess storage uses that helper too.

Both raster_material and clear_attachment now require `color_channels` and
`color_storage` arguments. Deferred native/browser fixtures need that ABI update.
Other formats/sRGB, depth/stencil/MSAA precision and runtime parity remain pending.
No shader generation, builds or tests ran. The new host module color-storage.js
must accompany pipeline.js and game-host.js in deployment.


### Depth attachment precision (source only)

Camera/renderbuffer and nested-depth-target formats now reach the browser.
`depth_bits` selects 16-bit normalized, 24-bit normalized or float32 storage in
`.cu` clears and the material rasterizer. Fragment depth is clamped/converted
before comparison; polygon-offset units now depend on depth format, including
an exponent-based floating-depth increment. Packed depth/stencil formats select
only their depth representation here; this does not implement stencil storage.

The explicit-destination attachment getter was also corrected to the installed
OSG API's getTextureLevel during source review. No builds/tests were run. Exact
depth rounding and polygon-offset parity, stencil/MSAA and other depth formats
remain unverified or incomplete; deferred fixtures need the new depth_bits arg.


### Stencil material transport (execution still pending)

Single- and two-sided OSG stencil state now encode front/back comparison,
8-bit reference/read/write masks and all eight operations (keep, zero, replace,
saturating increment/decrement, invert, wrapping increment/decrement). Material
flag8192 marks stencil testing. The raster parameter ABI is now **24 floats**:
existing raster/blend eight, front seven, back seven, two reserved. Material
cache keys, specialized copies, host defaults and raster indexing use that size.

The host deliberately rejects stencil-enabled materials until GPU stencil
storage, clear and ordered fragment operations are connected. Encoding is not
stencil rendering support. Tests are deferred and must adopt the new parameter
stride. No shader generation, compilation or tests were run.


### Packed stencil execution (source only)

The production target allocation is now **40 bytes per pixel**: the original
nine-float interleaved RGBA/depth/normal records followed by a separate float
plane at `pixel_count*9`, storing integer stencil values0..255. All production
target/scratch allocations use this size. Newly allocated targets initialize
stencil0; camera clears transport their stencil clear value. Packed24/8 and
float32/stencil8 depth formats enable the plane.

The `.cu` rasterizer applies encoded front/back comparison and masked operations
after shader discard/alpha decisions, choosing stencil-fail, depth-fail or pass
operations before colour/depth output. Stencil-enabled depth failures therefore
cannot take the early depth rejection path. Sun query samples use the same test
ordering. Shared packed attachments copy preserved stencil independently of
whether depth is cleared. Host stencil-parameter validation is connected and the
previous blanket stencil-material rejection is removed.

Standalone stencil attachments, default-framebuffer stencil discovery, complete
clear masks/scissor handling and MSAA remain. No generation/build/tests ran;
all deferred target fixtures need40-byte allocation and new stencil kernel args.


### Standalone/default stencil attachments (source only)

Viewer now recognizes standalone eight-bit stencil attachments, assigns an
identity retained with the owning OSG object, and transports that identity plus
stencil bit depth. The host preserves shared stencil contents across colour
attachment changes unless the pass clears stencil. Stencil-only targets disable
colour/depth output. Default-framebuffer stencil size comes from the graphics
context traits; unsupported bit sizes fail explicitly. Packed depth/stencil
continues to select eight-bit operation.

No generation, compilation or tests ran. Multisample/layered stencil, complete
clear-state parity and runtime ownership/resize behavior remain unverified or
unfinished. This is source wiring, not a claim of tested stencil support.

### Stage clear channel masks (source only)

The stage color mask now travels from OSG through the browser packet to the
`.cu` clear kernel. Disabled channels retain their previous values, including
normal attachment channels. Shared normal buffers are copied before a partial
clear so masked channels come from the correct attachment.

This follows `osgUtil::RenderStage::drawImplementation`: depth/stencil clears
force their write masks on; color clears use the stage color mask. The existing
zero-origin, full-target viewport restriction means its clear scissor covers the
whole allocated target. Subviewports and multisample clears remain unfinished.
`clear_attachment` now also requires `clear_color_mask` (four low channel bits).
Fixtures and generated artifacts must be updated during the deferred build/test
phase. No generation, compilation or tests ran for these changes.

### Independent attachment storage (source only)

Depth, stencil and normal identities now own their storage instead of aliasing
the last camera color composite. The host loads preserved planes before a pass
and stores changed planes after it using the existing `.cu` copy kernels. This
prevents a later pass on the same color target with different attachments from
overwriting an unrelated shared attachment. New/resized plane storage receives
explicit GPU initialization; depth isolation publishes depth changes as well.

Depth renderbuffers now receive retained identities, including packed
 depth/stencil renderbuffers. Offscreen color-only FBOs disable depth testing
and writes in the material encoder. Texture sampling still resolves only actual
texture identities.

These changes favor correct ownership over copy bandwidth; eliminating redundant
plane copies remains performance work. Owner retirement, full attachment sizes,
multisample/layered attachments, and the deferred renderer build/gameplay tests
remain outstanding. No shader generation, build or tests ran for this change.

### Target lifetime retirement (source only)

Renderer identity tables now observe engine textures/renderbuffer owners weakly.
Expired entries are collected before target registration and lookup; monotonic
IDs prevent a newly allocated object at a reused address inheriting old content.
The expired IDs remain queued through frame aborts. At the next accepted frame,
before any pass is recorded, the host destroys their independently owned GPU
storage and removes associated luminance history and exposure buffers.

Offscreen-only frames now wait for their final plane-store dispatches before
accepting another frame. This makes the retirement boundary cover all preceding
GPU work, including frames without presentation. This addresses owner lifetime,
not the remaining multisample/layered/subviewport implementation or overall
renderer verification. No shader generation, compilation or tests ran.

### Camera viewport transport (source only)

Camera packets now carry an integer bottom-left viewport independently of full
attachment dimensions. Texture/renderbuffer dimensions (or window context
traits) determine the target allocation. Mixed attachment extents still reject.
The `.cu` map_viewport kernel maps clipped homogeneous vertices into the target
without changing w or depth; clipping remains in the original camera frustum.
Point/line particle projection uses viewport dimensions before this mapping.

Camera clears operate only on viewport-covered pixel centers, respecting the
existing channel mask. Shared depth/stencil/normal planes load their preserved
contents before partial clears so pixels outside the viewport survive. Negative
integer viewport origins can intersect the target bounds. Fractional viewports,
mixed-size planes, layered/MSAA attachments and custom postprocess subviewport
semantics remain unfinished. No build/generation/tests ran; new map_viewport and
clear_attachment parameters require deferred compiler/fixture verification.

### Final postprocess viewport placement (source only)

Scene-resolve commands capture the camera viewport. For a partial viewport, the
last built-in effect renders at viewport resolution into scratch storage and
passes through the usual destination-format conversion. The authored `.cu`
place_postprocess kernel copies only its covered color pixels into the full
destination, retaining other pixels and all depth/normal/stencil planes.
Negative origins clip at the destination boundary. Full-target effects retain
the direct-output path and need no extra placement dispatch.

This connects viewport placement for the currently implemented built-in chain;
it does not implement arbitrary effect graphs, multiview, scaled fallback UVs,
fractional viewports, or complete per-draw postprocess state. No generation,
compilation or tests ran. The new kernel is registered for deferred generation.

### Fallback resolve UV scaling (source only)

The fallback fullscreen shader's two-component scaling uniform now travels
through SubmissionSink, Viewer and the host resolve command. resolve_scene.cu
multiplies its bottom-left sample coordinates by those values before sampling.
The previous blanket rejection of non-unit scaling is removed. Built-in effect
chains continue with unit scaling, matching the separate native fallback path.
Finite scale values are validated at the host boundary; negative/zero values
retain the existing clamp-to-edge sampling behavior.

resolve_scene now requires scale_x and scale_y kernel arguments. Deferred
fixtures/generation must account for this ABI addition. No generation, build or
tests ran. General custom effects, debug effect, multiview, multisampling and
remaining renderer paths are still unfinished.

### Built-in debug effect (source only)

The debug technique now transports depth/normal toggles, depth factor, camera
planes and raw view matrix into a host command. The authored debug_scene `.cu`
kernel implements linear-depth display, the original left-half normals overlay,
view/world normal selection and the shader's alpha behavior. Normal attachments
are optional when unavailable. The effect participates in the ordered built-in
chain, intermediate format conversion and final viewport placement.

Source inspection of PostProcessor::createTextures shows linear filtering on
its depth and normal textures. Debug and bloom depth sampling now use the same
bilinear attachment sampler before depth linearization. Previously bloom used
nearest sampling. No shader generation, compilation or tests ran; custom effect
graphs, MSAA/multiview and the other outstanding renderer paths still remain.

### WebCuda normal capability and indexed mask (source only)

PostProcessor now advertises normal attachments when WebCuda is requested,
independently of indexed GL entry points. The WebGL workaround remains in force
for the WebGL backend. This lets normal-requesting techniques create the actual
normal attachment and publish matching shader defines for the `.cu` path.

Raster parameter 22 now stores the normal attachment's disabled-channel bits.
The encoder reads ColorMaski member 1, falling back to a non-indexed ColorMask;
an indexed mask for color attachment 0 does not mask normals. The `.cu` normal
write uses these independent bits, so transparent material masks no longer rely
on the primary color mask. Parameter 23 remains reserved. Host range validation
is connected. No builds/generation/tests ran; end-to-end normal capability,
transparent materials, and the remaining renderer work still need verification.

### Generic OSG particle submission (source only)

Plain osgParticle::ParticleSystem drawables now enter the existing `.cu`
particle expansion/raster path under their read lock, including color-pass depth
write suppression and optional depth-only second pass. A small pinned OSG header
patch exposes external-draw bookkeeping (last frame and dirty delta time) so the
simulation does not infer that these systems were culled. build-osg.sh applies
this patch during the deferred dependency build; installed headers are not yet
rebuilt. Existing NIF custom submission remains first in dispatch.

The particle packet now carries its source normal in attribute slots 21..23;
`.cu` expansion preserves it. Generic particles default to (0,0,1), while NIF
submission explicitly supplies its (0.3,0.3,0.3) normal. ConnectedParticleSystem
ribbons still reject explicitly instead of silently drawing disconnected quads;
shader-driven particle systems remain unfinished. No generation/build/tests ran.

### Connected ribbon GPU preparation (in progress)

New authored ribbons.cu contains prepare_ribbon, porting OSG's projected pixel
size estimate, adaptive collinearity skipping, model-view inversion for local
eye position, and camera-facing ribbon pair construction. Thin-line selection
is retained in the output summary; selected points retain their color, alpha and
S coordinate. The kernel accepts particles already arranged in linked-list
order (host connectivity work, no host geometric calculations) and emits compact
packed vertex pairs plus count/mode/status.

This kernel is registered for deferred generation but is NOT YET wired into the
packet/host draw path. ConnectedParticleSystem still rejects until transport,
quad-strip assembly and thin-line projection are connected. The next step is
that integration, not treating this source-only kernel as working ribbons. No
shader generation, build or tests ran.

### Connected ribbon pipeline integration (source only)

Connected particle submission now packs linked-list order with cycle/index
checks and reserves four vertices/two triangles per possible segment. New packet
arrays ribbonParticles (10 floats per source particle) and ribbonRanges (12
uint words per system) pass through the WASM bridge. The host validates range,
material, matrix and overlap bounds, then dispatches prepare_ribbon and
assemble_ribbon before the ordinary transform/clip/raster sequence.

Assembly preserves draw ordering and makes unused slots degenerate. Thin-line
mode uses source attribute mode 7 and the GPU homogeneous line clip/project
path, interpolating endpoint RGBA and S coordinates with V fixed at 0.5.
Connected systems retain their own native depth-state semantics rather than
using ordinary ParticleSystem double-pass behavior. The prior ribbon rejection
is removed. No generation/build/tests ran; exact line coverage, shader-driven
particles and the remaining renderer features are still outstanding.

### Built-in OSG shader particle path (source only)

The exact embedded ParticleSystem vertex/fragment pair is recognized after
whitespace normalization; arbitrary particle shader source still rejects. Its
explicit unlit texture/color contract uses the selected baseTexture unit and
requires particle vertex inputs. Particle packets use mode 8 for point sprites,
ignore shape/rotation/atlas animation as the source shader does, carry alpha and
visibilityDistance, and supply full point-sprite UVs. Visibility rejection and
projection run in `.cu`; ordinary CPU particle depth visibility filtering does
not override the shader rule.

This covers the embedded built-in pair, not custom shader simulation. The native
built-in does not assign gl_PointSize despite enabling program point size;
point sizing/fade and sprite-coordinate orientation need explicit comparison
in the deferred runtime phase. No build, generation or tests ran. Remaining
custom shaders, exact primitive coverage, FX/MSAA/multiview and other renderer
work are not complete.

### Floating image storage conversion (source only)

Floating image decode records now encode source layout in low 8 bits, destination
channel kind in bits 8..10, storage class in bits 12..13, and conversion presence
in bit 16. Source-only old records retain their previous float32 behavior. `.cu`
decode performs channel expansion/swizzle, legacy luminance/alpha handling and
UNORM8, half or float32 storage conversion. The atlas remains four float words
per pixel, even for normalized storage. Image cache keys include internal format.

Float mip generation now requires color_channels/color_storage and quantizes
each generated level. Metadata propagates from decoded images and floating color
render targets. Unsupported internal storage formats reject rather than silently
preserve inappropriate source precision. Byte/integer uploads, sRGB and other
remaining texture formats still need work. No generation/build/tests ran.

### Byte-source storage conversion (source only)

Unsigned-byte images now enter the `.cu` conversion path when source layout and
internal storage differ, including float16/float32 targets and red/RG formats.
Decode tags 38..46 encode normalized-byte versions of layouts 6..14. The host
validates byte-sized source ranges; the decoder extracts packed bytes, normalizes
them, then applies the existing destination channel/precision rules. Row padding
is removed during raw upload, with checked source byte bounds.

Matching byte RGBA/RGB/luminance/alpha formats retain compact packed atlas
storage, avoiding a global fourfold atlas expansion. Other integer component
types, sRGB, compressed-to-different-storage conversion and legacy fixed-function
alpha semantics still need work. No shader generation, build or tests ran.

### Normalized integer component uploads (source only)

The uncompressed decoder tag is now layout6..14 plus 16*componentFamily:
0=float32, 1=half, 2=uint8, 3=uint16, 4=int8, 5=int16, 6=uint32,
7=int32. Raw rows retain their component bytes; host range checks use the correct
component width. `.cu` extracts signed/unsigned values and normalizes them, with
signed minima clamped to -1, before channel mapping and destination conversion.
Float32 conversion precision applies to 32-bit integer sources.

These are normalized scalar uploads, not integer-sampler internal formats.
Packed component types, integer samplers, sRGB and additional destination formats
remain unfinished. No shader generation, compilation or tests ran; signed edge
values and mip behavior remain part of the deferred verification phase.

### Packed normalized texture sources (source only)

Decode component families 8..15 now cover RGB565, RGB565_REV, RGBA4444,
RGBA4444_REV, RGB5_A1, A1_RGB5_REV, RGBA8888 and RGBA8888_REV. Upload rows
count packed words per pixel, not one word per channel. Layout checks constrain
565 to RGB/BGR and four-component packed types to RGBA/BGRA. `.cu` extracts
and normalizes bit fields before existing swizzle/storage conversion.

This covers these source types only; additional packed types, packed internal
storage precision, sRGB, integer samplers and other remaining renderer paths
are unfinished. No generation/build/tests ran. Bit-order and row-padding cases
remain explicit deferred verification requirements.

### Uncompressed sRGB texture sampling (source only)

Internal SRGB/SRGB8 and SRGB_ALPHA/SRGB8_ALPHA8 now select storage class 3.
`.cu` upload conversion quantizes encoded RGB to eight bits and decodes it to
linear atlas values before filtering; alpha is linear UNORM8. The shared
precision helper encodes, quantizes and decodes generated mip RGB so each level
retains sRGB storage precision while filtering stays in linear space. Source
sRGB RGB/RGBA layout aliases are accepted as well.

This implements uncompressed sampled textures, not framebuffer sRGB enable/
disable behavior or compressed sRGB formats. No generation/build/tests ran;
transfer-curve boundary values and mip/filter parity remain deferred checks.

### Compressed sRGB DXT textures (source only)

SRGB DXT1 RGB/RGBA, DXT3 and DXT5 internal formats now allocate a float atlas
and carry conversion metadata alongside their existing block-format tags.
The `.cu` DXT decoder decompresses encoded channels, converts RGB to linear,
and leaves alpha normalized/linear. The host distinguishes source block layout
from output atlas stride and propagates sRGB metadata to generated mip levels.
Ordinary non-sRGB DXT decoding retains packed RGBA8 output.

Existing file-provided mip levels use this path. Generated mip levels retain
sRGB8 precision but do not recompress into DXT blocks; compressed mip-generation
parity remains unfinished. Framebuffer sRGB, other formats and the broader
renderer implementation also remain. No generation/build/tests ran.

### Texture channel swizzles (source only)

Sampler metadata now uses bit28 to enable four three-bit channel selectors in
bits16..27. Selectors0..3 choose RGBA,4 supplies zero,5 supplies one. The engine
encodes OSG Texture::getSwizzle; default identity textures retain their previous
16-bit metadata. Host sampler validation now accepts and checks this extension
across primary, layer, water, screen and moon descriptors.

The authored `.cu` sample_mipped helper resolves the requested channel before
filtering, so swizzles apply to packed/float/sRGB decoded atlases without changing
shared storage or generated mip data. Constants also apply outside the image.
Shadow comparison remains its separate scalar path. No builds/generation/tests
ran; material-family and constant/border behavior require deferred verification.

### Texture border descriptors (source only)

Sampler bit29 redirects the texture base to a five-word descriptor: the original
image base followed by four float-bit border components. Identical descriptors
are shared within a pass. Image uploads, render-target copies, and mip generation
continue to address the original image; different border colors do not duplicate
its pixels. Host range validation follows the indirection for every material
family and rejects non-finite border values.

The `.cu` mip sampler selects border values per tap before filtering, including
swizzled channels. Shadow comparison uses the red border value before comparison
and filtering. Depth values are clamped to the normalized range; packed color
borders are also clamped. Format-specific border precision for converted float
atlases remains a parity item. Legacy zero/one depth-border metadata is accepted.

Ribbon output ranges now reject overlaps with skinning or morph inputs, which
would otherwise overwrite generated ribbon geometry in later dispatches.
These are source changes only: shader generation, builds and tests remain
deferred until the implementation pass is complete.

### Ordinary point and line geometry (source only)

The geometry packet now carries `screenPrimitives`, twelve uint words per
primitive: source endpoints, first of four reserved output vertices, point flag,
float-bit size/minimum/maximum/fade/attenuation XYZ, and one reserved zero.
The engine enumerates POINTS, LINES, LINE_STRIP and LINE_LOOP without doing
rendering arithmetic. DrawArrayLengths and available MultiDrawArrays subranges
retain their boundaries. Polygon draws keep their original material; generated
point/line quads use a material with polygon culling and fill offset disabled.

`screen-primitives.cu` expands the records after skinning, morphing, camera and
UV transforms. It clips line endpoints in homogeneous space, interpolates their
color/UV/material varyings, and creates screen-width quads. Points use distance
attenuation, size limits, fade and pixel alignment. Packet validation forbids
outputs aliasing inputs, other outputs or deformation destinations.

This establishes the geometry path, not exact native raster parity: diamond-exit
line coverage, smoothing/stipple, point-sprite replacement, and flat-shaded
provoking-vertex behavior remain implementation items. Shader generation,
compilation and tests have not run for this change.

### Ordinary point-sprite replacement (source only)

Screen primitive word11 now carries texture-unit replacement bits0..3 and a
lower-left-origin bit4. The engine resolves PointSprite state in texture-unit
order, matching the shared origin state. The `.cu` expansion generates sprite
coordinates after texture transforms and writes the enabled coordinate sets;
upper-left remains the default. Lines must have zero sprite flags.

Replacement applies to the fixed-function coordinate contract. OpenMW's built-in
world shaders use named UV varyings, which point-sprite replacement does not
modify, so their existing shader coordinates are preserved. The separate
built-in particle shader path remains separate. This source change has not been
generated, built, or tested; pixel/origin/texture-matrix cases remain deferred.

### Fixed-function texture environments (source only)

Material flag16384 identifies an eight-word texture-environment descriptor:
original texture base, operation, base-format class, reserved zero, constant RGBA.
Operations0..4 are MODULATE, REPLACE, DECAL, BLEND and ADD. Format classes encode
RGBA/LA, RGB/L, alpha-only and intensity component participation. Identical
records are shared per pass; the original texture base may itself be a border
descriptor. Host validation follows both indirections.

The authored `.cu` texture_environment function combines the sampled and primary
colors and clamps the fixed-function stage output. Alpha-only textures preserve
primary RGB; RGB/L textures preserve primary alpha. GUI and translated shader
materials retain their explicit contracts. General TexEnvCombine attributes
still fail explicitly and require implementation. Some legacy sized formats and
undefined DECAL/base-format combinations remain parity items. No shaders were
generated and no build or tests ran during this implementation step.

### Single-stage texture combiners (source only)

Texture-environment descriptors now occupy24 words. Operation5 enables
TexEnvCombine: words8/9 encode RGB/alpha operations,10/11 hold scales1/2/4,
12..14 and18..20 select RGB/alpha sources, and15..17 and21..23 select operands.
Sources are the sampled texture, primary color, constant, and previous (equal
to primary at this first stage). Operands select color/alpha or their inverse.

The `.cu` implementation covers replace, modulate, add, signed add, interpolate,
subtract, DOT3_RGB and DOT3_RGBA; alpha accepts the non-dot operations.
DOT3_RGBA replaces alpha using the RGB result/scale. Host validation checks
operations, operands and scales. Cross-unit texture sources and multiple
fixed-function stages remain explicitly unsupported and require implementation.

Packed alpha-only uploads now expand to zero RGB plus stored alpha, matching
the float decoder and allowing source-color operands to agree across upload
paths. Fixed-function alpha textures preserve primary RGB through base-format
rules. Texture swizzles can independently replace sampled channels.
No shader generation, build, or tests ran; all numerical and runtime validation
remains deferred with the rest of the implementation pass.

### Fixed-function fog (source only)

Material flag32768 enables a shared eight-word fog descriptor. Raster word23
holds its atlas offset as opaque uint bits in the float stream; it is never
interpolated or used in floating arithmetic. Descriptor word0 is mode0/1/2
(linear/exp/exp2) plus radial bit2, followed by density, start, end and RGBA bits.
Host validation checks ranges, finite values, density and color limits.

The `.cu` raster stage derives absolute eye-space Z or radial eye distance,
evaluates and clamps the fog factor, then mixes RGB before alpha/depth/blending.
Alpha is unchanged. Default enabled fog without an attribute follows OSG's
constructor values. GUI and translated shader fog remain separate. Explicit
per-vertex fog coordinates still require a packet stream and fail explicitly.
No generation, builds or tests ran; fog curves, radial distance, blending and
shader-path separation need the deferred validation pass.

### Explicit geometry fog coordinates (source only)

Ordinary fixed-function geometry now copies float/double fog coordinate arrays
with overall or per-vertex binding. Missing/off arrays use the initial zero
coordinate. Input attribute mode-1 carries the coordinate at slot2; the `.cu`
attribute transform moves it to varying9 after consuming the normal basis.
The regular clipping and interpolation paths therefore retain the coordinate,
including for generated ordinary points and lines. World-shader depth retains
its existing slot9 meaning and does not use this input mode.

Fog descriptor bit3 selects the interpolated explicit coordinate instead of
eye-space depth. Particle draws with explicit fog coordinates remain rejected
until their distinct attribute expansion is connected. GeometrySink now marks
particle contexts consistently with Viewer. No generation/build/tests ran;
binding, clipping, deformation and mixed-material checks remain deferred.

### Color logic operations and signed fog correction (source only)

Raster control bit25 enables color logic operations; bits21..24 hold the sixteen
GL opcode values relative to GL_CLEAR. The `.cu` raster implements all sixteen
boolean combinations on quantized UNORM8 components, including the normal
attachment and its channel masks. Enabled logic operations bypass blending;
floating color attachments skip the boolean operation itself. sRGB/integer and
other attachment formats remain part of the pending format work.

Explicit fog coordinates now retain their sign through interpolation and fog
evaluation. OpenGL1.5 section3.10 defines this input as the interpolated coordinate,
not its absolute value (https://registry.khronos.org/OpenGL/specs/gl/glspec15.pdf).
The eye-depth path continues to use absolute eye Z or radial distance.

Particle source inspection found no per-particle fog coordinate submission.
Inherited current-coordinate state needs further handling before that path can
be claimed; its explicit-fog rejection remains. No generation/build/tests ran.

### Frame-boundary completion (source only)

The game host now requests deferred pass completion. Camera passes no longer
wait for an extra idle fence after rasterization or allocate/dispatch their own
unused packed presentation image. The host still packs the completed screen
once, waits at the accepted-frame boundary, and keeps one frame in flight.
Standalone pipeline calls retain their completed-result/packed-pixel contract.

Query readback queues a staging copy before counts can be reused by the next
camera. Only the material-count tail is copied, not all tile counters. Results
are collected and published together at the frame boundary; rejected readbacks
are captured and surfaced through the host failure path. Source inspection of
WebCuda runtime.read confirmed that its copy is submitted before mapAsync yields.
The compact-list allocation readback remains an unavoidable fence in the current
implementation and still needs optimization. No timing/performance gain is
claimed: runtime, buffer-lifetime, query and frame-pacing tests remain deferred.

### Deferred buffer retirement (source only)

Pipeline buffer growth and host attachment/presentation replacement now retire
old storage into a shared set instead of immediately destroying it. Completed
standalone calls or the game host's frame-completion fence collect that set.
This keeps buffers alive across queued camera work after deferred pass completion.
Explicit releases also use the same retirement path.

The host failure path drains previously submitted work before clearing busy.
Disposal waits for the queue and then collects both active and retired resources.
No build or runtime tests ran; multi-camera growth, resize, injected failure,
device-loss and disposal cases remain required deferred checks.

### Fixed-function flat primary colors (source only)

Geometry packets now include one flatColors uint per input triangle. UINT32_MAX
means smooth; other entries identify the original provoking vertex. The engine
preserves the fixed-function convention while triangulating strips, fans,
quads, quad strips and polygons. Ordinary flat lines select their final endpoint;
points already have constant color. Shader programs with named varying outputs
retain their current explicit shader contract.

assemble_material now consumes an eighth storage binding, flat_colors, and
copies provoking RGBA after reconstructing clipped vertices. Texture coordinates
and the other material varyings remain interpolated. Keeping the original vertex
index preserves flat color even when clipping removes the provoking vertex.
Packet merging rebases indices, and the host validates lengths and bounds.

Generated shader artifacts and direct assembly-kernel fixtures must be updated
in the deferred generation/test phase. Particle/ribbon flat-shading semantics,
programmable flat varyings and first-vertex convention remain separate work.
No build, shader generation or tests ran for this source change.

### Flat connected-particle ribbons (source only)

Ribbon range records now contain13 words; word12 is the fixed-function flat-color
flag. The host validates it and forwards flat_color to assemble_ribbon. After GPU
particle selection, every segment copies RGBA from its final selected particle.
The same choice is applied to both wide ribbon quads and thin line endpoints,
so later line clipping cannot reintroduce a color gradient. Texture coordinates
continue to vary along and across the ribbon. Shader-program varyings retain
their explicit shader contract.

The prior12-word ribbon ABI and generated assemble_ribbon artifact are stale;
regeneration and fixture migration remain in the deferred validation phase.
No build, generation or tests ran. Line coverage, smoothing/stipple and broader
renderer work are still outstanding.

### Legacy intensity texture storage (source only)

INTENSITY/INTENSITY8 now route through the raw-upload GPU decoder. Destination
kind8 copies the source red/intensity component into all four output channels,
including alpha, before UNORM8 storage conversion. This connects the intensity
component rules already present in fixed-function texture environments.

Decode destination metadata now uses bits8..11 (four bits), with kinds1..8
accepted by the host. Generated float mip metadata treats replicated intensity
as four stored channels. sRGB conversion remains restricted to RGB/RGBA, and
compressed-image metadata retains its existing restricted format combinations.
Other sized intensity formats remain unsupported. No generation/build/tests ran;
intensity upload, alpha blending, combiner and mip tests remain deferred.

### Normalized16 texture storage (source only)

Storage class4 now quantizes to UNORM16 in precision.cuh. R16, RG16, RGB16,
RGBA16 and the legacy alpha/luminance/luminance-alpha/intensity16 internal
formats route through GPU decoding with their component semantics preserved.
Generated float-atlas mip levels use the same16-bit storage precision.

Decode storage metadata now occupies bits12..14, with host validation accepting
classes0..4 and rejecting reserved values. The format tag and destination-kind
fields are unchanged. Compressed sRGB remains restricted to class3. This step
covers sampled texture storage; normalized16 framebuffer registration and logic
operations still need their own connection. No generation/build/tests ran.

### Normalized16 framebuffer storage (source only)

R16, RG16, RGB16 and RGBA16 color attachments now use storage class4 for GPU
clears, fragment writes and postprocess storage conversion. Render-texture
registration selects a four-word float-bit atlas copy to retain16-bit precision.
The wide-atlas identity flag is now distinguished from an actually floating
attachment: normalized targets continue to clamp fragment/blend values.

The `.cu` boolean color operations now use an8- or16-bit mask according to the
color attachment storage class; normal attachments retain their8-bit behavior.
Float render-target sampling and generated mips reuse the format metadata already
carried by the host. Legacy luminance/alpha/intensity framebuffer formats remain
outside this registration path. No build, generation or tests ran; clear/write,
blend, logic and render-to-texture precision checks remain deferred.

### Signed normalized texture storage (source only)

Storage classes5/6 now quantize SNORM8/SNORM16 in `.cu`, retaining negative
components in the float-bit atlas. R/RG/RGB/RGBA signed normalized internal
formats route through existing signed/unsigned/float source decoding, then use
the requested destination quantization. Missing components retain zero RGB and
one alpha defaults. Generated mips preserve the signed destination precision.

The host accepts storage classes0..6 and rejects reserved class7. RGB signed
formats preserve primary alpha under fixed-function base-format rules. Signed
normalized framebuffer registration and boolean operations are not yet connected.
No generation/build/tests ran; signed endpoints, zero crossings, filtering and
mip precision remain deferred validation cases.

### Signed normalized framebuffer storage (source only)

SNORM8/SNORM16 R/RG/RGB/RGBA attachments now register storage classes5/6.
The engine chooses a wide atlas transport and avoids the unsigned [0,1] fragment
clamp; `.cu` storage conversion applies the signed destination range/precision.
Clear, raster write, postprocess conversion and render-texture/mip paths share
that storage metadata.

Boolean operations on signed attachments remain rejected. A float-valued target
cannot distinguish both signed integer endpoint encodings that normalize to -1,
so accepting bitwise operations here would silently lose stored-bit semantics.
They require a raw integer storage path. Signed blending and negative channel
round trips remain unverified. No generation, builds or tests ran.

### Format-aware texture borders (source only)

Border descriptors now occupy6 words: image base, RGBA float bits, and format
metadata. The metadata low nibble maps RGBA/R/RG/RGB/luminance/luminance-alpha/
alpha/intensity; bits4..5 choose unsigned-normalized, signed-normalized, half,
or float range. The engine records these for supported sampled/target formats.

`.cu` border sampling applies base-format component defaults/replication and
clamps to [0,1], [-1,1], or the finite half range as appropriate. Swizzles still
select the resulting sampled component. Borders are not rounded as uploaded
texels: OpenGL3.1 section3.8 specifies format-dependent clamping before use
(https://registry.khronos.org/OpenGL/specs/gl/glspec31.pdf). Depth comparison
continues to use the red border component.

Prior5-word border descriptors and fixtures are stale. No shader generation,
builds or tests ran; component defaults, signed extremes, half limits, swizzles,
sRGB borders and filtering remain deferred runtime/numerical checks.

### Attachment-dependent blend ranges (source only)

The `.cu` blend stage now derives source/destination component and factor ranges
from attachment storage: unsigned normalized clamps to [0,1], signed normalized
to [-1,1], and half/float attachments preserve their floating values. Source
alpha is no longer unconditionally clamped for floating attachments. MIN/MAX
still ignore blend factors, and final storage quantization remains separate.

This follows OpenGL4.6 section17.3.6's attachment-dependent rules
(https://registry.khronos.org/OpenGL/specs/gl/glspec46.core.pdf). No shader
regeneration, build or tests ran. Out-of-range float alpha, signed factors,
subtract/reverse-subtract and normalized saturation are deferred test cases.

### Ordered fixed-function texture stages (source only)

The engine now captures enabled 2D texture units 0 through 3 as an ordered
chain. A disabled lower unit does not suppress higher units. Each environment
is 44 words: the previous 24-word environment layout, with word3 now the next
stage pointer (zero terminates), then width/height/sampler/unit at24..27 and
its texture matrix at28..43. Descriptors are cached with their successor.

The `.cu` rasterizer samples all enabled units before applying their environment
operations in order. Combiner source codes0..3 are current texture, original
primary color, constant and previous stage; codes4..7 explicitly select texture
units0..3, including later units. A reference to a disabled unit is rejected.
This follows the cross-unit model in the Khronos texture environment crossbar
specification (https://registry.khronos.org/OpenGL/extensions/ARB/ARB_texture_env_crossbar.txt).

Texture coordinates use the original transported UV sets. Each stage applies
its own matrix in `.cu`, retains homogeneous Q through interpolation, and uses
quotient-rule derivatives for mip selection. Ordinary point primitives now
have a separate material identity: units whose point-sprite coordinates replace
the originals use the identity matrix, while lines and polygons preserve their
texture matrices. The host validates stage order, chain bounds, referenced
units, matrices, independent samplers and complete mip ranges.

This supersedes the single-stage24-word environment ABI. Fixture migration,
shader generation, compilation and tests remain deferred. Texture units beyond
the four transported UV sets, TexGen and general current texture-coordinate
state are still unfinished, as is the overall renderer replacement. No new
runtime or performance result is claimed.

### Homogeneous texture-coordinate transport (source only)

The vertex attribute ABI now has34 floats instead of26. Existing view-space,
basis and S/T fields retain their offsets; slots26..33 hold four R/Q pairs.
Geometry submission accepts one-, two-, three- and four-component float/double
texture-coordinate arrays. Missing components default to (0,0,0,1), and disabled
arrays use those defaults. Conversion to the GPU float packet stays in the host;
texture transformation, interpolation and sampling remain in `.cu`.

The fixed-function sampler multiplies the complete S/T/R/Q vector by each
stage's4x4 texture matrix and divides by the interpolated transformed Q.
Clipping and ordinary point/line interpolation carry every component. Generated
particles, ribbons, GUI and the optional default host attribute packet initialize
Q to1; point-sprite replacement restores R=0,Q=1. Skinning and world-material
attribute indexing use the expanded stride without changing their field offsets.

Shader artifacts, binaries and26-float fixtures are stale. Their migration and
all builds/tests remain deferred until implementation is complete. TexGen and
inherited current texture-coordinate state are still outstanding; this change
provides the full coordinate transport those paths need.

### GPU texture-coordinate generation (source only)

`texgen.cu` now owns fixed-function object-linear, sphere-map, normal-map and
reflection-map coordinate generation. The geometry packet carries four20-word
descriptors per draw: enabled component mask, generation mode, normal flags,
reserved zero, then four plane equations. They share the draw matrix identity.
The browser bridge copies this packet and the pipeline validates and dispatches
it after deformation/particle projection, before clipping and point-sprite
replacement. Programmable materials leave these descriptors disabled.

Object-linear coordinates use the deformed model-space position. Normal-map
coordinates use the inverse-transpose normal with the captured normalize/rescale
state; reflection/sphere calculations use a normalized normal and eye vector.
Generated components replace only enabled coordinates; remaining S/T/R/Q values
survive. Matrix multiplication and projective sampling remain in material.cu.
The normal-map state distinction follows the Khronos extension specification:
https://registry.khronos.org/OpenGL/extensions/ARB/ARB_texture_cube_map.txt .

Eye-linear generation is still explicitly unsupported: its planes need the
matrix at state application, including positioned attributes, rather than an
assumed current draw matrix. Inherited generation modes for coordinates outside
a sphere/normal/reflection attribute's defined components also need state
capture. Cubemap sampling remains separate unfinished work. This source pass
registered the kernel for later generation but ran no generation/build/tests.

### Eye-linear plane application capture (source only)

Submission now carries a per-stage texture-plane application tracker through
sorted leaves and custom-bin replay. It imports inherited and local positioned
TexGen attributes in the same order as OSG's RenderStage. Their application
matrices include the inherited positional post-matrix. Resolved attribute
identity changes capture the leaf model-view; an unchanged attribute preserves
its earlier application matrix, matching OSG's attribute caching behavior.
The positioned attributes also enter the resolved state as global defaults.

TexGen descriptors now have36 words (144 per draw): the previous20 words plus
the captured application matrix at20..35. Mode5 selects eye-linear generation.
The `.cu` kernel solves applicationModelView * position = currentEyePosition
with pivoted elimination, then evaluates the original plane equations. No host
plane inversion or texture-coordinate evaluation is introduced. Singular
application matrices produce deterministic zero coordinates for that undefined
case. The host validates the expanded descriptor and all matrix values.

This supersedes the20-word generation ABI and the explicit eye-linear rejection
above. Default/inherited per-coordinate modes, cross-stage global-state lifetime,
custom-drawable state transitions and precise render-bin stack ordering still
need implementation/audit. Generation, compilation, fixtures and gameplay tests
remain deferred; these changes do not establish renderer completion.

### Sorted-bin replay coverage (source only)

Normal submission, subtree replay and local-bin replay now share the same
local-leaf traversal. Each consumes both fine-grained RenderLeafList and coarse
StateGraphList leaves in OSG's draw order. Previously local-bin replay consumed
only RenderLeafList, so state-sorted bins could disappear from a replay pass.
Replay acceptance now runs before texture-plane application capture, preserving
cached plane state when a leaf is filtered out without being submitted.

Source inspection of RenderBin::drawImplementation, RenderLeaf::render and
StateGraph::numToPop supports the existing ordinary ordering of bin state before
geometry ancestry: the last leaf state is applied directly and the ancestor
stack is excluded from the bin insertion position. Boundary cases and custom
callbacks remain part of the deferred state-ordering tests. No build or runtime
test ran for these changes.

### Legacy clamp and minification crossover (source only)

Sampler bits30/31 now represent legacy GL_CLAMP independently for S/T. Their
ordinary two-bit wrap fields remain zero. Host validation accepts the full
unsigned32-bit sampler and rejects conflicting wrap encodings. The engine
allocates the same format-aware border descriptor used for clamp-to-border.
In .cu, legacy clamp first bounds the coordinate to [0,1]; nearest filtering
uses edge texels while linear filtering allows border taps. Both color and
shadow comparison sampling apply this rule. Shadow coordinates now also use
bounded wrap reduction before conversion to integer texel indices.

The mip sampler now uses the specified0.5 LOD magnification crossover when a
linear magnification filter is paired with nearest-mipmap-nearest or
nearest-mipmap-linear minification; other pairings retain a zero crossover.
Reference: OpenGL1.4 sections3.8.8-3.8.9,
https://registry.khronos.org/OpenGL/specs/gl/glspec14.pdf .
No generation, builds or tests ran. Edge/corner border weighting, negative and
large coordinates, independent-axis wrap and crossover boundaries remain in
the deferred sampling test scope.

### Texture LOD state (source only)

The sampler indirection record now occupies9 words: the previous image-base,
RGBA border and format fields, followed by minimum LOD, maximum LOD and bias as
float bits. Records are created for nondefault LOD state even when wrap modes
do not need a border. Their cache key includes all sampling state while shared
image storage stays independent. Host validation checks the complete record,
finite LOD values and ordered bounds.

`sample_mipped` in .cu adds bias (the replacement's supported bias range is
[-16,16]), clamps to the configured LOD interval, then chooses magnification or
minification and the mip levels. OSG's initial minLOD=0/maxLOD=-1 means that no
range is applied; that sentinel maps to the GL default interval[-1000,1000].
The engine rejects non-finite LOD state before transport.

This supersedes6-word indirection records. Comparison-sampler LOD behavior,
anisotropic filtering and other sampler state remain unfinished. Fixtures,
shader generation, builds and all tests are still deferred.

### Derivative-driven anisotropic sampling (source only)

Sampler indirection records now occupy10 words, adding maximum anisotropy at9.
The engine captures finite values >=1 and the host validates the expanded
record. The .cu implementation caps supported anisotropy at16. Values of1
retain the previous isotropic mip selection and sampling path.

`sample_gradient` derives the footprint axes from the eigensystem of J*J^T,
selects a bounded tap count and minor-axis mip scale, then integrates samples
along the long texture-space axis. Every tap uses the existing wrap, swizzle,
border, LOD-range and mip-filter implementation. It is connected to fixed
texture stages, ordinary textured materials, object/terrain layers (including
parallax derivatives), environment textures, sky textures/masks and shadow
caster alpha sampling. Explicit-LOD effects remain on sample_mipped.

The filtering formulation is an implementation choice permitted by
https://registry.khronos.org/OpenGL/extensions/EXT/EXT_texture_filter_anisotropic.txt .
This does not claim parity with a particular driver's filtering algorithm.
Comparison-sampler anisotropy remains unfinished.10-word fixture migration,
generation/builds, oblique/rotated texture checks and GPU cost measurements are
still deferred; no quality, gameplay or performance validation ran.

### Comparison-sampler filtering (source only)

Shadow cascade sampling now separates per-level comparison filtering from LOD
selection and anisotropic integration. The rasterizer derives projected shadow
S/T derivatives, including the interpolated normal offset and homogeneous
coordinate division. These feed .cu footprint selection. Sampler bias, LOD
limits, min/mag crossover, nearest/linear mip selection and anisotropic taps
now apply to comparisons. Every depth texel is compared before spatial or
mip-level results are blended.

Host validation checks the full declared single-word depth mip range and
rejects a conflicting four-word color stride. Current rendered depth textures
still allocate only their base level, so their advertised last level remains0;
this change does not synthesize a depth mip chain. Depth format-specific
reference-range behavior and explicit comparison modes outside the shadow
material family still need attention. No generation, builds or tests ran;
derivative, cascade-transition, filtering and performance checks are deferred.

### Depth comparison ranges (source only)

Shadow descriptor flag8 now identifies DEPTH_COMPONENT32F and
DEPTH32F_STENCIL8. The .cu comparison path preserves floating-point reference,
texel and border values for these formats; normalized depth still clamps both
comparison operands to[0,1]. Float-depth border descriptors also carry the
floating red-component format, so ordinary depth sampling no longer applies
an unconditional normalized border clamp. Host shadow flags accept the new bit.

This matches the fixed-versus-floating comparison distinction in section3.8.15
of https://registry.khronos.org/OpenGL/specs/es/3.0/es_spec_3.0.withchanges.pdf .
Out-of-range references/borders and all comparison functions remain deferred
numerical tests. No generation, build or test ran; the full renderer remains
unfinished.

### Rendered depth mip chains (source only)

Depth render-texture references now allocate a complete mip chain when their
minification filter requests mipmaps. A depthMipSources packet maps each copied
base offset to its16/24/float32 storage precision. It is copied through the
browser bridge and validated against actual depth attachment copies, so depth
words cannot fall through to packed-color mip generation.

`generate_depth_mip` in material.cu reduces source texels over each destination
footprint, including odd dimensions, and stores the result using the declared
depth precision. Host dispatch propagates that precision to successive levels.
Non-mip depth filters retain their base-only allocation. Comparison sampling
can now consume the advertised generated chain. The reduction filter is a box
filter, not a conservative minimum/maximum hierarchy.

This supersedes the base-only limitation noted above. Kernel generation,
transport/mip fixtures, full engine build and runtime verification remain
pending. No build or test ran during this implementation pass.

### Shared render-texture atlas resources (source only)

MaterialTable now caches render-texture atlas resources by attachment identity,
dimensions, storage format and mip requirement. Materials with different raster
or sampler state can reuse the same attachment copy and .cu-generated mip
chain. An existing full chain also serves later base-only samplers. A base-only
resource followed by a mipmapped request allocates a separate complete chain
because intervening atlas records may prevent in-place extension.

Color and depth render textures now generate mip levels only when the min
filter requires them. Sampler/border/environment descriptors remain independent
of image storage. Reused tables at nested-pass boundaries still submit their
copy/generation records again, refreshing attachment contents for that submitted
pass; this is not a cross-frame stale-image cache.

These changes remove duplicate copy/mip work from the source dispatch plan.
GPU savings and frame pacing are not measured. Cache identity, resize, mixed
samplers, nested boundaries and actual gameplay remain deferred tests, along
with shader generation and the full engine build.

### Expanded geometry array transport (source only)

Ordinary geometry now accepts Vec2/Vec3/Vec4 positions in float or double
arrays. Missing Z defaults to0 and missing W to1; authored W is retained for
the existing .cu model-view/projection/clipping path. CPU submission only
converts array storage to the GPU float packet. Position count checks for
indices, morph offsets and screen primitives now use the generic array size.
Skin snapshots retain their existing Vec3 source contract.

Primary colors now also accept RGB float/double/unsigned-byte arrays (default
alpha1) and RGBA double arrays, alongside the existing RGBA float/byte paths.
Normals accept Vec3 double as well as float. Existing binding and finite-value
checks remain. Integer/packed formats beyond these layouts and inherited
current-attribute state still require work. No generation/build/tests ran.

### Indexed primitive restart (source only)

Geometry submission now splits indexed draws at enabled primitive-restart
indices. Fixed-index restart takes precedence and uses the unsigned index
storage width; explicit restart uses the resolved PrimitiveRestartIndex value
(default0). Restart markers are removed before geometry bounds checks and
triangulation. Each resulting strip/fan/loop starts independently, resetting
strip winding and provoking-vertex selection; line loops close within their
own segment. Non-indexed draws retain their normal subrange behavior.

Point/line and polygon paths now share subrange enumeration for DrawArrayLengths,
MultiDrawArrays and restart segments. Smooth restarted polygons use the same
explicit topology conversion as flat polygons, with flat-color metadata emitted
only when flat shading is requested. Actual transforms, clipping and raster
arithmetic remain in .cu. Restart/empty-segment/topology fixtures and all builds
and tests remain deferred.

### Primitive dispatch and per-set attributes (source only)

The restart-aware range enumerator is now actually called by both point/line
and polygon submission. The earlier restart section described the intended
behavior, but both call sites still used their old subrange loops. Restart
markers now reach the shared splitter before topology conversion.

Colors, normals and explicit fog coordinates with BIND_PER_PRIMITIVE_SET now
select the source attribute by primitive-set index. Such geometry emits a
separate source packet for each set, allowing shared position indices to carry
different per-set attributes. Skin/morph inputs remain attached to each packet;
transforms, deformation and rasterization remain in .cu. This duplicates source
vertices for these draws and has not been measured for performance.

OSG Geometry/VertexArrayState bind texture-coordinate arrays per vertex without
consulting their Binding flag. The generic vector reader now matches that
behavior, including arrays tagged BIND_OFF; tangent unit 7 already used that
path. Position-array validation remains separate. No first-vertex provoking
StateAttribute exists in this OSG checkout, so no such state was invented.

Shader generation, builds, updated fixtures and runtime tests remain deferred
until the implementation pass is complete. The installed engine is still the
original WebGL build; this source checkpoint is not a playable release.

### World vertex lighting (source only)

Object and terrain variants without normal maps, specular maps or forcePPL now
select feature bit 8388608. Water and terrain composite materials retain their
separate paths. The new vertex-lighting.cu computes each original triangle
corner's shaded diffuse, shaded specular, unshadowed diffuse and unshadowed
specular values. Material color modes, sun/point lighting, attenuation, emission,
shininess and specular strength follow the legacy world shader inputs. Diffuse
lighting is clamped at the vertex, before interpolation, as in the source GLSL.

A second .cu kernel interpolates these four RGB varyings using polygon clipping
weights. The rasterizer interpolates the clipped varyings and mixes their lit
and shaded values by the shadow result, bypassing its per-pixel light loop for
these variants. Original vertex and attribute packet layouts remain 10/34.
The transient clipped-attribute buffer gains a separate 12-float lighting plane
before raster parameters when a pass contains a vertex-lit material. Raster
uniform lighting_offset identifies that plane; raster_offset moves after it.

For expanded points/lines, transform_attributes initializes GPU origin records
and expand_screen_primitives stores original endpoint indices and clipping
weights. Lighting evaluates those endpoints and interpolates their results,
rather than relighting line intersections. These records are allocated only
for passes combining vertex lighting with screen primitives. Triangle-owned
lighting results avoid shared-vertex material races, at the cost of repeated
work for shared vertices; performance remains unmeasured.

Both new kernels are registered with the shader generator and runtime. Generated
artifacts, updated kernel-signature fixtures, builds, comparisons against the
source lighting equations and gameplay/frame-pacing validation are still
pending. No shader generation, build or test ran during this source pass.

### Cluster construction and light culling (source only, consumer integration pending)

cluster-lighting.cu now contains build_light_clusters and cull_cluster_lights,
ported from the engine's core/lighting compute shaders. Construction uses raw
perspective XY scales and logarithmic near/far slices to form view-space AABBs;
reverse-Z depth coefficients do not change the reconstructed symmetric camera.
Culling consumes the engine's 20-float PointLight layout and performs sphere/
AABB intersection in .cu. Each cluster owns a fixed list segment, retaining
source light order without atomic list allocation.

MaterialPipeline.prepareClusterLights validates/uploads a light snapshot,
dispatches both kernels and returns the GPU grid, list and light buffers.
Per-cluster overflow reports the full required capacity. The host reads these
counts and, if necessary, grows the list and redispatches before returning it.
The public grid count never exceeds allocated capacity. Device buffer limits,
32-bit offsets, finite perspective matrices and nonnegative radii are checked.
Camera/snapshot resource keys keep concurrently needed lists distinct within a
serialized pass. Resource retirement uses the existing pipeline lifecycle.

These kernels and preparation routine are implemented and registered, but the
engine's clustered SSBO snapshots and material consumers are not yet connected
to this routine. The material translator still rejects clustered variants;
this entry does not claim clustered gameplay support. The next integration
must transport camera/light snapshots, consume the generated grid in vertex,
fragment and water lighting, implement clusterFar fading and intercept the
original DispatchCompute drawables without running GL compute jobs. Shader
generation, builds and all tests remain deferred as requested.

### Clustered snapshot transport (source only, activation still gated)

MaterialTable can now capture the resolved ShaderStorageBufferBinding at index2
as the engine's typed PointLight vector, honoring its byte offset and size.
It serializes the four vec4 fields plus attenuation/radius into 20-float records,
validates finite data and camera uniforms, and deduplicates complete snapshots
by content, including projection, grid, depth range and screen size. This avoids
reusing a stale camera or mutated light buffer based only on pointer identity.

The browser bridge now transports clusterRecords, clusterMaterials,
clusterLights and clusterProjections. A cluster record has ten uint words:
first light, light count, grid XYZ, near/far float bits, projection index, screen
width/height float bits. Each projection has16 floats. Material mappings are
pairs of material ID and snapshot ID; object feature bit16777216 identifies
clustered lighting, with legacy light count0. No old material header offsets
change. The host prepareClusterSnapshots routine validates ranges/mappings,
prepares each referenced snapshot once and returns material-to-resource entries.

The existing clustered-feature rejection intentionally remains ahead of material
capture until .cu vertex/fragment/water consumers and DispatchCompute replacement
are connected. prepareClusterSnapshots is ready for that render-pass call site
but is not called by render yet. These are transport/integration source changes,
not a claim of working clustered gameplay. No generation, build or tests ran.

### Clustered lighting consumers connected (source only)

The render pass now calls snapshot preparation and uploads a GPU cluster atlas.
The original texture/material atlas prefix is unchanged. A material-indexed
pointer table at uniform cluster_offset addresses twelve-word descriptors:
grid XYZ, near/far float bits, screen WH float bits, light count, grid/list/light
atlas offsets and per-cluster capacity. Generated grids and lists are copied
GPU-to-GPU; pack_cluster_lights converts the engine's20-float record into the
common16-word light layout in .cu. Snapshot sharing remains intact in the atlas.

cluster-lighting.cuh provides cell lookup, list access and clusterFar fading.
Both vertex and per-pixel object/terrain lighting consume the generated lists,
apply radius fade for clustered lighting regardless of classicFalloff, and apply
the far-plane fade. Vertex lighting clamps projected screen coordinates and
honors simple/disabled particle point lighting via feature bit33554432. Invalid
out-of-grid lookups return an empty list instead of accessing undefined memory.
Water now adds the clustered point specular term with shininess50 and brightness
1.5 using its perturbed specular normal transformed to view space.

Submission recognizes only the built-in cluster.comp/cull.comp compute programs
and skips their GL draw callbacks because the pass's .cu jobs replace them.
Unknown compute drawables still fail explicitly. LightManager accepts requested
WebCuda as a clustered backend independently of GL SSBO support. The clustered
material rejection has been removed; alpha-to-coverage remains gated. This
supersedes the previous cluster activation/consumer-pending notes.

The source path is connected but not compiled or verified. Outstanding checks
include shader compiler support, bridge/kernel signature fixtures, perspective
and reverse-Z grids, light overflow/growth, multiple camera snapshots, viewport
coordinates, vertex and water comparisons, full engine build and gameplay.
No shader generation, build or test ran during this implementation pass.

### Fixed-function lighting state capture (source only, shading pending)

Submission's positional-state tracker now records the eight compatibility lights
as well as TexGen. Positioned light attributes retain their application matrices,
including inherited positional-state post-matrices; changed leaf light attributes
capture the current model-view matrix. DrawContext borrows these matrices during
synchronous packet construction. No CPU light-position or lighting calculation
was added.

GeometryPacket and the browser bridge now carry fixedLighting, with368 uint words
per draw aligned to matrixIds. Word0 is the enabled-light mask; word1 contains
lighting-enabled128, two-sided1, local-viewer2, separate-specular4, normalize8 and
rescale-normal16. Word2 uses the existing color-material mode numbering0..5.
Word3 is reserved; words4..7 hold global ambient float bits. Front/back materials
at8 and25 each contain ambient/diffuse/specular/emission RGBA plus shininess
(17words). Words42..47 are reserved. Eight40-word light records begin at48:
position/ambient/diffuse/specular vec4, spot direction xyz, attenuation constant/
linear/quadratic, spot exponent/cutoff, then the16-word application matrix.

Inputs are copied as float bits. Absent light attributes use GL initial light
values rather than osg::Light's different authoring defaults. MyGUI explicitly
emits disabled lighting and TexGen descriptors. The host validates descriptor
counts, modes, finite values, shininess and spotlight/attenuation ranges.

The .cu lighting evaluation, two-face varying transport, separate-specular
composition and flat-shading integration are the next steps. This captures the
necessary state but does not yet make fixed-function lighting render correctly.
Cross-stage inherited current-state behavior still needs final parity review.
No shader generation, builds or tests ran during this source implementation pass.

### Fixed-function lighting kernels connected (source only)

fixed-lighting.cu now evaluates compatibility lighting from the captured368-word
descriptors. It transforms vertex and light positions, applies inverse-transpose
normal transformation with normalize/rescale modes, supports local/infinite
viewers, front/back materials, color-material selection, directional/positional
lights, attenuation and spotlights. Spotlight direction follows the application
matrix's upper3x3 as specified in OpenGL2.1 section2.14.2. Initial ambient and
emission, diffuse alpha, shininess0 and separate-specular colors are handled.
Reference: https://registry.khronos.org/OpenGL/specs/gl/glspec21.pdf

Each vertex produces16 transient floats: front primary RGBA, secondary RGB and
enabled marker, followed by the corresponding back-face values. Lighting runs
after deformation/particle expansion and before clipping. Screen primitives
interpolate endpoint lighting, apply point fade to lit alpha, and use front-face
lighting for both sides of their generated quad. A marker preserves this rule
when flat-shaded lines choose their original provoking vertex.

assemble_fixed_lighting interpolates smooth varyings with clipping weights or
copies the original provoking vertex for flat shading. The rasterizer selects
the front/back primary color before texture environments and adds separate
specular afterward, before fog. A fixed-lighting plane follows the world-lighting
plane in the transient attribute buffer; fixed_offset/fixed_enabled identify it.
Original geometry attributes remain34 floats. Both new kernels are registered.

Geometry without an enabled color array now takes an explicit osg::Material's
current-color initialization. RGB color arrays still supply alpha1. Inherited
current attributes across draws/stages and generated ribbon lighting need final
parity review; this is not a claim of exhaustive fixed-function parity.

No shader generation, build or tests ran. Kernel/signature fixture migration,
spot/attenuation/two-sided/normal/flat/specular comparisons, full engine build,
gameplay and pacing verification remain deferred until implementation completes.

### Generated ribbon and particle fixed lighting (source only)

assemble_ribbon now writes provoking indices to the shared GPU flat-color table.
Flat quad strips select the final particle's top vertex for both triangles;
smooth strips retain the sentinel. The host uploads this table once, before
ribbon generation, so later material/fixed-light assembly no longer overwrites
GPU-generated provoking metadata with the CPU placeholder table.

shade_fixed_vertices evaluates both endpoints for generated line modes6/7.
The particle projection kernel interpolates their lighting with the line's
clipping parameter; flat thin ribbons use the original final endpoint's result.
Generated points and lines use front lighting for both sides of the expanded
quad. Point-size fade also modifies lit diffuse alpha. Original geometry/ribbon
packet widths remain unchanged; mode7 uses input attribute24 for its flat flag.

The temporary endpoint buffer is allocated only for fixed-lit passes containing
ribbons or line particles. It stores two16-float lighting records per source
vertex in those passes. Kernels remain within eight storage-buffer bindings.
This completes the source connection for generated fixed-light geometry; world
Gouraud lighting on projected particle lines still needs the same endpoint
parity review. Inherited current-state behavior also remains outstanding.

No shader generation, build or tests ran. Updated ribbon/particle kernel fixtures,
flat and clipped endpoint comparisons and full gameplay validation are deferred.

### Projected particle world vertex lighting (source only)

project_particles now optionally writes a24-float GPU-only record per vertex
behind the transformed attribute plane. The record contains a point/line tag,
clipping fraction, both original view-space endpoint positions, original clip
XYW coordinates and endpoint RGBA colors. Ordinary vertices receive a zero tag.
The record is captured before point expansion or endpoint-color interpolation.

shade_vertex_lighting consumes these records for projected particles. It evaluates
original line endpoints and blends their already-clamped lighting by the clip
fraction, instead of relighting the clipped position. Cluster lookup also uses
the original endpoint clip coordinates. Projected points use their original
center for both lighting and cluster selection. Existing ordinary point/line
origin metadata remains the path for non-particle screen primitives.

The host allocates this tail only for passes with world vertex lighting and
potential projected particles or ribbons. No CPU packet width changes and no
additional storage-buffer binding are needed. Shader uniforms now include
track_world_particles/world_particle_offset. Generation/build/signature fixtures
and particle/cluster/clip comparisons remain deferred; no tests ran.

### Current normal and fog retention (source only)

SubmissionSink now retains current normal/fog inputs across stage and frame
boundaries. Sorted ordinary geometry submissions update these values from OSG's
OVERALL and PER_PRIMITIVE_SET dispatches, using the final dispatched set for the
latter. Values from per-vertex array draws are not inferred: those corresponding
GL current values are unspecified, so the backend retains its last explicitly
dispatched values. Float/double supported array types and finite values are
checked at the dispatch boundary.

DrawContext snapshots the retained values. Geometry without an enabled normal
array uses the current normal; explicit fog without a fog-coordinate array uses
the current fog coordinate. Particle normals inherit the same current normal.
All transforms, fog calculations and lighting remain in .cu. Current color,
secondary color, custom-drawable side effects and remaining state lifetime parity
still need implementation/review. No generation, build or tests ran.


### Current color retention and particle normal side effects (source only)

Submission now retains RGBA current color across sorted draws and render stages.
A material identity change initializes color; reusing that material leaves any
subsequent OVERALL/PER_PRIMITIVE_SET color intact. Material references are retained
to keep cached identity valid. After the first material application, leaving its
state stack restores OSG's default material color. Before any material applies,
the initial current color remains white. Current-color initialization follows the
configured OSG profile: fixed-function builds use the material color mode, while
the GLES build uses its diffuse constant, matching Material::apply.

Ordinary color dispatch supports RGB/RGBA float, double and unsigned-byte arrays,
including the implicit alpha of one for RGB. Packet construction uses the captured
current color whenever the color array is absent or disabled. Direct packet callers
without captured state retain the material fallback. NIF particle submission also
retains its explicit OVERALL normal (0.3,0.3,0.3), including empty systems, matching
the custom drawable's dispatch before the base particle early return.

This is input-state transport; rendering arithmetic remains in .cu. Per-vertex
array draws do not supply a defined post-draw current color. Secondary color,
color-material parameter persistence, other custom state effects and broader
renderer gaps remain. No generation, builds or tests ran in this source pass.


### Secondary color input and color sum (source only)

Geometry packets now transport RGB secondary color separately (three float values
per vertex). Float, double and unsigned-byte Vec3 arrays support OVERALL,
PER_PRIMITIVE_SET and PER_VERTEX bindings; absent/disabled arrays use the retained
current secondary color, initially black. Submission retains explicitly dispatched
secondary colors, including source arrays used by skin snapshots. Per-set packet
splitting includes secondary color. Generated particle inputs inherit the retained
value through descriptor slots42..44; generated ordinary screen primitives receive
interpolated values through the existing fixed-color output path.

Descriptor flag32 captures GL_COLOR_SUM. shade_fixed_vertices now takes an eighth
storage binding, secondary_colors. For unlit color-sum draws it outputs the primary
RGBA and secondary RGB for both faces, including projected line endpoint records.
Existing clipping/provoking-vertex assembly, point fading, line expansion and
post-texture/pre-fog color addition then handle these values entirely in .cu.
Lighting-enabled draws continue to use their calculated specular secondary color.
Shader-backed materials do not enable the compatibility color-sum path.

Pipeline validation accepts flags through191 and validates the secondary-color
stream; its fixed-color allocation/dispatch gate accepts lighting128 or colorSum32.
The WASM bridge carries the new stream. These source changes have not been generated,
compiled or tested. Kernel fixtures need the added secondary_colors binding during
the deferred validation pass. Reference: OpenGL2.0 specification section3.9,
https://registry.khronos.org/OpenGL/specs/gl/glspec20.pdf.


### Primary color renderbuffers (source only)

Viewer camera submission now registers single-sample primary color renderbuffers,
including camera-owned implicit attachments. Weak owner plus attachment component
identifies persistent storage; owner expiration retires the browser allocation.
A format change gets a new identity and retires the old allocation at a safe frame
boundary. Explicit renderbuffer dimensions use the existing attachment extent
resolution. The attachment's color format controls floating-color material state,
CUDA raster storage conversion, clears and postprocess destination conversion.

This reuses the same .cu attachment clear/raster/postprocess kernels as texture
color targets. Renderbuffers are not exposed as sampleable textures. Camera image
attachments now fail explicitly instead of being mistaken for renderbuffers;
image readback still needs implementation. Multisample counts are captured from
both FBO renderbuffers and camera attachments and explicitly rejected pending
sample storage/resolve, including configurations without a resolve FBO pointer.
Normal renderbuffers, other MRT layouts and multisampling remain incomplete.
No generation, build or tests ran; color-format/lifetime/camera checks are deferred.


### Main-game trace: groundcover deformation and transport (source only)

The main shader router has no groundcover.vert/frag translation, and ordinary
geometry rejects instancing. This is an exterior-scene blocker when groundcover
is enabled. Work on this path now precedes further compatibility edge cases.

Groundcover.cu ports instance rotation/scale/offset, four wind harmonics, player
stomping (three intensities and optional height sensitivity), and instance distance
rejection. It returns deformed positions to model space on GPU for reuse by the
shared lighting/shadow/clip stages; normals and authored tangents rotate on GPU.
An instance beyond fadeEnd collapses to one point, matching the reference shader's
degenerate primitive behavior. The affine inverse calculation stays in .cu.

The packet/bridge/pipeline now carry ranges3 (vertex,instance,parameter block),
instances7 (offset xyz,scale,rotation xyz) and parameters40 (inverseView16,view16,
wind,time,player xyz,stomp mode,intensity,fadeEnd). The host validates layouts,
finite values, unique destination vertices and settings, then dispatches the
kernel before ordinary transforms. The shared kernel manifest includes this entry.

This is not yet an enabled groundcover path. Capture/expansion of instanced geometry,
material routing, groundcover-specific lighting and per-fragment fade remain to
connect. The existing rejection remains until those parts exist. No generation,
compilation or tests ran. Singular/zero-scale camera transforms need explicit
coverage in the later validation pass.


### Groundcover instance capture (source only)

appendGeometry now recognizes groundcover vertex programs and emits source inputs
per primitive set and instance. Attributes6/7 must be Vec4 offsets/scales and Vec3
rotations, with divisor one. Shared wind/player uniforms and numeric groundcover
shader defines populate the parameter stream; DrawContext now carries the frame's
simulation time. The packet duplicates original inputs, not transformed vertices.
The instancing rejection is bypassed only for this explicit groundcover path.

Parameter slots0..15 now contain the view matrix to invert, rather than an inverse
computed on CPU; slots16..31 contain the forward view. groundcover.cu performs the
affine camera inverse as well as the model-view inverse. This supersedes the earlier
parameter description. Source capture currently prioritizes correctness over
instance-buffer residency; shared geometry expansion is a later performance step.

Material routing, groundcover lighting and fragment fade are still pending, so
normal game submission continues to reject this shader before geometry capture.
No shader generation, engine build or tests ran. Later validation must cover
instance counts, shader define metadata, transformed cameras and missing inputs.


### Groundcover material route (source only)

The exact groundcover.vert/groundcover.frag pair now routes to the shared world
material encoder with feature67108864. Unrelated object texture/effect features
are excluded to match the source shader. Groundcover ignores mesh material color,
emission and specular: white diffuse/ambient and zero specular/emission make the
existing light sums represent raw illumination. It ignores forcePPL, selecting
vertex lighting without a normal map and fragment lighting with one.

Both .cu lighting paths implement groundcover's view-dependent two-sided Lambert
response from lib/light/util.glsl. Fade bounds occupy otherwise-unused bump slots
320/321; interpolated vertex Euclidean depth drives smoothstep alpha fading before
the alpha test. Fog uses that same interpolated depth and the source shader's
linear-depth convention. Groundcover can write the normal attachment independently
of the object FORCE_OPAQUE define. The router now reaches the instanced source
capture and deformation path added in the preceding pass.

This removes the generic unsupported-material rejection for this exact shader pair,
not the remaining alpha-to-coverage/multisample rejection. No generation/build/tests
ran. Shader variant fidelity, normal-map basis, shadows, instance deformation,
visible grass, GPU memory costs and gameplay performance remain unverified.


### Multisample storage/resolve foundation (source only)

multisample.cu introduces seed_multisample and resolve_multisample. Each sample is
a full existing 10-word-per-pixel attachment plane (RGBA,depth,normal RGBA,stencil),
with planes laid out contiguously. Seed copies a single-sample attachment into all
planes for explicit initialization/copy operations; it must not replace persistent
sample contents on every draw or frame. Resolve averages color/normal values in
the target's linear representation and quantizes destination storage in .cu.
Depth/stencil resolve selects the explicitly requested sample rather than averaging.
Resolve masks allow independent color/depth/stencil updates.

MaterialPipeline now exposes validated seed/resolve dispatch methods for 1/2/4/8/16
samples, with bounds, aliasing and storage-binding limits checked. Both kernels
are in the shared build/runtime manifest. These methods are not yet called by the
game host: persistent sample allocations, raster coverage/sample positions,
alpha-to-coverage, shared depth/stencil planes and engine resolve-FBO identity
mapping still need connection. Existing multisample rejection remains in place.
No generation, build or tests ran. The main-game source trace also found the old
Emscripten postprocessor's forced single-sample setting; that must change only when
the replacement multisample path is complete.


### Per-sample CUDA raster path (source only)

raster_material now flattens pixel/sample invocations. Each sample addresses its
own 10-word-per-pixel target plane, including stencil accesses through apply_stencil.
Coverage and interpolation use authored sample positions: center for1, diagonal2,
rotated4, distributed8, and regular4x4 for16. Triangles and ordered tile lists remain
shared. Depth comparison, stencil updates, blending, logic operations and color/
normal writes all address the selected sample plane. Shading is currently evaluated
per sample, which favors correctness over shader reuse/performance.

clear_attachment clears every sample plane while respecting the existing clear
mask/rectangle behavior. Both kernels gain sample_count. Pipeline passes default
to one sample; multisample callers must provide persistent pass.sampleTarget plus
pass.sampleCount. The pipeline validates capacity, dispatches sample clears/raster,
then resolves to the single-sample target used for sampling/presentation. It does
not automatically seed or overwrite sample history. Occlusion counters count
passing samples, as their underlying query semantics require.

The game host and engine attachment/resolve mapping are not connected yet, so this
path is not enabled for gameplay. Alpha-to-coverage/sample masks and sample-aware
shared attachment transfers remain pending. Existing rejection guards remain.
No generation, build or tests ran. Fixtures need the added sample_count uniform.


### Persistent multisample host attachments (source only)

The game host now allocates and retains sampleBuffer/sampleCount alongside each
resolved attachment. A new or sample-count-changed allocation is seeded once; later
passes retain sample history. Resizing, owner retirement and host disposal release
both buffers. Allocation checks cover sample counts, u32 indexing and device buffer
limits. Raster passes now pass sampleTarget to MaterialPipeline.

Shared depth, normals and stencil transfers copy both resolved storage and matching
sample planes through copy_multisample_plane. Depth isolation saves/restores all
sample depths and clears them through clear_multisample_depth. Both new .cu kernels
are registered in the shared manifest. A resolved depth capture explicitly uses
single-sample destination storage. Postprocess output into a multisample destination
still rejects pending sample-aware output, and ripple simulation remains a
single-sample computation. These guards avoid leaving stale sample planes.

Engine sample-count transport and resolve-FBO mapping remain pending, so ordinary
game passes still arrive as single-sample. Alpha-to-coverage/masks and multisample
postprocess output also remain. No shader generation, builds or tests ran.


### Raster alpha-to-coverage / alpha-to-one state (source only)

Raster material flag65536 now captures GL_SAMPLE_ALPHA_TO_COVERAGE and flag131072
captures GL_SAMPLE_ALPHA_TO_ONE. After the fragment alpha test and before sample
depth/stencil updates, the CUDA rasterizer converts alpha to a deterministic,
monotonic sample mask. The sample ranking rotates by pixel; alpha0 covers no samples
and alpha1 covers all. Alpha-to-one occurs after coverage selection and before
blending/storage. Single-sample passes keep the previous behavior. Host material
validation accepts the added flags.

This implements the raster state, not OpenMW's shader alpha remapping. The source
alphaTest function uses fwidth(alpha) to remap alpha near the threshold; its object
and shadow alphaToCoverage feature guards remain until that shader behavior is
ported. Explicit sample-coverage/sample-mask controls and query-path interactions
also need integration. No shader generation, builds or tests ran.


### Camera sample-count transport and postprocess sample writes (source only)

Viewer now transports sampleCount through the pass-state bridge. Window passes use
sample-buffer traits; attachment passes use captured attachment sample counts.
Supported counts are1/2/4/8/16. Mixed counts and differing coverage/color sample
counts reject explicitly. The blanket sample-count rejection is removed for the
already-supported attachment kinds; the separate explicit resolve-FBO guard remains.
The game host can now select persistent multisample storage from engine pass data.

Fullscreen postprocess output into a multisample destination now broadcasts its
pixel-shaded color into each covered sample through broadcast_multisample_color.
It respects the integer viewport and preserves each sample's depth, stencil and
normals. The previous postprocess multisample-destination rejection is removed.
This is a .cu operation, not a WebGL blit or JavaScript pixel calculation.

Explicit resolve-FBO destination registration/mapping, shader fwidth alpha remapping,
explicit sample masks/coverage and the old forced-single-sample postprocessor policy
still need work. These changes remain ungenerated, unbuilt and untested; no gameplay
multisample or smoothness result is claimed.


### Explicit resolve FBO attachment mapping (source only)

Viewer registers base-level, single-sample Texture2D destinations from an explicit
RenderStage resolve FBO and records their plane mappings. Primary color, depth,
packed depth/stencil and the existing normal attachment are recognized. Dimensions,
source plane presence, identity kind and feedback are checked before submission.
EndPass emits ordered resolve commands after submitting the source pass.

The browser host creates independent destination storage and dispatches the new
copy_resolved_attachment .cu kernel. It copies from the source's resolved composite,
converts destination color/depth storage and respects the camera viewport. Later
material texture reads use the registered destination identities. No OpenGL blit
or JavaScript pixel math is used. Other resolve attachment layouts still reject.

This removes the blanket explicit-resolve-FBO rejection for these destination
layouts. The old Emscripten postprocessor sample policy and its normal attachment
setup still need integration, along with shader alpha remapping and sample masks.
No shader generation, build or tests ran; actual FBO ordering/visibility remains
unverified until the deferred engine/browser validation pass.


### Postprocessor multisample policy and normal renderbuffers (source only)

The Emscripten postprocessor now uses configured mSamples when WebCuda is requested;
the original WebGL path retains its forced single-sample workaround. WebCuda sample
settings validate supported counts instead of using a GL_MAX_SAMPLES query to cap
the compute backend. Existing multisample primary/first-person/normal renderbuffer
construction can therefore reach the new submission path.

Viewer now registers RGB/RGBA UNORM8 normal renderbuffers with normal-plane IDs.
Other normal storage formats still reject pending matching normal-plane storage.
Scene color-target recognition includes the current source's color resolve texture,
so transparent-depth capture/replay callbacks continue to recognize the scene while
its color is rendered into a multisample renderbuffer. Nested targets do not inherit
that recognition: it is restricted to the recorded resolve source identity.

Alpha-to-coverage shader remapping remains guarded, along with remaining coverage
controls and unsupported layouts. No generation, compilation or tests ran. This
source connection is not evidence that configured multisample gameplay works yet.


### Object/groundcover shader alpha remapping (source only)

World material feature134217728 captures the shader alphaToCoverage define. The
CUDA rasterizer evaluates pre-alphaTest inputs at a2x2 screen-pixel group to obtain
finite alpha differences. object_alpha includes material/vertex alpha, diffuse and
dark/blend layers, parallax offsets, coverage-preserving LOD scaling and groundcover
distance fade. Alpha is remapped around the clamped reference using the derivative
width, with LESS/LEQUAL inverted and GREATER/GEQUAL direct. Other comparisons keep
the source shader's regular discard behavior. The redundant fixed alpha comparison
is disabled for this shader-remapped material.

This removes the object/groundcover alphaToCoverage feature rejection. Raster
coverage remains controlled by the captured sample alpha-to-coverage state. Shadow
shader remapping is still guarded and must be ported separately. Derivative parity,
quad helper extrapolation, texture LOD behavior and resulting edge coverage remain
unverified; no generation, compilation or tests ran.

### Explicit sample coverage (implementation only)

Raster records now contain 26 floats per material: the previous 24 slots followed by sample coverage and inversion. C++ captures the resolved OSG Multisample attribute when GL_SAMPLE_COVERAGE is enabled, and material deduplication includes both fields. CUDA selects a monotonic per-pixel sample set and complements it for inversion before depth, stencil and query processing. This combines with alpha coverage through sample rejection. No additional GPU binding is required. Pipeline defaults and validation use the new stride. Fixtures and generated shaders still require the deferred migration/build/validation pass. Explicit sample masks and multisample-disable semantics remain pending.

Shadow alpha remapping is also connected in source, including the shader's additional translucent-shadow cutoff. Neither addition has been generated, built or runtime-tested.

### Sample masks and multisample enable (implementation only)

Raster records now contain 28 floats, superseding the previous 26-word record. Slot 26 carries the low 16 sample-mask bits as an exact numeric float; supported targets contain at most 16 samples. Slot 27 carries the resolved multisample enable state, defaulting to enabled when OSG returns INHERIT. CUDA intersects enabled sample masks with coverage and uses pixel-center geometry/interpolation for explicitly disabled multisampling, preserving separate stored sample depth/stencil values. Coverage, alpha-to-coverage and alpha-to-one are gated by multisample enable. Material keys, copies, host defaults and validation use the new stride. Generated shaders and fixtures remain pending; no build or runtime verification was performed.

Reference: https://registry.khronos.org/OpenGL/specs/gl/glspec31.pdf (multisample rasterization and fragment multisample operations).

### Sun-query shared fragment tests (implementation only)

The sunflash query retains its texture-alpha discard threshold of 0.8, then defines opaque white fragment output. The compatibility shader previously returned with undefined output; it now defines the same value. CUDA query counting now occurs after the shared alpha, alpha-coverage, stencil and depth tests, instead of bypassing the alpha controls. Query samples still do not write color, normals or depth. Visible and total queries both count samples, so the existing visible/total ratio needs no pixel normalization. Source inspection only; generation, compilation and runtime verification remain deferred.

### Debug and outline shader routes (implementation only)

`debug.cu::shade_debug_vertices` implements debug vertex scaling/translation and the debug lighting expression, as well as vertex/material diffuse selection and outline uniform color. The advanced debug light expression is linear in the interpolated normal with a constant color (or a constant normal in normal-as-color mode), allowing its arithmetic to be evaluated before interpolation. No CPU transform/shading is introduced. Each draw captures a 16-float parameter block aligned with its matrix ID; browser transport, validation, dispatch and the shared kernel manifest include it. Material routing recognizes paired debug and outline programs and uses their CUDA-produced untextured colors. Existing skin/morph deformation precedes this kernel; projection and screen primitive expansion follow it.

Custom debug drawable submission still requires review. Generated WGSL, fixtures, compilation and visual/runtime validation remain deferred; the new routes are source implementation only.

### Custom debug drawable submission (implementation only)

DebugCustomDraw now implements WebCuda::CustomDrawable. It submits line geometry and each cube/cylinder/sphere/wire-cube with captured translation, color, scale and normal-as-color uniform overrides. The replacement viewer invokes this handler instead of the drawable's GL implementation. The existing per-frame queues are cleared after all synchronous captures succeed. Source mesh data remains unchanged; debug.cu owns instance transforms and shading. Empty line queues produce no geometry submission. Build and visual validation remain deferred.

### Drawable callback capture and water depth clamp (implementation only)

Submission now requires an explicit CustomDrawCallback capture handler instead of silently ignoring drawable callbacks. Water's DepthClampCallback captures GL_DEPTH_CLAMP without invoking GL; the clustered-light storage-barrier callback acknowledges ordered WebGPU dispatch, rejecting unrepresented barrier types. The material flags carry depth clamp to clip_triangles and raster_material. CUDA skips near/far homogeneous clipping for these draws and clamps window depth to the sorted depth-range endpoints after polygon offset. Other clipping remains active. clip_triangles has a new materials binding; diagnostic callers and fixtures require migration during the deferred validation pass. Screenshot readback and stats callbacks remain without handlers and now fail explicitly. Terrain composite-map submission also remains to audit/connect. No build or runtime tests run.

### Terrain composite-map submission (implementation only)

CompositeMapRenderer now implements CustomDrawable. It processes immediate maps first, budgets background CPU capture using the existing frame-time policy, opens nested color targets, and submits each composite layer geometry with its own state. The existing terrain-composite CUDA material route performs shading; no FBO application or GL drawable invocation occurs in this handler. Captures run outside the queue mutex using unique_lock, failed captures are requeued, and source drawables are released only after successful target submission. Unreferenced maps are skipped consistently with the original path. GPU completion is asynchronous; source queue completion indicates capture, not verified GPU success. Build, fixtures, visual validation and performance measurements remain deferred.

### Ordered image readback foundation (implementation only)

readback.cu captures a centered aspect crop, bilinearly resizes it, and packs opaque RGBA8 in bottom-up image order. Module.webcudaCaptureImage queues a capture at a flushed pass boundary and returns a promise. The host dispatches and reads that command before processing later passes, so GUI rendering cannot overwrite the selected image. Allocation sizes are validated; aborted/failed frames reject pending captures. Readback uses the runtime's supported Uint32Array API and exposes a byte view. This host foundation is not yet connected to ScreenshotManager: its blocking GL condition-variable contract and save-thumbnail callers still need asynchronous engine integration. Current full-frame target capture does not yet expose subviewport/stereo selection. No generation/build/tests performed.

### Engine asynchronous image request bridge (implementation only)

Viewer::captureImage queues a camera-specific request and records the ordered host capture after that camera's final submitted pass. Completed host promises are polled on later rendering traversals, before frame acceptance. A tightly packed RGB osg::Image is allocated only when pixels are ready; byte copying occurs synchronously with current HEAPU8, so no WASM pointer survives an asynchronous operation. Completion callbacks run after request-map iteration. Expired cameras and failed readbacks report errors. ScreenshotManager::screenshotAsync selects the HUD camera for scene-only thumbnails, retaining a synchronous fallback for other viewers. Save-thumbnail and F12 callers are not yet migrated; the old synchronous API is still present. Viewport/stereo selection, cancellation during shutdown and callback reentrancy need completion before validation. No build/tests performed.

### F12 WebCuda screenshot consumer (implementation only)

ActionManager now routes screenshot requests on a WebCuda viewer to final-screen asynchronous capture, after all camera passes including GUI. The result is handed to the existing ScreenCaptureHandler CaptureOperation, retaining the configured file writer and notifications without installing a GL readback callback. The operation is retained independently of ActionManager until completion, and writer failures are logged. Null-camera image requests explicitly mean final screen; expired camera-specific requests remain errors. Save-thumbnail migration and lifecycle/viewport handling remain pending. No generated shaders, builds or runtime tests were run.

### Deferred save-thumbnail consumer (implementation only)

World and RenderingManager now forward screenshotAsync to ScreenshotManager. WebCuda save requests retain a shared pending record with description and character/slot paths, request a scene thumbnail, and return to the event loop. The weak completion callback only stores image/error; StateManager::update resolves paths again and invokes existing serialization with the captured image. It does not resume saving inside rendering. Cleanup cancels the pending record; changed/missing destinations or failed capture cancel the save with a message. Duplicate save requests are rejected while capture is pending. A subsequent quit waits for the pending save to complete or fail. Native/other viewers keep their existing synchronous save path. Host-terminal and request-cancellation lifecycle handling still needs completion to guarantee no indefinitely pending request. No compilation or runtime tests run.

### Image request terminal handling (implementation only)

The host tracks outstanding image promises independently of recorded frames, rejecting them on failure/device loss/disposal. The WASM bridge uses entry identity checks so a canceled request cannot be resurrected by a late GPU completion. Viewer polling cancels requests on host failure, expired camera, or a 30-second deadline; viewer destruction drops bridge results and notifies callbacks. StateManager separately times out pending thumbnails from its update path, allowing a queued quit to proceed even when rendering stops advancing. Cancellation releases completion state; it does not forcibly interrupt GPU commands already submitted. Failure injection and lifecycle runtime tests remain deferred.

### Viewport-aware image capture (implementation only)

Camera-bound image requests snapshot the selected pass viewport; final-screen requests select the complete screen attachment. capture_image receives the signed viewport origin and positive dimensions, performs the GL bottom-origin to attachment top-origin conversion in CUDA, then applies aspect crop and resize within that region. Reads outside the actual attachment return black without out-of-bounds memory access. Host validation limits coordinate/dimension ranges before dispatch. Stereo eye/layer selection is not supplied by this change and remains part of the broader stereo/multiview work. Generated kernel signatures/fixtures and offset viewport visual tests remain deferred.

### Resource stats refresh before submission (implementation only)

Resource stats text now uses Drawable::UpdateCallback rather than a GL DrawCallback. It reads the preceding frame's stats and updates osgText content before culling, without calling drawImplementation. The first frame no longer underflows the unsigned frame index. This removes the stats callback dependency for both renderers; it does not yet implement osgText glyph submission. Source inspection found glyph primitives and coordinates exposed by osgText, with texture coordinates available through its attribute functor; the text transform, atlas/material and backdrop paths still require capture/CUDA integration. No build or tests performed.

### Drawable local-placement stream for text (implementation only)

DrawContext can carry a borrowed local placement matrix; GeometryPacket captures it as a per-draw 17-float enabled/matrix record aligned with matrix IDs. Browser transport and validation preserve that record. local-transform.cu applies the raw matrix to homogeneous positions before the shared projection path, avoiding CPU glyph vertex transforms. Disabled records cost no dispatch when the whole packet has no local placement. This stream is intended for unlit glyph positions; it does not transform lighting normals. osgText glyph/atlas material submission is still pending, along with screen-facing/screen-sized text behavior. No shader generation/build/tests performed.

### Ordinary osgText glyph submission (implementation only)

Submission recognizes osgText::Text and sends it to the viewer's explicit text handler. For solid, object-coordinate, non-billboard text without backdrops/decorations, the handler copies glyph coordinates/UVs/primitive groups and CPU atlas pixels, and captures the cached layout placement matrix into the CUDA local-transform stream. The cached matrix is populated by OSG's computePositions layout path. A dedicated glyph material flag preserves RGB text color while multiplying alpha by the atlas alpha/red coverage channel in material.cu. Shader-generated text programs do not execute in GL. Distance-field atlases, gradients, backdrops, decorations and camera-dependent sizing/orientation remain explicit unsupported cases. This connects the ordinary glyph path but is ungenerated, unbuilt and untested.

### Distance-field glyph coverage (implementation only)

Glyph materials now distinguish greyscale coverage from distance fields, supporting RG and luminance-alpha distance atlases. Raster records expand to 30 floats: slots 28/29 carry GLYPH_DIMENSION and TEXTURE_DIMENSION from the text state's shader defines. CUDA implements the source OSG shader's footprint-based 2x2 to 4x4 sample grid, edge-distance conversion, whole-pixel rejection/acceptance, smooth transition and alpha-weighted accumulation for text without backdrops. Zero-coverage glyph fragments are discarded. Material copies/keys, transport validation and raster strides are updated. Reference: deps/src/osg/src/osgText/shaders/osgText_Text_frag.cpp. Backdrops/gradients/camera-dependent placement remain pending. All generated artifacts and fixtures still require the deferred build/validation pass.

### Per-character text gradients (implementation only)

The glyph capture path now accepts PER_CHARACTER gradients and supplies the authored top-left, bottom-left, bottom-right and top-right colors in OSG's documented vertex order. These are copied color inputs, not CPU-interpolated output; the existing CUDA clipping/raster path interpolates them and glyph coverage applies to the resulting alpha. Solid-color behavior remains available. OVERALL gradients still require their coordinate-bounds/bilinear computation in CUDA. Backdrops and decorations remain explicit gaps. No build/tests run.

### Whole-text gradients (implementation only)

OVERALL text gradients now capture only four authored corner colors and disjoint source-vertex ranges. text-gradient.cu reduces local coordinate bounds and computes bilinear RGBA colors before local placement/projection. It preserves OSG's FLT_MAX/FLT_MIN bounds initialization; degenerate dimensions use a finite zero interpolation coordinate. Each atlas submission retains the complete text coordinate set, matching OSG's whole-text bounds rather than bounds of only the glyphs in that atlas. Host validation checks color data, range bounds and non-overlap. The kernel uses one invocation per glyph group with sequential bounds/color loops; performance remains unmeasured. No generation, build or tests performed.

### Text decoration source integration

OSG text bounding-box fills, outlines and alignment marks now capture the original decoration primitive topology through a reproducible OSG header patch. Decorations precede glyphs, use the OSG fill/line colors, and support decoration-only draw modes. Line expansion suppresses polygon culling and fill offset. Zero-alpha text returns before submission. This is source implementation only: generation, compilation and runtime validation remain deferred until implementation is complete. Text backdrops and camera-dependent placement remain pending.

### Text shadow source integration

All eight OSG text drop-shadow directions now capture their offset/color and use CUDA glyph coverage sampling and shadow/glyph alpha-power compositing. Grayscale and distance-field paths share the existing coverage logic. Raster records are now 37 floats (the previous 30 plus seven backdrop words), with matching material keys and runtime validation. OSG shadow compositing uses backdrop RGB and does not multiply coverage by backdrop alpha. Outline and camera-dependent text remain pending. No shader generation, build or tests have run for this change.

### Text outline source integration

Backdrop mode 2 now selects CUDA outlines using the existing 37-float raster record. Grayscale coverage uses the GLES OSG 3x3 maximum-coverage formula; SDF outlines use glyph/outline transitions and weighted RGBA accumulation. The SDF accumulation now carries RGB sums as well as squared alpha, following OSG for partially transparent samples. Camera-dependent text placement remains pending. This source change has not been generated, built or tested.

### Camera-dependent text source integration

Text billboard rotation, screen-coordinate sizing and font-height screen caps now have a CUDA placement path. C++ captures the OSG layout offset, quaternion, position, sizing mode and viewport; local-transform.cu inverts the translation-free model-view and computes projection-dependent size and placement. The local-transform record is now 35 floats, and the kernel binds the existing camera matrix buffer. The reproducible OSG header patch exposes read-only layout inputs. Singular model-view inversion uses identity as a finite fallback; parity for this degenerate case remains unverified. This implementation is per vertex and its performance is unmeasured. Generation, builds and tests remain deferred.

### Loading-screen background source integration

The WebCuda loading screen now requests a registered texture snapshot of the previous resolved screen before the next accepted frame traverses its cameras. snapshot.cu performs the GPU copy (nearest resize on changed extent), and the existing render-texture resolver supplies that texture to GUI materials. No framebuffer readback or GL copy runs on this path. If no previous screen exists, the kernel writes opaque black. Requests survive a busy host or aborted submission and are cleared after accepted submission. Source only: generation, compilation and runtime checks remain deferred.

### Global-map camera readback source integration

Primary RGB/RGBA byte image attachments now request asynchronous CUDA readback. readback.cu preserves all four channels; existing RGB screenshot consumers still receive RGB. The global-map overlay keeps its texture attached while requesting CPU pixels, and its update callback waits for explicit capture completion before copying exploration data. A failed capture is surfaced instead of accepting an empty image. Current capture state is one-shot per camera; abort/retry, reusable attachments, save synchronization and GPU map-base generation remain audit work. No generation, build or runtime test has run.

### Capture retry and map-save readiness

The viewer records capture request IDs per accepted frame. Aborting that frame cancels the associated JS result entries and resets those requests for retry, without resetting their original timeout. Deferred WebCuda saves now require both the thumbnail result and an empty global-map pending-copy queue. A shared 30-second deadline cancels the deferred save if capture work cannot finish, rather than writing stale map pixels. Source review only; no tests or builds have run. CPU global-map base/alpha generation and reusable image attachments remain pending.

### Global-map CUDA generation

The WebCuda CreateMapWorkItem now captures raw 9x9 WNAM samples per land cell and decoded palette inputs, skipping CPU per-pixel map painting and its RGB/alpha allocations. MapTexture carries those inputs to material encoding; texture preparation dispatches map.cu to generate packed base-color or land-alpha texels. Decode record kinds 256/257 represent these generation jobs. Renderer selection is captured at work-item construction, not queried from the worker thread. Native rendering retains its original path. Generation is currently repeated when captured by a material table; caching/residency and numerical/visual fidelity remain unverified. No generation, build or tests have run.

### Map generation input reuse

Material tables now share a single captured land/palette block between map color and alpha jobs and reuse each generated image within the table. Shared ownership keeps source identity valid during capture. MapTexture clones preserve their procedural inputs. Dimension consistency, finite palette values and byte-range land indices are checked before dispatch. This is per-table reuse, not persistent cross-frame residency. No build, generation or tests have run.

### Reusable camera capture lifecycle

Camera-image requests now retain a destination/format/viewport ticket. Weak completion references prevent replaced tickets from publishing stale pixels, while callbacks also check current attachment identity and viewport bounds. Normal image cameras can request a new capture after completion; global-map updates explicitly opt into one-shot behavior. Failed captures permit an explicit status reset for retry. Dead/detached camera tickets are retired. This remains asynchronous and has not been compiled or runtime-tested. Render-stage FBO image handling still needs review.

### Map-camera completion scheduling

WebCuda local/global map cameras request a pass-completion signal. The viewer records them with the submitted frame and acknowledges them only when the host accepts a subsequent frame after successful GPU idle. Busy or aborted submissions do not acknowledge completion, and failed hosts do not accept new frames. Local-map RTT nodes now retire after their tracked cameras complete; global-map cameras also wait before retirement, including updates without CPU readback. Native scheduling is unchanged. Source-only implementation; no build or runtime test has run.

### Render-stage FBO and camera image separation

Camera image-readback requests are now collected independently from active render-stage FBO attachments. An FBO override controls GPU storage but no longer suppresses the camera image request. Image-only color storage uses the image internal format (RGBA8 if unspecified). Multiple image destinations are rejected explicitly; direct RenderStage-only image requests remain outside this implementation. Source review only; no generation, build or tests have run.

### Fog-map display integration

FogTexture captures saved mask pixels and exploration brush history; texture preparation kind 258 dispatches generate_fog_map to produce the displayed alpha mask. Repeated texture references reuse a revision within the material table, and host validation checks brush finiteness and positive radii. Loading saved fog resets the procedural baseline. The CPU fog-image loop remains temporarily for exploration queries and PNG save consumers; moving those consumers and compacting brush history are still required. This is an intermediate source implementation, not completion. No generation, build or tests have run.

### Fog gameplay queries and save-copy isolation

WebCuda isPositionExplored now evaluates only the requested texel from the saved mask and brush history, independently of the CPU-painted image. Exact repeated brushes are deduplicated across history because the minimum-alpha operation is idempotent. PNG serialization flips an isolated copy, avoiding mutation of the live mask and retaining orientation on writer failure. CPU full-image painting remains for saving/cell unload until synchronized GPU readback is connected. Distinct brush accumulation is still unbounded in ordinary sessions. No generation, build or tests have run.

### Standalone fog readback service

FogTexture can now capture owned mask/brush words. Viewer::captureFogImage submits those inputs to a standalone host job, which runs generate_fog_map into dedicated GPU buffers and returns packed RGBA using the existing timeout/completion polling path. The job retains copied input data independently of camera and segment lifetime; host disposal waits for outstanding jobs. Cell-unload and cell-store save ownership still need integration, so the CPU fog-image update loop remains active. No generation, build or tests have run.

### Cell-owned pending fog snapshots

ESM fog textures can now retain a shared transient PendingFogImage containing immutable raw snapshot inputs and the eventual PNG result. It survives map-segment deletion without retaining a CellStore pointer. FTEX still writes ordinary PNG bytes; incomplete, failed or empty results are rejected. FogTexture can reconstruct its saved mask and brushes from retained inputs, allowing a future cell-reload path to restore exploration without waiting for PNG readback. Snapshot producer, reload selection and save-readiness wiring remain pending; the CPU painter is still active. No generation, build or tests have run.

### Fog save/unload integration

LocalMap now receives its viewer and requests owned fog snapshots for cell records. GPU completion encodes PNG bytes into shared transient state, with errors retained for serialization. Revisited cells restore raw saved-mask/brush inputs without waiting for PNG completion. Deferred save readiness requests active-segment snapshots and waits for still-owned unloaded-cell jobs. WebCuda updatePlayer now skips the CPU full-image fog painter; gameplay point queries use inputs and saving uses GPU readback. Native painting remains on the native path. Save scheduling while moving, brush-history cost, failures, unload/reload and serialized compatibility have not been validated. No generation, build or tests have run.

### GPU fog-history compaction

Successful fog snapshots now replace the live baseline with GPU-produced pixels only when its previous baseline and captured brush prefix still match exactly. Only that prefix is removed; brushes added during readback remain. Background jobs start at 256 brushes and avoid duplicate pending background requests for one texture. Obsolete/reset results still belong to their cell/save snapshot but cannot overwrite current texture inputs. PNG encoding uses a separate copy to preserve readback orientation. This reduces accumulated history after successful jobs; it is not a hard bound during a stalled GPU. Deferred saves under continuous movement still need scheduling review. No generation, build or tests have run.

### Stable world during deferred save capture

StateManager exposes whether a render capture is pending. During that interval the engine disables gameplay controls and holds world, mechanics, physics, local/global scripts, Lua updates and simulation clocks. GUI updates, scene traversal, rendering and capture completion polling continue. This lets fog snapshots settle instead of chasing player movement. The hold derives from the pending request lifetime, so completion, cancellation and cleanup release it. This source change requires runtime verification of camera/GUI behavior, Lua scheduling, timeout and save/load; no generation, build or tests have run.

### Bethesda unlit material route

bs/nolighting vertex/fragment pairs now route to the CUDA object material with an explicit unlit feature bit. Fragment RGB uses diffuse texture times diffuse color without lighting; inherited lighting/maps absent from that shader are disabled. Existing shared alpha/fog/soft-particle/normal paths are reused but remain unverified for this family. Enabled useFalloff is explicitly rejected until its independently interpolated vertex varying is implemented. bs/default remains pending. No generation, build or tests have run.

### Unlit falloff integration

Authored unlit-falloff.cu evaluates the vertex falloff before clipping and reconstructs its varying using clipping weights. Raster alpha uses perspective interpolation of that value. The material packet stores its enable and four parameters in words 80-84, the dark-map descriptor disabled by this family; this avoids existing bump-matrix and shadow-cascade fields. Host validation rejects nonfinite parameters, invalid enable values and descriptor conflicts. This supersedes the earlier falloff rejection note. Shader-specific depth/fog/normal parity and bs/default remain pending. No generation, build or tests have run.

### Unlit alpha and fog ordering

Source review corrected falloff placement: final diffuse/coverage alpha is multiplied before alphaTest, including helper-lane alpha used for coverage derivatives. Unlit materials skip the point/sun lighting loop. Fog selects the interpolated vertex distance and shader linear-depth route used by bs/nolighting, rather than recomputing radial distance from interpolated position. Normal/soft-particle semantics still need review. No generation, build or tests have run.

### Unlit fragment normal transport

Unlit varying records now use four floats: falloff plus the raw normal transformed by inverse transpose. Both survive clipping and perspective interpolation; fragment normalization happens afterward for normal output and soft-particle fading. Falloff separately normalizes the source normal before its angle calculation. The host allocation and raster/helper offsets follow the four-float stride. The soft-particle formula matches the original shader for regular finite inputs in source review; expanded primitives, singular transforms and runtime parity remain unverified. No generation, build or tests have run.

### Bethesda default material route

bs/default shader pairs now use an explicit CUDA per-pixel material feature. Capture keeps diffuse, normal and emissive maps, disables absent material features and records useTreeAnim for alpha. CUDA multiplies material emission by the emissive texture before lighting, scales specular color by normal-map alpha, retains diffuse texture alpha for tree materials, and uses Bethesda normal/depth/fog varyings. Distortion remains the shared explicit distortion path; unlit no longer activates distortion from inherited state. Host checks reject conflicting Bethesda flags/layers. Source inspection identified pending point/line expansion transport: generated vertices currently have zero source placeholders, so these varyings must be evaluated from original endpoints. No generation, build or tests have run.

### Bethesda point/line endpoint transport

prepare_bethesda_vertices now computes source vertex view angles and raw view normals. shade_unlit_falloff evaluates material falloff at each original endpoint before interpolating with the screen-expansion origin weights. Original triangles use their own vertices. Origin tracking activates for both vertex-lit and Bethesda materials, and triangle clipping then transports the resulting four-float varyings. This avoids reading the generated screen vertices' zero source placeholders and keeps kernel bindings within the baseline eight-storage-buffer limit. The kernel manifest and host dispatch are updated. Particle-generated inputs still need review; generation, build and tests remain deferred.

### Bethesda projected-particle falloff

Bethesda materials now enable the existing projected-particle endpoint capture. Preparation reads both original view positions and the clipping fraction, recording six floats per source vertex (angle0, raw normal XYZ, angle1, fraction). Material falloff is evaluated at both original endpoints before interpolation, including stretched particles and ribbons. Billboard/fixed expansion runs before preparation; ordinary triangles and screen-primitive origin transport retain their paths. Host allocation and kernel uniforms match the new endpoint layout. Projected-particle depth interpolation remains under review. No generation, build or tests have run.

### Projected-particle radial depth

For stretched and ribbon particles, project_particles now interpolates original endpoint Euclidean distances through line clipping. Sphere-map coordinates separately normalize the actual clipped position, preserving their position-dependent direction. This matches the distinct vertex-depth and sphere-map calculations rather than sharing one distance for both. Source only; no generation, build or tests. Camera attachment producer review is next, including RTT mip-generation requests and helper-forwarded levels/faces.

### Bounded buffer growth

Pipeline allocations of at least 4 KiB now reserve up to 25 percent spare capacity, capped at 4 MiB headroom and the device storage/buffer limits, with 256-byte rounding. Small buffers stay exact. Upload sizes are checked against the requested logical size; kernel and readback lengths remain explicit. A replacement is allocated before retiring the previous buffer. This addresses repeated exact-size reallocations as geometry/tile counts vary; memory overhead and performance are unmeasured. Tile sizing/cluster overflow readbacks and frame-boundary GPU idle still remain. No generation, build or tests have run.

### Small-pass tile sizing without a submission wait

For passes whose conservative tile reference bound (tiles + 1 + clipped triangle slots times tiles) fits one million words and the device limit, candidate storage is allocated from that bound. GPU counting/prefix remains authoritative, but its status readback is joined to frame completion instead of awaited before scatter/raster. Larger passes retain exact compact allocation. Failed prefix status zeroes offsets and suppresses scatter; readback errors propagate through the frame completion result. Binning now binds the summary buffer, so generated kernels/fixtures must be refreshed during validation. This removes a submission wait for qualifying passes, not the readback itself. No build, tests or pacing measurements have run.

### Cluster overflow readback bound

prepareClusterLights now skips overflow readback when its capacity is at least the snapshot light count. cull_cluster_lights visits each source light once per cluster, so that allocation cannot overflow. This covers initial snapshots of at most 64 lights and retries reaching full count without increasing memory use. Atlas copies remain ordered after culling on the GPU queue. Partial-capacity lists retain overflow readback, validation and retry before consumption. Generation, builds, tests and performance measurements remain pending.

### Deferred validation precedes presentation

The game host and standalone pipeline now check deferred tile/status results before acquiring and copying to the canvas texture. Failed preparation cannot publish a partially rendered frame. Standalone deferred failures drain queued work before returning; the game host retains its failure drain. The final successful GPU wait remains necessary for retirement and camera pass-completion acknowledgment. Presentation buffer replacement now allocates before retiring its predecessor. These are source changes only; builds, tests and pacing measurements remain pending.

### Frame timing observations

The returned game host exposes timingSnapshot(), a copied chronological window of the last 240 successfully completed frames, and stats.lastFrame. Records contain packetCaptureMs, dispatchPhaseMs (including any in-phase GPU readback waits), validationWaitMs, completionWaitMs, frameWallMs, presentationSubmitAt, presentationSubmitIntervalMs, skippedSincePrevious and skippedTotal. Offscreen frames have null presentation fields. These are performance.now wall-clock observations; submission intervals do not prove compositor delivery or monitor scanout. The legacy stats.gpuFrameMs remains an alias of frameWallMs for compatibility, not a GPU timestamp measurement. No browser measurements, generation, builds or tests have run.

### Material current-color profile semantics

Retained submission capture and direct packet fallback now match the vendored OSG Material::apply profile branches. GL1 fixed-function builds select the relevant material color mode; non-fixed/emulated builds use diffuse; fixed-function builds without GL1 leave current color unchanged. The previous capture selected color modes for every fixed-function build. This source correction does not complete broader color-material parameter persistence. No generation, build or tests have run.

### Local-map reconstruction producer

Each rendered local-map segment now retains raw camera placement, up-vector and depth bounds. restoreRenderTargets removes obsolete RTT nodes and creates fresh completion-tracked cameras targeting the same texture objects used by GUI widgets. It leaves exploration textures, brush inputs and fog snapshots untouched and avoids loading cell fog again. The method is a reconstruction producer only: device-generation invalidation and the recovery trigger are not wired yet. Global overlay restoration remains pending. No generation, build or tests have run.

### Global-map reconstruction producer

GlobalMap retains raw overlay update recipes while their cameras are active. restoreRenderTargets snapshots the completed CPU overlay, recreates a baseline camera into the existing overlay texture without applying the land mask again, and recreates active update cameras in submission order with fresh readback destinations. Local-map source texture identities survive reconstruction. Retired recipes are removed and baseline recovery cameras do not become recipes themselves. Device-loss wiring remains pending, as do generation, build and tests.

### Engine device-generation invalidation

Each successful WebCuda host installation increments Module.webcudaDeviceGeneration. WindowManager checks it before its frame update; a replacement invalidates viewer target residency, resets queued camera completion and image tickets, cancels old captures, re-registers pending loading snapshots, and reconstructs local maps before global-map overlays. The initial generation does not trigger reconstruction. Automatic host replacement and already-completed loading-snapshot recovery are still pending. In-flight save/recovery behavior and all compilation/runtime paths remain unverified.

### Device-loss host replacement

Device loss now attempts host replacement after disposal. Submission stays gated until WindowManager invalidates viewer state and schedules local/global map reconstruction. A repeated loss before a successful GPU frame exhausts the attempt; ordinary shader/validation failures still report fatal errors. Renderer selection stays sticky across host downtime so resource producers do not select native paths. Live loading snapshot textures are retained weakly and recreated via the CUDA snapshot path; without a prior screen on the new device their pixels clear rather than preserving lost framebuffer contents. Transient host histories start fresh. Loading loops, save cancellation and asynchronous callback ordering still require audit and runtime validation. No generation, build or tests have run.

### Recovery during loading and fog capture

WindowManager now exposes restoreRenderTargetsIfNeeded for both normal update and LoadingScreen traversal before viewer update/cull. LocalMap reconstruction resubmits failed or unfinished retained fog snapshots after Viewer cancels old-device requests. Resubmission keeps the same shared snapshot identity and immutable mask/brush inputs, so unloaded CellStore records receive the replacement PNG; active matching textures can compact on success. Successful snapshots are left alone. Existing in-flight saves may still cancel on device loss, and save/reload/failure behavior remains unverified. No generation, build or tests have run.

### Opaque raster address transport

Raster word 23 contains fog atlas address bits, not a floating-point parameter. The browser bridge now snapshots raster records through HEAPU32 and reinterprets the owned buffer as Float32Array. Host finiteness validation excludes that word; enabled fog still validates its integer descriptor bounds and numeric descriptor contents. CUDA reads the word with __float_as_uint. Source inspection only; generation, build and tests remain deferred.

### Explicit particle fog coordinates

Particle capture now retains the current explicit fog coordinate in word 8 of a nine-word fog descriptor, with flag 16 requiring the existing explicit-coordinate flag 8. This avoids colliding with particle expansion attributes. The material cache includes the coordinate, the host validates descriptor length and finiteness, and material.cu selects this constant before computing fog attenuation. Existing geometry fog continues to interpolate its vertex coordinate. This removes the particle-specific rejection in source only; generation, compilation and visual validation remain pending.

### Empty program state

OSG Program::apply disables the active program when its shader list is empty. resolveState now removes an effective empty Program from its private merged snapshot, after OVERRIDE/PROTECTED inheritance has been resolved. Existing CUDA compatibility capture therefore handles lighting, explicit fog, TexGen and flat colors consistently with the material route. Original StateSets are unchanged, and unknown nonempty programs remain explicit errors. Source review only; compilation and runtime validation remain pending.

### Front-face state without culling

Raster capture now transports FrontFace winding whether or not CULL_FACE is enabled. material.cu already uses this bit to classify triangles independently of its cull test, so front/back stencil and two-sided lighting can receive the correct face on uncullled draws. The packet layout is unchanged. Source inspection only; generated shaders, engine compilation and runtime validation remain pending.

### Indexed blend enable and normal output

Raster capture now reads effective Enablei/Disablei(GL_BLEND) attributes separately for attachments 0 and 1, falling back to the global blend mode. Bit 26 of raster control enables normal-attachment blending; the host accepts the extended control range. material.cu uses the normal attachment destination and alpha with the captured shared blend factors/equations, preserving its channel mask and logic-op precedence. Normal output retains the renderer's existing alpha value of one. Independent indexed blend factors/equations and undefined GLSL normal alpha behavior are not newly implemented. No generation, compilation or runtime checks have run.

### Camera-pass bridge sample count

Corrected the EM_JS signatures: the camera-pass declaration now accepts the sampleCount already supplied by its C++ caller and consumed by JavaScript. Removed the unused sampleCount parameter from the luminance declaration, whose caller does not supply it. Both mismatches would block the Emscripten build. The stage clear path was also compared with OSG: viewport scissor and color masks are transported, while OSG explicitly enables depth/stencil writes for clears. Compilation and runtime validation remain pending.

### Normal attachment channel contract

Camera passes now carry normalFormat for RGB/RGB8 or RGBA/RGBA8 attachments. CUDA clear, raster and multisample resolve receive normal_channels; missing alpha stores/reads as one, including masked normal writes. Destination-alpha blending also uses one for primary color formats without an alpha channel. Normal texture formats outside this implemented range now produce an explicit capture error, matching the renderbuffer restriction. Generated kernel bindings and fixtures must be updated during the deferred generation/test phase. No build or runtime validation has run.

### Missing channels with write masks

CUDA clear and fragment storage apply write masks only to channels physically present in the color format. Missing components retain their format-defined representation (zero RGB, one alpha) rather than preserving arbitrary shared-buffer values. Blend and logic destination reads use those defaults as well. Resolved attachment copies already call destination-format conversion. Source inspection only; no generation, build or tests.

### Wider normal attachment formats

The previous RGB8/RGBA8 normal restriction is superseded: normal targets now share the color-storage format table, including R/RG, half/full float, UNORM16 and SNORM. CUDA clear, raster blending and multisample resolve receive normal storage precision. Wide normal identities carry both plane and float-atlas flags, and float_normals_to_texture preserves the normal plane in four-word atlas storage. Host metadata selects matching precision during mip generation. Signed-normalized logic operations still reject explicitly. The new kernel is registered for deferred generation; all format behavior remains unbuilt and untested.

### Disposal failure isolation

Host disposal collects failures while still attempting every remaining GPU resource release, context unconfiguration, canvas removal and device destruction. It reports an AggregateError after cleanup attempts. Concurrent disposal callers share the cleanup promise; explicit disposal cancels automatic recovery. This strengthens teardown before host replacement but does not establish recovery correctness. Source review only, with runtime/device-loss validation deferred.

### Host installation ownership

A per-module WeakMap token reserves the host before asynchronous device creation and remains held until disposal settles. Creation failures release their token; identity checks prevent stale cleanup from releasing another owner. Public installs also reject while automatic recovery is pending, and only the private recovery path can install in the gap after old-host teardown. Runtime concurrency and device-loss tests remain deferred.

### Attachment replacement ordering

Camera targets, attachment planes and depth captures now share allocation/initialization through planeStorage. It allocates and queues clear/sample initialization before retiring the old target; synchronous setup failures retire only new resources. Sample-count changes allocate and seed new sample storage before replacing the old buffer. Ripple targets retain their zero-alpha initialization. This ordering does not turn asynchronous WebGPU allocation/validation errors into synchronous success checks; those still flow through host failure/recovery handling. Source review only, without generation, build or runtime tests.

### Particle depth clamp

Particle input attribute25 now retains depth-clamp state for projected point/line modes. Ribbon record flags use bit0 for flat color and bit1 for depth clamp; assemble_ribbon writes the latter into thin-line inputs. project_particles skips near/far clipping when enabled, preserving side clipping, positive-w rejection and the built-in particle shader visibility-distance test. Thick ribbons continue through ordinary material clipping. Kernel generation and all build/runtime checks remain deferred.

### Polygon mode transport in progress

Raster records now contain 43 words. New fields 37/38 hold line width and point size, and 39-42 hold front/back polygon-offset factor/unit pairs. Control bits27-28 and29-30 select front/back fill(0), line(1), point(2). Material deduplication, copies, host validation and CUDA indexing use the new layout. Expanded ordinary/particle line and point quads force fill. This is transport only: non-fill polygon coverage and bin expansion remain to be implemented; wireframe is not yet functional. Generated artifacts and fixtures remain stale until the deferred build/test phase.

### Polygon coverage implementation in progress

Clipping's fourth weight component now carries an outgoing perimeter flag; the first
three components remain interpolation weights. `assemble_attributes` copies flags
into a distinct `boundary_offset` region before the 43-word raster records. CUDA
material coverage selects front/back fill, line or point mode, and tile bounds
include half the line/point size plus the actual MSAA sample range. Line varyings
follow the segment and point varyings are constant. Per-face polygon offset uses
raster words 39-42.

This is source-only work. Original quads/polygons still need boundary metadata,
clipping-created point behavior and exact line coverage/overlap ownership remain
unfinished, and no runtime parity is claimed. Generated bindings and fixtures must
be updated in the deferred generation/build/test phase.

Original polygon boundary transport is now connected in source: `polygonEdges`
contains three outgoing-edge bits per captured triangle. Quads, quad strips and
polygons suppress their decomposition diagonals; ordinary triangles default to
all three edges. C++ commit and browser capture preserve the array, host dispatch
validates it, and CUDA clipping carries incoming edge flags separately from
interpolation, creating visible clipping-plane edges. This supersedes the missing
original-boundary item above. Point semantics and exact line/overlap coverage are
still pending, as are generation, build and runtime verification.

Polygon boundary primitives now run the fragment pipeline independently, preserving
multiple fragments where distinct points or wide edges overlap. Non-MSAA polygon
points round size and snap window-coordinate centres; tile bounds include the
snap displacement. Point selection follows outgoing boundary flags, including
clipping-created boundaries (Khronos OpenGL 1.4 polygon-mode specification).
Size/centre rules follow OpenGL 1.5 section 3.3.1:
https://registry.khronos.org/OpenGL/specs/gl/glspec15.pdf
Remaining source gaps include precise line coverage, point smoothing/attenuation/
sprite state, and clipping fidelity for decomposed polygons. No build or runtime
validation has been performed for these changes.

Polygon point attenuation now runs in CUDA using the clipped eye-space position.
Raster records are **49 words**, superseding earlier 43-word descriptions: words
43-48 hold min size, max size, fade threshold and attenuation A/B/C. C++ record
copy/dedup, host validation/defaults and CUDA strides use this layout. Raster and
tile bounds both compute attenuated size and clamp it to the captured range.
Fade is transported but not applied yet; smoothing, sprites and precise line
rasterization remain pending. All changes are source-only and unverified.

Polygon multisample point fade is now connected in source. Below the fade
threshold, CUDA raises raster width to the threshold and applies the squared
derived-size/threshold ratio to final fragment alpha before fixed alpha testing
and coverage. Normal output alpha also receives the factor, except when
alpha-to-one replaces it. Tile bounds include the increased width.
Source basis: OpenGL 1.4 section 3.3 and OpenGL 2.0 section 3.13:
https://registry.khronos.org/OpenGL/specs/gl/glspec14.pdf
https://registry.khronos.org/OpenGL/specs/gl/glspec20.pdf
Ordinary screen-point expansion still applies fade to vertex alpha without this
multisample gate; that consistency correction remains pending. No build or tests
have run for the polygon changes.

Ordinary screen points now capture MULTISAMPLE as record flag64 (flags range0-127).
Expansion gates fading on that state plus actual sample count, raises the footprint
to the threshold, and preserves subpixel MSAA position/size. Fade uses separate
per-vertex storage initialized to one; attribute assembly interpolates it through
clipping into `point_fade_offset`, and raster applies it after shading. Vertex and
fixed-lighting alpha are no longer modified by ordinary point fade. Projected
particle points still use the earlier alpha path and remain pending. Kernel
bindings/generated fixtures and runtime behavior are unverified until validation.

Projected particle point fade now shares the final-fragment route. Input attribute
25 packs depth clamp in bit0 and multisample enable in bit1. Fade and subpixel
point expansion require both captured enable and a multisampled target. Fade
metadata now occupies a tail of transformedAttributes, initialized in CUDA by
transform_attributes and consumed by assemble_attributes. Ordinary point expansion
uses that same region; the earlier separate pointFade buffer is removed. The
project_particles kernel retains eight storage bindings. Generated signatures,
fixtures and runtime behavior remain unverified until the deferred validation.

Polygon smooth-point coverage now uses CUDA disk/pixel-square intersection area,
with coverage applied to final alpha and conservative bins including partial
pixels. Raster stride is **50 words**; word49 packs POINT_SMOOTH (bit0) and
POINT_SPRITE (bit1). Sprite state disables circle coverage and aliased snapping;
texture-coordinate replacement is still pending. C++ material/glyph and host/CUDA
record indexing use the new stride. Source basis is OpenGL 2.0 section3.3:
https://registry.khronos.org/OpenGL/specs/gl/glspec20.pdf
No compiler, numerical, build or runtime validation has run. Generated ordinary
and particle point quads still need smoothing metadata integration.

Polygon point sprite coordinate replacement is connected for compatibility
materials. Raster word49 now includes unit0-3 replacement bits2-5 and lower-left
origin bit6. CUDA uses fragment-centre UVs and reciprocal point-size gradients;
fixed texture stages replace coordinates after texture matrices, while unit0
direct sampling uses the same values. No-Program capture preserves shader-defined
UVs for world materials. Record stride remains50. Host flag validation now accepts
0-127 and requires sprite enable for replacement/origin flags. This is unbuilt,
untested source; ordinary/particle smoothing and precise line coverage remain.

Generated ordinary/particle point smoothing now uses shared fragment coverage.
Point metadata is four floats per vertex: fade, local X/Y, radius. CUDA initializes
neutral records, expansion writes smooth footprints with half-pixel support, and
clipping assembly interpolates metadata before disk coverage is applied to alpha.
Ordinary screen flags add smooth128 and sprite256 (range0-511); particle input
flags add smooth4 and sprite8 (range0-15). MSAA or sprite points bypass smoothing;
smooth/sprite points bypass aliased snapping. No new storage binding is required.
This source remains unbuilt and untested; precise line rasterization and generated
sprite sampling/viewport fidelity still need review.

Generated sprite points now tag metadata radius negative; smooth points retain
positive radius. CUDA reconstructs fragment-centre sprite coordinates from local
XY, correcting MSAA sample displacement, then uses captured per-unit replacement
and origin flags. This covers ordinary and projected particle compatibility
sprites and bypasses fixed texture matrices at sampling. Shader-authored UVs
remain unchanged when their replacement mask is zero. Four-word metadata and
storage binding counts are unchanged. No generation/build/runtime checks yet.

One-pixel non-MSAA polygon lines now use a CUDA diamond-exit helper. Interval
endpoints carry symbolic epsilon and epsilon-squared coefficients for GL endpoint
perturbation, instead of a chosen finite pixel epsilon. Coverage requires exit
before the final endpoint. Interpolation clamps at endpoints; bins retain at least
half a pixel for widths rounded to one. Source basis: OpenGL2.0 section3.4.1:
https://registry.khronos.org/OpenGL/specs/gl/glspec20.pdf
This is unverified source. Wide/smooth/stippled lines and generated line quads
remain pending, along with compiler/numerical/runtime checks.

Wide non-MSAA polygon lines now use rounded width and minor-axis replication of
the shifted diamond-exit line. CUDA checks three nearby replicas per pixel,
independent of width. Tile padding uses the rounded width. Attribute interpolation
stays on the original segment, an allowed alternative to replicated attributes.
Source basis: OpenGL4.6 section14.5.2.2:
https://registry.khronos.org/OpenGL/specs/gl/glspec46.core.pdf
Source only: no generation, compiler, numerical or runtime validation. Smooth,
stippled and generated-line coverage remain pending.

Polygon LINE_SMOOTH now uses bit7 of raster word49; stride remains50 and flags
range0-255. CUDA clips the finite line rectangle against the pixel square and
uses intersection area as final alpha coverage. Tile bounds include a half-pixel
margin. Point snapping tests mask the low point-state bits independently.
Source basis: OpenGL1.4 section3.4 antialiasing:
https://registry.khronos.org/OpenGL/specs/gl/glspec14.pdf
No compiler/numerical/runtime verification yet. Generated line coverage and
stipple phase/state are still pending.

Generated-line endpoint transport is in progress. Shared primitive metadata now
uses **12 floats per vertex**: point fade/localXY/radius0-3, clipped homogeneous
line start4-7 and end8-11. Ordinary line expansion writes identical endpoints
at every support-quad corner. Initialization, clipping assembly, host allocations
and existing point consumers use the new stride. Raster record stride remains50.
Generated line coverage/interpolation is NOT connected yet; support expansion,
particle lines, stipple and validation remain pending. No builds/tests run.

Generated line metadata now includes projected particle lines/thin ribbons as
well as ordinary lines. Word1 is their clipped-segment parameter; words4-11
retain both clipped homogeneous endpoints. map_viewport now binds the shared
attribute buffer and maps endpoint XY with exactly the support-vertex viewport
transform, preserving endpoint Z/W. Raster coverage/interpolation activation,
expanded support and ownership remain pending. Generated bindings and runtime
behavior are unverified; no builds/tests run.

Generated-line coverage is now connected in source for ordinary lines, projected
particle lines and thin ribbons. Expansion supplies conservative side/end support
quads and metadata2 retains actual width. Raster keeps support-triangle top-left
ownership, then evaluates centreline diamond-exit, smooth area or MSAA coverage.
It derives the perspective endpoint parameter and reconstructs weights/gradients
from retained per-corner parameters for depth and shading. This supersedes earlier
transport-only notes. Stipple remains pending. This substantial change has NOT
been compiled, numerically tested or verified in gameplay; clipping, short lines,
unequal endpoint w, partial viewports and overlap require deferred validation.

Dedicated generated point/line materials now carry flag4194304 indicating that
the centre/centreline was clipped before footprint expansion. CUDA skips redundant
side-plane clipping for these support quads; depth/clamp and framebuffer/scissor
handling remain. This prevents wide footprints being cut to viewport boundaries.
Source-only and untested; shader-particle mode8 using base materials and polygon
footprint clipping still need review. Stipple audit found no OpenMW app/component
producer and OSG LineStipple::apply is disabled by this build's GL1 profile.
Stipple remains unsupported, not implemented or verified.

Source-review correction: shader-particle mode8 already selects screenMaterial
through isPoint, so it receives the expanded-footprint clipping flag. Polygon
LINE/POINT footprints are evaluated after polygon clipping with expanded tile
bounds. Generated nonpolygon points/lines now explicitly use front stencil
state, independent of support-triangle winding; polygon LINE/POINT keeps its
original face selection. Generated outputs remain stale and all of these paths
remain unbuilt and untested.

Generation milestone: all 84 manifest entries now compile through the local
WebCuda compiler. Compiler compatibility fixes remain in authored CUDA: atan2f
for disk/water angles, local copies of kernel scalar parameters, and whole local
arrays for shoreline wave helpers. Generated JSON/WGSL was regenerated, never
hand-edited. This supersedes earlier stale-generation notes. Browser shader
validation, full engine build/link, gameplay and frame pacing remain unverified.
