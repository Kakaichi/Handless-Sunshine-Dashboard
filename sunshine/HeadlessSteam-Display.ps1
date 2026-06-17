. "$PSScriptRoot\Sunshine-Config.ps1"
. "$PSScriptRoot\HeadlessSteam-VirtualDisplay.ps1"

$script:HeadlessSteamSunshineDxgiInfo = Join-Path ${env:ProgramFiles} "Sunshine\tools\dxgi-info.exe"
$script:HeadlessSteamVirtualOutputNamePattern = '(?i)Virtual|MttVDD|IddSample|SunshineHDR|VirtualDisplay|\bVDD\b|MTT'

function Set-SunshineConfValue {
    param(
        [Parameter(Mandatory = $true)][string]$SunshineConf,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $configDir = Split-Path -Parent $SunshineConf
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    }

    $lines = @()
    if (Test-Path -LiteralPath $SunshineConf) {
        $lines = @(Get-Content -Path $SunshineConf -ErrorAction SilentlyContinue)
    }

    $pattern = "^\s*$([regex]::Escape($Key))\s*="
    $found = $false
    $lines = @($lines | ForEach-Object {
        if ($_ -match $pattern) {
            $found = $true
            "$Key = $Value"
        } else {
            $_
        }
    })

    if (-not $found) {
        $lines += "$Key = $Value"
    }

    $lines | Set-Content -Path $SunshineConf -Encoding UTF8
}

function Get-SunshineConfValue {
    param(
        [Parameter(Mandatory = $true)][string]$SunshineConf,
        [Parameter(Mandatory = $true)][string]$Key
    )

    if (-not (Test-Path -LiteralPath $SunshineConf)) {
        return $null
    }

    $pattern = "^\s*$([regex]::Escape($Key))\s*=\s*(.+)\s*$"
    foreach ($line in (Get-Content -Path $SunshineConf -ErrorAction SilentlyContinue)) {
        if ($line -match $pattern) {
            return $Matches[1].Trim().Trim('"')
        }
    }
    return $null
}

function Invoke-HeadlessSteamSunshineDxgiInfo {
    if (-not (Test-Path -LiteralPath $script:HeadlessSteamSunshineDxgiInfo)) {
        return $null
    }

    try {
        $stdout = & $script:HeadlessSteamSunshineDxgiInfo 2>&1
        return ($stdout | Out-String)
    } catch {
        return $null
    }
}

function Get-HeadlessSteamSunshineLogPath {
    $path = Join-Path ${env:ProgramFiles} "Sunshine\config\sunshine.log"
    if (Test-Path -LiteralPath $path) {
        return $path
    }
    return $null
}

function Get-HeadlessSteamSunshineDisplayDevicesFromLog {
    $logPath = Get-HeadlessSteamSunshineLogPath
    if (-not $logPath) {
        return @()
    }

    try {
        $content = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
    } catch {
        return @()
    }

    $pattern = 'Currently available display devices:\s*\r?\n(\[\s*\{[\s\S]*?\}\s*\])'
    $matches = [regex]::Matches($content, $pattern)
    if ($matches.Count -eq 0) {
        return @()
    }

    try {
        return @((ConvertFrom-Json -InputObject $matches[$matches.Count - 1].Groups[1].Value))
    } catch {
        return @()
    }
}

function Get-HeadlessSteamVirtualSunshineDeviceId {
    param([switch]$RefreshLog)

    if ($RefreshLog) {
        Invoke-HeadlessSteamSunshineDxgiInfo | Out-Null
        Start-Sleep -Milliseconds 500
    }

    $virtualMonitor = Get-HeadlessSteamVirtualMonitorBounds
    $devices = @(Get-HeadlessSteamSunshineDisplayDevicesFromLog)
    if ($devices.Count -eq 0) {
        return Get-HeadlessSteamVirtualDeviceGuidFromDxgi
    }

    foreach ($device in $devices) {
        $deviceId = [string]$device.device_id
        if (-not ($deviceId -match '^\{')) {
            continue
        }

        $displayName = [string]$device.display_name
        if ($virtualMonitor -and $displayName -and $displayName -eq $virtualMonitor.device) {
            return $deviceId
        }
    }

    foreach ($device in $devices) {
        $deviceId = [string]$device.device_id
        if (-not ($deviceId -match '^\{')) {
            continue
        }

        $friendlyName = [string]$device.friendly_name
        if ($friendlyName -match $script:HeadlessSteamVirtualOutputNamePattern) {
            return $deviceId
        }
    }

    foreach ($device in $devices) {
        $deviceId = [string]$device.device_id
        if (-not ($deviceId -match '^\{')) {
            continue
        }
        if ($device.info -and -not $device.info.primary) {
            $friendlyName = [string]$device.friendly_name
            if ($friendlyName -match $script:HeadlessSteamVirtualOutputNamePattern) {
                return $deviceId
            }
        }
    }

    $fromDxgi = Get-HeadlessSteamVirtualDeviceGuidFromDxgi
    if ($fromDxgi) {
        return $fromDxgi
    }

    return $null
}

