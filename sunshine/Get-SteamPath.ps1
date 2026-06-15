function Add-SteamPathCandidate {
    param(
        [System.Collections.Generic.List[string]]$Candidates,
        [string]$Path,
        [switch]$Prepend
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    $normalized = $Path.Trim().TrimEnd('\', '/')
    if (-not $normalized) { return }

    if ($Candidates.Contains($normalized)) { return }

    if ($Prepend) {
        $Candidates.Insert(0, $normalized) | Out-Null
    } else {
        $Candidates.Add($normalized) | Out-Null
    }
}

function Get-HeadlessSteamInteractiveSteamRegistryKey {
    $interactiveUserScript = Join-Path $PSScriptRoot "HeadlessSteam-InteractiveUser.ps1"
    if (-not (Test-Path -LiteralPath $interactiveUserScript)) {
        return $null
    }

    . $interactiveUserScript
    $info = Get-HeadlessSteamInteractiveUserInfo
    if (-not $info -or -not $info.Sid) {
        return $null
    }

    return "Registry::HKEY_USERS\$($info.Sid)\Software\Valve\Steam"
}

function Get-SteamInstallCandidates {
    $candidates = New-Object System.Collections.Generic.List[string]

    $interactiveSteamKey = Get-HeadlessSteamInteractiveSteamRegistryKey
    if ($interactiveSteamKey -and (Test-Path -LiteralPath $interactiveSteamKey)) {
        $props = Get-ItemProperty -Path $interactiveSteamKey -ErrorAction SilentlyContinue
        Add-SteamPathCandidate -Candidates $candidates -Path $props.SteamPath -Prepend
    }

    foreach ($key in @(
        "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam",
        "HKLM:\SOFTWARE\Valve\Steam"
    )) {
        if (-not (Test-Path $key)) { continue }
        $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        Add-SteamPathCandidate -Candidates $candidates -Path $props.InstallPath
        Add-SteamPathCandidate -Candidates $candidates -Path $props.SteamPath
    }

    if (Test-Path "HKCU:\Software\Valve\Steam") {
        $props = Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue
        Add-SteamPathCandidate -Candidates $candidates -Path $props.SteamPath
    }

    Get-ChildItem "Registry::HKEY_USERS" -ErrorAction SilentlyContinue | ForEach-Object {
        $sid = $_.PSChildName
        if ($sid -notmatch "^S-1-5-21-") { return }

        $userKey = "Registry::HKEY_USERS\$sid\Software\Valve\Steam"
        if (-not (Test-Path $userKey)) { return }

        $props = Get-ItemProperty -Path $userKey -ErrorAction SilentlyContinue
        Add-SteamPathCandidate -Candidates $candidates -Path $props.SteamPath
    }

    foreach ($pattern in @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )) {
        Get-ItemProperty $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.DisplayName -match "Steam" -and $_.InstallLocation) {
                Add-SteamPathCandidate -Candidates $candidates -Path $_.InstallLocation
            }
        }
    }

    Get-Process -Name steam -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            if ($_.Path) {
                Add-SteamPathCandidate -Candidates $candidates -Path (Split-Path -Parent $_.Path)
            }
        } catch {
        }
    }

    foreach ($drive in (Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue)) {
        $letter = $drive.DeviceID
        foreach ($sub in @(
            "$letter\Program Files (x86)\Steam",
            "$letter\Program Files\Steam",
            "$letter\Steam",
            "$letter\Games\Steam",
            "$letter\Jogos\Steam"
        )) {
            Add-SteamPathCandidate -Candidates $candidates -Path $sub
        }
    }

    Add-SteamPathCandidate -Candidates $candidates -Path "${env:ProgramFiles(x86)}\Steam"
    Add-SteamPathCandidate -Candidates $candidates -Path "$env:ProgramFiles\Steam"

    return $candidates
}

function Get-SteamExePath {
    foreach ($root in Get-SteamInstallCandidates) {
        $exe = Join-Path $root "steam.exe"
        if (Test-Path $exe) {
            return (Resolve-Path $exe).Path
        }
    }

    return $null
}

function Get-SteamInstallPath {
    $exe = Get-SteamExePath
    if ($exe) {
        return (Split-Path -Parent $exe)
    }

    return $null
}

function Test-SteamInstalled {
    return $null -ne (Get-SteamExePath)
}

function Test-SteamLibraryRootAvailable {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) { return $false }

    try {
        $drive = [System.IO.Path]::GetPathRoot($Root)
        if ($drive -and -not (Test-Path -LiteralPath $drive)) {
            return $false
        }
        return $true
    } catch {
        return $false
    }
}

function Get-SteamLibraryRoots {
    param([switch]$Quiet)

    $roots = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    $steamRoot = Get-SteamInstallPath

    function Add-LibraryRoot {
        param([string]$Path)

        if (-not $Path -or $roots.Contains($Path) -or $skipped.Contains($Path)) { return }

        if (-not (Test-SteamLibraryRootAvailable $Path)) {
            $skipped.Add($Path) | Out-Null
            if (-not $Quiet) {
                Write-Host "Ignorando biblioteca (unidade ausente): $Path"
            }
            return
        }

        $roots.Add($Path) | Out-Null
    }

    Add-LibraryRoot $steamRoot

    $vdfFiles = @()
    if ($steamRoot) {
        $vdfFiles += Join-Path $steamRoot "steamapps\libraryfolders.vdf"
        $vdfFiles += Join-Path $steamRoot "config\libraryfolders.vdf"
    }

    foreach ($vdf in $vdfFiles) {
        if (-not (Test-Path $vdf)) { continue }

        $content = Get-Content $vdf -Raw
        foreach ($match in [regex]::Matches($content, '"path"\s+"([^"]+)"')) {
            $path = $match.Groups[1].Value -replace '\\\\', '\'
            Add-LibraryRoot $path
        }
    }

    return $roots
}
