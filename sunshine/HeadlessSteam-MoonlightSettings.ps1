$script:HeadlessSteamMoonlightSettingsFile = Join-Path $env:APPDATA "HeadlessSteam\moonlight_settings.json"

function Get-HeadlessSteamTailscaleFunnelSetupUrl {
    $tailscaleScript = Join-Path $PSScriptRoot "HeadlessSteam-Tailscale.ps1"
    if (Test-Path -LiteralPath $tailscaleScript) {
        . $tailscaleScript
        if (Get-Command Get-HeadlessSteamTailscaleFunnelAclUrl -ErrorAction SilentlyContinue) {
            return Get-HeadlessSteamTailscaleFunnelAclUrl
        }
    }
    return "https://login.tailscale.com/admin/acls/file"
}

function Get-HeadlessSteamTailscaleFunnelAclSetupUrl {
    return Get-HeadlessSteamTailscaleFunnelSetupUrl
}

function Write-HeadlessSteamUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Repair-HeadlessSteamMoonlightConfigFile {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    if (-not (Test-Path $ConfigPath)) {
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($ConfigPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
        Write-HeadlessSteamUtf8NoBom -Path $ConfigPath -Content $text
    }
}

function Test-HeadlessSteamTailscaleFunnelAllowed {
    $tailscaleScript = Join-Path $PSScriptRoot "HeadlessSteam-Tailscale.ps1"
    if (Test-Path -LiteralPath $tailscaleScript) {
        . $tailscaleScript
    }

    if (Get-Command Test-HeadlessSteamTailscaleFunnelAllowedOnNode -ErrorAction SilentlyContinue) {
        return Test-HeadlessSteamTailscaleFunnelAllowedOnNode
    }

    $tailscaleExe = "C:\Program Files\Tailscale\tailscale.exe"
    if (-not (Test-Path $tailscaleExe)) {
        return $false
    }

    try {
        $status = & $tailscaleExe status --json 2>$null | ConvertFrom-Json
        if (-not $status -or -not $status.Self) {
            return $false
        }

        $caps = @($status.Self.Capabilities)
        if ($caps -contains "funnel") {
            return $true
        }

        if ($status.Self.CapMap -and ($status.Self.CapMap.PSObject.Properties.Name -contains "funnel")) {
            return $true
        }

        $capMap = $status.Self.CapMap
        if ($capMap -and ($capMap.PSObject.Properties | Where-Object { $_.Name -like '*funnel*' })) {
            return $true
        }
    } catch {
    }

    return $false
}

function Get-HeadlessSteamMoonlightSettingsPath {
    return $script:HeadlessSteamMoonlightSettingsFile
}

function Get-HeadlessSteamMoonlightSettings {
    $defaults = [ordered]@{
        public_funnel_enabled = $false
        skip_login_enabled    = $false
        skip_login_user_id    = $null
    }

    $path = Get-HeadlessSteamMoonlightSettingsPath
    if (-not (Test-Path $path)) {
        return [pscustomobject]$defaults
    }

    try {
        $raw = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{
            public_funnel_enabled = [bool]$raw.public_funnel_enabled
            skip_login_enabled    = [bool]$raw.skip_login_enabled
            skip_login_user_id    = if ($null -ne $raw.skip_login_user_id) { [string]$raw.skip_login_user_id } else { $null }
        }
    } catch {
        return [pscustomobject]$defaults
    }
}

function Set-HeadlessSteamMoonlightSettings {
    param(
        [bool]$PublicFunnelEnabled,
        [bool]$SkipLoginEnabled,
        [string]$SkipLoginUserId
    )

    $path = Get-HeadlessSteamMoonlightSettingsPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $payload = [ordered]@{
        public_funnel_enabled = $PublicFunnelEnabled
        skip_login_enabled    = $SkipLoginEnabled
        skip_login_user_id    = if ($SkipLoginEnabled -and $SkipLoginUserId) { $SkipLoginUserId } else { $null }
    }

    $payload | ConvertTo-Json -Compress | ForEach-Object {
        Write-HeadlessSteamUtf8NoBom -Path $path -Content $_
    }
}

function Get-HeadlessSteamMoonlightConfigPath {
    param([string]$ScriptDir = $PSScriptRoot)

    . (Join-Path $ScriptDir "HeadlessSteam-Paths.ps1")
    $moonlightPkg = Get-HeadlessSteamMoonlightPackageDir -FromScriptDir $ScriptDir
    return Join-Path $moonlightPkg "server\config.json"
}

function Set-HeadlessSteamMoonlightSkipLogin {
    param(
        [bool]$Enabled,
        [string]$UserId = $null,
        [string]$ScriptDir = $PSScriptRoot
    )

    $configPath = Get-HeadlessSteamMoonlightConfigPath -ScriptDir $ScriptDir
    if (-not (Test-Path $configPath)) {
        throw "config.json do Moonlight Web nao encontrado em $configPath"
    }

    Repair-HeadlessSteamMoonlightConfigFile -ConfigPath $configPath

    $config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $config.web_server) {
        $config | Add-Member -NotePropertyName web_server -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    if ($Enabled -and $UserId) {
        $config.web_server.default_user_id = [long]$UserId
    } else {
        $config.web_server.default_user_id = $null
    }

    $config | ConvertTo-Json -Depth 20 | ForEach-Object {
        Write-HeadlessSteamUtf8NoBom -Path $configPath -Content $_
    }
}

function Get-HeadlessSteamMoonlightDataPath {
    param([string]$ScriptDir = $PSScriptRoot)

    . (Join-Path $ScriptDir "HeadlessSteam-Paths.ps1")
    $moonlightPkg = Get-HeadlessSteamMoonlightPackageDir -FromScriptDir $ScriptDir
    return Join-Path $moonlightPkg "server\data.json"
}

function Get-HeadlessSteamMoonlightUserCount {
    param([string]$ScriptDir = $PSScriptRoot)

    $dataPath = Get-HeadlessSteamMoonlightDataPath -ScriptDir $ScriptDir
    if (-not (Test-Path $dataPath)) {
        return 0
    }

    try {
        $data = Get-Content $dataPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $data.users) {
            return 0
        }
        return @($data.users.PSObject.Properties).Count
    } catch {
        return 0
    }
}

