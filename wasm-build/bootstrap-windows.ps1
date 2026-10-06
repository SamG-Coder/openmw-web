# Local Windows toolchain for this fork. Game assets are never downloaded here.
[CmdletBinding()]
param([string]$ToolsRoot = 'D:\OpenMW-local', [switch]$Install)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$sdk = Join-Path $ToolsRoot 'emsdk'
if ($Install) {
    if (-not (Test-Path "$sdk\emsdk.bat")) {
        git clone --depth 1 https://github.com/emscripten-core/emsdk.git $sdk
        if ($LASTEXITCODE) { throw 'emsdk clone failed' }
    }
    & "$sdk\emsdk.bat" install 6.0.1
    if ($LASTEXITCODE) { throw 'emsdk installation failed' }
    & "$sdk\emsdk.bat" activate 6.0.1
    if ($LASTEXITCODE) { throw 'emsdk activation failed' }
}
$env:EM_CONFIG = "$sdk\.emscripten"
$env:EM_LIBEXEC = "$sdk/upstream/emscripten".Replace('\', '/')
$env:EMSDK_BIN = $env:EM_LIBEXEC
$env:OMW_WASM64 = '1'
$env:ROOT = $repo.Replace('\', '/')
$env:CMAKE_BUILD_PARALLEL_LEVEL = '6'
$env:JOBS = '6'
$env:PATH = "$env:EM_LIBEXEC;C:\msys64\ucrt64\bin;C:\msys64\usr\bin;$env:PATH"
& "$env:EM_LIBEXEC\emcc.exe" --version
if ($LASTEXITCODE) { throw 'Emscripten is not usable' }
Write-Host 'Local wasm64 toolchain configured for this PowerShell process.'
Write-Host 'Dot-source this file to retain the environment: . .\wasm-build\bootstrap-windows.ps1'
Write-Host 'Dependency archives and the full engine must still be built before linking.'
