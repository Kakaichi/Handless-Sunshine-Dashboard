#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory = $true)][string]$Action,
    [Parameter(Mandatory = $true)][string]$LogPath,
    [string]$AppRoot = ""
)

if ($AppRoot) {
    $env:HEADLESS_STEAM_APP_ROOT = $AppRoot.Trim().TrimEnd('\')
}

$scriptDir = $PSScriptRoot
$invoke = Join-Path $scriptDir "Invoke-HeadlessSteamAction.ps1"

& $invoke -Action $Action *>&1 | Tee-Object -FilePath $LogPath
exit $LASTEXITCODE