function Normalize-HeadlessSteamDisplayDeviceName {
    param([string]$Name)

    if (-not $Name) {
        return ""
    }

    return ($Name -replace '\\\\+', '\').Trim()
}

function Find-HeadlessSteamSunshineDeviceGuidInLog {
    param(
        [string]$DisplayName,
        [switch]$PreferVirtualPattern
    )

    $targetDisplay = Normalize-HeadlessSteamDisplayDeviceName $DisplayName
    foreach ($device in @(Get-HeadlessSteamSunshineDisplayDevicesFromLog)) {
        $deviceId = [string]$device.device_id
        if ($deviceId -notmatch '^\{') {
            continue
        }

        $dn = Normalize-HeadlessSteamDisplayDeviceName ([string]$device.display_name)
        if ($targetDisplay -and $dn -and $dn -eq $targetDisplay) {
            return $deviceId
        }

        if ($PreferVirtualPattern -or -not $targetDisplay) {
            $friendlyName = [string]$device.friendly_name
            if ($friendlyName -match $script:HeadlessSteamVirtualOutputNamePattern) {
                return $deviceId
            }
        }
    }

    return $null
}

function Wait-HeadlessSteamSunshineDeviceGuid {
    param(
        [string]$DisplayName,
        [int]$TimeoutSec = 45
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $guid = Find-HeadlessSteamSunshineDeviceGuidInLog -DisplayName $DisplayName
        if ($guid) {
            return $guid
        }

        $guid = Find-HeadlessSteamSunshineDeviceGuidInLog -PreferVirtualPattern
        if ($guid) {
            foreach ($device in @(Get-HeadlessSteamSunshineDisplayDevicesFromLog)) {
                if ([string]$device.device_id -ne $guid) {
                    continue
                }
                $dn = Normalize-HeadlessSteamDisplayDeviceName ([string]$device.display_name)
                $targetDisplay = Normalize-HeadlessSteamDisplayDeviceName $DisplayName
                if ($targetDisplay -and $dn -and $dn -ne $targetDisplay) {
                    break
                }
                if ($device.info -and $device.info.primary) {
                    break
                }
                return $guid
            }
        }

        Start-Sleep -Milliseconds 750
    }

    return $null
}

function Invoke-HeadlessSteamSunshineDisplayEnumeration {
    $svc = Get-Service -Name "SunshineService" -ErrorAction SilentlyContinue
    if (-not $svc) {
        return $false
    }

    Restart-HeadlessSteamSunshineService | Out-Null
    return $true
}

function Resolve-HeadlessSteamVirtualSunshineOutputName {
    $virtualMonitor = Get-HeadlessSteamVirtualMonitorBounds
    $targetDisplay = if ($virtualMonitor) { [string]$virtualMonitor.device } else { $null }

    $guid = Find-HeadlessSteamSunshineDeviceGuidInLog -DisplayName $targetDisplay
    if ($guid) {
        return $guid
    }

    $guid = Resolve-HeadlessSteamVirtualSunshineDeviceId
    if ($guid -match '^\{') {
        return $guid
    }

    $guid = Get-HeadlessSteamVirtualDeviceGuidFromDxgi
    if ($guid -match '^\{') {
        return $guid
    }

    if (Invoke-HeadlessSteamSunshineDisplayEnumeration) {
        $guid = Wait-HeadlessSteamSunshineDeviceGuid -DisplayName $targetDisplay
        if ($guid) {
            return $guid
        }
    }

    return $null
}

function Get-HeadlessSteamVirtualDeviceGuidFromDxgi {
    $output = Find-HeadlessSteamVirtualDisplayOutput
    if (-not $output) {
        return $null
    }

    $deviceId = [string]$output.device_id
    if ($deviceId -match '^\{') {
        return $deviceId
    }

    return $null
}

function Resolve-HeadlessSteamVirtualSunshineDeviceId {
    $virtualMonitor = Get-HeadlessSteamVirtualMonitorBounds
    $deviceId = Get-HeadlessSteamVirtualSunshineDeviceId
    if ($deviceId -and $virtualMonitor) {
        foreach ($device in @(Get-HeadlessSteamSunshineDisplayDevicesFromLog)) {
            if ([string]$device.device_id -ne $deviceId) {
                continue
            }
            $displayName = [string]$device.display_name
            if ($displayName -and $displayName -ne $virtualMonitor.device) {
                $deviceId = $null
            }
            break
        }
    }

    if (-not $deviceId) {
        $deviceId = Get-HeadlessSteamVirtualSunshineDeviceId -RefreshLog
    }

    if (-not $deviceId) {
        $deviceId = Get-HeadlessSteamVirtualDeviceGuidFromDxgi
    }

    return $deviceId
}

function ConvertFrom-HeadlessSteamDxgiInfoText {
    param([string]$Text)

    if (-not $Text) {
        return @()
    }

    $adapters = New-Object System.Collections.Generic.List[object]
    $currentAdapter = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*====== ADAPTER =====') {
            if ($currentAdapter) {
                $adapters.Add($currentAdapter)
            }
            $currentAdapter = [ordered]@{
                adapter_name = ""
                outputs      = New-Object System.Collections.Generic.List[object]
            }
            continue
        }

        if (-not $currentAdapter) { continue }

        if ($line -match '^\s*Device Name\s*:\s*(.+)\s*$') {
            $currentAdapter.adapter_name = $Matches[1].Trim()
            continue
        }

        if ($line -match '^\s*Output Name\s*:\s*(.+)\s*$') {
            $outputName = $Matches[1].Trim()
            $currentAdapter.outputs.Add([ordered]@{
                display_name  = $outputName
                device_id     = $outputName
                friendly_name = $outputName
                adapter_name  = [string]$currentAdapter.adapter_name
                primary       = $false
            }) | Out-Null
            continue
        }

        if ($line -match '^\s*Friendly Name\s*:\s*(.+)\s*$') {
            if ($currentAdapter.outputs.Count -gt 0) {
                $last = $currentAdapter.outputs[$currentAdapter.outputs.Count - 1]
                $last.friendly_name = $Matches[1].Trim()
            }
        }
    }

    if ($currentAdapter) {
        $adapters.Add($currentAdapter)
    }

    return [object[]]$adapters.ToArray()
}

