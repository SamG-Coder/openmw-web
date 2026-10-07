[CmdletBinding()]
param([string]$ToolsRoot='D:\OpenMW-local')
$ErrorActionPreference='Stop'
. "$PSScriptRoot\bootstrap-windows.ps1" -ToolsRoot $ToolsRoot
$repo=Split-Path $PSScriptRoot
$output="$repo/.local-runtime/webcuda-probe"
New-Item -ItemType Directory -Force $output | Out-Null
$compiler="$env:EM_LIBEXEC/em++.exe"
$flags=@('-m64','-pthread','-fwasm-exceptions','-std=c++20','-DOSG_LIBRARY_STATIC','--use-port=emdawnwebgpu','-include',"$repo/wasm-build/include/gl_compat.h","-I$repo/deps/wasm64/include","-I$repo/openmw")
$objects=@()
foreach($unit in @('submission','renderer','geometrypacket','materialstate','materialtable','browserbridge','browserframe','directwebgpu')) {
    $object="$output/$unit.o"
    & $compiler @flags -c "$repo/openmw/components/webcuda/$unit.cpp" -o $object
    if($LASTEXITCODE){throw "Failed to compile $unit"}
    $objects+=$object
}
$libraries=@('osgParticle', 'osgViewer','osgGA','osgDB','osgText','osgUtil','osg','OpenThreads')|ForEach-Object{"$repo/deps/wasm64/lib/lib$_.a"}
& $compiler @flags "$repo/render/webcuda/probe.cpp" @objects '-Wl,--start-group' @libraries '-Wl,--end-group' `
    -sMAX_WEBGL_VERSION=2 -sFULL_ES3=1 --use-port=zlib --use-port=freetype -sMODULARIZE=1 -sEXPORT_NAME=createOpenMWProbe `
    -sEXIT_RUNTIME=0 -sALLOW_MEMORY_GROWTH=1 -o "$output/probe.js"
if($LASTEXITCODE){throw 'Failed to link browser integration probe'}
