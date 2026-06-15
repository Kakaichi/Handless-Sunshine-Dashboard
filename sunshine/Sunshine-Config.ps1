function Get-SunshineServiceImagePath {
    $svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\SunshineService"
    if (-not (Test-Path $svcKey)) {
        return $null
    }

    $props = Get-ItemProperty -Path $svcKey -ErrorAction SilentlyContinue
    if (-not $props -or -not $props.ImagePath) {
        return $null
    }

    $raw = [string]$props.ImagePath.Trim()
    $exePath = $null
    if ($raw.StartsWith('"')) {
        $endQuote = $raw.IndexOf('"', 1)
        if ($endQuote -gt 1) {
            $exePath = $raw.Substring(1, $endQuote - 1)
        }
    } else {
        $exePath = ($raw -split '\s+', 2)[0]
    }

    if (-not $exePath -or -not (Test-Path -LiteralPath $exePath)) {
        return $null
    }

    return $exePath
}

function Get-SunshineServiceInstallDirectory {
    $exePath = Get-SunshineServiceImagePath
    if ($exePath) {
        return Split-Path -Parent $exePath
    }
    return $null
}

function Get-ConfigDirsNearServiceImage {
    param([string]$ImagePath)

    $dirs = New-Object System.Collections.Generic.List[string]
    if (-not $ImagePath) {
        return @()
    }

    $exeDir = Split-Path -Parent $ImagePath
    $leaf = Split-Path -Leaf $exeDir

    if ($leaf -match '^(tools|bin)$') {
        $parentConfig = Join-Path (Split-Path -Parent $exeDir) "config"
        [void]$dirs.Add($parentConfig)
    }

    [void]$dirs.Add((Join-Path $exeDir "config"))
    return @($dirs)
}

function Get-SunshineInstallRootCandidates {
    $candidates = New-Object System.Collections.Generic.List[string]

    function Add-SunshineCandidate {
        param([string]$Path)
        if ($Path -and -not $candidates.Contains($Path)) {
            $candidates.Add($Path) | Out-Null
        }
    }

    $serviceRoot = Get-SunshineServiceInstallDirectory
    if ($serviceRoot) {
        Add-SunshineCandidate $serviceRoot
    }

    Add-SunshineCandidate (Join-Path $env:ProgramFiles "Sunshine")
    $programFilesX86 = ${env:ProgramFiles(x86)}
    if ($programFilesX86) {
        Add-SunshineCandidate (Join-Path $programFilesX86 "Sunshine")
    }
    Add-SunshineCandidate (Join-Path $env:ProgramData "Sunshine")
    Add-SunshineCandidate (Join-Path $env:LOCALAPPDATA "Sunshine")

    foreach ($pattern in @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )) {
        Get-ItemProperty $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.DisplayName -match "Sunshine" -and $_.InstallLocation) {
                Add-SunshineCandidate ($_.InstallLocation.TrimEnd('\'))
            }
        }
    }

    return @($candidates)
}

function Resolve-SunshineConfigDirectoryFromRoot {
    param([string]$Root)

    if (-not $Root) {
        return $null
    }

    $leaf = Split-Path -Leaf $Root
    if ($leaf -match '^(tools|bin)$') {
        $parentConfig = Join-Path (Split-Path -Parent $Root) "config"
        if ((Test-Path (Join-Path $parentConfig "sunshine.conf")) -or (Test-Path (Join-Path $parentConfig "apps.json"))) {
            return $parentConfig
        }
    }

    $configDir = Join-Path $Root "config"
    if (Test-Path (Join-Path $configDir "sunshine.conf")) {
        return $configDir
    }

    if (Test-Path (Join-Path $configDir "apps.json")) {
        return $configDir
    }

    if (Test-Path (Join-Path $Root "sunshine.exe")) {
        return $configDir
    }

    if ((Test-Path (Join-Path $Root "apps.json")) -or (Test-Path (Join-Path $Root "sunshine.conf"))) {
        return $Root
    }

    return $null
}

