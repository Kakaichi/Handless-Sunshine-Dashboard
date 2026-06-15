function Get-HeadlessSteamActiveConsoleSessionId {
    if (-not ("NativeSession" -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NativeSession {
    [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
}
'@
    }

    return [NativeSession]::WTSGetActiveConsoleSessionId()
}

function Get-HeadlessSteamInteractiveUserInfo {
    $activeSession = Get-HeadlessSteamActiveConsoleSessionId

    $explorers = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $activeSession })

    foreach ($explorer in $explorers) {
        try {
            $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction Stop
            if ($owner.User -match '^(SYSTEM|LOCAL SERVICE|NETWORK SERVICE)$') { continue }

            $account = if ($owner.Domain -and $owner.Domain -ne $owner.User) {
                "$($owner.Domain)\$($owner.User)"
            } else {
                $owner.User
            }

            $sid = ([System.Security.Principal.NTAccount]$account).Translate(
                [System.Security.Principal.SecurityIdentifier]
            ).Value

            $profilePath = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
            if (-not $profilePath) { continue }

            return [pscustomobject]@{
                UserName      = $account
                Sid           = $sid
                ProfilePath   = $profilePath
                ConsoleSessionId = [int]$activeSession
                Source        = "explorer"
            }
        } catch {
        }
    }

    $loggedInUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if ($loggedInUser -and $loggedInUser -notmatch '\\\$') {
        try {
            $sid = ([System.Security.Principal.NTAccount]$loggedInUser).Translate(
                [System.Security.Principal.SecurityIdentifier]
            ).Value
            $profilePath = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
            if ($profilePath) {
                return [pscustomobject]@{
                    UserName      = $loggedInUser
                    Sid           = $sid
                    ProfilePath   = $profilePath
                    ConsoleSessionId = [int]$activeSession
                    Source        = "Win32_ComputerSystem"
                }
            }
        } catch {
        }
    }

    return $null
}
