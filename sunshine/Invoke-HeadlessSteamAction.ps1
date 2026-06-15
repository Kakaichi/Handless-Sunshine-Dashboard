#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "ligar_tudo",
        "desligar_tudo",
        "alternar",
        "sunshine_ligar",
        "sunshine_desligar",
        "gamepad_ds4",
        "gamepad_x360",
        "tailscale_ligar",
        "tailscale_desligar",
        "moonlight_ligar",
        "moonlight_desligar",
        "moonlight_expose",
        "moonlight_reset_exposure",
        "moonlight_apply_settings",
        "instalar_deps",
        "atualizar_jogos",
        "open_sunshine_web"
    )]
    [string]$Action
)

$ErrorActionPreference = "Continue"

$scriptDir = $PSScriptRoot
$script:HeadlessSteamAppRoot = if ($env:HEADLESS_STEAM_APP_ROOT) {
    $env:HEADLESS_STEAM_APP_ROOT.Trim().TrimEnd('\')
} else {
    Split-Path -Parent $scriptDir
}
$env:HEADLESS_STEAM_APP_ROOT = $script:HeadlessSteamAppRoot
. (Join-Path $scriptDir "HeadlessSteam-MoonlightSettings.ps1")
. (Join-Path $scriptDir "HeadlessSteam-MoonlightRuntime.ps1")
. (Join-Path $scriptDir "HeadlessSteam-Tailscale.ps1")
$tailscaleExe = Get-HeadlessSteamTailscaleExe
if (-not $tailscaleExe) {
    $tailscaleExe = "C:\Program Files\Tailscale\tailscale.exe"
}
$sunshineService = "SunshineService"
$sunshineConf = Join-Path $env:ProgramFiles "Sunshine\config\sunshine.conf"
$tailscaleService = "Tailscale"
$moonlightDir = Join-Path (Split-Path -Parent $scriptDir) "moonlight-web"
$moonlightPkg = Join-Path $moonlightDir "package"
$webServerExe = "web-server.exe"
$webServerProcess = "web-server"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Reset-TailscaleExposure {
    $tailscaleScript = Join-Path $scriptDir "HeadlessSteam-Tailscale.ps1"
    if (Test-Path -LiteralPath $tailscaleScript) {
        . $tailscaleScript
        if (Get-Command Reset-HeadlessSteamTailscaleExposure -ErrorAction SilentlyContinue) {
            Reset-HeadlessSteamTailscaleExposure
            return
        }
    }

    if (-not (Get-HeadlessSteamTailscaleExe)) {
        return
    }

    $tsSvc = Get-Service -Name $tailscaleService -ErrorAction SilentlyContinue
    if (-not $tsSvc -or $tsSvc.Status -ne "Running") {
        return
    }

    $reset = Invoke-HeadlessSteamTailscaleCommand -ArgumentList @("serve", "reset") -TimeoutSeconds 10
    if ($reset.TimedOut) {
        Write-ActionLog "AVISO: tailscale serve reset expirou; continuando."
    }

    Start-Sleep -Milliseconds 300
}

function Write-ActionLog {
    param([string]$Message)
    Write-Output $Message
}

function Invoke-ExternalPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $FilePath
    ) + $ArgumentList

    & powershell.exe @args
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao executar $FilePath (codigo $LASTEXITCODE)"
    }
}

