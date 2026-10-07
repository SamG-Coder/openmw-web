# Engine and WebGPU performance

This pass changes the C++ capture frontend as well as the browser frame diagnostics. It does not lower image quality, change simulation frequency, skip geometry, or change the packet ABI.

## Engine change

`openmw/components/webcuda/shaderanalysis.hpp` caches repeated compact-source substring classification. The capture frontend uses these checks when selecting how OpenMW geometry/shader inputs are represented for the GPU. Entries own their source/query bytes and compare the entire content before reuse: edits at the same string address and length invalidate a result. The thread-local direct-mapped cache has 64 slots; only ASCII sources from 512 through 16384 bytes and queries up to 256 bytes are eligible. Other inputs use the original matcher. Cache collisions affect performance, not correctness.

This removes repeated whitespace-aware source searching, not shader compilation. It is not a persistent material/geometry cache. A geometry-packet pooling prototype was benchmarked and reverted because it slowed small packets despite reducing allocation counts.

## Rebuild required

The shader-analysis and capture-profile headers are compiled into `openmw.wasm`. Stop the host, pull this branch, and run F5. The host's automatic source fingerprint should trigger an incremental engine rebuild. Reloading JavaScript alone cannot apply the engine change.

## Capture a hitch without heavy renderdebug readbacks

Open `http://localhost:8910/?src=hosted&engineprofile=1`, reproduce the hitch, and promptly click **Save engine + WebGPU report**. Do not add `renderdebug=1` for this measurement.

The report includes a bounded ring of the last 360 engine ticks, engine p50/p95/p99 and maximum wall time, MessageChannel task delay, per-tick StreamFS stall/miss/byte deltas, C++ geometry/material capture timing, shader-analysis cache counters, and copies of existing WebGPU frame timings/counters. It does not request extra GPU pixel readbacks. CPU capture timing still adds profiling overhead, so use the plain hosted URL for ordinary play.

The engine tick includes synchronous work invoked during that tick, including some JS renderer submission. These measurements are not GPU timestamps or display-scanout measurements. Capture phase times can be nested; do not sum them as independent phases. Shader-analysis counters are cumulative snapshots sampled before the current capture.

`play/streamfs.js` still blocks the engine/browser thread on a cold chunk read while a helper worker supplies bytes. A hitch coinciding with `streamStallMs` must not be attributed solely to GPU rendering. Repeated GPU resource/atlas copies and first-use pipeline compilation remain separate investigation targets; this change does not claim to remove them.

## Validation

From the repository root, compile/run the standalone C++ test with assertions enabled:

```sh
c++ -std=c++17 -O2 -pthread wasm-build/tests/shaderanalysis-cache.cpp -o shaderanalysis-cache
./shaderanalysis-cache --benchmark
node --test play/frame-pump-performance.test.mjs
```

The C++ suite checks source/query mutation, negative results, bypass paths, collisions, randomized whitespace, and thread-local use. The Node suite uses a fake browser scheduler to verify the existing rAF-to-MessageChannel input boundary, cancellation, bounded timing storage, and report behavior. The optional native CPU benchmark is synthetic classification work, not an OpenMW/RTX 5080 FPS measurement. Full Emscripten/game performance must still be measured on the actual machine.