function Get-SunshineConfigDirectoryCandidates {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $ordered = New-Object System.Collections.Generic.List[string]

    function Add-ConfigCandidate {
        param([string]$Dir)
        if (-not $Dir) {
            return
        }
        $normalized = $Dir.TrimEnd('\')
        if ($seen.Add($normalized)) {
            [void]$ordered.Add($normalized)
        }
    }

    $imagePath = Get-SunshineServiceImagePath
    foreach ($dir in (Get-ConfigDirsNearServiceImage -ImagePath $imagePath)) {
        Add-ConfigCandidate $dir
    }

    foreach ($root in Get-SunshineInstallRootCandidates) {
        $configDir = Resolve-SunshineConfigDirectoryFromRoot -Root $root
        if ($configDir) {
            Add-ConfigCandidate $configDir
        }
    }

    return @($ordered)
}

function Get-SunshineConfigDirectory {
    $candidates = Get-SunshineConfigDirectoryCandidates
    if ($candidates.Count -gt 0) {
        return $candidates[0]
    }

    if ($null -ne (Get-Service -Name "SunshineService" -ErrorAction SilentlyContinue)) {
        $serviceRoot = Get-SunshineServiceInstallDirectory
        if ($serviceRoot) {
            $leaf = Split-Path -Leaf $serviceRoot
            if ($leaf -match '^(tools|bin)$') {
                return Join-Path (Split-Path -Parent $serviceRoot) "config"
            }
            return Join-Path $serviceRoot "config"
        }
        return Join-Path $env:ProgramFiles "Sunshine\config"
    }

    return $null
}

function Initialize-SunshineDefaults {
    param([string]$SunshineConf)

    $configDir = Split-Path -Parent $SunshineConf
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    }

    $defaults = [ordered]@{
        "gamepad"                   = "ds4"
        "motion_as_ds4"             = "enabled"
        "touchpad_as_ds4"           = "enabled"
        "ds4_back_as_touchpad_click" = "enabled"
        "origin_web_ui_allowed"     = "wan"
        "origin_pin_allowed"        = "wan"
    }

    $lines = @()
    if (Test-Path $SunshineConf) {
        $lines = @(Get-Content -Path $SunshineConf -ErrorAction SilentlyContinue)
    }

    foreach ($entry in $defaults.GetEnumerator()) {
        $key = [string]$entry.Key
        $value = [string]$entry.Value
        $pattern = "^\s*$([regex]::Escape($key))\s*="
        $found = $false

        $lines = @($lines | ForEach-Object {
            if ($_ -match $pattern) {
                $found = $true
                "$key = $value"
            } else {
                $_
            }
        })

        if (-not $found) {
            $lines += "$key = $value"
        }
    }

    $lines | Set-Content -Path $SunshineConf -Encoding UTF8
}

function Get-SunshineDefaultAssetPath {
    param([Parameter(Mandatory = $true)][string]$FileName)

    foreach ($root in Get-SunshineInstallRootCandidates) {
        $leaf = Split-Path -Leaf $root
        $candidates = @(
            (Join-Path $root "assets\$FileName")
        )
        if ($leaf -match '^(tools|bin)$') {
            $parent = Split-Path -Parent $root
            $candidates += Join-Path $parent "assets\$FileName"
        }

        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }

    return $null
}

function Test-ValidSunshineCoverPng {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        $file = Get-Item -LiteralPath $Path
        if ($file.Length -lt 100) {
            return $false
        }
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 8) {
            return $false
        }
        $pngSig = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
        for ($i = 0; $i -lt 8; $i++) {
            if ($bytes[$i] -ne $pngSig[$i]) {
                return $false
            }
        }
        return $true
    } catch {
        return $false
    }
}

function Write-SunshineAppsJsonForConfig {
    param(
        [Parameter(Mandatory = $true)][string]$AppsFile,
        [Parameter(Mandatory = $true)][string]$DestAppsJson,
        [Parameter(Mandatory = $true)][string]$DestCoversDir,
        [Parameter(Mandatory = $true)][string]$SourceCoversDir
    )

    $data = Get-Content -Path $AppsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $coversCopied = 0

    New-Item -ItemType Directory -Force -Path $DestCoversDir | Out-Null

    foreach ($app in @($data.apps)) {
        $imagePath = [string]$app.'image-path'
        if (-not $imagePath) {
            continue
        }

        if ($imagePath -in @("steam.png", "desktop.png")) {
            $assetPath = Get-SunshineDefaultAssetPath -FileName $imagePath
            if ($assetPath) {
                $app.'image-path' = $assetPath
            }
            continue
        }

        $sourcePath = if ([System.IO.Path]::IsPathRooted($imagePath)) {
            $imagePath
        } else {
            Join-Path $SourceCoversDir (Split-Path -Leaf $imagePath)
        }

        if (-not (Test-Path -LiteralPath $sourcePath)) {
            $sourcePath = Join-Path $SourceCoversDir (Split-Path -Leaf $imagePath)
        }

        if (-not (Test-Path -LiteralPath $sourcePath)) {
            continue
        }

        $destName = Split-Path -Leaf $sourcePath
        $destPath = Join-Path $DestCoversDir $destName

        $needsCopy = $true
        if (Test-Path -LiteralPath $destPath) {
            $sourceInfo = Get-Item -LiteralPath $sourcePath
            $destInfo = Get-Item -LiteralPath $destPath
            if ($sourceInfo.Length -eq $destInfo.Length -and
                $sourceInfo.LastWriteTimeUtc -le $destInfo.LastWriteTimeUtc -and
                (Test-ValidSunshineCoverPng -Path $destPath)) {
                $needsCopy = $false
            }
        }

        if ($needsCopy) {
            Copy-Item -LiteralPath $sourcePath -Destination $destPath -Force
        }

        if (-not (Test-ValidSunshineCoverPng -Path $destPath)) {
            continue
        }

        $app.'image-path' = (Resolve-Path -LiteralPath $destPath).Path
        $coversCopied++
    }

    $data | ConvertTo-Json -Depth 8 | Set-Content -Path $DestAppsJson -Encoding UTF8

    return $coversCopied
}

