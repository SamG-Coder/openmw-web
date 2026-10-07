[CmdletBinding()]
param([string]$ToolsRoot = 'D:\OpenMW-local')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\bootstrap-windows.ps1" -ToolsRoot $ToolsRoot
$repo = Split-Path $PSScriptRoot
$output = Join-Path $ToolsRoot 'webcuda-tests'
New-Item -ItemType Directory -Force $output | Out-Null
$compiler = "$env:EM_LIBEXEC/em++.exe"
$flags = @('-m64', '-pthread', '-fwasm-exceptions', '-std=c++20', '-DOSG_LIBRARY_STATIC', '--use-port=emdawnwebgpu',
    '-include',"$repo/wasm-build/include/gl_compat.h","-I$repo/deps/wasm64/include", "-I$repo/openmw")
$objects = @()
foreach ($unit in @('submission', 'renderer', 'geometrypacket', 'materialstate', 'materialtable', 'browserbridge', 'browserframe', 'directwebgpu')) {
    $object = "$output/$unit.o"
    & $compiler @flags -c "$repo/openmw/components/webcuda/$unit.cpp" -o $object
    if ($LASTEXITCODE) { throw "Failed to compile $unit" }
    $objects += $object
}
$libraries = @('osgParticle', 'osgViewer', 'osgGA', 'osgDB', 'osgText', 'osgUtil', 'osg', 'OpenThreads') |
    ForEach-Object { "$repo/deps/wasm64/lib/lib$_.a" }
$node = Get-ChildItem "$ToolsRoot/emsdk/node/*/bin/node.exe", "$ToolsRoot/emsdk/node/*/node.exe" -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $node) { throw 'Bundled Emscripten Node runtime not found' }
foreach ($test in @('submission', 'renderer', 'geometrypacket', 'materialstate', 'materialtable', 'browserbridge', 'draw-capture', 'positioned-state', 'draw-state', 'particle-input', 'gui-input', 'color-input', 'raster-state-input', 'light-input', 'cluster-input')) {
    # The exhaustive color suite retains full expanded fixtures for native GPU replay.
    $memoryFlag = if ($test -eq 'color-input') { '-sINITIAL_MEMORY=67108864' } else { '-sINITIAL_MEMORY=16777216' }
    & $compiler @flags "$repo/render/webcuda/$test.test.cpp" @objects `
        '-Wl,--start-group' @libraries '-Wl,--end-group' -sMAX_WEBGL_VERSION=2 -sFULL_ES3=1 `
        --use-port=zlib --use-port=freetype -sEXIT_RUNTIME=1 $memoryFlag -o "$output/$test.js"
    if ($LASTEXITCODE) { throw "Failed to link $test test" }
    & $node "$output/$test.js"
    if ($LASTEXITCODE) { throw "Failed $test test" }
}
