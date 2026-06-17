param(
    [Parameter(Mandatory = $true)][string]$AppId,
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $true)][string]$SteamExe,
    [int]$StartupTimeoutSec = 300,
    [int]$PollIntervalMs = 500,
    [int]$StopConfirmCount = 2,
    [int]$FocusIntervalMs = 300,
    [int]$MoveWindowIntervalMs = 5000,
    [switch]$KeepFocus = $true,
    [switch]$HostFreeMode,
    [switch]$UserSession
)

$ErrorActionPreference = "SilentlyContinue"

$script:ScriptDir = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Write-MonitorLog {
    param([string]$Message)

    $logPath = Join-Path $env:TEMP "sunshine-steam-monitor-$AppId.log"
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" | Add-Content -Path $logPath
}

if (-not $UserSession) {
    . (Join-Path $script:ScriptDir "Start-UserSessionProcess.ps1")

    $scriptPath = $MyInvocation.MyCommand.Path
    $argumentList = @(
        "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden",
        "-File `"$scriptPath`"",
        "-AppId $AppId",
        "-InstallDir `"$InstallDir`"",
        "-SteamExe `"$SteamExe`"",
        "-StartupTimeoutSec $StartupTimeoutSec",
        "-PollIntervalMs $PollIntervalMs",
        "-StopConfirmCount $StopConfirmCount",
        "-FocusIntervalMs $FocusIntervalMs",
        "-UserSession"
    ) -join " "

    if ($KeepFocus) {
        $argumentList += " -KeepFocus"
    }
    if ($HostFreeMode) {
        $argumentList += " -HostFreeMode"
    }

    Write-MonitorLog "Reiniciando na sessao do usuario..."
    $processId = Start-UserSessionProcess `
        -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList $argumentList `
        -WorkingDirectory $script:ScriptDir

    if ($processId -le 0) {
        Write-MonitorLog "ERRO: nao foi possivel abrir na sessao do usuario (codigo $processId)."
        exit 1
    }

    Write-MonitorLog "Sessao do usuario ativa (PID $processId). Aguardando fim do jogo..."
    Wait-Process -Id $processId -ErrorAction SilentlyContinue
    Write-MonitorLog "Sessao do jogo encerrada."
    exit 0
}

if (-not ([System.Management.Automation.PSTypeName]"SunshineGameFocus").Type) {
    $addTypeError = $null
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class SunshineGameFocus {
    public const int SW_RESTORE = 9;
    public const int SW_MINIMIZE = 6;
    public const int ASFW_ANY = -1;
    public const int MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const int MOUSEEVENTF_LEFTUP = 0x0004;
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    public static readonly IntPtr HWND_TOP = new IntPtr(0);
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_SHOWWINDOW = 0x0040;
    public const uint SWP_NOACTIVATE = 0x0010;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left; public int Top; public int Right; public int Bottom;
    }

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] private static extern void SwitchToThisWindow(IntPtr hWnd, bool fAltTab);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] private static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
    [DllImport("user32.dll")] private static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] private static extern bool AllowSetForegroundWindow(int dwProcessId);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern void mouse_event(int dwFlags, int dx, int dy, int dwData, int dwExtraInfo);
    [DllImport("user32.dll")] private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();

    public static bool TryGetWindowRect(IntPtr hWnd, out RECT rect) {
        rect = new RECT();
        if (hWnd == IntPtr.Zero) return false;
        return GetWindowRect(hWnd, out rect);
    }

    public static bool MoveCursorTo(int x, int y) {
        return SetCursorPos(x, y);
    }

    public static void ClickAt(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
    }

    public static string GetWindowTitle(IntPtr hWnd) {
        int len = GetWindowTextLength(hWnd);
        var sb = new StringBuilder(Math.Max(len + 1, 1));
        GetWindowText(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static int GetWindowProcessId(IntPtr hWnd) {
        uint pid; GetWindowThreadProcessId(hWnd, out pid); return (int)pid;
    }

    public static IntPtr GetForegroundWindowHandle() {
        return GetForegroundWindow();
    }

    public static bool TryGetRawWindowRect(IntPtr hWnd, out int left, out int top, out int width, out int height) {
        left = 0; top = 0; width = 0; height = 0;
        if (hWnd == IntPtr.Zero) return false;
        RECT rect;
        if (!GetWindowRect(hWnd, out rect)) return false;
        left = rect.Left; top = rect.Top;
        width = rect.Right - rect.Left;
        height = rect.Bottom - rect.Top;
        return true;
    }

    public static bool TryGetWindowBounds(IntPtr hWnd, out int left, out int top, out int width, out int height) {
        left = 0; top = 0; width = 0; height = 0;
        if (hWnd == IntPtr.Zero) return false;
        RECT rect;
        if (!GetWindowRect(hWnd, out rect)) return false;
        left = rect.Left; top = rect.Top;
        width = rect.Right - rect.Left;
        height = rect.Bottom - rect.Top;
        return width >= 64 && height >= 64;
    }

    public static string DescribeWindow(IntPtr hWnd) {
        WindowInfo info = GetWindowInfo(hWnd);
        if (!info.Ok) return "invalid";
        return info.Left + "," + info.Top + " " + info.Width + "x" + info.Height + " title='" + info.Title + "'";
    }

    public class WindowInfo {
        public bool Ok;
        public int Left;
        public int Top;
        public int Width;
        public int Height;
        public string Title;
    }

    public static WindowInfo GetWindowInfo(IntPtr hWnd) {
        var info = new WindowInfo { Title = GetWindowTitle(hWnd) };
        info.Ok = TryGetRawWindowRect(hWnd, out info.Left, out info.Top, out info.Width, out info.Height);
        return info;
    }

    public static bool IsWindowOnVirtualMonitor(IntPtr hWnd, int virtualLeft, int virtualTop, int virtualRight, int virtualBottom) {
        WindowInfo info = GetWindowInfo(hWnd);
        if (!info.Ok || info.Width <= 0 || info.Height <= 0) return false;
        int virtW = virtualRight - virtualLeft;
        int virtH = virtualBottom - virtualTop;
        int centerX = info.Left + (info.Width / 2);
        int centerY = info.Top + (info.Height / 2);
        if (centerX < (virtualLeft + 40) || centerX > (virtualRight - 40)) return false;
        if (centerY < (virtualTop + 40) || centerY > (virtualBottom - 40)) return false;
        if (info.Width > (virtW + 120) || info.Height > (virtH + 120)) return false;
        return true;
    }

    public static IntPtr FindBestWindow(ISet<int> processIds, int minWidth, int minHeight) {
        IntPtr best = IntPtr.Zero; long bestScore = 0;
        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            uint pid; GetWindowThreadProcessId(hWnd, out pid);
            if (!processIds.Contains((int)pid)) return true;
            string title = GetWindowTitle(hWnd);
            if (title.Contains("MSCTFIME UI") || title.Contains("Default IME")) return true;
            int left, top, width, height;
            if (!TryGetWindowBounds(hWnd, out left, out top, out width, out height)) return true;
            if (width < minWidth || height < minHeight) return true;
            long score = (long)width * height;
            if (!string.IsNullOrWhiteSpace(title)) {
                score += 1000000000L;
            } else if (width >= 1280 && height >= 720) {
                score += 500000000L;
            } else {
                return true;
            }
            if (title.IndexOf("Splash", StringComparison.OrdinalIgnoreCase) >= 0 ||
                title.IndexOf("Loading", StringComparison.OrdinalIgnoreCase) >= 0) score -= 500000000L;
            if (score > bestScore) { bestScore = score; best = hWnd; }
            return true;
        }, IntPtr.Zero);
        return best;
    }

    public static void MinimizeWindow(IntPtr hWnd) {
        if (hWnd != IntPtr.Zero) ShowWindow(hWnd, SW_MINIMIZE);
    }

    public static void ClickWindowCenter(IntPtr hWnd) {
        if (hWnd == IntPtr.Zero) return;
        RECT rect; if (!GetWindowRect(hWnd, out rect)) return;
        int x = rect.Left + ((rect.Right - rect.Left) / 2);
        int y = rect.Top + ((rect.Bottom - rect.Top) / 2);
        SetCursorPos(x, y);
        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
    }

    public static void ForceForegroundWindow(IntPtr hWnd, bool clickCenter) {
        if (hWnd == IntPtr.Zero) return;
        AllowSetForegroundWindow(ASFW_ANY);
        ShowWindow(hWnd, SW_RESTORE);
        SwitchToThisWindow(hWnd, true);
        SetWindowPos(hWnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        SetWindowPos(hWnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        IntPtr fg = GetForegroundWindow();
        uint fgPid, targetPid;
        uint fgThread = GetWindowThreadProcessId(fg, out fgPid);
        uint targetThread = GetWindowThreadProcessId(hWnd, out targetPid);
        uint currentThread = GetCurrentThreadId();
        if (fgThread != targetThread) {
            AttachThreadInput(currentThread, fgThread, true);
            AttachThreadInput(currentThread, targetThread, true);
        }
        SetForegroundWindow(hWnd);
        if (fgThread != targetThread) {
            AttachThreadInput(currentThread, targetThread, false);
            AttachThreadInput(currentThread, fgThread, false);
        }
        if (clickCenter) ClickWindowCenter(hWnd);
    }

    public static bool TryMoveWindowTo(IntPtr hWnd, int x, int y, int width, int height) {
        if (hWnd == IntPtr.Zero) return false;
        return SetWindowPos(hWnd, HWND_TOP, x, y, width, height, SWP_SHOWWINDOW | SWP_NOACTIVATE);
    }

    public static bool TryMoveWindowToRestored(IntPtr hWnd, int x, int y, int width, int height) {
        if (hWnd == IntPtr.Zero) return false;
        ShowWindow(hWnd, SW_RESTORE);
        return SetWindowPos(hWnd, HWND_TOP, x, y, width, height, SWP_SHOWWINDOW | SWP_NOACTIVATE);
    }

    public static bool TryMoveWindowNative(IntPtr hWnd, int x, int y, int width, int height) {
        if (hWnd == IntPtr.Zero) return false;
        ShowWindow(hWnd, SW_RESTORE);
        if (!MoveWindow(hWnd, x, y, width, height, true)) return false;
        return SetWindowPos(hWnd, HWND_TOP, x, y, width, height, SWP_SHOWWINDOW | SWP_NOACTIVATE);
    }

    public static void MoveWindowTo(IntPtr hWnd, int x, int y, int width, int height) {
        TryMoveWindowToRestored(hWnd, x, y, width, height);
    }
}
"@
    } catch {
        $addTypeError = $_.Exception.Message
    }
}

if (-not ([System.Management.Automation.PSTypeName]"SunshineGameFocus").Type) {
    Write-MonitorLog "ERRO: SunshineGameFocus nao carregou. $addTypeError"
    exit 1
}

Add-Type -AssemblyName Microsoft.VisualBasic

$script:UtilityProcessNames = [System.Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
@(
    "CrashReport.exe", "InstallerMessage.exe", "UnityCrashHandler64.exe",
    "UnityCrashHandler32.exe", "GameBarPresenceWriter.exe", "EasyAntiCheat_EOS.exe",
    "EasyAntiCheat.exe", "UE4PrereqSetup_x64.exe", "UE4PrereqSetup.exe"
) | ForEach-Object { [void]$script:UtilityProcessNames.Add($_) }

function Test-SteamGameRunning {
    param([string]$AppId)

    $appIdNumber = [int]$AppId
    $steamKey = "HKCU:\Software\Valve\Steam"

    if (Test-Path $steamKey) {
        $appKey = Join-Path $steamKey "Apps\$AppId"
        if (Test-Path $appKey) {
            if ((Get-ItemProperty -Path $appKey -Name Running -ErrorAction SilentlyContinue).Running -eq 1) {
                return $true
            }
        }
        $runningAppId = (Get-ItemProperty -Path $steamKey -Name RunningAppID -ErrorAction SilentlyContinue).RunningAppID
        if ($null -ne $runningAppId -and [int]$runningAppId -eq $appIdNumber) {
            return $true
        }
    }

    return $false
}

function Get-GameExecutableNames {
    param([string]$GameDir)

    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path $GameDir)) { return $names }

    Get-ChildItem -Path $GameDir -Filter "*.exe" -File -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($script:UtilityProcessNames.Contains($_.Name)) { return }
            [void]$names.Add([IO.Path]::GetFileNameWithoutExtension($_.Name))
        }
    return $names
}

function Get-GameProcessIds {
    param(
        [string]$GameDir,
        [System.Collections.Generic.HashSet[string]]$GameExecutableNames
    )

    $processIds = [System.Collections.Generic.HashSet[int]]::new()
    if (-not (Test-Path $GameDir)) { return $processIds }

    foreach ($gameName in $GameExecutableNames) {
        foreach ($process in (Get-Process -Name $gameName -ErrorAction SilentlyContinue)) {
            [void]$processIds.Add($process.Id)
        }
    }

    if ($processIds.Count -eq 0) {
        $gameRoot = (Resolve-Path -LiteralPath $GameDir -ErrorAction SilentlyContinue).Path
        if ($gameRoot) {
            foreach ($process in (Get-Process -ErrorAction SilentlyContinue)) {
                try {
                    $processPath = $process.Path
                    if (-not $processPath) { continue }
                    if ($processPath.StartsWith($gameRoot, [StringComparison]::OrdinalIgnoreCase)) {
                        $exeName = [IO.Path]::GetFileName($processPath)
                        if ($script:UtilityProcessNames.Contains($exeName)) { continue }
                        [void]$processIds.Add($process.Id)
                    }
                } catch {}
            }
        }
    }

    return ,$processIds
}

function Test-GameProcessIdInSet {
    param(
        [object]$ProcessIds,
        [int]$ProcessId
    )

    if ($null -eq $ProcessIds) {
        return $false
    }

    if ($ProcessIds -is [System.Collections.Generic.HashSet[int]]) {
        return $ProcessIds.Contains($ProcessId)
    }

    return @($ProcessIds) -contains $ProcessId
}

function Test-GameSessionActive {
    param(
        [string]$AppId,
        [string]$GameDir,
        [System.Collections.Generic.HashSet[string]]$GameExecutableNames
    )

    if (Test-SteamGameRunning -AppId $AppId) {
        return $true
    }

    $processIds = Get-GameProcessIds -GameDir $GameDir -GameExecutableNames $GameExecutableNames
    if ($processIds -is [System.Collections.Generic.HashSet[int]]) {
        return ($processIds.Count -gt 0)
    }

    return @($processIds).Count -gt 0
}

function Hide-SteamLauncherWindows {
    foreach ($processName in @("steamwebhelper", "steam")) {
        foreach ($process in (Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
            if ($process.MainWindowHandle -ne 0) {
                [SunshineGameFocus]::MinimizeWindow($process.MainWindowHandle) | Out-Null
            }
        }
    }
}

function Test-GameMainWindowHandle {
    param([IntPtr]$WindowHandle)

    if ($WindowHandle -eq [IntPtr]::Zero) {
        return $false
    }

    $left = 0; $top = 0; $width = 0; $height = 0
    if (-not [SunshineGameFocus]::TryGetWindowBounds($WindowHandle, [ref]$left, [ref]$top, [ref]$width, [ref]$height)) {
        return $false
    }

    $title = [SunshineGameFocus]::GetWindowTitle($WindowHandle)
    if (-not [string]::IsNullOrWhiteSpace($title)) {
        return $true
    }

    return ($width -ge 640 -and $height -ge 480)
}

function Get-GameMainWindowHandle {
    param([System.Collections.Generic.HashSet[string]]$GameExecutableNames)

    foreach ($gameName in $GameExecutableNames) {
        foreach ($process in (Get-Process -Name $gameName -ErrorAction SilentlyContinue)) {
            if (Test-GameMainWindowHandle -WindowHandle $process.MainWindowHandle) {
                return $process.MainWindowHandle
            }
        }
    }
    return [IntPtr]::Zero
}

function Get-BestGameWindow {
    param(
        [System.Collections.Generic.HashSet[int]]$ProcessIds,
        [System.Collections.Generic.HashSet[string]]$GameExecutableNames,
        [switch]$AllowSmallWindows
    )

    $mainWindow = Get-GameMainWindowHandle -GameExecutableNames $GameExecutableNames
    if ($mainWindow -ne [IntPtr]::Zero) {
        return $mainWindow
    }

    $best = [SunshineGameFocus]::FindBestWindow($ProcessIds, 640, 480)
    if ($best -ne [IntPtr]::Zero) { return $best }
    $best = [SunshineGameFocus]::FindBestWindow($ProcessIds, 200, 150)
    if ($best -ne [IntPtr]::Zero) { return $best }
    if ($AllowSmallWindows) {
        return [SunshineGameFocus]::FindBestWindow($ProcessIds, 100, 80)
    }
    return [IntPtr]::Zero
}

function Get-ScriptMoveLogState {
    return [string]$script:MoveLogState
}

function Set-ScriptMoveLogState {
    param([string]$State)
    $script:MoveLogState = $State
}

$script:MoveLogState = $null
$script:HostFreeVirtualDevice = $null
$script:HostFreeMmtUsed = $false
$script:HostFreeGameOnVirtual = $false
$script:HostFreeGameWindow = [IntPtr]::Zero
$script:HostFreePrimarySwapped = $false
$script:HostFreeVirtualStableCount = 0
$script:HostFreeVirtualStableRequired = 3
$script:HostFreeRemineAttempts = 0

function Get-HostFreeVirtualMonitorBounds {
    if ($script:HostFreeVirtualDevice) {
        $monitor = @(Get-HeadlessSteamMonitorLayout) |
            Where-Object { [string]$_.device_name -eq [string]$script:HostFreeVirtualDevice } |
            Select-Object -First 1
        if ($monitor) {
            return [pscustomobject]@{
                left   = [int]$monitor.left
                top    = [int]$monitor.top
                width  = [int]$monitor.width
                height = [int]$monitor.height
                right  = [int]$monitor.right
                bottom = [int]$monitor.bottom
                device = [string]$monitor.device_name
            }
        }
    }
    return Get-HeadlessSteamVirtualMonitorBounds
}

function Focus-VirtualDisplayForGameLaunch {
    $virtual = Get-HostFreeVirtualMonitorBounds
    if (-not $virtual) {
        Write-MonitorLog "AVISO: Monitor virtual nao encontrado para focar cursor."
        return $false
    }

    $x = [int]$virtual.left + [int]($virtual.width / 2)
    $y = [int]$virtual.top + [int]($virtual.height / 2)
    [SunshineGameFocus]::MoveCursorTo($x, $y) | Out-Null
    Start-Sleep -Milliseconds 200
    [SunshineGameFocus]::ClickAt($x, $y)
    Start-Sleep -Milliseconds 300
    Write-MonitorLog "Cursor e foco na tela virtual $($virtual.device) ($x, $y) antes do launch."
    return $true
}

function Stop-HeadlessSteamGameProcesses {
    param(
        [string]$GameDir,
        [System.Collections.Generic.HashSet[string]]$GameExecutableNames
    )

    $stopped = 0
    if (Test-Path $GameDir) {
        $gameDir = (Resolve-Path $GameDir).Path.TrimEnd('\')
        Get-CimInstance Win32_Process |
            Where-Object {
                $_.ExecutablePath -and
                $_.ExecutablePath.StartsWith($gameDir, [StringComparison]::OrdinalIgnoreCase)
            } |
            ForEach-Object {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                $stopped++
            }
    }

    foreach ($gameName in $GameExecutableNames) {
        foreach ($process in (Get-Process -Name $gameName -ErrorAction SilentlyContinue)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $stopped++
        }
    }

    if ($stopped -gt 0) {
        Write-MonitorLog "Processos anteriores do jogo encerrados ($stopped)."
        Start-Sleep -Seconds 3
    }
}

function Test-IsGameProcessWindow {
    param(
        [IntPtr]$WindowHandle,
        [System.Collections.Generic.HashSet[int]]$ProcessIds,
        [System.Collections.Generic.HashSet[string]]$GameExecutableNames,
        [string]$GameDir
    )

    if ($WindowHandle -eq [IntPtr]::Zero) {
        return $false
    }

    $windowPid = [SunshineGameFocus]::GetWindowProcessId($WindowHandle)
    if ($ProcessIds -and (Test-GameProcessIdInSet -ProcessIds $ProcessIds -ProcessId $windowPid)) {
        return $true
    }

    try {
        $proc = Get-Process -Id $windowPid -ErrorAction Stop
        $procName = [IO.Path]::GetFileNameWithoutExtension($proc.ProcessName)
        if ($GameExecutableNames.Contains($procName)) {
            return $true
        }
        if ($GameDir -and $proc.Path) {
            $gameRoot = (Resolve-Path -LiteralPath $GameDir -ErrorAction SilentlyContinue).Path
            if ($gameRoot -and $proc.Path.StartsWith($gameRoot, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    } catch {}

    return $false
}

function Find-GameWindowForHostFree {
    param(
        [string]$GameDir,
        [System.Collections.Generic.HashSet[string]]$GameExecutableNames
    )

    $processIds = Get-GameProcessIds -GameDir $GameDir -GameExecutableNames $GameExecutableNames
    if ($processIds.Count -eq 0) {
        return [IntPtr]::Zero
    }

    return (Get-BestGameWindow -ProcessIds $processIds -GameExecutableNames $GameExecutableNames -AllowSmallWindows)
}

function Invoke-HeadlessSteamMoveGameViaMultiMonitorTool {
    param(
        [string]$VirtualDevice,
        [System.Collections.Generic.HashSet[string]]$GameExecutableNames
    )

    $mmt = Get-HeadlessSteamMultiMonitorToolPath
    if (-not $mmt) {
        return $false
    }

    foreach ($name in $GameExecutableNames) {
        $proc = if ($name -match '\.exe$') { $name } else { "$name.exe" }
        $mmtProc = Start-Process -FilePath $mmt -ArgumentList @(
            '/MoveWindow', $VirtualDevice, 'Process', $proc) -PassThru -Wait -WindowStyle Hidden
        if ($mmtProc -and $mmtProc.ExitCode -eq 0) {
            return $true
        }
    }

    return $false
}

function Test-WindowOnVirtualMonitor {
    param(
        [IntPtr]$WindowHandle,
        [int]$VirtualLeft,
        [int]$VirtualTop,
        [int]$VirtualRight,
        [int]$VirtualBottom
    )

    return [SunshineGameFocus]::IsWindowOnVirtualMonitor(
        $WindowHandle, $VirtualLeft, $VirtualTop, $VirtualRight, $VirtualBottom)
}

function Test-HostFreeGameWindowReady {
    param(
        [IntPtr]$WindowHandle,
        [int]$Width,
        [int]$Height
    )

    if ($Width -lt 1280 -or $Height -lt 720) {
        return $false
    }

    return ($WindowHandle -ne [IntPtr]::Zero)
}

function Test-HostFreeGameWindowOnVirtual {
    param(
        [IntPtr]$WindowHandle,
        [object]$Bounds,
        [int]$Width,
        [int]$Height
    )

    if (-not (Test-HostFreeGameWindowReady -WindowHandle $WindowHandle -Width $Width -Height $Height)) {
        return $false
    }

    return (Test-WindowOnVirtualMonitor -WindowHandle $WindowHandle -VirtualLeft $Bounds.left `
        -VirtualTop $Bounds.top -VirtualRight $Bounds.right -VirtualBottom $Bounds.bottom)
}

