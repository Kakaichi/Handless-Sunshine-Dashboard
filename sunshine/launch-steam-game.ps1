param(
    [Parameter(Mandatory = $true)][string]$AppId,
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $true)][string]$SteamExe,
    [int]$StartupTimeoutSec = 300,
    [int]$PollIntervalMs = 500,
    [int]$StopConfirmCount = 2,
    [int]$FocusIntervalMs = 300,
    [switch]$KeepFocus = $true,
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
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_SHOWWINDOW = 0x0040;

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
    [DllImport("user32.dll")] private static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] private static extern bool AllowSetForegroundWindow(int dwProcessId);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern void mouse_event(int dwFlags, int dx, int dy, int dwData, int dwExtraInfo);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();

    public static string GetWindowTitle(IntPtr hWnd) {
        int len = GetWindowTextLength(hWnd);
        var sb = new StringBuilder(Math.Max(len + 1, 1));
        GetWindowText(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static int GetWindowProcessId(IntPtr hWnd) {
        uint pid; GetWindowThreadProcessId(hWnd, out pid); return (int)pid;
    }

    public static IntPtr FindBestWindow(ISet<int> processIds, int minWidth, int minHeight) {
        IntPtr best = IntPtr.Zero; long bestScore = 0;
        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            uint pid; GetWindowThreadProcessId(hWnd, out pid);
            if (!processIds.Contains((int)pid)) return true;
            string title = GetWindowTitle(hWnd);
            if (title.Contains("MSCTFIME UI") || title.Contains("Default IME")) return true;
            RECT rect; if (!GetWindowRect(hWnd, out rect)) return true;
            int w = rect.Right - rect.Left, h = rect.Bottom - rect.Top;
            if (w < minWidth || h < minHeight) return true;
            long score = (long)w * h;
            if (!string.IsNullOrWhiteSpace(title)) score += 1000000000L;
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
        uint fgThread = GetWindowThreadProcessId(fg, out _);
        uint targetThread = GetWindowThreadProcessId(hWnd, out _);
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
}
"@
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
    return $processIds
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

function Get-BestGameWindow {
    param(
        [System.Collections.Generic.HashSet[int]]$ProcessIds,
        [System.Collections.Generic.HashSet[string]]$GameExecutableNames
    )

    foreach ($gameName in $GameExecutableNames) {
        foreach ($process in (Get-Process -Name $gameName -ErrorAction SilentlyContinue)) {
            if ($process.MainWindowHandle -ne 0) {
                return $process.MainWindowHandle
            }
        }
    }

    $best = [SunshineGameFocus]::FindBestWindow($ProcessIds, 640, 480)
    if ($best -ne [IntPtr]::Zero) { return $best }
    return [SunshineGameFocus]::FindBestWindow($ProcessIds, 200, 150)
}

function Keep-GameFocused {
    param(
        [string]$GameDir,
        [System.Collections.Generic.HashSet[string]]$GameExecutableNames
    )

    $processIds = Get-GameProcessIds -GameDir $GameDir -GameExecutableNames $GameExecutableNames
    if ($processIds.Count -eq 0) { return }

    $gameWindow = Get-BestGameWindow -ProcessIds $processIds -GameExecutableNames $GameExecutableNames
    if ($gameWindow -eq [IntPtr]::Zero) { return }

    $foregroundPid = [SunshineGameFocus]::GetWindowProcessId([SunshineGameFocus]::GetForegroundWindow())
    $wrongFocus = -not $processIds.Contains($foregroundPid)

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
}

if (-not (Test-Path $SteamExe)) {
    Write-MonitorLog "ERRO: steam.exe nao encontrado em $SteamExe"
    exit 1
}

Write-MonitorLog "Sessao do usuario: monitoramento + foco AppId=$AppId"
$gameExecutableNames = Get-GameExecutableNames -GameDir $InstallDir
Write-MonitorLog "Executaveis: $($gameExecutableNames -join ', ')"

if (-not (Get-Process -Name "steam" -ErrorAction SilentlyContinue)) {
    Write-MonitorLog "Steam fechado. Abrindo..."
    Start-Process -FilePath $SteamExe -WindowStyle Hidden
    Start-Sleep -Seconds 4
}

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
    exit 0
}

$stoppedPolls = 0
$lastFocusAt = [DateTime]::MinValue

while ($true) {
    if (Test-SteamGameRunning -AppId $AppId) {
        $stoppedPolls = 0

        if ($KeepFocus -and ((Get-Date) - $lastFocusAt).TotalMilliseconds -ge $FocusIntervalMs) {
            Keep-GameFocused -GameDir $InstallDir -GameExecutableNames $gameExecutableNames
            $lastFocusAt = Get-Date
        }
    } else {
        $stoppedPolls++
        if ($stoppedPolls -ge $StopConfirmCount) { break }
    }

    Start-Sleep -Milliseconds $PollIntervalMs
}

Write-MonitorLog "Jogo encerrado. Fim da sessao."
exit 0