function Start-TailscaleService {
    $svc = Get-Service -Name $tailscaleService -ErrorAction SilentlyContinue
    if (-not ($svc -and $svc.Status -eq "Running")) {
        net start $tailscaleService *> $null
        Start-Sleep -Seconds 2
    }

    if (-not (Test-Path $tailscaleExe)) {
        throw "Tailscale nao instalado."
    }

    $up = Invoke-HeadlessSteamTailscaleCommand -ArgumentList @("up", "--timeout=30s") -TimeoutSeconds 35
    if ($up.TimedOut) {
        Write-ActionLog "AVISO: tailscale up expirou; verifique login na bandeja do Tailscale."
    } elseif (-not $up.Success -and $up.Error) {
        Write-ActionLog "AVISO: tailscale up: $($up.Error.Trim())"
    }

    Start-Sleep -Seconds 2
    $conn = Get-HeadlessSteamTailscaleConnectionState

    if (-not $conn.Connected) {
        if ($conn.NeedsLogin) {
            $loginUrl = if ($conn.AuthUrl) { $conn.AuthUrl } else { "https://login.tailscale.com/admin/machines" }
            Write-ActionLog "TAILSCALE_LOGIN_REQUIRED:$loginUrl"
            Write-ActionLog "AVISO: Tailscale precisa de login. Abrindo app na bandeja — entre na conta e aguarde o IP 100.x."
        } elseif ($conn.IsStarting) {
            Write-ActionLog "AVISO: Tailscale ainda conectando. Abrindo app na bandeja para concluir."
        } else {
            Write-ActionLog "AVISO: Tailscale sem IP. Abrindo app na bandeja."
        }

        if (Start-HeadlessSteamTailscaleGui) {
            Write-ActionLog "TAILSCALE_GUI_OPENED:"
        } else {
            Write-ActionLog "AVISO: Nao foi possivel abrir tailscale-ipn.exe. Abra o Tailscale manualmente na bandeja."
        }
    }

    $svc = Get-Service -Name $tailscaleService -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        if ($conn.Connected) {
            Write-ActionLog "Tailscale conectado ($($conn.Ip))."
        } else {
            Write-ActionLog "Tailscale iniciado (aguardando conexao)."
        }
        return
    }
    throw "ERRO ao iniciar Tailscale."
}

function Stop-TailscaleService {
    Write-ActionLog "Desconectando VPN Tailscale..."
    if (Test-Path $tailscaleExe) {
        $down = Invoke-HeadlessSteamTailscaleCommand -ArgumentList @("down") -TimeoutSeconds 15
        if ($down.TimedOut) {
            Write-ActionLog "AVISO: tailscale down expirou; parando servico mesmo assim."
        }
    }
    Write-ActionLog "Parando servico Tailscale..."
    net stop $tailscaleService *> $null
    $svc = Get-Service -Name $tailscaleService -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Stopped") {
        Write-ActionLog "Tailscale parado."
        return
    }
    if ($svc -and $svc.Status -eq "Running") {
        throw "ERRO ao parar Tailscale."
    }
    Write-ActionLog "Tailscale ja estava desligado."
}

function Start-SunshineService {
    net start $sunshineService *> $null
    $svc = Get-Service -Name $sunshineService -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-ActionLog "Sunshine iniciado."
        return
    }
    throw "ERRO ao iniciar Sunshine."
}

function Stop-SunshineService {
    Write-ActionLog "Parando Sunshine..."
    net stop $sunshineService *> $null
    $svc = Get-Service -Name $sunshineService -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Stopped") {
        Write-ActionLog "Sunshine parado."
        return
    }
    if ($svc -and $svc.Status -eq "Running") {
        throw "ERRO ao parar Sunshine."
    }
    Write-ActionLog "Sunshine ja estava desligado."
}

function Stop-MoonlightWeb {
    param([switch]$SkipTailscaleReset)

    $wasRunning = Test-MoonlightWebActive
    $userScript = Join-Path $scriptDir "Start-MoonlightWeb-UserProcess.ps1"
    & $userScript -Action stop -ScriptDir $scriptDir
    if ($LASTEXITCODE -ne 0) {
        throw "ERRO ao parar Moonlight Web (codigo $LASTEXITCODE)."
    }

    if (Test-MoonlightWebProcessRunning) {
        throw "ERRO: Moonlight Web ainda esta em execucao."
    }

    if ($wasRunning) {
        Write-ActionLog "Moonlight Web parado."
    } else {
        Write-ActionLog "Moonlight Web ja estava desligado."
    }

    if (-not $SkipTailscaleReset) {
        Reset-TailscaleExposure
    }
}