function Reset-HostFreeGameVirtualLock {
    param([string]$Reason)

    if ($script:HostFreeGameOnVirtual -or $script:HostFreeVirtualStableCount -gt 0) {
        Write-MonitorLog "Host free: $Reason"
    }
    $script:HostFreeGameOnVirtual = $false
    $script:HostFreeVirtualStableCount = 0
    $script:HostFreeGameWindow = [IntPtr]::Zero
}

function Set-HostFreeGameVirtualLocked {
    param(
        [IntPtr]$WindowHandle,
        [string]$Details
    )

    $script:HostFreeGameOnVirtual = $true
    $script:HostFreeGameWindow = $WindowHandle
    $script:HostFreeVirtualStableCount = 0
    $script:HostFreeRemineAttempts = 0
    Set-ScriptMoveLogState "ok"
    Write-MonitorLog "Jogo estabilizado no monitor virtual. $Details"
}

function Test-HostFreeGameStillOnVirtual {
    param(
        [string]$GameDir,
        [System.Collections.Generic.HashSet[string]]$GameExecutableNames
    )

    $bounds = Get-HostFreeVirtualMonitorBounds
    if (-not $bounds) {
        return $false
    }

    $gameWindow = Find-GameWindowForHostFree -GameDir $GameDir -GameExecutableNames $GameExecutableNames
    if ($gameWindow -eq [IntPtr]::Zero) {
        return $true
    }

    $winInfo = [SunshineGameFocus]::GetWindowInfo($gameWindow)
    $width = if ($winInfo.Ok) { [int]$winInfo.Width } else { 0 }
    $height = if ($winInfo.Ok) { [int]$winInfo.Height } else { 0 }

    return (Test-HostFreeGameWindowOnVirtual -WindowHandle $gameWindow -Bounds $bounds `
        -Width $width -Height $height)
}

function Test-HostFreeGameNeedsMove {
    param(
        [string]$GameDir,
        [System.Collections.Generic.HashSet[string]]$GameExecutableNames
    )

    if (-not $script:HostFreeGameOnVirtual) {
        return $true
    }

    if (Test-HostFreeGameStillOnVirtual -GameDir $GameDir -GameExecutableNames $GameExecutableNames) {
        return $false
    }

    Reset-HostFreeGameVirtualLock -Reason "Jogo saiu do monitor virtual (ou janela principal mudou); re-movendo."
    $script:HostFreeMmtUsed = $false
    return $true
}

function Invoke-HostFreeVirtualPrimaryFallback {
    if ($script:HostFreePrimarySwapped) {
        return $false
    }

    if (-not (Get-Command Enable-HeadlessSteamVirtualPrimaryForGame -ErrorAction SilentlyContinue)) {
        return $false
    }

    Write-MonitorLog "Tentando monitor virtual como primario (jogos fullscreen)..."
    if (-not (Enable-HeadlessSteamVirtualPrimaryForGame)) {
        Write-MonitorLog "AVISO: Nao foi possivel tornar monitor virtual primario."
        return $false
    }

    $script:HostFreePrimarySwapped = $true
    Start-Sleep -Milliseconds 800
    Write-MonitorLog "Monitor virtual definido como primario para esta sessao."
    return $true
}

function Move-GameWindowToVirtualMonitor {
    param(
        [string]$GameDir,
        [System.Collections.Generic.HashSet[string]]$GameExecutableNames,
        [string]$SteamAppId = "",
        [switch]$Quiet
    )

    $bounds = Get-HostFreeVirtualMonitorBounds
    if (-not $bounds) {
        if (-not $Quiet) {
            Write-MonitorLog "AVISO: Monitor virtual nao encontrado."
        }
        return $false
    }

    $processIds = Get-GameProcessIds -GameDir $GameDir -GameExecutableNames $GameExecutableNames
    $sessionActive = ($processIds.Count -gt 0) -or ($SteamAppId -and (Test-SteamGameRunning -AppId $SteamAppId))
    if (-not $sessionActive) {
        if (-not $Quiet) {
            Set-ScriptMoveLogState "processo_ausente"
            Write-MonitorLog "Aguardando processo do jogo..."
        }
        return $false
    }

    if (-not $script:HostFreeMmtUsed) {
        Invoke-HeadlessSteamMoveGameViaMultiMonitorTool -VirtualDevice $bounds.device `
            -GameExecutableNames $GameExecutableNames | Out-Null
        $script:HostFreeMmtUsed = $true
        Start-Sleep -Milliseconds 400
    }

    $gameWindow = Find-GameWindowForHostFree -GameDir $GameDir -GameExecutableNames $GameExecutableNames
    if ($gameWindow -eq [IntPtr]::Zero) {
        if (-not $Quiet) {
            $state = "janela_ausente"
            if ((Get-ScriptMoveLogState) -ne $state) {
                Set-ScriptMoveLogState $state
                Write-MonitorLog "Aguardando janela do jogo."
            }
        }
        return $false
    }

    if (-not (Test-IsGameProcessWindow -WindowHandle $gameWindow -ProcessIds $processIds `
            -GameExecutableNames $GameExecutableNames -GameDir $GameDir)) {
        if (-not $Quiet) {
            Write-MonitorLog "Ignorando janela que nao e do jogo: $([SunshineGameFocus]::DescribeWindow($gameWindow))"
        }
        return $false
    }

    $title = [SunshineGameFocus]::GetWindowTitle($gameWindow)
    $winInfo = [SunshineGameFocus]::GetWindowInfo($gameWindow)
    $left = 0; $top = 0; $width = 0; $height = 0
    if ($winInfo.Ok) {
        $left = [int]$winInfo.Left
        $top = [int]$winInfo.Top
        $width = [int]$winInfo.Width
        $height = [int]$winInfo.Height
    }
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = [string]$winInfo.Title
    }

    $hasUsableBounds = ($width -ge 64 -and $height -ge 64)
    if (-not $hasUsableBounds -and [string]::IsNullOrWhiteSpace($title)) {
        if (-not $Quiet) {
            $state = "splash_${width}x${height}"
            if ((Get-ScriptMoveLogState) -ne $state) {
                Set-ScriptMoveLogState $state
                Write-MonitorLog "Aguardando janela principal (bounds ${width}x${height})..."
            }
        }
        return $false
    }

    if (-not (Test-HostFreeGameWindowReady -WindowHandle $gameWindow -Width $width -Height $height)) {
        if (-not $Quiet) {
            $state = "splash_${width}x${height}"
            if ((Get-ScriptMoveLogState) -ne $state) {
                Set-ScriptMoveLogState $state
                Write-MonitorLog "Aguardando janela principal (${width}x${height}). titulo='$title'"
            }
        }
        return $false
    }

    $descBefore = "${left},${top} ${width}x${height} title='$title'"

    if (Test-HostFreeGameWindowOnVirtual -WindowHandle $gameWindow -Bounds $bounds -Width $width -Height $height) {
        $script:HostFreeVirtualStableCount++
        if ($script:HostFreeVirtualStableCount -ge $script:HostFreeVirtualStableRequired) {
            if (-not $script:HostFreeGameOnVirtual) {
                Set-HostFreeGameVirtualLocked -WindowHandle $gameWindow -Details $descBefore
            }
            return $true
        }
        if (-not $Quiet) {
            $state = "estabilizando_$($script:HostFreeVirtualStableCount)"
            if ((Get-ScriptMoveLogState) -ne $state) {
                Set-ScriptMoveLogState $state
                Write-MonitorLog "Jogo no monitor virtual ($($script:HostFreeVirtualStableCount)/$($script:HostFreeVirtualStableRequired)). $descBefore"
            }
        }
        return $false
    }

    $script:HostFreeVirtualStableCount = 0

    if (-not $Quiet) {
        Set-ScriptMoveLogState "movendo"
        Write-MonitorLog "Movendo jogo para $($bounds.device). $descBefore"
    }

    $targetX = [int]$bounds.left
    $targetY = [int]$bounds.top
    $targetW = [int]$bounds.width
    $targetH = [int]$bounds.height

    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        [SunshineGameFocus]::TryMoveWindowNative($gameWindow, $targetX, $targetY, $targetW, $targetH) | Out-Null
        Start-Sleep -Milliseconds 300
        $afterMove = [SunshineGameFocus]::GetWindowInfo($gameWindow)
        $movedW = if ($afterMove.Ok) { [int]$afterMove.Width } else { $width }
        $movedH = if ($afterMove.Ok) { [int]$afterMove.Height } else { $height }
        if (Test-HostFreeGameWindowOnVirtual -WindowHandle $gameWindow -Bounds $bounds -Width $movedW -Height $movedH) {
            $script:HostFreeVirtualStableCount++
            if ($script:HostFreeVirtualStableCount -ge $script:HostFreeVirtualStableRequired) {
                Set-HostFreeGameVirtualLocked -WindowHandle $gameWindow `
                    -Details "titulo='$title' destino=$($bounds.device) (${targetW}x${targetH})"
                return $true
            }
            if (-not $Quiet) {
                Write-MonitorLog "Jogo no monitor virtual ($($script:HostFreeVirtualStableCount)/$($script:HostFreeVirtualStableRequired)). titulo='$title'"
            }
            return $false
        }
    }

    $script:HostFreeRemineAttempts++
    if ($script:HostFreeRemineAttempts -ge 3) {
        if (Invoke-HostFreeVirtualPrimaryFallback) {
            $script:HostFreeRemineAttempts = 0
            $script:HostFreeMmtUsed = $false
            $bounds = Get-HostFreeVirtualMonitorBounds
            if ($bounds) {
                $targetX = [int]$bounds.left
                $targetY = [int]$bounds.top
                $targetW = [int]$bounds.width
                $targetH = [int]$bounds.height
                for ($retry = 0; $retry -lt 4; $retry++) {
                    [SunshineGameFocus]::TryMoveWindowNative($gameWindow, $targetX, $targetY, $targetW, $targetH) | Out-Null
                    Start-Sleep -Milliseconds 400
                    $afterMove = [SunshineGameFocus]::GetWindowInfo($gameWindow)
                    $movedW = if ($afterMove.Ok) { [int]$afterMove.Width } else { $width }
                    $movedH = if ($afterMove.Ok) { [int]$afterMove.Height } else { $height }
                    if (Test-HostFreeGameWindowOnVirtual -WindowHandle $gameWindow -Bounds $bounds `
                            -Width $movedW -Height $movedH) {
                        Set-HostFreeGameVirtualLocked -WindowHandle $gameWindow `
                            -Details "titulo='$title' apos primario virtual"
                        return $true
                    }
                }
            }
        }
    }

    if (-not $Quiet) {
        $afterInfo = [SunshineGameFocus]::GetWindowInfo($gameWindow)
        $descAfter = if ($afterInfo.Ok) {
            "$([int]$afterInfo.Left),$([int]$afterInfo.Top) $([int]$afterInfo.Width)x$([int]$afterInfo.Height) title='$([SunshineGameFocus]::GetWindowTitle($gameWindow))'"
        } else {
            "sem bounds title='$([SunshineGameFocus]::GetWindowTitle($gameWindow))'"
        }
        $state = "falha_$descAfter"
        if ((Get-ScriptMoveLogState) -ne $state) {
            Set-ScriptMoveLogState $state
            Write-MonitorLog "AVISO: Nao foi possivel mover o jogo. antes=$descBefore depois=$descAfter"
        }
    }
    return $false
}