function ConvertFrom-HeadlessSteamDxgiInfoJson {
    param([string]$Text)

    $trim = $Text.Trim()
    if (-not ($trim.StartsWith("{") -or $trim.StartsWith("["))) {
        return $null
    }

    try {
        return ConvertFrom-Json -InputObject $trim
    } catch {
        return $null
    }
}

function Get-HeadlessSteamSunshineDxgiOutputs {
    $raw = Invoke-HeadlessSteamSunshineDxgiInfo
    if (-not $raw) {
        return @()
    }

    $json = ConvertFrom-HeadlessSteamDxgiInfoJson -Text $raw
    if ($json) {
        $flat = New-Object System.Collections.Generic.List[object]
        foreach ($adapter in @($json)) {
            $adapterName = [string]$adapter.adapter_name
            if ($adapterName -and $adapter.outputs) {
                foreach ($output in $adapter.outputs) {
                    $flat.Add([pscustomobject]@{
                        adapter_name  = $adapterName
                        device_id     = [string]$output.device_id
                        display_name  = [string]$output.display_name
                        friendly_name = [string]$output.friendly_name
                        primary       = [bool]$output.info.primary
                    }) | Out-Null
                }
                continue
            }
            if ($json -is [System.Array]) {
                foreach ($item in @($json)) {
                    if ($item.device_id -or $item.display_name) {
                        $flat.Add([pscustomobject]@{
                            adapter_name  = [string]$item.adapter_name
                            device_id     = [string]$item.device_id
                            display_name  = [string]$item.display_name
                            friendly_name = [string]$item.friendly_name
                            primary       = [bool]$item.info.primary
                        }) | Out-Null
                    }
                }
            }
        }
        if ($flat.Count -gt 0) {
            return [object[]]$flat.ToArray()
        }
    }

    $adapters = ConvertFrom-HeadlessSteamDxgiInfoText -Text $raw
    $flat = New-Object System.Collections.Generic.List[object]
    foreach ($adapter in $adapters) {
        foreach ($output in $adapter.outputs) {
            $flat.Add([pscustomobject]@{
                adapter_name  = [string]$adapter.adapter_name
                device_id     = [string]$output.device_id
                display_name  = [string]$output.display_name
                friendly_name = [string]$output.friendly_name
                primary       = [bool]$output.primary
            }) | Out-Null
        }
    }
    $outputs = [object[]]$flat.ToArray()
    $primaryDevices = @{}
    foreach ($monitor in Get-HeadlessSteamMonitorLayout) {
        if ($monitor.primary) {
            $primaryDevices[[string]$monitor.device_name] = $true
        }
    }
    foreach ($output in $outputs) {
        $displayName = [string]$output.display_name
        if ($primaryDevices.ContainsKey($displayName)) {
            $output.primary = $true
        }
    }
    return $outputs
}

