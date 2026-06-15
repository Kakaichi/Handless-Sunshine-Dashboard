#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$distDir = Join-Path $here "dist\HandlessSteam"
$resources = Join-Path $here "resources"

function Stop-HeadlessSteamBuildBlockers {
    $stopped = $false
    foreach ($name in @("web-server", "HandlessSteam", "HeadlessSteam")) {
        cmd /c "taskkill /F /IM $($name).exe /T 2>nul" | Out-Null
        foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            Write-Host "Encerrando $name (PID $($proc.Id)) para liberar arquivos do build..."
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            $stopped = $true
        }
    }
    if ($stopped) {
        Start-Sleep -Milliseconds 1200
    }
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) {
            throw "Comando falhou (codigo $LASTEXITCODE): $FilePath $($ArgumentList -join ' ')"
        }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Remove-DirectoryForce {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Retries = 5,
        [switch]$ThrowOnFailure
    )

    if (-not (Test-Path $Path)) {
        return $true
    }

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            if ($attempt -eq $Retries) {
                if ($ThrowOnFailure) {
                    throw
                }
                return $false
            }
            Write-Host "Nao foi possivel remover '$Path' (tentativa $attempt/$Retries). Liberando arquivos..."
            Stop-HeadlessSteamBuildBlockers
            Start-Sleep -Milliseconds 1200
        }
    }

    return $false
}

if (-not (Test-Path $resources)) {
    New-Item -ItemType Directory -Path $resources | Out-Null
}

$faviconResources = Join-Path $resources "favicon.ico"
$faviconSunshine = Join-Path $repoRoot "sunshine\favicon.ico"
if (-not (Test-Path -LiteralPath $faviconResources)) {
    if (Test-Path -LiteralPath $faviconSunshine) {
        Copy-Item -LiteralPath $faviconSunshine -Destination $faviconResources -Force
    } else {
        throw "favicon.ico nao encontrado em headless-steam-app/resources/ nem sunshine/"
    }
}
Copy-Item -LiteralPath $faviconResources -Destination $faviconSunshine -Force

Push-Location $here
try {
    Stop-HeadlessSteamBuildBlockers

    $useAltDist = $false
    $distName = "HandlessSteam"
    $distDir = Join-Path $here "dist\$distName"
    if (Test-Path -LiteralPath $distDir) {
        if (-not (Remove-DirectoryForce -Path $distDir)) {
            $useAltDist = $true
            Write-Host "AVISO: dist/HandlessSteam em uso. Gerando em dist-build/HandlessSteam ..."
        }
    }

    Invoke-NativeCommand -FilePath "python" -ArgumentList @("-m", "pip", "install", "-r", "requirements.txt", "pyinstaller")
    if ($useAltDist) {
        $distParent = Join-Path $here "dist-build"
        $distDir = Join-Path $distParent $distName
        if (Test-Path -LiteralPath $distDir) {
            Remove-DirectoryForce -Path $distDir -ThrowOnFailure
        }
        Invoke-NativeCommand -FilePath "pyinstaller" -ArgumentList @("--noconfirm", "--distpath", $distParent, "HandlessSteam.spec")
    } else {
        Invoke-NativeCommand -FilePath "pyinstaller" -ArgumentList @("--noconfirm", "HandlessSteam.spec")
        $distDir = Join-Path $here "dist\$distName"
    }

    if (-not (Test-Path $distDir)) {
        throw "Build nao gerou $distDir"
    }

    $versionFile = Join-Path $here "VERSION"
    if (Test-Path $versionFile) {
        $version = (Get-Content $versionFile -Raw).Trim()
        Copy-Item -Path $versionFile -Destination (Join-Path $distDir "VERSION") -Force
        Write-Host "Versao: $version"
    }

    $sunshineDest = Join-Path $distDir "sunshine"
    $moonlightDest = Join-Path $distDir "moonlight-web"

    if (Test-Path $sunshineDest) {
        Remove-DirectoryForce -Path $sunshineDest -ThrowOnFailure
    }
    Copy-Item -Path (Join-Path $repoRoot "sunshine") -Destination $sunshineDest -Recurse -Force

    $requiredScripts = @(
        "HeadlessSteam-Status.ps1",
        "Invoke-HeadlessSteamAction.ps1",
        "sync-steam-games.ps1",
        "Apply-HeadlessSteamUpdate.ps1"
    )
    foreach ($scriptName in $requiredScripts) {
        $scriptPath = Join-Path $sunshineDest $scriptName
        if (-not (Test-Path -LiteralPath $scriptPath)) {
            throw "Build incompleto: sunshine/$scriptName nao foi copiado para $sunshineDest"
        }
    }
    Write-Host "sunshine/ copiado para dist ($($requiredScripts.Count) scripts verificados)."

    $moonlightSrc = Join-Path $repoRoot "moonlight-web"
    if (-not (Test-Path $moonlightSrc)) {
        throw "Build incompleto: moonlight-web/ nao encontrado em $moonlightSrc"
    }

    if (Test-Path $moonlightDest) {
        $preserveData = Join-Path $moonlightDest "package\server\data.json"
        $preserveConfig = Join-Path $moonlightDest "package\server\config.json"
        $backupData = $null
        $backupConfig = $null
        if (Test-Path -LiteralPath $preserveData) {
            $backupData = Get-Content -LiteralPath $preserveData -Raw -Encoding UTF8
        }
        if (Test-Path -LiteralPath $preserveConfig) {
            $backupConfig = Get-Content -LiteralPath $preserveConfig -Raw -Encoding UTF8
        }
        Remove-DirectoryForce -Path $moonlightDest -ThrowOnFailure
    } else {
        $backupData = $null
        $backupConfig = $null
    }
    Copy-Item -Path $moonlightSrc -Destination $moonlightDest -Recurse -Force

    if ($backupData) {
        $dataPath = Join-Path $moonlightDest "package\server\data.json"
        [System.IO.File]::WriteAllText($dataPath, $backupData, [System.Text.UTF8Encoding]::new($false))
        Write-Host "moonlight-web: data.json do dist anterior preservado."
    }
    if ($backupConfig) {
        $configPath = Join-Path $moonlightDest "package\server\config.json"
        [System.IO.File]::WriteAllText($configPath, $backupConfig, [System.Text.UTF8Encoding]::new($false))
        Write-Host "moonlight-web: config.json do dist anterior preservado."
    }

    $webServerExe = Join-Path $moonlightDest "package\web-server.exe"
    $dataExample = Join-Path $moonlightDest "package\server\data.json.example"
    if (-not (Test-Path -LiteralPath $webServerExe)) {
        throw "Build incompleto: moonlight-web/package/web-server.exe nao encontrado"
    }
    if (-not (Test-Path -LiteralPath $dataExample)) {
        throw "Build incompleto: moonlight-web/package/server/data.json.example nao encontrado"
    }
    Write-Host "moonlight-web copiado para dist."

    $shortcutScript = Join-Path $sunshineDest "Install-HeadlessSteamShortcut.ps1"
    if (Test-Path $shortcutScript) {
        Write-Host ""
        Write-Host "Atualizando atalho na area de trabalho..."
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $shortcutScript
    }

    Write-Host ""
    Write-Host "Build concluido: $distDir\HandlessSteam.exe"
} finally {
    Pop-Location
}