function Write-HeadlessSteamVirtualDisplayResolutionLog {
    $virtualRes = Get-HostFreeVirtualMonitorBounds
    if ($virtualRes) {
        Write-MonitorLog "Monitor virtual: $($virtualRes.width)x$($virtualRes.height) em $($virtualRes.device)"
    }
}

function Apply-HeadlessSteamVirtualDisplayResolution {
    $applied = Set-HeadlessSteamVirtualDisplayResolution
    foreach ($line in @($script:HeadlessSteamVirtualDisplayResolutionLog)) {
        Write-MonitorLog $line
    }

    if ($applied) {
        Write-HeadlessSteamVirtualDisplayResolutionLog
        return $true
    }
    Write-MonitorLog "AVISO: Nao foi possivel ajustar resolucao do monitor virtual."
    return $false
}

function Keep-GameFocused {
    param(
        [string]$GameDir,
        [System.Collections.Generic.HashSet[string]]$GameExecutableNames
    )

    try {
        $processIds = Get-GameProcessIds -GameDir $GameDir -GameExecutableNames $GameExecutableNames
        if ($processIds.Count -eq 0) { return }

        $gameWindow = Get-BestGameWindow -ProcessIds $processIds -GameExecutableNames $GameExecutableNames
        if ($gameWindow -eq [IntPtr]::Zero) { return }

        $foregroundPid = [SunshineGameFocus]::GetWindowProcessId(
            [SunshineGameFocus]::GetForegroundWindowHandle())
        $wrongFocus = -not (Test-GameProcessIdInSet -ProcessIds $processIds -ProcessId $foregroundPid)

        Hide-SteamLauncherWindows
        [SunshineGameFocus]::ForceForegroundWindow($gameWindow, $wrongFocus) | Out-Null

        foreach ($gameName in $GameExecutableNames) {
            foreach ($process in (Get-Process -Name $gameName -ErrorAction SilentlyContinue)) {
                try { [Microsoft.VisualBasic.Interaction]::AppActivate($process.Id) | Out-Null } catch {}
            }
        }

        if ($wrongFocus) {
            $title = [SunshineGameFocus]::GetWindowTitle($gameWindow)
            Write-MonitorLog "Foco corrigido. titulo='$title' fgAnteriorPid=$foregroundPid"
        }
    } catch {
        Write-MonitorLog "AVISO: Erro ao manter foco no jogo: $($_.Exception.Message)"
    }
}