function Get-HeadlessSteamMonitorLayout {
    Ensure-HeadlessSteamMonitorEnum

    $monitors = [HeadlessSteamMonitorEnum]::GetMonitors()
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($info in $monitors) {
        $isPrimary = (($info.dwFlags -band [HeadlessSteamMonitorEnum]::MONITORINFOF_PRIMARY) -ne 0)
        $result.Add([pscustomobject]@{
            device_name = [string]$info.szDevice
            primary     = $isPrimary
            left        = [int]$info.rcMonitor.Left
            top         = [int]$info.rcMonitor.Top
            right       = [int]$info.rcMonitor.Right
            bottom      = [int]$info.rcMonitor.Bottom
            width       = [int]($info.rcMonitor.Right - $info.rcMonitor.Left)
            height      = [int]($info.rcMonitor.Bottom - $info.rcMonitor.Top)
        }) | Out-Null
    }
    return [object[]]$result.ToArray()
}

function Ensure-HeadlessSteamExtendedDesktop {
    $displaySwitch = Join-Path $env:Windir "System32\DisplaySwitch.exe"
    if (Test-Path -LiteralPath $displaySwitch) {
        Start-Process -FilePath $displaySwitch -ArgumentList "/extend" -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 2
    }
    return (Get-HeadlessSteamConnectedMonitorCount -ge 2)
}

