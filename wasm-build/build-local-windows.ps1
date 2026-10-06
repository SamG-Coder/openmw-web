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

$bash = (Get-Command bash.exe -ErrorAction Stop).Source
& $bash -lc 'cd "$ROOT" && ./wasm-build/link-openmw.sh'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