function Publish-SunshineAppsJson {
    param(
        [Parameter(Mandatory = $true)][string]$AppsFile,
        [switch]$Quiet
    )

    $result = [ordered]@{
        Success             = $false
        SunshineInstalled   = $false
        SunshineConfigDir   = $null
        SunshineAppsJson    = $null
        SunshineConf        = $null
        ServiceImagePath    = $null
        ConfigDirsPublished = @()
        CoversCopied        = 0
        AppsCount           = 0
        ServiceRestarted    = $false
        ServiceRestartError = $null
        VerifiedOnDisk      = $false
        CandidatesTried     = @()
        Errors              = @()
        Warnings            = @()
    }

    $result.CandidatesTried = @(Get-SunshineInstallRootCandidates)
    $result.ServiceImagePath = Get-SunshineServiceImagePath

    $sunshineService = Get-Service -Name "SunshineService" -ErrorAction SilentlyContinue
    $configDirs = @(Get-SunshineConfigDirectoryCandidates)
    $result.SunshineConfigDir = if ($configDirs.Count -gt 0) { $configDirs[0] } else { $null }
    $result.SunshineInstalled = ($null -ne $sunshineService) -or [bool]$result.SunshineConfigDir

    if ($configDirs.Count -eq 0) {
        $result.Warnings = @($result.Warnings) + @("Sunshine nao encontrado. apps.json salvo apenas em: $AppsFile")
        if (-not $Quiet) {
            Write-Host "AVISO: Sunshine nao encontrado. apps.json salvo apenas em: $AppsFile"
            Write-Host "       Instale o Sunshine e execute novamente."
        }
        return [pscustomobject]$result
    }

    $sourceCoversDir = Join-Path (Split-Path -Parent $AppsFile) "covers"
    $publishedPaths = New-Object System.Collections.Generic.List[string]
    $lastAppsCount = 0
    $totalCoversCopied = 0
    $publishErrors = New-Object System.Collections.Generic.List[string]
    $anyConfigChanged = $false

    foreach ($sunshineConfigDir in $configDirs) {
        try {
            New-Item -ItemType Directory -Force -Path $sunshineConfigDir | Out-Null

            $sunshineConf = Join-Path $sunshineConfigDir "sunshine.conf"
            Initialize-SunshineDefaults -SunshineConf $sunshineConf

            $sunshineApps = Join-Path $sunshineConfigDir "apps.json"
            $destCoversDir = Join-Path $sunshineConfigDir "covers"
            $previousAppsJson = if (Test-Path -LiteralPath $sunshineApps) {
                Get-Content -Path $sunshineApps -Raw -Encoding UTF8
            } else {
                $null
            }

            $coversCopied = Write-SunshineAppsJsonForConfig `
                -AppsFile $AppsFile `
                -DestAppsJson $sunshineApps `
                -DestCoversDir $destCoversDir `
                -SourceCoversDir $sourceCoversDir

            if (-not (Test-Path -LiteralPath $sunshineApps)) {
                throw "Falha ao gravar apps.json em $sunshineApps"
            }

            $published = Get-Content -Path $sunshineApps -Raw -Encoding UTF8 | ConvertFrom-Json
            $appsCount = @($published.apps).Count
            if ($appsCount -lt 1) {
                throw "apps.json publicado sem aplicativos em $sunshineApps"
            }

            $currentAppsJson = Get-Content -Path $sunshineApps -Raw -Encoding UTF8
            if ($previousAppsJson -ne $currentAppsJson) {
                $anyConfigChanged = $true
            }

            [void]$publishedPaths.Add($sunshineApps)
            $lastAppsCount = $appsCount
            $totalCoversCopied = [Math]::Max($totalCoversCopied, $coversCopied)

            if (-not $Quiet) {
                Write-Host "Aplicado no Sunshine: $sunshineApps ($appsCount apps, $coversCopied capas)"
            }
        } catch {
            [void]$publishErrors.Add("$sunshineConfigDir :: $($_.Exception.Message)")
        }
    }

    $result.ConfigDirsPublished = @($publishedPaths)
    if ($publishedPaths.Count -gt 0) {
        $result.SunshineAppsJson = $publishedPaths[0]
        $result.SunshineConf = Join-Path (Split-Path -Parent $publishedPaths[0]) "sunshine.conf"
    }

    if ($publishErrors.Count -gt 0) {
        $result.Warnings = @($result.Warnings) + @($publishErrors)
    }

    if ($publishedPaths.Count -eq 0) {
        $result.Success = $false
        $result.Errors = @($result.Errors) + @($publishErrors)
        if (-not $Quiet) {
            Write-Host "ERRO ao publicar apps.json no Sunshine."
        }
        return [pscustomobject]$result
    }

    $result.CoversCopied = $totalCoversCopied
    $result.AppsCount = $lastAppsCount
    $result.VerifiedOnDisk = $true
    $result.Success = $true

    $serviceConfigDirs = @(Get-ConfigDirsNearServiceImage -ImagePath $result.ServiceImagePath)
    $serviceConfigPublished = $false
    foreach ($serviceDir in $serviceConfigDirs) {
        $expectedApps = Join-Path $serviceDir "apps.json"
        foreach ($publishedPath in @($publishedPaths)) {
            if ($publishedPath -ieq $expectedApps) {
                $serviceConfigPublished = $true
                break
            }
        }
        if ($serviceConfigPublished) { break }
    }

    if ($result.ServiceImagePath -and -not $serviceConfigPublished) {
        $msg = "Publicado em $($publishedPaths.Count) pasta(s), mas nao no config do servico em execucao ($($serviceConfigDirs -join ', '))."
        $result.Warnings = @($result.Warnings) + @($msg)
        if (-not $Quiet) {
            Write-Host "AVISO: $msg"
        }
    }

    if ($sunshineService) {
        try {
            if (-not $anyConfigChanged) {
                if (-not $Quiet) {
                    Write-Host "Sunshine: apps.json inalterado; servico nao reiniciado."
                }
            } elseif ($sunshineService.Status -ne 'Running') {
                Start-Service SunshineService -ErrorAction Stop
                $result.ServiceRestarted = $true
                if (-not $Quiet) {
                    Write-Host "Sunshine iniciado. Feche e reabra o Moonlight."
                }
            } else {
                Restart-Service SunshineService -ErrorAction Stop
                $result.ServiceRestarted = $true
                if (-not $Quiet) {
                    Write-Host "Sunshine reiniciado. Feche e reabra o Moonlight."
                }
            }
        } catch {
            $result.ServiceRestarted = $false
            $result.ServiceRestartError = $_.Exception.Message
            $result.Warnings = @($result.Warnings) + @("Nao foi possivel reiniciar o SunshineService: $($_.Exception.Message)")
            if (-not $Quiet) {
                Write-Host "AVISO: Nao foi possivel reiniciar o SunshineService. Reinicie manualmente."
            }
        }
    } else {
        $result.Warnings = @($result.Warnings) + @("Servico SunshineService nao encontrado.")
        if (-not $Quiet) {
            Write-Host "AVISO: Servico SunshineService nao encontrado."
        }
    }

    if (-not $Quiet) {
        try {
            . "$PSScriptRoot\HeadlessSteam-Status.ps1"
            if (Test-HeadlessSteamSunshineNeedsSetup) {
                Write-Host ""
                Write-Host "Primeira vez? Acesse https://localhost:47990 ou use a aba Sunshine no Handless Sunshine Dashboard."
            }
        } catch {
            $result.Warnings = @($result.Warnings) + @("Aviso pos-publicacao: $($_.Exception.Message)")
        }
    }

    return [pscustomobject]$result
}
