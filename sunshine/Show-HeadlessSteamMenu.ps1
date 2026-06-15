param(
    [ValidateSet("main", "sunshine", "tailscale", "moonlight")]
    [string]$Menu = "main"
)

$ErrorActionPreference = "SilentlyContinue"

if ($Host.Name -eq "ConsoleHost") {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
    } catch {
    }
}

$Host.UI.RawUI.WindowTitle = "Handless Sunshine Dashboard"

. "$PSScriptRoot\HeadlessSteam-Status.ps1"

$SunshineWebPort = $script:HeadlessSteamSunshineWebPort
$PanelWidth = 60

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("── $Title " + ("─" * [Math]::Max(0, $PanelWidth - $Title.Length - 4))) -ForegroundColor DarkCyan
}

function Write-StatusLine {
    param(
        [string]$Label,
        [string]$Value,
        [ConsoleColor]$ValueColor = "Gray"
    )

    $dots = "." * [Math]::Max(1, 24 - $Label.Length)
    Write-Host ("  {0} {1} " -f $Label, $dots) -ForegroundColor DarkGray -NoNewline
    Write-Host $Value -ForegroundColor $ValueColor
}

function Write-UrlLine {
    param(
        [string]$Label,
        [string]$Url
    )

    Write-Host ("  {0,-16}" -f $Label) -ForegroundColor DarkGray -NoNewline
    Write-Host $Url -ForegroundColor Cyan
}

function Write-MenuItem {
    param(
        [string]$Key,
        [string]$Text
    )

    Write-Host ("  [{0}] " -f $Key) -ForegroundColor Yellow -NoNewline
    Write-Host $Text
}

function Write-Banner {
    param(
        [string]$Title,
        [string]$Subtitle = ""
    )

    $inner = $PanelWidth - 2
    Write-Host ""
    Write-Host ("  ╔" + ("═" * $inner) + "╗") -ForegroundColor Blue

    $pad = [Math]::Max(0, [Math]::Floor(($inner - $Title.Length) / 2))
    $titleLine = (" " * $pad) + $Title + (" " * [Math]::Max(0, $inner - $pad - $Title.Length))
    Write-Host ("  ║" + $titleLine + "║") -ForegroundColor Blue

    if ($Subtitle) {
        $padSub = [Math]::Max(0, [Math]::Floor(($inner - $Subtitle.Length) / 2))
        $subLine = (" " * $padSub) + $Subtitle + (" " * [Math]::Max(0, $inner - $padSub - $Subtitle.Length))
        Write-Host ("  ║" + $subLine + "║") -ForegroundColor DarkGray
    }

    Write-Host ("  ╚" + ("═" * $inner) + "╝") -ForegroundColor Blue
}

function Show-MainMenu {
    param($Status)

    Clear-Host
    Write-Banner -Title "HANDLESS SUNSHINE DASHBOARD" -Subtitle "Sunshine · Tailscale · Moonlight"

    Write-Section "Status"
    Write-StatusLine "Sunshine" $(if ($Status.SunshineRunning) { "LIGADO" } else { "DESLIGADO" }) $(if ($Status.SunshineRunning) { "Green" } else { "Red" })

    if (-not $Status.TailscaleRunning) {
        Write-StatusLine "Tailscale" "DESLIGADO" "Red"
    } elseif ($Status.TailscaleConnected) {
        Write-StatusLine "Tailscale" $Status.TailscaleIp "Green"
    } else {
        Write-StatusLine "Tailscale" "ATIVO (sem VPN)" "Yellow"
    }

    Write-StatusLine "Moonlight Web" $(if ($Status.MoonlightRunning) { "LIGADO :8080" } else { "DESLIGADO" }) $(if ($Status.MoonlightRunning) { "Green" } else { "DarkGray" })

    if ($Status.SunshineRunning) {
        Write-Section "Painel Sunshine (porta $SunshineWebPort)"
        Write-UrlLine "Local" "https://localhost:$SunshineWebPort"
    }

    Write-Section "Acoes"
    Write-MenuItem "1" "Ligar Sunshine + Tailscale"
    Write-MenuItem "2" "Desligar tudo"
    Write-MenuItem "3" "Alternar (liga / desliga)"
    Write-Host ""
    Write-MenuItem "4" "So Sunshine          [5] So Tailscale"
    Write-MenuItem "6" "So Moonlight Web"
    Write-Host ""
    Write-MenuItem "7" "Instalar dependencias"
    Write-MenuItem "8" "Abrir painel Sunshine no navegador"
    Write-Host ""
    Write-MenuItem "0" "Sair"
}

