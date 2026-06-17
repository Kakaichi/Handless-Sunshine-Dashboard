$script:HeadlessSteamVirtualDisplayWingetId = "VirtualDrivers.Virtual-Display-Driver"
$script:HeadlessSteamVirtualDisplaySettingsPath = "C:\VirtualDisplayDriver\vdd_settings.xml"
$script:HeadlessSteamVirtualDisplayNamePattern = '(?i)Virtual Display|MttVDD|IddSample|VirtualDisplay'

function Get-HeadlessSteamVirtualDisplayPnpDevices {
    return @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -match $script:HeadlessSteamVirtualDisplayNamePattern })
}

function Test-HeadlessSteamVirtualDisplayInstalled {
    return (@(Get-HeadlessSteamVirtualDisplayPnpDevices)).Count -gt 0
}

function Test-HeadlessSteamVirtualDisplayDriverEnabled {
    $devices = @(Get-HeadlessSteamVirtualDisplayPnpDevices)
    if ($devices.Count -eq 0) {
        return $false
    }
    return (@($devices | Where-Object { $_.Status -eq "OK" })).Count -gt 0
}

function Get-HeadlessSteamVirtualDisplayWingetPackageRoot {
    $wingetPackages = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    if (-not (Test-Path -LiteralPath $wingetPackages)) {
        return $null
    }

    $match = Get-ChildItem -LiteralPath $wingetPackages -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "VirtualDrivers.Virtual-Display-Driver*" } |
        Select-Object -First 1
    if ($match) {
        return $match.FullName
    }
    return $null
}

function Bootstrap-HeadlessSteamVirtualDisplaySettingsDir {
    param([string]$PkgRoot)

    $destDir = Split-Path -Parent $script:HeadlessSteamVirtualDisplaySettingsPath
    $dest = $script:HeadlessSteamVirtualDisplaySettingsPath
    if (Test-Path -LiteralPath $dest) {
        return $true
    }

    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $candidates = @(
        (Join-Path $PkgRoot "Dependencies\vdd_settings.xml"),
        (Join-Path $PkgRoot "SignedDrivers\x86\VDD\vdd_settings.xml")
    )
    foreach ($src in $candidates) {
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $dest -Force
            return $true
        }
    }
    return $false
}

function Register-HeadlessSteamVirtualDisplayDevice {
    if (Test-HeadlessSteamVirtualDisplayInstalled) {
        return $true
    }

    $pkgRoot = Get-HeadlessSteamVirtualDisplayWingetPackageRoot
    if (-not $pkgRoot) {
        throw "Pacote VDD do winget nao encontrado. Execute a instalacao novamente."
    }

    $devcon = Join-Path $pkgRoot "Dependencies\devcon.exe"
    $driverDir = Join-Path $pkgRoot "SignedDrivers\x86\VDD"
    $inf = Join-Path $driverDir "MttVDD.inf"
    if (-not (Test-Path -LiteralPath $devcon)) {
        throw "devcon.exe nao encontrado no pacote VDD."
    }
    if (-not (Test-Path -LiteralPath $inf)) {
        throw "MttVDD.inf nao encontrado no pacote VDD."
    }

    Bootstrap-HeadlessSteamVirtualDisplaySettingsDir -PkgRoot $pkgRoot | Out-Null

    Push-Location -LiteralPath $driverDir
    try {
        $output = & $devcon install .\MttVDD.inf Root\MttVDD 2>&1
        $exitCode = $LASTEXITCODE
        if ($output) {
            $output | ForEach-Object { Write-Output $_ }
        }
        if ($exitCode -ne 0) {
            throw "Falha ao registrar o driver virtual (codigo $exitCode)."
        }
    } finally {
        Pop-Location
    }

    Start-Sleep -Seconds 3
    return (Test-HeadlessSteamVirtualDisplayInstalled)
}

