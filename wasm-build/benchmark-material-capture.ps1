[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BaselineSource,
    [string]$ToolsRoot='D:/OpenMW-local'
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/bootstrap-windows.ps1" -ToolsRoot $ToolsRoot
$benchRepo=Split-Path $PSScriptRoot
$benchOutput=Join-Path $ToolsRoot 'material-define-benchmark'
New-Item -ItemType Directory -Force -Path $benchOutput | Out-Null
$benchBaseline=(Resolve-Path -LiteralPath $BaselineSource).Path
$benchCurrent=Join-Path $benchRepo 'openmw/components/webcuda/materialtable.cpp'
$benchCompiler="$env:EM_LIBEXEC/em++.exe"
$benchFlags=@('-O3','-m64','-pthread','-fwasm-exceptions','-std=c++20','-DOSG_LIBRARY_STATIC',
    '-include',"$benchRepo/wasm-build/include/gl_compat.h","-I$benchRepo/deps/wasm64/include", "-I$benchRepo/openmw","-I$benchRepo/openmw/components/webcuda")
$benchLibraries=@('osgParticle','osgViewer','osgGA','osgDB','osgText','osgUtil','osg','OpenThreads') |
    ForEach-Object { "$benchRepo/deps/wasm64/lib/lib$_.a" }
$benchNode=Get-ChildItem "$ToolsRoot/emsdk/node/*/bin/node.exe","$ToolsRoot/emsdk/node/*/node.exe" -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
if (!$benchNode) { throw 'Bundled Emscripten Node runtime not found' }
& $benchCompiler @benchFlags -c "$benchRepo/openmw/components/webcuda/materialstate.cpp" -o "$benchOutput/state.o"
if ($LASTEXITCODE) { throw 'Benchmark state compilation failed' }
foreach ($variant in @('before','after')) {
    $benchSource=if ($variant -eq 'before') { $benchBaseline } else { $benchCurrent }
    & $benchCompiler @benchFlags -c $benchSource -o "$benchOutput/$variant.o"
    if ($LASTEXITCODE) { throw "Benchmark $variant compilation failed" }
    & $benchCompiler @benchFlags "$benchRepo/render/webcuda/material-capture.bench.cpp" "$benchOutput/$variant.o" "$benchOutput/state.o" `
        '-Wl,--start-group' @benchLibraries '-Wl,--end-group' -sMAX_WEBGL_VERSION=2 -sFULL_ES3=1 --use-port=zlib --use-port=freetype `
        -sEXIT_RUNTIME=1 -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=268435456 -o "$benchOutput/$variant.js"
    if ($LASTEXITCODE) { throw "Benchmark $variant link failed" }
}
$benchCases=@()
for ($scenario=0;$scenario -lt 10;$scenario++) {
    $benchPair=@{}
    $benchOrder=if ($scenario%2) { @('after','before') } else { @('before','after') }
    foreach ($variant in $benchOrder) {
        & $benchNode "$benchOutput/$variant.js" $scenario > "$benchOutput/$scenario-$variant.json"
        if ($LASTEXITCODE) { throw "Benchmark case $scenario $variant failed" }
        $benchPair[$variant]=Get-Content -Raw "$benchOutput/$scenario-$variant.json" | ConvertFrom-Json
    }
    if ($benchPair.before.checksum -ne $benchPair.after.checksum) { throw "Packet mismatch in case $scenario" }
    $benchCases+=@{before=$benchPair.before;after=$benchPair.after}
    Write-Host ("{0} {1}: {2:F3} -> {3:F3} ms; identical packets" -f $scenario,$benchPair.after.material,$benchPair.before.medianMs,$benchPair.after.medianMs)
}
@{
    scope='Isolated WASM64 O3 material capture; 640 draws, 16 variants, 2 warmups and 9 measured samples per case. Process order alternates by case; not game FPS.'
    baselineSourceSha256=(Get-FileHash -LiteralPath $benchBaseline -Algorithm SHA256).Hash
    currentSourceSha256=(Get-FileHash -LiteralPath $benchCurrent -Algorithm SHA256).Hash
    equivalentPackets=$true
    cases=$benchCases
} | ConvertTo-Json -Depth 8 | Set-Content "$benchOutput/report.json"
Write-Host "Report: $benchOutput/report.json"
