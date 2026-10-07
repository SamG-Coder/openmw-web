[CmdletBinding()]
param([string]$ToolsRoot = 'D:\OpenMW-local')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\bootstrap-windows.ps1" -ToolsRoot $ToolsRoot
$repo = Split-Path $PSScriptRoot
$output = Join-Path $ToolsRoot 'webcuda-tests'
New-Item -ItemType Directory -Force $output | Out-Null
$compiler = "$env:EM_LIBEXEC/em++.exe"
$flags = @('-m64', '-pthread', '-fwasm-exceptions', '-std=c++20', '-O2', '-DOSG_LIBRARY_STATIC',
    '-include',"$repo/wasm-build/include/gl_compat.h","-I$repo/deps/wasm64/include", "-I$repo/openmw")
$libraries = @('osgParticle', 'osgViewer', 'osgGA', 'osgDB', 'osgText', 'osgUtil', 'osg', 'OpenThreads', 'lz4') |
    ForEach-Object { "$repo/deps/wasm64/lib/lib$_.a" }
$boost = Get-ChildItem "$repo/deps/wasm64/lib/libboost_iostreams*.a" | Select-Object -ExpandProperty FullName
if (@($boost).Count -ne 1) { throw 'Expected one Boost iostreams archive' }
# Build from the actual component archive, including the terrain producer.
& C:/msys64/usr/bin/bash.exe -c "cd '$($repo.Replace('\','/'))/build-wasm64' && ninja -j 6 components"
if ($LASTEXITCODE) { throw 'Failed to build terrain components' }
& $compiler @flags "$repo/render/webcuda/terrain-blend.test.cpp" '-Wl,--start-group' `
    "$repo/build-wasm64/components/libcomponents.a" @libraries $boost '-Wl,--end-group' `
    -sMAX_WEBGL_VERSION=2 -sFULL_ES3=1 --use-port=emdawnwebgpu --use-port=zlib --use-port=freetype `
    -sEXIT_RUNTIME=1 -sNODERAWFS=1 -sINITIAL_MEMORY=134217728 -sALLOW_MEMORY_GROWTH=1 `
    -o "$output/terrain-blend.js"
if ($LASTEXITCODE) { throw 'Failed to link terrain producer fixture' }
$node = Get-ChildItem "$ToolsRoot/emsdk/node/*/bin/node.exe", "$ToolsRoot/emsdk/node/*/node.exe" -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $node) { throw 'Bundled Emscripten Node runtime not found' }
& $node "$output/terrain-blend.js" "$output/terrain-blend-fixtures.bin"
if ($LASTEXITCODE) { throw 'Failed terrain producer or CPU-kernel comparisons' }
