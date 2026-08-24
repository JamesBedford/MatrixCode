[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = 'x64',
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [switch]$Capture
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceRoot = Split-Path -Parent $scriptRoot
$preset = "windows-$Architecture"
$buildRoot = Join-Path $sourceRoot "out/build/$preset"

& (Join-Path $scriptRoot 'Build-Windows.ps1') -Architecture $Architecture `
    -Configuration $Configuration

if ($Capture) {
    $captureExecutable = Join-Path $buildRoot "$Configuration/MatrixCodeRenderCapture.exe"
    $output = Join-Path $sourceRoot "out/captures/windows-$Architecture.png"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $output) | Out-Null
    & $captureExecutable --output $output
    if ($LASTEXITCODE -ne 0) { throw 'Canonical WARP capture failed.' }
}
