[CmdletBinding()]
param(
    [string]$Version = '0.1.0',
    [string]$Publisher = 'MatrixCode Project',
    [switch]$RequireSigning
)

$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') {
    throw 'Version must be numeric MAJOR.MINOR.PATCH[.BUILD].'
}
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceRoot = Split-Path -Parent $scriptRoot
$artifacts = Join-Path $sourceRoot 'out/artifacts'
New-Item -ItemType Directory -Force -Path $artifacts | Out-Null

$currentVersionOutputs = @(
    foreach ($architecture in @('x64', 'arm64')) {
        Join-Path $artifacts "MatrixCode-$Version-windows-$architecture.msi"
        Join-Path $artifacts "MatrixCode-$Version-windows-$architecture-portable.zip"
        Join-Path $artifacts "MatrixCode-$Version-windows-$architecture-symbols.zip"
    }
    Join-Path $artifacts 'SHA256SUMS.txt'
)
foreach ($output in $currentVersionOutputs) {
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }
}

foreach ($architecture in @('x64', 'arm64')) {
    & (Join-Path $scriptRoot 'Build-Windows.ps1') -Architecture $architecture `
        -Configuration Release -Version $Version -Publisher $Publisher
    $stage = Join-Path $sourceRoot "out/stage/$architecture"
    & (Join-Path $scriptRoot 'Sign-Windows.ps1') `
        -Path @((Join-Path $stage 'MatrixCode.exe'), (Join-Path $stage 'Matrix Code.scr')) `
        -RequireSigning:$RequireSigning
    & (Join-Path $scriptRoot 'Build-Windows.ps1') -Architecture $architecture `
        -Configuration Release -Version $Version -Publisher $Publisher -Package -SkipBuild -SkipTests
    & (Join-Path $scriptRoot 'Sign-Windows.ps1') `
        -Path (Join-Path $artifacts "MatrixCode-$Version-windows-$architecture.msi") `
        -RequireSigning:$RequireSigning

    $portable = Join-Path $artifacts "MatrixCode-$Version-windows-$architecture-portable.zip"
    foreach ($requiredStageFile in @('MatrixCode.exe', 'Matrix Code.scr')) {
        if (-not (Test-Path -LiteralPath (Join-Path $stage $requiredStageFile) -PathType Leaf)) {
            throw "Required staged payload is missing for $architecture`: $requiredStageFile"
        }
    }
    $portableFiles = @(Get-ChildItem -LiteralPath $stage -File | Sort-Object Name |
        ForEach-Object { $_.FullName })
    if ($portableFiles.Count -eq 0) {
        throw "No portable payload files were found for $architecture in $stage"
    }
    Compress-Archive -LiteralPath $portableFiles -DestinationPath $portable -CompressionLevel Optimal -Force

    $releaseDirectory = Join-Path $sourceRoot "out/build/windows-$architecture/Release"
    $symbolFiles = @(Get-ChildItem -LiteralPath $releaseDirectory -Filter '*.pdb' -File |
        Sort-Object Name | ForEach-Object { $_.FullName })
    if ($symbolFiles.Count -gt 0) {
        $symbols = Join-Path $artifacts "MatrixCode-$Version-windows-$architecture-symbols.zip"
        Compress-Archive -LiteralPath $symbolFiles -DestinationPath $symbols -CompressionLevel Optimal -Force
    } else {
        throw "No PDB files were found for $architecture in $releaseDirectory"
    }
}

$checksums = foreach ($file in Get-ChildItem -LiteralPath $artifacts -File |
    Where-Object Name -Like "MatrixCode-$Version-*" | Sort-Object Name) {
    $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
    "$($hash.Hash.ToLowerInvariant())  $($file.Name)"
}
$checksums | Set-Content -LiteralPath (Join-Path $artifacts 'SHA256SUMS.txt') -Encoding ascii
Write-Host "Release artifacts: $artifacts"
