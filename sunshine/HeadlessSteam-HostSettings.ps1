$script:HeadlessSteamHostSettingsFile = Join-Path $env:APPDATA "HeadlessSteam\host_settings.json"

function Write-HeadlessSteamHostSettingsUtf8 {
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

function Get-HeadlessSteamHostSettings {
    $defaults = [ordered]@{
        host_free_mode_enabled     = $false
        keep_focus_enabled         = $false
        keep_remote_input_enabled  = $true
        stream_output_device_id    = $null
    }

    if (-not (Test-Path -LiteralPath $script:HeadlessSteamHostSettingsFile)) {
        return [pscustomobject]$defaults
    }

    try {
        $data = Get-Content -LiteralPath $script:HeadlessSteamHostSettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return [pscustomobject]$defaults
    }

    return [pscustomobject]@{
        host_free_mode_enabled     = [bool]$data.host_free_mode_enabled
        keep_focus_enabled         = [bool]$data.keep_focus_enabled
        keep_remote_input_enabled  = if ($null -ne $data.PSObject.Properties['keep_remote_input_enabled']) {
            [bool]$data.keep_remote_input_enabled
        } else {
            $true
        }
        stream_output_device_id    = if ($data.stream_output_device_id) { [string]$data.stream_output_device_id } else { $null }
    }
}

function Set-HeadlessSteamHostSettings {
    param(
        [bool]$HostFreeModeEnabled,
        [bool]$KeepFocusEnabled,
        [bool]$KeepRemoteInputEnabled = $true,
        [string]$StreamOutputDeviceId = $null
    )

    $payload = [ordered]@{
        host_free_mode_enabled     = [bool]$HostFreeModeEnabled
        keep_focus_enabled         = [bool]$KeepFocusEnabled
        keep_remote_input_enabled  = [bool]$KeepRemoteInputEnabled
        stream_output_device_id    = if ($StreamOutputDeviceId) { $StreamOutputDeviceId } else { $null }
    }

    $json = ($payload | ConvertTo-Json -Depth 4)
    Write-HeadlessSteamHostSettingsUtf8 -Path $script:HeadlessSteamHostSettingsFile -Content $json
    return [pscustomobject]$payload
}

function Update-HeadlessSteamHostSettings {
    param([hashtable]$Updates)

    $current = Get-HeadlessSteamHostSettings
    $hostFree = if ($Updates.ContainsKey("host_free_mode_enabled")) {
        [bool]$Updates.host_free_mode_enabled
    } else {
        [bool]$current.host_free_mode_enabled
    }

    $keepFocus = if ($Updates.ContainsKey("keep_focus_enabled")) {
        [bool]$Updates.keep_focus_enabled
    } elseif ($hostFree) {
        $false
    } else {
        [bool]$current.keep_focus_enabled
    }

    $keepRemote = if ($Updates.ContainsKey("keep_remote_input_enabled")) {
        [bool]$Updates.keep_remote_input_enabled
    } else {
        [bool]$current.keep_remote_input_enabled
    }

    $streamOutput = if ($Updates.ContainsKey("stream_output_device_id")) {
        $Updates.stream_output_device_id
    } else {
        $current.stream_output_device_id
    }

    return Set-HeadlessSteamHostSettings `
        -HostFreeModeEnabled $hostFree `
        -KeepFocusEnabled $keepFocus `
        -KeepRemoteInputEnabled $keepRemote `
        -StreamOutputDeviceId $streamOutput
}

function Test-HeadlessSteamHostFreeModeEnabled {
    return [bool](Get-HeadlessSteamHostSettings).host_free_mode_enabled
}

function Test-HeadlessSteamHostFreeAutoSetupOnStart {
    return Test-HeadlessSteamHostFreeModeEnabled
}
