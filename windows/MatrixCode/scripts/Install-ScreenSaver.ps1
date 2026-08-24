[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = 'x64',
    [string]$SourcePath = '',
    [switch]$SkipBuild,
    [switch]$NoSettings
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceRoot = Split-Path -Parent $scriptRoot
$logRoot = Join-Path $sourceRoot 'out/logs'
$logPath = Join-Path $logRoot 'install-screen-saver.log'
$transcriptStarted = $false

function Stop-MatrixCodeScreenSaver {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessName -in @('Matrix Code', 'Matrix Code.scr') -or
                $_.ProcessName -like 'MATRIX~*.SCR'
        } |
        Stop-Process -Force -ErrorAction Stop
}

if (-not $SkipBuild) {
    Stop-MatrixCodeScreenSaver
    & (Join-Path $scriptRoot 'Build-Windows.ps1') `
        -Architecture $Architecture -Configuration Release -SkipTests
}

if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Join-Path $sourceRoot "out/stage/$Architecture/Matrix Code.scr"
}
$resolvedSource = [System.IO.Path]::GetFullPath($SourcePath)
if (-not (Test-Path -LiteralPath $resolvedSource -PathType Leaf)) {
    throw "The staged screen saver does not exist: $resolvedSource"
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    $powerShell = Join-Path $PSHOME 'powershell.exe'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" " +
        "-Architecture $Architecture -SkipBuild -SourcePath `"$resolvedSource`""
    if ($NoSettings) { $arguments += ' -NoSettings' }
    Write-Host 'Administrator access is required to install into Windows System32.'
    $elevated = Start-Process -FilePath $powerShell -Verb RunAs `
        -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
    if ($elevated.ExitCode -ne 0) {
        throw "The elevated installer failed with exit code $($elevated.ExitCode). See $logPath"
    }
    Write-Host "Screen saver installation completed. Log: $logPath"
    exit 0
}

New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
Start-Transcript -LiteralPath $logPath -Force | Out-Null
$transcriptStarted = $true
trap {
    Write-Host "ERROR: $_" -ForegroundColor Red
    if ($transcriptStarted) {
        Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    }
    exit 1
}

$systemDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
$targetPath = [System.IO.Path]::GetFullPath((Join-Path $systemDirectory 'Matrix Code.scr'))
$expectedTarget = [System.IO.Path]::GetFullPath(
    (Join-Path $systemDirectory 'Matrix Code.scr'))
if (-not $targetPath.Equals($expectedTarget, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to install to an unexpected path: $targetPath"
}

$sourceHash = (Get-FileHash -LiteralPath $resolvedSource -Algorithm SHA256).Hash
$targetExists = Test-Path -LiteralPath $targetPath -PathType Leaf
$targetHash = if ($targetExists) {
    (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
} else {
    $null
}

$backupPath = $null
if ($targetHash -ne $sourceHash) {
    Stop-MatrixCodeScreenSaver

    if ($targetExists) {
        $backupRoot = Join-Path $sourceRoot 'out/backups'
        New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupPath = Join-Path $backupRoot "Matrix Code.$stamp.$PID.scr"
        Copy-Item -LiteralPath $targetPath -Destination $backupPath
        Write-Host "Backed up the previous screen saver to $backupPath"
    }

    try {
        Copy-Item -LiteralPath $resolvedSource -Destination $targetPath -Force
        $installedHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
        if ($installedHash -ne $sourceHash) {
            throw 'The installed screen saver failed SHA-256 verification.'
        }
    } catch {
        if ($backupPath -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            Copy-Item -LiteralPath $backupPath -Destination $targetPath -Force
        }
        throw
    }

    Write-Host "Installed $targetPath"
    Write-Host "SHA256: $sourceHash"
} else {
    Write-Host "Matrix Code is already current at $targetPath"
    Write-Host "SHA256: $sourceHash"
}

$desktopKey = 'Registry::HKEY_CURRENT_USER\Control Panel\Desktop'
New-Item -Path $desktopKey -Force | Out-Null
New-ItemProperty -Path $desktopKey -Name 'SCRNSAVE.EXE' `
    -PropertyType String -Value $targetPath -Force | Out-Null
New-ItemProperty -Path $desktopKey -Name 'ScreenSaveActive' `
    -PropertyType String -Value '1' -Force | Out-Null

if (-not $NoSettings) {
    Start-Process -FilePath control.exe -ArgumentList 'desk.cpl,,@screensaver'
}

Stop-Transcript | Out-Null
$transcriptStarted = $false
