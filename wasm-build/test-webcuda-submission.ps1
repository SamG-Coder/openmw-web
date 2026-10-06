[CmdletBinding()]
param([string]$ToolsRoot = 'D:\OpenMW-local')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\bootstrap-windows.ps1" -ToolsRoot $ToolsRoot
$repo = Split-Path $PSScriptRoot
$output = Join-Path $ToolsRoot 'webcuda-tests'
New-Item -ItemType Directory -Force $output | Out-Null
$compiler = "$env:EM_LIBEXEC/em++.exe"
$flags = @('-m64', '-pthread', '-fwasm-exceptions', '-std=c++20', '-DOSG_LIBRARY_STATIC',
    '-include',"$repo/wasm-build/include/gl_compat.h","-I$repo/deps/wasm64/include", "-I$repo/openmw")
foreach ($unit in @('submission', 'renderer', 'geometrypacket', 'materialstate', 'materialtable', 'browserbridge')) {
    & $compiler @flags -c "$repo/openmw/components/webcuda/$unit.cpp" -o "$output/$unit.o"
    if ($LASTEXITCODE) { throw "Failed to compile $unit" }
}
$libraries = @('osgParticle', 'osgViewer', 'osgGA', 'osgDB', 'osgText', 'osgUtil', 'osg', 'OpenThreads') |
    ForEach-Object { "$repo/deps/wasm64/lib/lib$_.a" }
$node = Get-ChildItem "$ToolsRoot/emsdk/node/*/bin/node.exe", "$ToolsRoot/emsdk/node/*/node.exe" -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $node) { throw 'Bundled Emscripten Node runtime not found' }
foreach ($test in @('submission', 'renderer', 'geometrypacket', 'materialstate', 'materialtable', 'browserbridge', 'draw-capture', 'positioned-state', 'draw-state', 'particle-input')) {
    & $compiler @flags "$repo/render/webcuda/$test.test.cpp" "$output/submission.o" "$output/renderer.o" "$output/geometrypacket.o" "$output/materialstate.o" "$output/materialtable.o" "$output/browserbridge.o" `
        '-Wl,--start-group' @libraries '-Wl,--end-group' -sMAX_WEBGL_VERSION=2 -sFULL_ES3=1 `
        --use-port=zlib --use-port=freetype -sEXIT_RUNTIME=1 -o "$output/$test.js"
    if ($LASTEXITCODE) { throw "Failed to link $test test" }
    & $node "$output/$test.js"
    if ($LASTEXITCODE) { throw "Failed $test test" }
}
