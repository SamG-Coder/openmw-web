# Build/relink the local wasm64 OpenMW engine using the repository's Windows toolchain.
# Called automatically by OpenMW.WebHost when its C++ capture source fingerprint changes.
[CmdletBinding()]
param([string]$ToolsRoot = $env:OPENMW_TOOLS_ROOT)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ToolsRoot)) { $ToolsRoot = 'D:\OpenMW-local' }

. (Join-Path $PSScriptRoot 'bootstrap-windows.ps1') -ToolsRoot $ToolsRoot

$bash = (Get-Command bash.exe -ErrorAction Stop).Source
& $bash -lc 'cd "$ROOT" && ./wasm-build/link-openmw.sh'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
