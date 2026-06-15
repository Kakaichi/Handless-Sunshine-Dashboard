function Get-HeadlessSteamAppRoot {
    param([string]$FromScriptDir = $PSScriptRoot)

    if ($env:HEADLESS_STEAM_APP_ROOT) {
        $root = [string]$env:HEADLESS_STEAM_APP_ROOT.Trim().TrimEnd('\')
        if ($root) {
            return $root
        }
    }

    if ($env:HEADLESS_STEAM_HOME) {
        $homeRoot = [string]$env:HEADLESS_STEAM_HOME.Trim().TrimEnd('\')
        if ($homeRoot) {
            if ((Split-Path -Leaf $homeRoot) -ieq "sunshine") {
                return Split-Path -Parent $homeRoot
            }
            if (Test-Path -LiteralPath (Join-Path $homeRoot "sunshine")) {
                return $homeRoot
            }
            return $homeRoot
        }
    }

    if ($FromScriptDir) {
        return Split-Path -Parent $FromScriptDir
    }

    return (Get-Location).Path
}

function Get-HeadlessSteamMoonlightPackageDir {
    param([string]$FromScriptDir = $PSScriptRoot)

    $appRoot = Get-HeadlessSteamAppRoot -FromScriptDir $FromScriptDir
    return Join-Path $appRoot "moonlight-web\package"
}

function Get-HeadlessSteamMoonlightLogPath {
    param([string]$FromScriptDir = $PSScriptRoot)
    return Join-Path (Get-HeadlessSteamAppRoot -FromScriptDir $FromScriptDir) "moonlight-web.log.json"
}

function Write-HeadlessSteamMoonlightLog {
    param(
        [Parameter(Mandatory = $true)]
        $RunEntry,
        [string]$FromScriptDir = $PSScriptRoot,
        [int]$MaxRuns = 20
    )

    $logPath = Get-HeadlessSteamMoonlightLogPath -FromScriptDir $FromScriptDir
    $runs = @()

    if (Test-Path -LiteralPath $logPath) {
        try {
            $existing = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $existing.runs) {
                $runs = @($existing.runs)
            }
        } catch {
        }
    }

    $runs += ,$RunEntry
    if ($runs.Count -gt $MaxRuns) {
        $runs = @($runs | Select-Object -Last $MaxRuns)
    }

    $document = [ordered]@{
        version   = 1
        logFile   = $logPath
        appRoot   = (Get-HeadlessSteamAppRoot -FromScriptDir $FromScriptDir)
        updatedAt = (Get-Date).ToUniversalTime().ToString("o")
        runs      = $runs
    }

    $json = $document | ConvertTo-Json -Depth 12
    $tempPath = "$logPath.tmp"
    [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $logPath) {
        Remove-Item -LiteralPath $logPath -Force
    }
    Move-Item -LiteralPath $tempPath -Destination $logPath -Force
    return $logPath
}

function Initialize-HeadlessSteamMoonlightRuntime {
    param([string]$FromScriptDir = $PSScriptRoot)

    $moonlightPkg = Get-HeadlessSteamMoonlightPackageDir -FromScriptDir $FromScriptDir
    $serverExe = Join-Path $moonlightPkg "web-server.exe"
    $configPath = Join-Path $moonlightPkg "server\config.json"
    $dataPath = Join-Path $moonlightPkg "server\data.json"
    $dataExample = Join-Path $moonlightPkg "server\data.json.example"
    $warnings = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path -LiteralPath $moonlightPkg)) {
        throw "Moonlight Web nao encontrado. Copie a pasta moonlight-web/ para: $(Split-Path -Parent $moonlightPkg)"
    }

    if (-not (Test-Path -LiteralPath $serverExe)) {
        throw "web-server.exe nao encontrado em $moonlightPkg"
    }

    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "config.json do Moonlight Web nao encontrado em $configPath"
    }

    if (-not (Test-Path -LiteralPath $dataPath)) {
        if (Test-Path -LiteralPath $dataExample) {
            Copy-Item -LiteralPath $dataExample -Destination $dataPath -Force
            $warnings.Add("data.json criado a partir de data.json.example")
        } else {
            throw "data.json nao encontrado em $dataPath"
        }
    }

    return [pscustomobject]@{
        PackageDir   = $moonlightPkg
        ServerExe    = $serverExe
        ConfigPath   = $configPath
        DataPath     = $dataPath
        Warnings     = @($warnings)
    }
}

function Get-HeadlessSteamTailscaleIPv4 {
    param([string]$PreferredIp = $null)

    if ($PreferredIp -match '^\d+\.\d+\.\d+\.\d+$') {
        return $PreferredIp
    }

    $tailscaleExe = "C:\Program Files\Tailscale\tailscale.exe"
    if (Test-Path -LiteralPath $tailscaleExe) {
        try {
            $output = & $tailscaleExe ip -4 2>&1
            foreach ($line in @($output)) {
                $candidate = [string]$line.Trim()
                if ($candidate -match '^\d+\.\d+\.\d+\.\d+$') {
                    return $candidate
                }
            }
        } catch {
        }
    }

    try {
        foreach ($addr in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
            $ip = [string]$addr.IPAddress
            if ($ip -match '^100\.') {
                return $ip
            }
            if ($addr.InterfaceAlias -match 'Tailscale' -and $ip -notmatch '^(127\.|169\.254\.)') {
                return $ip
            }
        }
    } catch {
    }

    return $null
}
