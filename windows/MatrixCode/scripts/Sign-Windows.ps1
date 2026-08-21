[CmdletBinding()]
param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [string[]]$Path,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$RequireSigning
)

begin {
    $ErrorActionPreference = 'Stop'
    $signTool = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if (-not $signTool) {
        $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
        if (Test-Path $kits) {
            $candidate = Get-ChildItem -LiteralPath $kits -Filter signtool.exe -Recurse -File |
                Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
                Sort-Object FullName -Descending |
                Select-Object -First 1
            if ($candidate) { $signTool = $candidate }
        }
    }
    $pfx = $env:MATRIXCODE_SIGN_PFX
    $password = $env:MATRIXCODE_SIGN_PFX_PASSWORD
    $subject = $env:MATRIXCODE_SIGN_SUBJECT
    $external = $env:MATRIXCODE_SIGN_COMMAND
}

process {
    foreach ($item in $Path) {
        $resolved = (Resolve-Path -LiteralPath $item).Path
        if ($external) {
            & $external $resolved
            if ($LASTEXITCODE -ne 0) { throw "External signer failed for $resolved" }
        } elseif ($signTool -and $pfx) {
            $arguments = @('sign', '/fd', 'SHA256', '/td', 'SHA256', '/tr', $TimestampUrl,
                '/f', $pfx)
            if ($password) { $arguments += @('/p', $password) }
            $arguments += $resolved
            & $signTool.Source @arguments
            if ($LASTEXITCODE -ne 0) { throw "Signing failed for $resolved" }
        } elseif ($signTool -and $subject) {
            & $signTool.Source sign /fd SHA256 /td SHA256 /tr $TimestampUrl /n $subject $resolved
            if ($LASTEXITCODE -ne 0) { throw "Signing failed for $resolved" }
        } elseif ($RequireSigning) {
            throw 'No signing backend is configured. Set MATRIXCODE_SIGN_PFX, MATRIXCODE_SIGN_SUBJECT, or MATRIXCODE_SIGN_COMMAND.'
        } else {
            Write-Warning "Leaving unsigned: $resolved"
            continue
        }
        if ($signTool) {
            & $signTool.Source verify /pa /all $resolved
            if ($LASTEXITCODE -ne 0) { throw "Signature verification failed for $resolved" }
        } elseif ((Get-AuthenticodeSignature -LiteralPath $resolved).Status -ne 'Valid') {
            throw "Signature verification failed for $resolved"
        }
    }
}
