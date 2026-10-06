# OpenMW.WebHost

A C# 10 / ASP.NET Core host for the native WebGPU branch.

Open `openmw-web.sln` in Visual Studio 2022 and press **F5**, or run:

```powershell
dotnet run --project OpenMW.WebHost
```

The host serves the authored page and WebGPU renderer directly from the repository, so renderer edits do not need a staging command.

Engine discovery order:

1. `.local-runtime/e/<version>/openmw.{js,wasm,data}`
2. `play/e/<version>/openmw.{js,wasm,data}`
3. `build-wasm64/openmw.{js,wasm,data}`
4. `play/openmw.{js,wasm,data}`

Set `OpenMW:EngineVersion` to a particular staged version instead of `auto` if needed.

If no engine bundle exists and `BuildEngineWhenMissing` is true, the host runs the repository's existing `wasm-build/link-openmw.sh`. That build still requires the OpenMW/Emscripten dependencies used by the repository. A build failure is shown at `/status` and on the startup page rather than terminating ASP.NET.

The host adds COOP/COEP headers required by the threaded WebAssembly build and serves `.wasm`, `.data`, `.wgsl`, JavaScript, game data and byte ranges itself.
