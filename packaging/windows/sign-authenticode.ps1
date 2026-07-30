[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SignToolPath,
    [Parameter(Mandatory = $true)][string]$PfxPath,
    [Parameter(Mandatory = $true)][string]$TargetPath
)

$ErrorActionPreference = 'Stop'
$password = $env:MIMI_WINDOWS_SIGN_PASSWORD
if (-not $password) {
    throw 'MIMI_WINDOWS_SIGN_PASSWORD is required.'
}

& $SignToolPath sign `
    /fd SHA256 `
    /f $PfxPath `
    /p $password `
    /tr http://timestamp.digicert.com `
    /td SHA256 `
    $TargetPath
if ($LASTEXITCODE -ne 0) {
    throw "Authenticode signing failed for $TargetPath"
}
