# OpenMW.WebHost

A C# 10 / ASP.NET Core host for the native WebGPU branch.

Open `openmw-web.sln` in Visual Studio 2022 and press **F5**, or run:

```powershell
dotnet run --project OpenMW.WebHost
```

The host serves the authored page and WebGPU renderer directly from the repository, so renderer edits do not need a staging command.

With `OpenMW:EngineVersion` set to `auto`, the host first checks
`build-wasm64/openmw.{js,wasm,data}`, then stamped bundles in
`.local-runtime/e/<version>` and `play/e/<version>`. A bundle is current only when
its source fingerprint matches the renderer C++ and build configuration. Set a
particular staged version instead of `auto` to reproduce that bundle explicitly.

If the engine is missing or stale and `BuildEngineWhenMissing` is true, the host
runs `wasm-build/build-local-windows.ps1` on Windows, or
`wasm-build/link-openmw.sh` on other systems. Ninja regenerates CMake when its
inputs change, rebuilds affected objects, and relinks the engine. The host then
mounts that build directly. Restart F5 after pulling C++ or build configuration
changes so this check runs again; renderer JavaScript and WGSL edits are served
directly without a WASM rebuild.

The direct WebGPU C++ sources declare `--use-port=emdawnwebgpu` in CMake, and the
final link uses the same port. This supplies both `webgpu/webgpu.h` and its
browser implementation, including when the existing CMake cache predates the
direct backend. The incremental build preserves that cache's dependency paths.
The Emscripten toolchain and dependency archives must already be installed and
the `build-wasm64` tree configured. A build failure is shown at `/status` and on
the startup page rather than terminating ASP.NET.

The host adds COOP/COEP headers required by the threaded WebAssembly build and serves `.wasm`, `.data`, `.wgsl`, JavaScript, game data and byte ranges itself.