. (Join-Path $script:ScriptDir "HeadlessSteam-HostSettings.ps1")
if ($HostFreeMode -and -not (Test-HeadlessSteamHostFreeModeEnabled)) {
    Write-MonitorLog "AVISO: -HostFreeMode ignorado (tela virtual desativada nas configuracoes)."
    $HostFreeMode = $false
}

if ($HostFreeMode) {
    $KeepFocus = $false
}

. (Join-Path $script:ScriptDir "HeadlessSteam-Display.ps1")

if (-not (Test-Path $SteamExe)) {
    Write-MonitorLog "ERRO: steam.exe nao encontrado em $SteamExe"
    exit 1
}

Write-MonitorLog "Sessao do usuario: monitoramento AppId=$AppId HostFreeMode=$HostFreeMode KeepFocus=$KeepFocus (launch v15)"
$gameExecutableNames = Get-GameExecutableNames -GameDir $InstallDir
Write-MonitorLog "Executaveis: $($gameExecutableNames -join ', ')"

if (-not $HostFreeMode) {
    try {
        Write-MonitorLog "Modo normal: desativando monitor virtual (sem reiniciar Sunshine)..."
        Ensure-HeadlessSteamNormalDisplayMode -SkipSunshineRestart | Out-Null
        Write-MonitorLog "Modo normal: pronto. Jogo na tela principal."
    } catch {
        Write-MonitorLog "AVISO: Modo normal setup: $($_.Exception.Message)"
    }
}

