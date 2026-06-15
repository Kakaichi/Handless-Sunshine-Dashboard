$ErrorActionPreference = "Stop"

if (-not ([System.Management.Automation.PSTypeName]"SunshineUserProcess").Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class SunshineUserProcess {
    private const int SW_HIDE = 0;
    private const uint TOKEN_DUPLICATE = 0x0002;
    private const uint TOKEN_QUERY = 0x0008;
    private const uint TOKEN_ASSIGN_PRIMARY = 0x0001;
    private const uint TOKEN_ALL_ACCESS = 0xF01FF;
    private const int SecurityImpersonation = 2;
    private const int TokenPrimary = 1;
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    private const uint CREATE_NO_WINDOW = 0x08000000;
    private const int PROCESS_QUERY_INFORMATION = 0x0400;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(int dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool DuplicateTokenEx(
        IntPtr existingToken,
        uint desiredAccess,
        IntPtr tokenAttributes,
        int impersonationLevel,
        int tokenType,
        out IntPtr duplicateToken);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessAsUser(
        IntPtr token,
        string applicationName,
        string commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll")]
    private static extern uint WTSGetActiveConsoleSessionId();

    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSQueryUserToken(uint sessionId, out IntPtr token);

    private static IntPtr GetInteractiveUserToken() {
        uint sessionId = WTSGetActiveConsoleSessionId();
        if (sessionId != 0xFFFFFFFF) {
            IntPtr sessionToken;
            if (WTSQueryUserToken(sessionId, out sessionToken)) {
                return sessionToken;
            }
        }

        Process[] explorers = Process.GetProcessesByName("explorer");
        if (explorers != null && explorers.Length > 0) {
            foreach (Process explorer in explorers) {
                if (sessionId != 0xFFFFFFFF && explorer.SessionId != (int)sessionId) {
                    continue;
                }

                IntPtr processHandle = OpenProcess(PROCESS_QUERY_INFORMATION, false, explorer.Id);
                if (processHandle == IntPtr.Zero) {
                    continue;
                }

                IntPtr token;
                if (OpenProcessToken(processHandle, TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ASSIGN_PRIMARY, out token)) {
                    CloseHandle(processHandle);
                    return token;
                }
                CloseHandle(processHandle);
            }
        }

        return IntPtr.Zero;
    }

    public static int LastWin32Error { get; private set; }

    public static int Start(string commandLine, string workingDirectory) {
        LastWin32Error = 0;
        IntPtr sourceToken = GetInteractiveUserToken();
        if (sourceToken == IntPtr.Zero) {
            return -1;
        }

        IntPtr primaryToken;
        if (!DuplicateTokenEx(
            sourceToken,
            TOKEN_ALL_ACCESS,
            IntPtr.Zero,
            SecurityImpersonation,
            TokenPrimary,
            out primaryToken)) {
            CloseHandle(sourceToken);
            return -2;
        }

        CloseHandle(sourceToken);

        STARTUPINFO startupInfo = new STARTUPINFO();
        startupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        startupInfo.lpDesktop = "winsta0\\default";

        PROCESS_INFORMATION processInfo;
        string cmd = commandLine;
        bool created = CreateProcessAsUser(
            primaryToken,
            null,
            cmd,
            IntPtr.Zero,
            IntPtr.Zero,
            false,
            CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW,
            IntPtr.Zero,
            string.IsNullOrEmpty(workingDirectory) ? Environment.CurrentDirectory : workingDirectory,
            ref startupInfo,
            out processInfo);

        CloseHandle(primaryToken);

        if (!created) {
            LastWin32Error = Marshal.GetLastWin32Error();
            return -3;
        }

        int pid = processInfo.dwProcessId;
        CloseHandle(processInfo.hThread);
        CloseHandle(processInfo.hProcess);
        return pid;
    }
}
"@
}

function Start-UserSessionProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$ArgumentList = "",
        [string]$WorkingDirectory = ""
    )

    if (-not $WorkingDirectory) {
        $WorkingDirectory = (Get-Location).Path
    }

    $commandLine = "`"$FilePath`""
    if ($ArgumentList) {
        $commandLine += " $ArgumentList"
    }

    return [SunshineUserProcess]::Start($commandLine, $WorkingDirectory)
}