function Repair-HeadlessSteamMoonlightSecuritySettings {
    param([string]$ScriptDir = $PSScriptRoot)

    $settings = Get-HeadlessSteamMoonlightSettings
    $userCount = Get-HeadlessSteamMoonlightUserCount -ScriptDir $ScriptDir
    $changed = $false

    if ($settings.public_funnel_enabled -and $userCount -le 0) {
        $settings.public_funnel_enabled = $false
        $changed = $true
    }

    if ($settings.public_funnel_enabled -and $settings.skip_login_enabled) {
        $settings.skip_login_enabled = $false
        $settings.skip_login_user_id = $null
        $changed = $true
    }

    if ($changed) {
        Set-HeadlessSteamMoonlightSettings `
            -PublicFunnelEnabled $settings.public_funnel_enabled `
            -SkipLoginEnabled $settings.skip_login_enabled `
            -SkipLoginUserId $settings.skip_login_user_id
    }

    return $settings
}

function Apply-HeadlessSteamMoonlightSettings {
    param([string]$ScriptDir = $PSScriptRoot)

    $settings = Repair-HeadlessSteamMoonlightSecuritySettings -ScriptDir $ScriptDir
    Set-HeadlessSteamMoonlightSkipLogin `
        -Enabled $settings.skip_login_enabled `
        -UserId $settings.skip_login_user_id `
        -ScriptDir $ScriptDir
}

function Test-HeadlessSteamMoonlightFunnelAllowed {
    param([string]$ScriptDir = $PSScriptRoot)

    if ((Get-HeadlessSteamMoonlightUserCount -ScriptDir $ScriptDir) -le 0) {
        return $false
    }

    return $true
}

function Get-HeadlessSteamMoonlightFunnelUrl {
    $tailscaleScript = Join-Path $PSScriptRoot "HeadlessSteam-Tailscale.ps1"
    if (Test-Path -LiteralPath $tailscaleScript) {
        . $tailscaleScript
    }

    if (Get-Command Get-HeadlessSteamTailscalePublicFunnelUrl -ErrorAction SilentlyContinue) {
        return Get-HeadlessSteamTailscalePublicFunnelUrl
    }

    return $null
}

function Test-HeadlessSteamMoonlightFunnelActive {
    return $null -ne (Get-HeadlessSteamMoonlightFunnelUrl)
}
