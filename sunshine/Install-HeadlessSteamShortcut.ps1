. (Join-Path $PSScriptRoot "HeadlessSteam-InteractiveUser.ps1")

function Get-InteractiveUserInfo {
    return Get-HeadlessSteamInteractiveUserInfo
}

function Get-ActiveConsoleSessionId {
    return Get-HeadlessSteamActiveConsoleSessionId
}

function Expand-UserRegistryPath {
    param(
        [string]$Path,
        [string]$Sid,
        [string]$ProfilePath
    )

    if (-not $Path) { return $null }

    $expanded = $Path
    $envKey = "Registry::HKEY_USERS\$Sid\Environment"
    if (Test-Path $envKey) {
        $envBlock = Get-ItemProperty $envKey -ErrorAction SilentlyContinue
        if ($envBlock.USERPROFILE) {
            $expanded = $expanded -replace [regex]::Escape('%USERPROFILE%'), $envBlock.USERPROFILE
        }
        if ($envBlock.OneDrive) {
            $expanded = $expanded -replace [regex]::Escape('%ONEDRIVE%'), $envBlock.OneDrive
        }
        if ($envBlock.OneDriveConsumer) {
            $expanded = $expanded -replace [regex]::Escape('%ONEDRIVECONSUMER%'), $envBlock.OneDriveConsumer
        }
    }

    $expanded = $expanded -replace [regex]::Escape('%USERPROFILE%'), $ProfilePath
    return $expanded
}

function Get-UserDesktopPaths {
    param(
        [Parameter(Mandatory = $true)][string]$Sid,
        [Parameter(Mandatory = $true)][string]$ProfilePath
    )

    $paths = New-Object System.Collections.Generic.List[string]

    function Add-DesktopPath {
        param([string]$Path)
        if (-not $Path) { return }
        if ($Path -match '%') { return }
        if (-not $paths.Contains($Path)) {
            $paths.Add($Path) | Out-Null
        }
    }

    $shellFoldersKey = "Registry::HKEY_USERS\$Sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
    if (Test-Path $shellFoldersKey) {
        $desktopFromReg = (Get-ItemProperty $shellFoldersKey -Name Desktop -ErrorAction SilentlyContinue).Desktop
        Add-DesktopPath (Expand-UserRegistryPath -Path $desktopFromReg -Sid $Sid -ProfilePath $ProfilePath)
    }

    foreach ($candidate in @(
        (Join-Path $ProfilePath "OneDrive\Área de Trabalho"),
        (Join-Path $ProfilePath "OneDrive\Desktop"),
        (Join-Path $ProfilePath "OneDrive - Personal\Desktop"),
        (Join-Path $ProfilePath "OneDrive - Personal\Área de Trabalho"),
        (Join-Path $ProfilePath "Desktop")
    )) {
        if (Test-Path $candidate) {
            Add-DesktopPath $candidate
        }
    }

    if ($paths.Count -eq 0) {
        Add-DesktopPath (Join-Path $ProfilePath "Desktop")
    }

    return $paths
}

function Get-WindowsTerminalPath {
    $localWt = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\wt.exe"
    if (Test-Path $localWt) {
        return $localWt
    }

    $wtCmd = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wtCmd) {
        return $wtCmd.Source
    }

    return $null
}

function Set-ShortcutRunAsAdministrator {
    param([Parameter(Mandatory = $true)][string]$ShortcutPath)

    $bytes = [System.IO.File]::ReadAllBytes($ShortcutPath)
    if ($bytes.Length -lt 0x16) {
        throw "Atalho invalido: $ShortcutPath"
    }

    # SLDF_RUNAS_USER (0x2000) no ShellLinkHeader.dwFlags
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [System.IO.File]::WriteAllBytes($ShortcutPath, $bytes)
}

$script:HeadlessSteamAppDisplayName = "Handless Sunshine Dashboard"
$script:HeadlessSteamLegacyShortcutNames = @(
    "Headless Steam",
    "Sunshine UX Dashboard"
)

function Get-HeadlessSteamExePath {
    param(
        [Parameter(Mandatory = $true)][string]$SunshineDir
    )

    $override = $env:HEADLESS_STEAM_EXE
    if ($override -and (Test-Path $override)) {
        return (Resolve-Path $override).Path
    }

    $parent = Split-Path -Parent $SunshineDir
    $candidates = @(
        (Join-Path $parent "HandlessSteam.exe"),
        (Join-Path $parent "HeadlessSteam.exe"),
        (Join-Path $parent "headless-steam-app\dist\HandlessSteam\HandlessSteam.exe")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }

    return $null
}