function Set-MoonlightTailscaleExposure {
    param([bool]$UseFunnel)

    if (-not (Get-HeadlessSteamTailscaleExe)) {
        Write-ActionLog "AVISO: Tailscale nao instalado; Moonlight Web so em localhost."
        return
    }

    $tsSvc = Get-Service -Name $tailscaleService -ErrorAction SilentlyContinue
    if (-not $tsSvc -or $tsSvc.Status -ne "Running") {
        Write-ActionLog "AVISO: Tailscale desligado; Moonlight Web so em localhost."
        return
    }

    Reset-TailscaleExposure

    if ($UseFunnel) {
        if (-not (Test-HeadlessSteamMoonlightFunnelAllowed -ScriptDir $scriptDir)) {
            throw "ERRO: Crie pelo menos um usuario antes de usar o Funnel."
        }

        $settings = Repair-HeadlessSteamMoonlightSecuritySettings -ScriptDir $scriptDir
        if (-not $settings.public_funnel_enabled) {
            throw "ERRO: Funnel indisponivel sem usuarios cadastrados."
        }

        if (-not (Test-HeadlessSteamTailscaleFunnelAllowed)) {
            Write-ActionLog "AVISO: Funnel pode nao estar habilitado na conta Tailscale."
            Write-ActionLog "AVISO: Regras gerais de ACL nao bastam; adicione nodeAttrs funnel na policy."
        }

        $funnelStart = Invoke-HeadlessSteamTailscaleCommand -ArgumentList @("funnel", "--bg", "--yes", "8080") -TimeoutSeconds 25
        $funnelOutput = "$($funnelStart.Output) $($funnelStart.Error)".Trim()
        $failureHint = $null
        if (Get-Command Get-HeadlessSteamTailscaleFunnelFailureHint -ErrorAction SilentlyContinue) {
            $failureHint = Get-HeadlessSteamTailscaleFunnelFailureHint -CombinedOutput $funnelOutput
        }

        if ($funnelStart.TimedOut -or -not $funnelStart.Success) {
            if ($failureHint -eq "ACL_FUNNEL_NODEATTRS") {
                $aclUrl = Get-HeadlessSteamTailscaleFunnelAclSetupUrl
                Write-ActionLog "FUNNEL_ACL_REQUIRED:$aclUrl"
                throw "ERRO: ACL sem permissao funnel (nodeAttrs). Edite login.tailscale.com/admin/acls/file"
            }

            if ($failureHint -eq "TAILSCALE_HTTPS_OR_DNS") {
                Write-ActionLog "FUNNEL_DNS_REQUIRED:https://login.tailscale.com/admin/dns"
                throw "ERRO: Ative MagicDNS e certificados HTTPS em login.tailscale.com/admin/dns"
            }

            $aclUrl = Get-HeadlessSteamTailscaleFunnelAclSetupUrl
            Write-ActionLog "FUNNEL_ACL_REQUIRED:$aclUrl"
            throw "ERRO: Funnel nao iniciou. Verifique ACL, MagicDNS/HTTPS e se o Moonlight Web esta na porta 8080."
        }

        $funnelUrl = $null
        if ($funnelOutput -match '(https://[^\s]+\.ts\.net)') {
            $funnelUrl = $Matches[1].TrimEnd('/')
        }

        Start-Sleep -Seconds 2
        if (-not $funnelUrl) {
            for ($attempt = 0; $attempt -lt 10; $attempt++) {
                $funnelUrl = Get-HeadlessSteamMoonlightFunnelUrl
                if ($funnelUrl) {
                    break
                }
                if (Get-Command Get-HeadlessSteamTailscaleSelfHttpsUrl -ErrorAction SilentlyContinue) {
                    $funnelUrl = Get-HeadlessSteamTailscaleSelfHttpsUrl
                    if ($funnelUrl) {
                        break
                    }
                }
                Start-Sleep -Seconds 1
            }
        }
        if ($funnelUrl) {
            Write-ActionLog "Tailscale Funnel ativo: $funnelUrl"
        } else {
            Write-ActionLog "AVISO: Funnel iniciado; URL publica ainda nao detectada (aguarde DNS)."
        }
        return
    }

    $serveStart = Invoke-HeadlessSteamTailscaleCommand -ArgumentList @("serve", "--bg", "--yes", "8080") -TimeoutSeconds 25
    if ($serveStart.TimedOut) {
        Write-ActionLog "AVISO: tailscale serve expirou; use http://localhost:8080 na tailnet."
        return
    }
    if (-not $serveStart.Success) {
        Write-ActionLog "AVISO: tailscale serve falhou; use http://localhost:8080."
        return
    }

    Start-Sleep -Seconds 1
    Write-ActionLog "Tailscale Serve ativo na tailnet."
}

