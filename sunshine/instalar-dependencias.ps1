param(
    [switch]$InstallMissing,
    [switch]$CheckOnly
)

$ErrorActionPreference = "Continue"

if ($Host.Name -eq 'ConsoleHost') {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
    } catch {
    }
}

function Write-Status {
    param([string]$Message)
    Write-Host $Message
}

function Test-WingetAvailable {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        return $false
    }
    return ($LASTEXITCODE -eq 0 -or $?)
}

. "$PSScriptRoot\Get-SteamPath.ps1"
. "$PSScriptRoot\Sunshine-Config.ps1"

function Test-SunshineInstalled {
    if (Test-Path "$env:ProgramFiles\Sunshine\sunshine.exe") { return $true }
    return $null -ne (Get-Service -Name "SunshineService" -ErrorAction SilentlyContinue)
}

function Test-TailscaleInstalled {
    return Test-Path "C:\Program Files\Tailscale\tailscale.exe"
}

function Test-ViGEmBusInstalled {
    if (Get-Service -Name "ViGEmBus" -ErrorAction SilentlyContinue) { return $true }
    return Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\ViGEmBus"
}

function Test-MoonlightWebPresent {
    param([string]$MoonlightWebServerPath)
    return $MoonlightWebServerPath -and (Test-Path $MoonlightWebServerPath)
}

function Install-WingetPackage {
    param(
        [string]$Id,
        [string]$Name
    )

    Write-Status "  Instalando $Name ($Id)..."
    $output = winget install -e --id $Id --accept-package-agreements --accept-source-agreements --silent 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0 -or $exitCode -eq -1978335189) {
        Write-Status "  OK: $Name instalado (ou ja estava presente)."
        return $true
    }

    Write-Status "  ERRO ao instalar $Name (codigo $exitCode)."
    if ($output) {
        $output | Select-Object -Last 5 | ForEach-Object { Write-Status "    $_" }
    }
    return $false
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\HeadlessSteam-Paths.ps1"
$moonlightWebServer = Join-Path (Get-HeadlessSteamMoonlightPackageDir -FromScriptDir $scriptDir) "web-server.exe"
$sunshineConf = Join-Path $env:ProgramFiles "Sunshine\config\sunshine.conf"

$dependencies = @(
    [ordered]@{
        Name     = "Sunshine"
        Test     = { Test-SunshineInstalled }
        WingetId = "LizardByte.Sunshine"
        Required = $true
        PostInstall = {
            Initialize-SunshineDefaults -SunshineConf $sunshineConf
            Write-Status "  Sunshine: gamepad DS4 e acesso remoto configurados em sunshine.conf"
        }
    },
    [ordered]@{
        Name     = "Tailscale"
        Test     = { Test-TailscaleInstalled }
        WingetId = "Tailscale.Tailscale"
        Required = $true
    },
    [ordered]@{
        Name     = "ViGEm Bus"
        Test     = { Test-ViGEmBusInstalled }
        WingetId = "ViGEm.ViGEmBus"
        Required = $true
    },
    [ordered]@{
        Name     = "Steam"
        Test     = { Test-SteamInstalled }
        WingetId = "Valve.Steam"
        Required = $false
    },
    [ordered]@{
        Name          = "Moonlight Web (local)"
        Test          = { Test-MoonlightWebPresent -MoonlightWebServerPath $moonlightWebServer }
        WingetId      = $null
        Required      = $false
        LocalOnlyNote = "Incluso na pasta moonlight-web\package do projeto."
    }
)

$missingRequired = New-Object System.Collections.Generic.List[string]
$failedInstalls = New-Object System.Collections.Generic.List[string]
$installedSomething = $false

Write-Status ""
Write-Status "Verificando dependencias..."
Write-Status ""

foreach ($dep in $dependencies) {
    $isInstalled = & $dep.Test

    if ($isInstalled) {
        if ($dep.Name -eq "Steam") {
            $steamExe = Get-SteamExePath
            if ($steamExe) {
                Write-Status "[OK] $($dep.Name) ($steamExe)"
            } else {
                Write-Status "[OK] $($dep.Name)"
            }
        } else {
            Write-Status "[OK] $($dep.Name)"
        }
        continue
    }

    Write-Status "[--] $($dep.Name) - nao encontrado"

    if ($CheckOnly) {
        if ($dep.Required) {
            $missingRequired.Add($dep.Name) | Out-Null
        }
        continue
    }

    if (-not $InstallMissing) {
        if ($dep.Required) {
            $missingRequired.Add($dep.Name) | Out-Null
        }
        continue
    }

    if ($dep.WingetId) {
        if (-not (Test-WingetAvailable)) {
            Write-Status "  ERRO: winget nao disponivel. Instale o App Installer da Microsoft Store."
            $failedInstalls.Add($dep.Name) | Out-Null
            continue
        }

        if (Install-WingetPackage -Id $dep.WingetId -Name $dep.Name) {
            $installedSomething = $true
            Start-Sleep -Seconds 2

            if ($dep.PostInstall) {
                & $dep.PostInstall
            }
        } else {
            $failedInstalls.Add($dep.Name) | Out-Null
        }
    } elseif ($dep.LocalOnlyNote) {
        Write-Status "  AVISO: $($dep.LocalOnlyNote)"
        if ($dep.Required) {
            $failedInstalls.Add($dep.Name) | Out-Null
        }
    }
}

Write-Status ""

if ($InstallMissing -and $installedSomething) {
    Write-Status "Aguarde alguns segundos e reinicie o PC se o ViGEm Bus foi instalado agora."
    Write-Status "Tailscale novo: faca login com 'tailscale up' ou pelo icone na bandeja."
    Write-Status "Sunshine novo: acesse https://localhost:47990 para definir usuario/senha."
    Write-Status ""
}

if ($failedInstalls.Count -gt 0) {
    Write-Status "Falha ao instalar: $($failedInstalls -join ', ')"
    exit 1
}

if ($missingRequired.Count -gt 0 -and ($CheckOnly -or -not $InstallMissing)) {
    Write-Status "Faltando (obrigatorio): $($missingRequired -join ', ')"
    Write-Status "Use a opcao [7] Instalar dependencias ou [1] Ligar (instala automaticamente)."
    exit 2
}

Write-Status "Todas as dependencias obrigatorias estao presentes."

if (-not $CheckOnly) {
    . "$scriptDir\Install-HeadlessSteamShortcut.ps1"
    Install-HeadlessSteamDesktopShortcut -SunshineDir $scriptDir | Out-Null
}

exit 0