function Install-HeadlessSteamVirtualDisplay {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget nao disponivel. Instale o App Installer da Microsoft Store."
    }

    $output = winget install -e --id $script:HeadlessSteamVirtualDisplayWingetId `
        --accept-package-agreements --accept-source-agreements --silent 2>&1
    $exitCode = $LASTEXITCODE
    if ($output) {
        $output | Select-Object -Last 8 | ForEach-Object { Write-Output $_ }
    }

    if ($exitCode -ne 0 -and $exitCode -ne -1978335189) {
        throw "Falha ao instalar Virtual Display Driver (codigo $exitCode)."
    }

    Start-Sleep -Seconds 2

    if (-not (Test-HeadlessSteamVirtualDisplayInstalled)) {
        Register-HeadlessSteamVirtualDisplayDevice | Out-Null
    }

    Enable-HeadlessSteamVirtualDisplay | Out-Null
    Ensure-HeadlessSteamVirtualDisplaySettings | Out-Null

    if (-not (Test-HeadlessSteamVirtualDisplayInstalled)) {
        throw "Virtual Display Driver baixado, mas o dispositivo ainda nao apareceu. Aguarde alguns segundos ou abra VDD Control.exe como administrador."
    }

    return $true
}

function Ensure-HeadlessSteamVirtualDisplaySettings {
    $path = $script:HeadlessSteamVirtualDisplaySettingsPath
    if (-not (Test-Path -LiteralPath $path)) {
        return $false
    }

    try {
        [xml]$xml = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    } catch {
        return $false
    }

    $monitorsNode = $xml.SelectSingleNode("//monitors")
    if (-not $monitorsNode) {
        return $false
    }

    $countNode = $monitorsNode.SelectSingleNode("count")
    if ($countNode -and [int]$countNode.InnerText -gt 0) {
        return $true
    }

    if (-not $countNode) {
        $countNode = $xml.CreateElement("count")
        [void]$monitorsNode.AppendChild($countNode)
    }
    $countNode.InnerText = "1"
    $xml.Save($path)
    return $true
}

function Enable-HeadlessSteamVirtualDisplay {
    $devices = @(Get-HeadlessSteamVirtualDisplayPnpDevices)
    if ($devices.Count -eq 0) {
        return $false
    }

    foreach ($device in $devices) {
        try {
            if ($device.Status -eq "OK") {
                Disable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                Start-Sleep -Seconds 2
            }
            Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        } catch {
            Write-Output "AVISO: Nao foi possivel alternar $($device.FriendlyName): $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 2
    return (Test-HeadlessSteamVirtualDisplayDriverEnabled)
}

function Disable-HeadlessSteamVirtualDisplay {
    $devices = @(Get-HeadlessSteamVirtualDisplayPnpDevices)
    if ($devices.Count -eq 0) {
        return $true
    }

    foreach ($device in $devices) {
        try {
            if ($device.Status -eq "OK") {
                Disable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            }
        } catch {
            Write-Output "AVISO: Nao foi possivel desativar $($device.FriendlyName): $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 2
    return (-not (Test-HeadlessSteamVirtualDisplayDriverEnabled))
}

function Ensure-HeadlessSteamMonitorEnum {
    if ("HeadlessSteamMonitorEnum" -as [type]) {
        return
    }

    Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class HeadlessSteamMonitorEnum {
    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left; public int Top; public int Right; public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct MONITORINFOEX {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    public const int MONITORINFOF_PRIMARY = 1;

    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);

    public static List<MONITORINFOEX> GetMonitors() {
        var list = new List<MONITORINFOEX>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData) => {
            var info = new MONITORINFOEX();
            info.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            if (GetMonitorInfo(hMonitor, ref info)) {
                list.Add(info);
            }
            return true;
        }, IntPtr.Zero);
        return list;
    }

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX lpmi);
}
'@
}

function Get-HeadlessSteamConnectedMonitorCount {
    Ensure-HeadlessSteamMonitorEnum
    return [HeadlessSteamMonitorEnum]::GetMonitors().Count
}

function Test-HeadlessSteamVirtualDisplayReady {
    if (-not (Test-HeadlessSteamVirtualDisplayDriverEnabled)) {
        return $false
    }
    return [bool]((Get-HeadlessSteamConnectedMonitorCount) -ge 2)
}

function Test-HeadlessSteamVirtualDisplayRebootHint {
    if (-not (Test-HeadlessSteamVirtualDisplayInstalled)) {
        return $false
    }
    if (Test-HeadlessSteamVirtualDisplayReady) {
        return $false
    }
    return $true
}

function Ensure-HeadlessSteamDisplaySettingsApi {
    if ("HeadlessSteamDisplaySettings" -as [type]) {
        return
    }

    Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class HeadlessSteamDisplaySettings {
    public const int ENUM_CURRENT_SETTINGS = -1;
    public const int DM_PELSWIDTH = 0x80000;
    public const int DM_PELSHEIGHT = 0x100000;
    public const int DM_POSITION = 0x20;
    public const int CDS_UPDATEREGISTRY = 0x01;
    public const int CDS_SET_PRIMARY = 0x10;
    public const int CDS_NORESET = 0x10000000;
    public const int DISP_CHANGE_SUCCESSFUL = 0;
    public const int DISP_CHANGE_RESTART = 1;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern bool EnumDisplaySettings(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern int ChangeDisplaySettingsEx(
        string lpszDeviceName,
        ref DEVMODE lpDevMode,
        IntPtr hwnd,
        int dwflags,
        IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    private static extern int ChangeDisplaySettingsEx(
        string lpszDeviceName,
        IntPtr lpDevMode,
        IntPtr hwnd,
        int dwflags,
        IntPtr lParam);

    public static int CommitDisplayChanges() {
        return ChangeDisplaySettingsEx(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
    }

    public static bool SetPrimaryDisplay(string deviceName) {
        if (string.IsNullOrWhiteSpace(deviceName)) return false;
        DEVMODE dm = new DEVMODE();
        dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettings(deviceName, ENUM_CURRENT_SETTINGS, ref dm)) return false;
        dm.dmPositionX = 0;
        dm.dmPositionY = 0;
        dm.dmFields = DM_POSITION;
        int flags = CDS_UPDATEREGISTRY | CDS_SET_PRIMARY | CDS_NORESET;
        int result = ChangeDisplaySettingsEx(deviceName, ref dm, IntPtr.Zero, flags, IntPtr.Zero);
        if (result != DISP_CHANGE_SUCCESSFUL && result != DISP_CHANGE_RESTART) return false;
        DEVMODE apply = new DEVMODE();
        apply.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        ChangeDisplaySettingsEx(null, ref apply, IntPtr.Zero, 0, IntPtr.Zero);
        return true;
    }
}
'@
}

function Get-HeadlessSteamPrimaryMonitorSize {
    Ensure-HeadlessSteamMonitorEnum
    foreach ($info in [HeadlessSteamMonitorEnum]::GetMonitors()) {
        $isPrimary = (($info.dwFlags -band [HeadlessSteamMonitorEnum]::MONITORINFOF_PRIMARY) -ne 0)
        if (-not $isPrimary) {
            continue
        }

        $width = [int]($info.rcMonitor.Right - $info.rcMonitor.Left)
        $height = [int]($info.rcMonitor.Bottom - $info.rcMonitor.Top)
        if ($width -gt 0 -and $height -gt 0) {
            return [pscustomobject]@{
                width       = $width
                height      = $height
                device_name = [string]$info.szDevice
            }
        }
    }
    return $null
}

function Get-HeadlessSteamPhysicalMonitorSize {
    $virtualDevice = Get-HeadlessSteamVirtualMonitorDeviceName
    $savedPrimary = $null
    if (Get-Variable -Name HeadlessSteamSavedPrimaryDevice -Scope Script -ErrorAction SilentlyContinue) {
        $savedPrimary = $script:HeadlessSteamSavedPrimaryDevice
    }

    if ($savedPrimary) {
        $size = Get-HeadlessSteamMonitorSize -DeviceName ([string]$savedPrimary)
        if ($size -and $size.width -gt 0 -and $size.height -gt 0) {
            return [pscustomobject]@{
                width       = [int]$size.width
                height      = [int]$size.height
                device_name = [string]$savedPrimary
                source      = 'saved_primary'
            }
        }
    }

    Ensure-HeadlessSteamMonitorEnum
    $best = $null
    foreach ($info in [HeadlessSteamMonitorEnum]::GetMonitors()) {
        $deviceName = [string]$info.szDevice
        if ($virtualDevice -and $deviceName -eq $virtualDevice) {
            continue
        }

        $width = [int]($info.rcMonitor.Right - $info.rcMonitor.Left)
        $height = [int]($info.rcMonitor.Bottom - $info.rcMonitor.Top)
        if ($width -le 0 -or $height -le 0) {
            continue
        }

        if (-not $best -or ($width * $height) -gt ($best.width * $best.height)) {
            $best = [pscustomobject]@{
                width       = $width
                height      = $height
                device_name = $deviceName
                source      = 'physical'
            }
        }
    }

    if ($best) {
        return $best
    }

    $primary = Get-HeadlessSteamPrimaryMonitorSize
    if ($primary) {
        $primary | Add-Member -NotePropertyName source -NotePropertyValue 'primary_fallback' -Force
        return $primary
    }

    return $null
}

function Get-HeadlessSteamVirtualMonitorDeviceName {
    if (Get-Command Find-HeadlessSteamVirtualDisplayOutput -ErrorAction SilentlyContinue) {
        $output = Find-HeadlessSteamVirtualDisplayOutput
        if ($output -and $output.display_name) {
            return [string]$output.display_name
        }
    }

    if ($script:HeadlessSteamSavedPrimaryDevice) {
        Ensure-HeadlessSteamMonitorEnum
        foreach ($info in [HeadlessSteamMonitorEnum]::GetMonitors()) {
            $deviceName = [string]$info.szDevice
            if ($deviceName -and $deviceName -ne [string]$script:HeadlessSteamSavedPrimaryDevice) {
                return $deviceName
            }
        }
    }

    Ensure-HeadlessSteamMonitorEnum
    foreach ($info in [HeadlessSteamMonitorEnum]::GetMonitors()) {
        $isPrimary = (($info.dwFlags -band [HeadlessSteamMonitorEnum]::MONITORINFOF_PRIMARY) -ne 0)
        if ($isPrimary) {
            continue
        }

        $deviceName = [string]$info.szDevice
        if ($deviceName) {
            return $deviceName
        }
    }
    return $null
}

function Get-HeadlessSteamMonitorSize {
    param([Parameter(Mandatory = $true)][string]$DeviceName)

    Ensure-HeadlessSteamMonitorEnum
    foreach ($info in [HeadlessSteamMonitorEnum]::GetMonitors()) {
        if ([string]$info.szDevice -ne $DeviceName) {
            continue
        }

        return [pscustomobject]@{
            width  = [int]($info.rcMonitor.Right - $info.rcMonitor.Left)
            height = [int]($info.rcMonitor.Bottom - $info.rcMonitor.Top)
        }
    }
    return $null
}

function Get-HeadlessSteamDisplayModeDevMode {
    param(
        [Parameter(Mandatory = $true)][string]$DeviceName,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height
    )

    Ensure-HeadlessSteamDisplaySettingsApi

    for ($mode = 0; ; $mode++) {
        $devMode = New-Object HeadlessSteamDisplaySettings+DEVMODE
        $devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($devMode)
        if (-not [HeadlessSteamDisplaySettings]::EnumDisplaySettings($DeviceName, $mode, [ref]$devMode)) {
            break
        }
        if ([int]$devMode.dmPelsWidth -eq $Width -and [int]$devMode.dmPelsHeight -eq $Height) {
            return $devMode
        }
    }
    return $null
}

function Test-HeadlessSteamDisplayModeAvailable {
    param(
        [Parameter(Mandatory = $true)][string]$DeviceName,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height
    )

    Ensure-HeadlessSteamDisplaySettingsApi

    for ($mode = 0; ; $mode++) {
        $devMode = New-Object HeadlessSteamDisplaySettings+DEVMODE
        $devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($devMode)
        if (-not [HeadlessSteamDisplaySettings]::EnumDisplaySettings($DeviceName, $mode, [ref]$devMode)) {
            break
        }
        if ([int]$devMode.dmPelsWidth -eq $Width -and [int]$devMode.dmPelsHeight -eq $Height) {
            return $true
        }
    }
    return $false
}

function Add-HeadlessSteamVirtualDisplaySettingsResolution {
    param(
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [int]$RefreshRate = 60
    )

    $path = $script:HeadlessSteamVirtualDisplaySettingsPath
    if (-not (Test-Path -LiteralPath $path)) {
        return $false
    }

    try {
        [xml]$xml = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    } catch {
        return $false
    }

    $resolutionsNode = $xml.SelectSingleNode("//resolutions")
    if (-not $resolutionsNode) {
        return $false
    }

    foreach ($existing in @($resolutionsNode.SelectNodes("resolution"))) {
        $existingWidth = [int]$existing.SelectSingleNode("width").InnerText
        $existingHeight = [int]$existing.SelectSingleNode("height").InnerText
        if ($existingWidth -eq $Width -and $existingHeight -eq $Height) {
            return $true
        }
    }

    $resolutionNode = $xml.CreateElement("resolution")
    $widthNode = $xml.CreateElement("width")
    $widthNode.InnerText = [string]$Width
    [void]$resolutionNode.AppendChild($widthNode)
    $heightNode = $xml.CreateElement("height")
    $heightNode.InnerText = [string]$Height
    [void]$resolutionNode.AppendChild($heightNode)
    $refreshNode = $xml.CreateElement("refresh_rate")
    $refreshNode.InnerText = [string]$RefreshRate
    [void]$resolutionNode.AppendChild($refreshNode)
    [void]$resolutionsNode.AppendChild($resolutionNode)
    $xml.Save($path)
    return $true
}

function Set-HeadlessSteamDisplayResolution {
    param(
        [Parameter(Mandatory = $true)][string]$DeviceName,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height
    )

    Ensure-HeadlessSteamDisplaySettingsApi

    $devMode = Get-HeadlessSteamDisplayModeDevMode -DeviceName $DeviceName -Width $Width -Height $Height
    if ($null -eq $devMode) {
        $devMode = New-Object HeadlessSteamDisplaySettings+DEVMODE
        $devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($devMode)
        if (-not [HeadlessSteamDisplaySettings]::EnumDisplaySettings(
                $DeviceName,
                [HeadlessSteamDisplaySettings]::ENUM_CURRENT_SETTINGS,
                [ref]$devMode)) {
            return $false
        }

        $devMode.dmPelsWidth = $Width
        $devMode.dmPelsHeight = $Height
        $devMode.dmFields = [HeadlessSteamDisplaySettings]::DM_PELSWIDTH -bor [HeadlessSteamDisplaySettings]::DM_PELSHEIGHT
    }

    $flagSets = @(
        0,
        [HeadlessSteamDisplaySettings]::CDS_UPDATEREGISTRY
    )

    foreach ($flags in $flagSets) {
        $mode = Get-HeadlessSteamDisplayModeDevMode -DeviceName $DeviceName -Width $Width -Height $Height
        if ($null -eq $mode) {
            $mode = New-Object HeadlessSteamDisplaySettings+DEVMODE
            $mode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mode)
            if (-not [HeadlessSteamDisplaySettings]::EnumDisplaySettings(
                    $DeviceName,
                    [HeadlessSteamDisplaySettings]::ENUM_CURRENT_SETTINGS,
                    [ref]$mode)) {
                continue
            }
            $mode.dmPelsWidth = $Width
            $mode.dmPelsHeight = $Height
            $mode.dmFields = [HeadlessSteamDisplaySettings]::DM_PELSWIDTH -bor [HeadlessSteamDisplaySettings]::DM_PELSHEIGHT
        }

        $result = [HeadlessSteamDisplaySettings]::ChangeDisplaySettingsEx(
            $DeviceName,
            [ref]$mode,
            [IntPtr]::Zero,
            $flags,
            [IntPtr]::Zero)
        if ($result -ne [HeadlessSteamDisplaySettings]::DISP_CHANGE_SUCCESSFUL -and
            $result -ne [HeadlessSteamDisplaySettings]::DISP_CHANGE_RESTART) {
            continue
        }

        Start-Sleep -Milliseconds 500
        $actual = Get-HeadlessSteamMonitorSize -DeviceName $DeviceName
        if ($actual -and $actual.width -eq $Width -and $actual.height -eq $Height) {
            return $true
        }
    }

    return $false
}

function Test-HeadlessSteamDisplayResolutionApplied {
    param(
        [Parameter(Mandatory = $true)][object]$Actual,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height
    )

    if (-not $Actual) {
        return $false
    }

    if ($Actual.width -eq $Width -and $Actual.height -eq $Height) {
        return $true
    }

    return ($Actual.width -ge $Width -and $Actual.height -ge $Height)
}

function Get-HeadlessSteamVirtualDisplayResolutionCandidates {
    $candidates = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    $addCandidate = {
        param([int]$Width, [int]$Height, [string]$Source)
        if ($Width -lt 1280 -or $Height -lt 720) {
            return
        }
        $key = "${Width}x${Height}"
        if ($seen.ContainsKey($key)) {
            return
        }
        $seen[$key] = $true
        $candidates.Add([pscustomobject]@{
            width  = $Width
            height = $Height
            source = $Source
        }) | Out-Null
    }

    $physical = Get-HeadlessSteamPhysicalMonitorSize
    if ($physical) {
        & $addCandidate $physical.width $physical.height ([string]$physical.source)
    }

    if (-not $physical -or $physical.width -ne 1920 -or $physical.height -ne 1080) {
        & $addCandidate 1920 1080 'fallback'
    }

    return @($candidates.ToArray())
}

function Wait-HeadlessSteamDisplayModeAvailable {
    param(
        [Parameter(Mandatory = $true)][string]$DeviceName,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [int]$TimeoutSec = 8
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-HeadlessSteamDisplayModeAvailable -DeviceName $DeviceName -Width $Width -Height $Height) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Set-HeadlessSteamVirtualDisplayResolution {
    $script:HeadlessSteamVirtualDisplayResolutionLog = @()

    $deviceName = Get-HeadlessSteamVirtualMonitorDeviceName
    if (-not $deviceName) {
        return $false
    }

    $candidates = @(Get-HeadlessSteamVirtualDisplayResolutionCandidates)
    if ($candidates.Count -eq 0) {
        return $false
    }

    $physical = Get-HeadlessSteamPhysicalMonitorSize
    if ($physical) {
        $script:HeadlessSteamVirtualDisplayResolutionLog += ("HOST_FREE_RES_TARGET:{0}x{1}:{2}" -f `
            $physical.width, $physical.height, $physical.device_name)
    }

    $current = Get-HeadlessSteamMonitorSize -DeviceName $deviceName
    foreach ($target in $candidates) {
        if ($current -and $current.width -eq $target.width -and $current.height -eq $target.height) {
            $script:HeadlessSteamVirtualDisplayResolutionLog += ("HOST_FREE_VIRTUAL_RES:{0}x{1}" -f $current.width, $current.height)
            return $true
        }
    }

    foreach ($target in $candidates) {
        $label = "{0}x{1}" -f $target.width, $target.height
        $script:HeadlessSteamVirtualDisplayResolutionLog += ("HOST_FREE_RES_TRY:{0}:{1}" -f $label, $target.source)

        Add-HeadlessSteamVirtualDisplaySettingsResolution -Width $target.width -Height $target.height | Out-Null

        if (-not (Test-HeadlessSteamDisplayModeAvailable -DeviceName $deviceName -Width $target.width -Height $target.height)) {
            Enable-HeadlessSteamVirtualDisplay | Out-Null
            Wait-HeadlessSteamDisplayModeAvailable -DeviceName $deviceName `
                -Width $target.width -Height $target.height -TimeoutSec 8 | Out-Null
        }

        if (-not (Set-HeadlessSteamDisplayResolution -DeviceName $deviceName -Width $target.width -Height $target.height)) {
            $script:HeadlessSteamVirtualDisplayResolutionLog += ("HOST_FREE_RES_TRY_FAILED:{0}" -f $label)
            continue
        }

        Start-Sleep -Milliseconds 500
        $updated = Get-HeadlessSteamMonitorSize -DeviceName $deviceName
        if ($updated -and $updated.width -eq $target.width -and $updated.height -eq $target.height) {
            $script:HeadlessSteamVirtualDisplayResolutionLog += ("HOST_FREE_VIRTUAL_RES:{0}x{1}" -f $updated.width, $updated.height)
            return $true
        }

        $script:HeadlessSteamVirtualDisplayResolutionLog += ("HOST_FREE_RES_TRY_FAILED:{0}" -f $label)
    }

    return $false
}