function Wait-HeadlessSteamVirtualDisplayReady {
    param(
        [int]$TimeoutSec = 45,
        [int]$PollMs = 1500
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    Enable-HeadlessSteamVirtualDisplay | Out-Null
    while ((Get-Date) -lt $deadline) {
        Ensure-HeadlessSteamExtendedDesktop | Out-Null
        if (Test-HeadlessSteamVirtualDisplayReady) {
            return $true
        }
        Start-Sleep -Milliseconds $PollMs
    }

    return [bool](Test-HeadlessSteamVirtualDisplayReady)
}

$script:HeadlessSteamSavedPrimaryDevice = $null

function Get-HeadlessSteamMultiMonitorToolPath {
    @(
        (Join-Path $PSScriptRoot "tools\MultiMonitorTool.exe"),
        (Join-Path ${env:ProgramFiles} "Sunshine\tools\MultiMonitorTool.exe"),
        (Join-Path ${env:ProgramFiles} "Sunshine\tools\multimonitortool.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "NirSoft\MultiMonitorTool\MultiMonitorTool.exe")
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

function Set-HeadlessSteamPrimaryDisplayDevice {
    param([Parameter(Mandatory = $true)][string]$DeviceName)

    $mmt = Get-HeadlessSteamMultiMonitorToolPath
    if ($mmt) {
        & $mmt /SetPrimary $DeviceName 2>&1 | Out-Null
        Start-Sleep -Milliseconds 800
        $now = (Get-HeadlessSteamMonitorLayout | Where-Object primary | Select-Object -First 1).device_name
        return ([string]$now -eq $DeviceName)
    }

    return (Set-HeadlessSteamPrimaryDisplayViaChangeDisplaySettings -NewPrimaryDevice $DeviceName)
}

function Set-HeadlessSteamPrimaryDisplayViaChangeDisplaySettings {
    param([Parameter(Mandatory = $true)][string]$NewPrimaryDevice)

    Ensure-HeadlessSteamDisplaySettingsApi
    $monitors = @(Get-HeadlessSteamMonitorLayout)
    $oldPrimary = $monitors | Where-Object primary | Select-Object -First 1
    if (-not $oldPrimary) {
        return $false
    }

    $newPrimaryMonitor = $monitors | Where-Object { [string]$_.device_name -eq $NewPrimaryDevice } | Select-Object -First 1
    if (-not $newPrimaryMonitor) {
        return $false
    }

    $anchorX = [int]$newPrimaryMonitor.left
    $anchorY = [int]$newPrimaryMonitor.top
    $allOk = $true

    foreach ($m in $monitors) {
        $devMode = New-Object HeadlessSteamDisplaySettings+DEVMODE
        $devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($devMode)
        if (-not [HeadlessSteamDisplaySettings]::EnumDisplaySettings(
                $m.device_name,
                [HeadlessSteamDisplaySettings]::ENUM_CURRENT_SETTINGS,
                [ref]$devMode)) {
            $allOk = $false
            continue
        }

        $newX = [int]$m.left - $anchorX
        $newY = [int]$m.top - $anchorY
        if ([string]$m.device_name -eq $NewPrimaryDevice) {
            $newX = 0
            $newY = 0
        }

        $devMode.dmPositionX = $newX
        $devMode.dmPositionY = $newY
        $devMode.dmFields = [HeadlessSteamDisplaySettings]::DM_POSITION

        $flags = [HeadlessSteamDisplaySettings]::CDS_UPDATEREGISTRY -bor [HeadlessSteamDisplaySettings]::CDS_NORESET
        if ([string]$m.device_name -eq $NewPrimaryDevice) {
            $flags = $flags -bor [HeadlessSteamDisplaySettings]::CDS_SET_PRIMARY
        }

        $rc = [HeadlessSteamDisplaySettings]::ChangeDisplaySettingsEx(
            $m.device_name, [ref]$devMode, [IntPtr]::Zero, $flags, [IntPtr]::Zero)
        if ($rc -ne [HeadlessSteamDisplaySettings]::DISP_CHANGE_SUCCESSFUL) {
            $allOk = $false
        }
    }

    $rc = [HeadlessSteamDisplaySettings]::CommitDisplayChanges()
    Start-Sleep -Milliseconds 500

    $now = (Get-HeadlessSteamMonitorLayout | Where-Object primary | Select-Object -First 1).device_name
    return ([string]$now -eq $NewPrimaryDevice) -and $allOk -and ($rc -eq 0 -or $rc -eq 1)
}

function Enable-HeadlessSteamVirtualPrimaryForGame {
    if ($script:HeadlessSteamSavedPrimaryDevice) {
        return $true
    }

    $physical = Get-HeadlessSteamMonitorLayout | Where-Object primary | Select-Object -First 1
    $virtual = Get-HeadlessSteamVirtualMonitorBounds
    if (-not $physical -or -not $virtual) {
        return $false
    }

    if ([string]$physical.device_name -eq [string]$virtual.device) {
        return $true
    }

    $ok = Set-HeadlessSteamPrimaryDisplayDevice -DeviceName $virtual.device
    if ($ok) {
        $script:HeadlessSteamSavedPrimaryDevice = [string]$physical.device_name
    }
    return $ok
}

function Restore-HeadlessSteamPhysicalPrimaryAfterGame {
    if (-not $script:HeadlessSteamSavedPrimaryDevice) {
        return $false
    }

    $physicalDevice = [string]$script:HeadlessSteamSavedPrimaryDevice
    $script:HeadlessSteamSavedPrimaryDevice = $null
    return (Set-HeadlessSteamPrimaryDisplayDevice -DeviceName $physicalDevice)
}

function Find-HeadlessSteamVirtualDisplayOutput {
    $outputs = @(Get-HeadlessSteamSunshineDxgiOutputs)
    if ($outputs.Count -eq 0) {
        return $null
    }

    foreach ($output in $outputs) {
        $label = "$($output.friendly_name) $($output.display_name) $($output.adapter_name)"
        if ($label -match $script:HeadlessSteamVirtualOutputNamePattern -and -not $output.primary) {
            return $output
        }
    }

    $monitors = @(Get-HeadlessSteamMonitorLayout)
    $nonPrimaryDevices = @($monitors | Where-Object { -not $_.primary } | ForEach-Object { $_.device_name })
    if ($nonPrimaryDevices.Count -gt 0) {
        foreach ($output in $outputs) {
            $displayName = [string]$output.display_name
            foreach ($deviceName in $nonPrimaryDevices) {
                if ($displayName -and $deviceName -and $displayName -eq $deviceName) {
                    if ($output.adapter_name -notmatch '(?i)Basic Render') {
                        return $output
                    }
                }
            }
        }

        foreach ($output in $outputs) {
            if (-not $output.primary -and $output.adapter_name -notmatch '(?i)Basic Render') {
                return $output
            }
        }
    }

    return $null
}

function Find-HeadlessSteamPhysicalDisplayOutput {
    $outputs = @(Get-HeadlessSteamSunshineDxgiOutputs)
    if ($outputs.Count -eq 0) {
        return $null
    }

    foreach ($output in $outputs) {
        if (-not $output.primary) {
            continue
        }
        $label = "$($output.friendly_name) $($output.display_name) $($output.adapter_name)"
        if ($label -match $script:HeadlessSteamVirtualOutputNamePattern) {
            continue
        }
        if ($output.adapter_name -match '(?i)Basic Render') {
            continue
        }
        return $output
    }

    foreach ($output in $outputs) {
        $label = "$($output.friendly_name) $($output.display_name) $($output.adapter_name)"
        if ($label -match $script:HeadlessSteamVirtualOutputNamePattern) {
            continue
        }
        if ($output.adapter_name -match '(?i)Basic Render') {
            continue
        }
        return $output
    }

    return $null
}

function Restore-HeadlessSteamPhysicalPrimaryIfNeeded {
    $virtualDevice = Get-HeadlessSteamVirtualMonitorDeviceName
    if (-not $virtualDevice) {
        return $false
    }

    $primary = Get-HeadlessSteamMonitorLayout | Where-Object primary | Select-Object -First 1
    if (-not $primary -or [string]$primary.device_name -ne $virtualDevice) {
        return $false
    }

    $physical = Find-HeadlessSteamPhysicalDisplayOutput
    if (-not $physical -or -not $physical.display_name) {
        $physicalMonitor = Get-HeadlessSteamPhysicalMonitorSize
        if (-not $physicalMonitor) {
            return $false
        }
        return (Set-HeadlessSteamPrimaryDisplayDevice -DeviceName ([string]$physicalMonitor.device_name))
    }

    return (Set-HeadlessSteamPrimaryDisplayDevice -DeviceName ([string]$physical.display_name))
}

function Restore-HeadlessSteamPhysicalStreamDisplay {
    param([switch]$SkipSunshineRestart)

    $physical = Find-HeadlessSteamPhysicalDisplayOutput
    if (-not $physical) {
        return $false
    }

    $outputName = if ($physical.device_id) { [string]$physical.device_id } else { [string]$physical.display_name }
    if (-not $outputName) {
        return $false
    }

    $adapterName = [string]$physical.adapter_name
    $changed = Set-SunshineStreamDisplay -OutputName $outputName -AdapterName $adapterName
    if ($changed -and -not $SkipSunshineRestart) {
        Restart-HeadlessSteamSunshineService | Out-Null
    }
    return $changed
}

function Teardown-HeadlessSteamHostFreeMode {
    param(
        [switch]$ResyncGames,
        [switch]$RestartSunshine
    )

    Restore-HeadlessSteamPhysicalPrimaryIfNeeded | Out-Null
    Disable-HeadlessSteamVirtualDisplay | Out-Null

    $streamChanged = Restore-HeadlessSteamPhysicalStreamDisplay -SkipSunshineRestart
    if ($RestartSunshine -and -not $streamChanged) {
        Restart-HeadlessSteamSunshineService | Out-Null
    }

    . "$PSScriptRoot\HeadlessSteam-HostSettings.ps1"
    Update-HeadlessSteamHostSettings @{
        stream_output_device_id = $null
    } | Out-Null

    if ($ResyncGames) {
        $syncScript = Join-Path $PSScriptRoot "sync-steam-games.ps1"
        if (Test-Path -LiteralPath $syncScript) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $syncScript | Out-Null
        }
    }

    Write-Output "HOST_FREE_TEARDOWN:"
    return $true
}

function Ensure-HeadlessSteamNormalDisplayMode {
    param([switch]$SkipSunshineRestart)

    Restore-HeadlessSteamPhysicalPrimaryIfNeeded | Out-Null
    if (Test-HeadlessSteamVirtualDisplayDriverEnabled) {
        Disable-HeadlessSteamVirtualDisplay | Out-Null
    }

    if ($SkipSunshineRestart) {
        return $true
    }

    $virtualStream = $false
    foreach ($confPath in Get-HeadlessSteamSunshineConfPaths) {
        $current = Get-SunshineConfValue -SunshineConf $confPath -Key "output_name"
        if (-not $current) {
            continue
        }
        $settings = Get-HeadlessSteamHostSettings
        if ($settings.stream_output_device_id -and (
                $current -eq $settings.stream_output_device_id -or
                $current -eq "{$($settings.stream_output_device_id)}")) {
            $virtualStream = $true
            break
        }
    }

    if (-not $virtualStream) {
        return $true
    }

    Restore-HeadlessSteamPhysicalStreamDisplay | Out-Null
    return $true
}

function Get-HeadlessSteamVirtualMonitorBounds {
    $layout = @(Get-HeadlessSteamMonitorLayout)
    if ($layout.Count -eq 0) {
        return $null
    }

    $virtualDevice = Get-HeadlessSteamVirtualMonitorDeviceName
    $target = $null
    if ($virtualDevice) {
        $target = $layout | Where-Object { [string]$_.device_name -eq $virtualDevice } | Select-Object -First 1
    }

    if (-not $target) {
        $target = $layout | Where-Object { -not $_.primary } | Sort-Object { $_.left }, { $_.top } | Select-Object -First 1
    }

    if (-not $target) {
        return $null
    }

    return [pscustomobject]@{
        left   = [int]$target.left
        top    = [int]$target.top
        width  = [int]$target.width
        height = [int]$target.height
        right  = [int]$target.right
        bottom = [int]$target.bottom
        device = [string]$target.device_name
    }
}

function Get-HeadlessSteamSunshineConfPaths {
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($dir in Get-SunshineConfigDirectoryCandidates) {
        $conf = Join-Path $dir "sunshine.conf"
        if (Test-Path -LiteralPath $dir) {
            [void]$paths.Add($conf)
        }
    }

    $fallback = Join-Path ${env:ProgramFiles} "Sunshine\config\sunshine.conf"
    if (-not $paths.Contains($fallback)) {
        [void]$paths.Add($fallback)
    }

    return @($paths | Select-Object -Unique)
}

function Set-SunshineStreamDisplay {
    param(
        [Parameter(Mandatory = $true)][string]$OutputName,
        [string]$AdapterName = ""
    )

    $changed = $false
    foreach ($confPath in Get-HeadlessSteamSunshineConfPaths) {
        $configDir = Split-Path -Parent $confPath
        if (-not (Test-Path $configDir)) {
            New-Item -ItemType Directory -Force -Path $configDir | Out-Null
        }

        $previous = Get-SunshineConfValue -SunshineConf $confPath -Key "output_name"
        Set-SunshineConfValue -SunshineConf $confPath -Key "output_name" -Value $OutputName
        if ($previous -ne $OutputName) {
            $changed = $true
        }

        if ($AdapterName) {
            $prevAdapter = Get-SunshineConfValue -SunshineConf $confPath -Key "adapter_name"
            Set-SunshineConfValue -SunshineConf $confPath -Key "adapter_name" -Value $AdapterName
            if ($prevAdapter -ne $AdapterName) {
                $changed = $true
            }
        }
    }

    return $changed
}

function Test-HeadlessSteamStreamOutputConfigured {
    param([string]$ExpectedOutputName)

    $expectedGuid = Resolve-HeadlessSteamVirtualSunshineDeviceId
    if (-not $expectedGuid) {
        if (-not $ExpectedOutputName) {
            $virtual = Find-HeadlessSteamVirtualDisplayOutput
            if (-not $virtual) {
                return $false
            }
            $ExpectedOutputName = if ($virtual.device_id) { $virtual.device_id } else { $virtual.display_name }
        }
    } else {
        $ExpectedOutputName = $expectedGuid
    }

    foreach ($confPath in Get-HeadlessSteamSunshineConfPaths) {
        $current = Get-SunshineConfValue -SunshineConf $confPath -Key "output_name"
        if (-not $current) {
            continue
        }
        if ($current -eq $ExpectedOutputName -or $current -eq "{$ExpectedOutputName}") {
            return $true
        }
    }
    return $false
}

function Restart-HeadlessSteamSunshineService {
    $svc = Get-Service -Name "SunshineService" -ErrorAction SilentlyContinue
    if (-not $svc) {
        return $false
    }

    if ($svc.Status -eq "Running") {
        Restart-Service -Name "SunshineService" -Force -ErrorAction Stop
    } else {
        Start-Service -Name "SunshineService" -ErrorAction Stop
    }
    Start-Sleep -Seconds 4
    return $true
}

function Initialize-HeadlessSteamHostFreeMode {
    param(
        [switch]$InstallIfMissing,
        [switch]$ResyncGames
    )

    if (-not (Test-HeadlessSteamVirtualDisplayInstalled)) {
        if ($InstallIfMissing) {
            Install-HeadlessSteamVirtualDisplay | Out-Null
        } else {
            Write-Output "HOST_FREE_MISSING_VDD:"
            throw "Virtual Display Driver nao instalado."
        }
    }

    if (-not (Wait-HeadlessSteamVirtualDisplayReady)) {
        throw "Monitor virtual ainda nao apareceu. Aguarde alguns segundos e tente novamente."
    }

    if (-not (Set-HeadlessSteamVirtualDisplayResolution)) {
        Write-Output "AVISO: Nao foi possivel ajustar a resolucao do monitor virtual."
    }

    $virtualOutput = $null
    $outputName = Resolve-HeadlessSteamVirtualSunshineOutputName
    if ($outputName) {
        $virtualOutput = Find-HeadlessSteamVirtualDisplayOutput
        if (-not $virtualOutput) {
            $virtualMonitor = Get-HeadlessSteamVirtualMonitorBounds
            if ($virtualMonitor) {
                $virtualOutput = [pscustomobject]@{
                    display_name  = [string]$virtualMonitor.device
                    device_id     = $outputName
                    adapter_name  = ""
                    friendly_name = ""
                    primary       = $false
                }
            }
        }
    }

    if (-not $outputName) {
        $virtualOutput = Find-HeadlessSteamVirtualDisplayOutput
        if ($virtualOutput -and $virtualOutput.display_name) {
            throw ("Nao foi possivel obter o GUID do monitor virtual ($($virtualOutput.display_name)). " +
                "Verifique se o servico Sunshine esta instalado e em execucao.")
        }
        throw "Nao foi possivel identificar o monitor virtual. Verifique se o Sunshine esta em execucao."
    }

    $adapterName = [string]$virtualOutput.adapter_name
    if ($adapterName -match '(?i)Basic Render') {
        $discrete = @(Get-HeadlessSteamSunshineDxgiOutputs |
            Where-Object { $_.adapter_name -notmatch '(?i)Basic Render' } |
            Select-Object -ExpandProperty adapter_name -Unique | Select-Object -First 1)
        if ($discrete) {
            $adapterName = $discrete
        }
    }

    $changed = Set-SunshineStreamDisplay -OutputName $outputName -AdapterName $adapterName

    Write-Output "HOST_FREE_OUTPUT:$outputName"

    if ($ResyncGames) {
        $syncScript = Join-Path $PSScriptRoot "sync-steam-games.ps1"
        if (Test-Path -LiteralPath $syncScript) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $syncScript
        }
    }

    Write-Output "HOST_FREE_READY:"
    return [pscustomobject]@{
        OutputName  = $outputName
        AdapterName = $adapterName
        Changed     = $changed
    }
}

function Get-HeadlessSteamHostFreeStatus {
    param([switch]$Quick)

    . "$PSScriptRoot\HeadlessSteam-HostSettings.ps1"
    $settings = Get-HeadlessSteamHostSettings

    $installed = Test-HeadlessSteamVirtualDisplayInstalled
    $active = [bool](Test-HeadlessSteamVirtualDisplayReady)

    $virtualOutput = $null
    if ($active -and -not $Quick) {
        $virtualOutput = Find-HeadlessSteamVirtualDisplayOutput
    }

    $expectedOutput = if ($settings.stream_output_device_id) {
        $settings.stream_output_device_id
    } else {
        $sunshineDeviceId = Resolve-HeadlessSteamVirtualSunshineDeviceId
        if ($sunshineDeviceId) {
            $sunshineDeviceId
        } elseif ($virtualOutput) {
            if ($virtualOutput.device_id) { $virtualOutput.device_id } else { $virtualOutput.display_name }
        } else {
            $null
        }
    }

    $streamConfigured = $false
    if ($expectedOutput) {
        $streamConfigured = Test-HeadlessSteamStreamOutputConfigured -ExpectedOutputName $expectedOutput
    }

    $message = if (-not $installed) {
        "Instale o Virtual Display Driver."
    } elseif (-not $active) {
        "Monitor virtual inativo. Clique em Configurar para ativar."
    } elseif (-not $streamConfigured) {
        "Configure o Sunshine para o monitor virtual."
    } else {
        "Pronto para jogar na tela virtual."
    }

    $ready = $settings.host_free_mode_enabled -and $installed -and $active -and $streamConfigured

    return [pscustomobject]@{
        HostFreeModeEnabled      = [bool]$settings.host_free_mode_enabled
        VirtualDisplayInstalled  = $installed
        VirtualDisplayActive     = $active
        StreamOutputConfigured   = $streamConfigured
        HostFreeReady            = $ready
        HostFreeStatusMessage    = $message
        StreamOutputDeviceId     = $expectedOutput
        HostFreeRebootRequired   = $false
    }
}
