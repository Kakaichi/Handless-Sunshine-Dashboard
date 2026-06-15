#Requires -Version 5.1
param(
    [string]$Version = "",
    [string]$DistDir = "",
    [string]$OutputDir = ""
)

$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $Version) {
    $versionFile = Join-Path $here "VERSION"
    if (-not (Test-Path -LiteralPath $versionFile)) {
        throw "VERSION nao encontrado em $versionFile"
    }
    $Version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
}

if (-not $DistDir) {
    foreach ($candidate in @(
        (Join-Path $here "dist\HandlessSteam"),
        (Join-Path $here "dist-build\HandlessSteam")
    )) {
        if (Test-Path -LiteralPath (Join-Path $candidate "HandlessSteam.exe")) {
            $DistDir = $candidate
            break
        }
    }
}

if (-not $DistDir -or -not (Test-Path -LiteralPath (Join-Path $DistDir "HandlessSteam.exe"))) {
    throw "Build nao encontrado. Rode .\build.ps1 antes de empacotar."
}

if (-not $OutputDir) {
    $OutputDir = Join-Path $here "release"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$assetName = "Handless-Sunshine-Dashboard-$Version-win64.zip"
$zipPath = Join-Path $OutputDir $assetName
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

$staging = Join-Path $env:TEMP "HeadlessSteam-release-$Version"
if (Test-Path -LiteralPath $staging) {
    Remove-Item -LiteralPath $staging -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $staging | Out-Null
Copy-Item -Path (Join-Path $DistDir "*") -Destination $staging -Recurse -Force
Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zipPath -CompressionLevel Optimal
Remove-Item -LiteralPath $staging -Recurse -Force

$distVersion = (Get-Content -LiteralPath (Join-Path $DistDir "VERSION") -Raw).Trim()
if ($distVersion -ne $Version) {
    throw "VERSION do dist ($distVersion) difere da versao solicitada ($Version)."
}

Write-Host "Release package: $zipPath"
Write-Output $zipPath