try {
    if (-not (Get-Process -Name "steam" -ErrorAction SilentlyContinue)) {
        Write-MonitorLog "Steam fechado. Abrindo..."
        Start-Process -FilePath $SteamExe -WindowStyle Hidden
        Start-Sleep -Seconds 4
    }

    if ($HostFreeMode) {
        Write-MonitorLog "Passo: host free setup..."
        Hide-SteamLauncherWindows
        if (Test-SteamGameRunning -AppId $AppId) {
            Write-MonitorLog "Steam ainda reporta AppId $AppId em execucao. Aguardando encerrar..."
            $clearDeadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $clearDeadline -and (Test-SteamGameRunning -AppId $AppId)) {
                Start-Sleep -Seconds 2
            }
        }
        Stop-HeadlessSteamGameProcesses -GameDir $InstallDir -GameExecutableNames $gameExecutableNames
        $script:HostFreeGameOnVirtual = $false
        $script:HostFreeMmtUsed = $false
        $script:HostFreeGameWindow = [IntPtr]::Zero
        $script:HostFreeVirtualStableCount = 0
        $script:HostFreeRemineAttempts = 0
        $physicalRes = Get-HeadlessSteamPhysicalMonitorSize
        if ($physicalRes) {
            Write-MonitorLog ("Resolucao alvo (monitor fisico): {0}x{1} em {2}" -f `
                $physicalRes.width, $physicalRes.height, $physicalRes.device_name)
        }
        $preVirtual = Get-HeadlessSteamVirtualMonitorBounds
        if ($preVirtual) {
            $script:HostFreeVirtualDevice = [string]$preVirtual.device
            Write-MonitorLog "Dispositivo virtual fixado: $($script:HostFreeVirtualDevice)"
        }
        Apply-HeadlessSteamVirtualDisplayResolution | Out-Null
        Focus-VirtualDisplayForGameLaunch | Out-Null
    }

    Write-MonitorLog "Passo: enviando applaunch..."
    Start-Process -FilePath $SteamExe -ArgumentList "-silent -applaunch $AppId" -WindowStyle Hidden
    Write-MonitorLog "Comando enviado: -silent -applaunch $AppId"

    $startupDeadline = (Get-Date).AddSeconds($StartupTimeoutSec)
    $gameDetected = $false

    while ((Get-Date) -lt $startupDeadline) {
        if (Test-SteamGameRunning -AppId $AppId) {
            $gameDetected = $true
            Write-MonitorLog "Steam reportou jogo em execucao."
            break
        }
        Start-Sleep -Milliseconds $PollIntervalMs
    }

    if (-not $gameDetected) {
        Write-MonitorLog "AVISO: Steam nao reportou jogo apos $StartupTimeoutSec s."
    } else {
        $stoppedPolls = 0
        $lastFocusAt = [DateTime]::MinValue

        while ($true) {
            if (Test-GameSessionActive -AppId $AppId -GameDir $InstallDir -GameExecutableNames $gameExecutableNames) {
                $stoppedPolls = 0

                if ($HostFreeMode) {
                    if (Test-HostFreeGameNeedsMove -GameDir $InstallDir -GameExecutableNames $gameExecutableNames) {
                        try {
                            Move-GameWindowToVirtualMonitor -GameDir $InstallDir `
                                -GameExecutableNames $gameExecutableNames -SteamAppId $AppId `
                                -Quiet:($script:HostFreeVirtualStableCount -gt 0) | Out-Null
                        } catch {
                            Write-MonitorLog "AVISO: Erro ao mover jogo: $($_.Exception.Message)"
                        }
                    }
                } elseif ($KeepFocus -and ((Get-Date) - $lastFocusAt).TotalMilliseconds -ge $FocusIntervalMs) {
                    Keep-GameFocused -GameDir $InstallDir -GameExecutableNames $gameExecutableNames
                    $lastFocusAt = Get-Date
                }
            } else {
                $stoppedPolls++
                if ($stoppedPolls -ge $StopConfirmCount) {
                    Write-MonitorLog "Sessao encerrada: Steam e processo do jogo ausentes ($stoppedPolls leituras)."
                    break
                }
            }

            $loopMs = if ($HostFreeMode) { 2000 } else { $PollIntervalMs }
            Start-Sleep -Milliseconds $loopMs
        }
    }
} catch {
    Write-MonitorLog "ERRO: $($_.Exception.Message)"
} finally {
    if ($HostFreeMode -and $script:HostFreePrimarySwapped) {
        try {
            if (Restore-HeadlessSteamPhysicalPrimaryAfterGame) {
                Write-MonitorLog "Monitor fisico restaurado como primario."
            }
        } catch {
            Write-MonitorLog "AVISO: Falha ao restaurar monitor fisico: $($_.Exception.Message)"
        }
        $script:HostFreePrimarySwapped = $false
    }
}

Write-MonitorLog "Jogo encerrado. Fim da sessao."
exit 0