function Start-MoonlightWeb {
    . (Join-Path $scriptDir "HeadlessSteam-Paths.ps1")
    $userScript = Join-Path $scriptDir "Start-MoonlightWeb-UserProcess.ps1"
    $tailscaleIp = Get-HeadlessSteamTailscaleIPv4
    & $userScript -Action start -ScriptDir $scriptDir -AppRoot $script:HeadlessSteamAppRoot -TailscaleIp $tailscaleIp

    $settings = Repair-HeadlessSteamMoonlightSecuritySettings -ScriptDir $scriptDir
    Set-MoonlightTailscaleExposure -UseFunnel $settings.public_funnel_enabled

    Write-ActionLog "Moonlight Web iniciado."
}

function Install-Dependencies {
    Invoke-ExternalPowerShell -FilePath (Join-Path $scriptDir "instalar-dependencias.ps1") -ArgumentList @("-InstallMissing")
}

function Update-SteamGames {
    Write-ActionLog "Atualizando jogos e capas da Steam..."
    $syncScript = Join-Path $scriptDir "sync-steam-games.ps1"
    $logPath = Join-Path $script:HeadlessSteamAppRoot "sync-games.log.json"

    $env:HEADLESS_STEAM_APP_ROOT = $script:HeadlessSteamAppRoot
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $syncScript -RefreshCovers
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path -LiteralPath $logPath) {
            throw "Falha ao sincronizar jogos. Consulte o log: $logPath"
        }
        throw "Falha ao sincronizar jogos (codigo $LASTEXITCODE). Log esperado em: $logPath"
    }

    if (Test-Path -LiteralPath $logPath) {
        Write-ActionLog "Jogos atualizados. Log: $logPath"
    } else {
        Write-ActionLog "Jogos atualizados."
    }
}

function Set-GamepadMode {
    param([string]$Target)

    $configDir = Split-Path -Parent $sunshineConf
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    }
    if (-not (Test-Path $sunshineConf)) {
        New-Item -ItemType File -Force -Path $sunshineConf | Out-Null
    }

    $lines = @(Get-Content -Path $sunshineConf -ErrorAction SilentlyContinue)
    $found = $false
    $lines = @($lines | ForEach-Object {
        if ($_ -match '(?i)^gamepad\s*=') {
            $found = $true
            "gamepad = $Target"
        } else {
            $_
        }
    })
    if (-not $found) {
        $lines += "gamepad = $Target"
    }

    if ($Target -eq "ds4") {
        foreach ($key in @("motion_as_ds4", "touchpad_as_ds4")) {
            $keyFound = $false
            $lines = @($lines | ForEach-Object {
                if ($_ -match "^\s*$([regex]::Escape($key))\s*=") {
                    $keyFound = $true
                    "$key = enabled"
                } else {
                    $_
                }
            })
            if (-not $keyFound) {
                $lines += "$key = enabled"
            }
        }
    }

    $lines | Set-Content -Path $sunshineConf -Encoding UTF8
    Write-ActionLog "Gamepad configurado: $Target"
    Write-ActionLog "Reiniciando Sunshine..."
    Stop-SunshineService
    Start-Sleep -Seconds 2
    Start-SunshineService
    Write-ActionLog "Reinicie o stream no navegador para aplicar."
}

function Test-AnyServiceRunning {
    . (Join-Path $scriptDir "HeadlessSteam-Status.ps1")
    $status = Get-HeadlessSteamStatus
    return ($status.SunshineRunning -or $status.TailscaleRunning -or $status.MoonlightRunning)
}

