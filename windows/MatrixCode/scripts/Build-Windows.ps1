[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = 'x64',
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$Version = '0.1.0',
    [string]$Publisher = 'MatrixCode Project',
    [switch]$Package,
    [switch]$SkipBuild,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') {
    throw 'Version must be numeric MAJOR.MINOR.PATCH[.BUILD].'
}
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceRoot = Split-Path -Parent $scriptRoot
$preset = "windows-$Architecture"
$buildPreset = "$preset-$($Configuration.ToLowerInvariant())"
$buildRoot = Join-Path $sourceRoot "out/build/$preset"
$stageRoot = Join-Path $sourceRoot "out/stage/$Architecture"
$artifactRoot = Join-Path $sourceRoot 'out/artifacts'

if (-not $SkipBuild) {
    if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
        throw 'CMake 3.29 or newer is required.'
    }
    Push-Location $sourceRoot
    try {
        cmake --preset $preset -D "MATRIXCODE_VERSION=$Version" -D "MATRIXCODE_PUBLISHER=$Publisher"
        if ($LASTEXITCODE -ne 0) { throw 'CMake configure failed.' }
        cmake --build --preset $buildPreset
        if ($LASTEXITCODE -ne 0) { throw 'CMake build failed.' }
    } finally {
        Pop-Location
    }

    if (-not $SkipTests -and $Architecture -eq 'x64') {
        ctest --test-dir $buildRoot -C $Configuration --output-on-failure
        if ($LASTEXITCODE -ne 0) { throw 'Native tests failed.' }
    }

    $stageParent = [System.IO.Path]::GetFullPath((Join-Path $sourceRoot 'out/stage'))
    $resolvedStage = [System.IO.Path]::GetFullPath($stageRoot)
    $stagePrefix = $stageParent.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedStage.StartsWith($stagePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean a staging directory outside $stageParent`: $resolvedStage"
    }
    if (Test-Path -LiteralPath $resolvedStage) {
        Remove-Item -LiteralPath $resolvedStage -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
    cmake --install $buildRoot --config $Configuration --prefix $stageRoot
    if ($LASTEXITCODE -ne 0) { throw 'CMake install staging failed.' }
} elseif (-not (Test-Path -LiteralPath (Join-Path $stageRoot 'MatrixCode.exe'))) {
    throw "The staged application does not exist: $stageRoot"
}

if ($Package) {
    if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
        throw 'WiX Toolset v4 (wix.exe) is required when -Package is used.'
    }
    New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
    # Both architectures are one product family: installing the native package must major-upgrade
    # (and remove) the other architecture rather than registering two owners for the same files.
    $upgradeCode = '{F2B19834-234B-4011-B692-6EAC7FB7FFAA}'
    $msi = Join-Path $artifactRoot "MatrixCode-$Version-windows-$Architecture.msi"
    wix build (Join-Path $sourceRoot 'installer/MatrixCode.wxs') `
        -arch $Architecture `
        -d "StageDir=$stageRoot" `
        -d "Version=$Version" `
        -d "Publisher=$Publisher" `
        -d "UpgradeCode=$upgradeCode" `
        -d "SourceRoot=$sourceRoot" `
        -out $msi
    if ($LASTEXITCODE -ne 0) { throw 'WiX package build failed.' }
    Write-Host "Built $msi"
}

if (-not $SkipBuild) { Write-Host "Staged native binaries in $stageRoot" }