function Install-HeadlessSteamDesktopShortcut {
    param(
        [string]$SunshineDir,
        [string]$ExePath,
        [string]$BatPath,
        [string]$IconPath,
        [string]$ShortcutName = $script:HeadlessSteamAppDisplayName
    )

    if (-not $SunshineDir) {
        $SunshineDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    }

    if (-not $BatPath) {
        $BatPath = Join-Path $SunshineDir "gerenciar-servicos.bat"
    }

    if (-not $IconPath) {
        $IconPath = Join-Path $SunshineDir "favicon.ico"
    }

    if (-not $ExePath) {
        $ExePath = Get-HeadlessSteamExePath -SunshineDir $SunshineDir
    } elseif (Test-Path $ExePath) {
        $ExePath = (Resolve-Path $ExePath).Path
    } else {
        $ExePath = $null
    }

    $useExe = [bool]$ExePath
    if (-not $useExe -and -not (Test-Path $BatPath)) {
        Write-Host "  ERRO: HandlessSteam.exe e gerenciar-servicos.bat nao encontrados."
        return $false
    }

    if (-not (Test-Path $IconPath)) {
        Write-Host "  AVISO: favicon.ico nao encontrado; atalho usara icone padrao."
        $IconPath = if ($useExe) { $ExePath } else { $BatPath }
    }

    $userInfo = Get-InteractiveUserInfo
    if (-not $userInfo) {
        Write-Host "  ERRO: nao foi possivel detectar o usuario logado na sessao ativa."
        return $false
    }

    $desktopDirs = Get-UserDesktopPaths -Sid $userInfo.Sid -ProfilePath $userInfo.ProfilePath
    $batFullPath = if (Test-Path $BatPath) { (Resolve-Path $BatPath).Path } else { $null }
    $iconFullPath = if (Test-Path $IconPath) { (Resolve-Path $IconPath).Path } else { if ($useExe) { $ExePath } else { $batFullPath } }
    $wtPath = Get-WindowsTerminalPath
    $createdPaths = New-Object System.Collections.Generic.List[string]

    if ($useExe) {
        $targetPath = $ExePath
        $arguments = ""
        $workingDir = Split-Path -Parent $ExePath
    } else {
        $workingDir = Split-Path -Parent $BatPath
        if ($wtPath) {
            $targetPath = $wtPath
            $arguments = "--title `"$($script:HeadlessSteamAppDisplayName)`" -d `"$workingDir`" cmd /k `"$batFullPath`""
        } else {
            $targetPath = $batFullPath
            $arguments = ""
        }
    }

    foreach ($desktopDir in $desktopDirs) {
        if (-not (Test-Path $desktopDir)) {
            New-Item -ItemType Directory -Force -Path $desktopDir | Out-Null
        }

        foreach ($legacyName in $script:HeadlessSteamLegacyShortcutNames) {
            $legacyShortcut = Join-Path $desktopDir "$legacyName.lnk"
            if (Test-Path $legacyShortcut) {
                Remove-Item -LiteralPath $legacyShortcut -Force -ErrorAction SilentlyContinue
            }
        }

        $shortcutPath = Join-Path $desktopDir "$ShortcutName.lnk"
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $targetPath
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = $workingDir
        $shortcut.WindowStyle = 1
        $shortcut.Description = "$($script:HeadlessSteamAppDisplayName) - Sunshine, Tailscale e Moonlight Web"
        $shortcut.IconLocation = "$iconFullPath,0"
        $shortcut.Save()
        Set-ShortcutRunAsAdministrator -ShortcutPath $shortcutPath
        $createdPaths.Add($shortcutPath) | Out-Null
    }

    Write-Host "[OK] Atalho $($script:HeadlessSteamAppDisplayName) para $($userInfo.UserName):"
    if ($useExe) {
        Write-Host "     Destino: HandlessSteam.exe (interface grafica)"
        Write-Host "     $ExePath"
    } elseif ($wtPath) {
        Write-Host "     Destino: gerenciar-servicos.bat via Windows Terminal"
    } else {
        Write-Host "     Destino: gerenciar-servicos.bat (CMD)"
        Write-Host "     AVISO: Windows Terminal nao encontrado; instale para links clicaveis."
        Write-Host "     AVISO: Execute .\build.ps1 para gerar HandlessSteam.exe e usar a interface grafica."
    }
    foreach ($path in $createdPaths) {
        Write-Host "     $path"
    }
    return $true
}

if ($MyInvocation.InvocationName -ne '.') {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $null = Install-HeadlessSteamDesktopShortcut -SunshineDir $scriptDir
}