try {
    switch ($Action) {
        "ligar_tudo" {
            Install-Dependencies
            Start-TailscaleService
            Update-SteamGames
            Start-SunshineService
            Write-ActionLog "Concluido. Moonlight Web e opcional pela aba Moonlight Web."
        }
        "desligar_tudo" {
            Stop-MoonlightWeb -SkipTailscaleReset
            Stop-SunshineService
            Stop-TailscaleService
            Write-ActionLog "Concluido."
        }
        "alternar" {
            if (Test-AnyServiceRunning) {
                Write-ActionLog "Alternando: desligando..."
                Stop-MoonlightWeb -SkipTailscaleReset
                Stop-SunshineService
                Stop-TailscaleService
            } else {
                Write-ActionLog "Alternando: ligando..."
                Install-Dependencies
                Start-TailscaleService
                Update-SteamGames
                Start-SunshineService
            }
            Write-ActionLog "Concluido."
        }
        "sunshine_ligar" {
            Install-Dependencies
            Update-SteamGames
            Start-SunshineService
            Write-ActionLog "Concluido."
        }
        "sunshine_desligar" {
            Stop-SunshineService
            Write-ActionLog "Concluido."
        }
        "gamepad_ds4" { Set-GamepadMode -Target "ds4" }
        "gamepad_x360" { Set-GamepadMode -Target "x360" }
        "tailscale_ligar" {
            Start-TailscaleService
            Write-ActionLog "Concluido."
        }
        "tailscale_desligar" {
            Stop-TailscaleService
            Write-ActionLog "Concluido."
        }
        "moonlight_ligar" {
            Start-MoonlightWeb
            Write-ActionLog "Concluido."
        }
        "moonlight_desligar" {
            Stop-MoonlightWeb
            Write-ActionLog "Concluido."
        }
        "moonlight_expose" {
            if (-not (Wait-MoonlightWebReady -TimeoutSeconds 45)) {
                throw "ERRO: Moonlight Web nao esta ligado."
            }

            try {
                Apply-HeadlessSteamMoonlightSettings -ScriptDir $scriptDir
            } catch {
                Write-ActionLog "AVISO: Config Moonlight Web: $($_.Exception.Message)"
            }

            try {
                $settings = Get-HeadlessSteamMoonlightSettings
                Set-MoonlightTailscaleExposure -UseFunnel $settings.public_funnel_enabled
            } catch {
                if ($settings.public_funnel_enabled) {
                    throw
                }
                Write-ActionLog "AVISO: $($_.Exception.Message)"
            }

            Write-ActionLog "Moonlight Web disponivel em http://localhost:8080"
            Write-ActionLog "Concluido."
        }
        "moonlight_reset_exposure" {
            Reset-TailscaleExposure
            Write-ActionLog "Concluido."
        }
        "moonlight_apply_settings" {
            $before = Get-HeadlessSteamMoonlightSettings
            Apply-HeadlessSteamMoonlightSettings -ScriptDir $scriptDir
            $settings = Get-HeadlessSteamMoonlightSettings

            $skipLoginChanged = ($before.skip_login_enabled -ne $settings.skip_login_enabled) -or `
                ($before.skip_login_user_id -ne $settings.skip_login_user_id)

            if (-not (Wait-MoonlightWebReady -TimeoutSeconds 10)) {
                Write-ActionLog "Configuracoes salvas. Ligue o Moonlight Web para aplicar."
                Write-ActionLog "Concluido."
                break
            }

            if ($skipLoginChanged) {
                Write-ActionLog "Reiniciando Moonlight Web para aplicar login automatico..."
                Stop-MoonlightWeb
                Start-Sleep -Seconds 1
                Start-MoonlightWeb
            } else {
                Set-MoonlightTailscaleExposure -UseFunnel $settings.public_funnel_enabled
                Write-ActionLog "Configuracoes aplicadas."
            }
            Write-ActionLog "Concluido."
        }
        "instalar_deps" {
            Install-Dependencies
            Write-ActionLog "Concluido."
        }
        "atualizar_jogos" {
            Update-SteamGames
            Write-ActionLog "Concluido."
        }
        "open_sunshine_web" {
            . (Join-Path $scriptDir "HeadlessSteam-Status.ps1")
            $status = Get-HeadlessSteamStatus
            if (-not $status.SunshineRunning) {
                throw "Sunshine esta desligado. Ligue primeiro."
            }
            Write-ActionLog "OK:$($status.SunshinePanelUrl)"
        }
    }
    exit 0
} catch {
    Write-ActionLog "ERRO: $($_.Exception.Message)"
    exit 1
}