function Show-SunshineMenu {
    param($Status)

    Clear-Host
    Write-Host ""
    Write-Host "  Sunshine" -ForegroundColor Blue
    Write-Section "Status"
    Write-StatusLine "Servico" $(if ($Status.SunshineRunning) { "LIGADO" } else { "DESLIGADO" }) $(if ($Status.SunshineRunning) { "Green" } else { "Red" })
    Write-StatusLine "Gamepad" $Status.GamepadMode "Cyan"

    if ($Status.SunshineRunning) {
        Write-Section "URLs"
        Write-UrlLine "Local" "https://localhost:$SunshineWebPort"
    }

    Write-Section "Acoes"
    Write-MenuItem "1" "Ligar"
    Write-MenuItem "2" "Desligar"
    Write-MenuItem "3" "Gamepad PS4 (DS4) - recomendado"
    Write-MenuItem "4" "Gamepad Xbox 360"
    Write-MenuItem "5" "Abrir painel no navegador"
    Write-MenuItem "0" "Voltar"
}

function Show-TailscaleMenu {
    param($Status)

    Clear-Host
    Write-Host ""
    Write-Host "  Tailscale" -ForegroundColor Blue
    Write-Section "Status"
    if (-not $Status.TailscaleRunning) {
        Write-StatusLine "VPN" "DESLIGADO" "Red"
    } elseif ($Status.TailscaleConnected) {
        Write-StatusLine "VPN" "CONECTADO" "Green"
        Write-StatusLine "IP" $Status.TailscaleIp "Cyan"
    } else {
        Write-StatusLine "VPN" "SERVICO ATIVO" "Yellow"
    }

    Write-Section "Acoes"
    Write-MenuItem "1" "Ligar"
    Write-MenuItem "2" "Desligar"
    Write-MenuItem "0" "Voltar"
}

function Show-MoonlightMenu {
    param($Status)

    Clear-Host
    Write-Host ""
    Write-Host "  Moonlight Web" -ForegroundColor Blue
    Write-Section "Status"
    Write-StatusLine "Servico" $(if ($Status.MoonlightRunning) { "LIGADO :8080" } else { "DESLIGADO" }) $(if ($Status.MoonlightRunning) { "Green" } else { "Red" })

    if ($Status.TailscaleIp) {
        Write-Section "URLs"
        Write-UrlLine "Local" "http://localhost:8080"
        Write-UrlLine "Tailscale" "http://$($Status.TailscaleIp):8080"
    }

    Write-Section "Acoes"
    Write-MenuItem "1" "Ligar"
    Write-MenuItem "2" "Desligar"
    Write-MenuItem "0" "Voltar"
}

$status = Get-HeadlessSteamStatus

switch ($Menu) {
    "main" { Show-MainMenu -Status $status }
    "sunshine" { Show-SunshineMenu -Status $status }
    "tailscale" { Show-TailscaleMenu -Status $status }
    "moonlight" { Show-MoonlightMenu -Status $status }
}

Write-Host ""
$choice = Read-Host "  Escolha"
$choiceFile = Join-Path $env:TEMP "headless-steam-menu-choice.txt"
Set-Content -Path $choiceFile -Value $choice.Trim() -Encoding ASCII -NoNewline
