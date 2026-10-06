# Build/relink the local wasm64 OpenMW engine using the repository's Windows toolchain.
# Called automatically by OpenMW.WebHost when its C++ capture source fingerprint changes.
[CmdletBinding()]
param([string]$ToolsRoot = $env:OPENMW_TOOLS_ROOT)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ToolsRoot)) { $ToolsRoot = 'D:\OpenMW-local' }

. (Join-Path $PSScriptRoot 'bootstrap-windows.ps1') -ToolsRoot $ToolsRoot

# emsdk's Windows package ships Python, but not necessarily under a python3.exe
# name visible to MSYS bash. Pass its exact interpreter path to link-openmw.sh.
$python = Get-ChildItem -Path (Join-Path $ToolsRoot 'emsdk\python') -Filter python.exe -Recurse -File -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending |
    Select-Object -First 1
if (-not $python) {
    $python = Get-Command python.exe -ErrorAction SilentlyContinue
}
if (-not $python) {
    throw 'Python >= 3.10 was not found. Run wasm-build\bootstrap-windows.ps1 -Install or install Python.'
}
$env:PYTHON = $python.FullName.Replace('\', '/')
$env:PATH = "$($python.Directory.FullName);$env:PATH"
Write-Host "Using Python: $($python.FullName)"

$ninja = Get-Command ninja.exe -ErrorAction SilentlyContinue
if (-not $ninja) {
    $candidates = @(
        'C:\msys64\ucrt64\bin\ninja.exe',
        'C:\msys64\usr\bin\ninja.exe',
        (Join-Path $ToolsRoot 'ninja\ninja.exe')
    ) | Where-Object { Test-Path $_ }
    if ($candidates.Count -gt 0) { $ninja = Get-Item $candidates[0] }
}
if (-not $ninja) {
    throw 'ninja.exe was not found. Install Ninja or MSYS2 ucrt64 tools.'
}
$env:PATH = "$($ninja.Directory.FullName);$env:PATH"
Write-Host "Using Ninja: $($ninja.FullName)"

$bash = (Get-Command bash.exe -ErrorAction Stop).Source
# Do NOT use -l here. A login MSYS shell rewrites PATH and discards the
# Emscripten/Python/Ninja paths configured above.
& $bash -c 'cd "$ROOT" && ./wasm-build/link-openmw.sh'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
