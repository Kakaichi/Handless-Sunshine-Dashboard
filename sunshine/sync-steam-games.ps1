#Requires -RunAsAdministrator
param(
    [switch]$RefreshCovers
)

$ErrorActionPreference = "Stop"

if ($Host.Name -eq 'ConsoleHost') {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
    } catch {
    }
}

. "$PSScriptRoot\Get-SteamPath.ps1"
. "$PSScriptRoot\Sunshine-Config.ps1"
. "$PSScriptRoot\HeadlessSteam-SyncLog.ps1"
. "$PSScriptRoot\HeadlessSteam-InteractiveUser.ps1"
. "$PSScriptRoot\HeadlessSteam-HostSettings.ps1"

if (-not $env:HEADLESS_STEAM_APP_ROOT) {
    $env:HEADLESS_STEAM_APP_ROOT = Get-HeadlessSteamAppRoot -FromScriptDir $PSScriptRoot
}

function Add-SyncRunLine {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("errors", "warnings")]
        [string]$Field,
        [Parameter(Mandatory = $true)][string]$Line
    )

    if (-not $Line) {
        return
    }

    $current = @($script:SyncRun[$Field])
    $script:SyncRun[$Field] = $current + @([string]$Line)
}

$script:SyncRun = [ordered]@{
    startedAt      = (Get-Date).ToUniversalTime().ToString("o")
    success        = $false
    appRoot        = (Get-HeadlessSteamAppRoot -FromScriptDir $PSScriptRoot)
    steamPath      = $null
    libraries      = @()
    gamesCount     = 0
    coversOk       = 0
    coversFail     = 0
    sourceAppsJson = $null
    publish        = $null
    interactiveUser = $null
    interactiveUserSid = $null
    elevatedIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    errors         = @()
    warnings       = @()
}

$interactiveUser = Get-HeadlessSteamInteractiveUserInfo
if ($interactiveUser) {
    $script:SyncRun.interactiveUser = $interactiveUser.UserName
    $script:SyncRun.interactiveUserSid = $interactiveUser.Sid
}
$script:SyncRunFinished = $false
$script:SyncExitCode = 0

function Get-SyncRunLogPayload {
    $publish = $null
    if ($null -ne $script:SyncRun.publish) {
        $entry = $script:SyncRun.publish
        $publish = [ordered]@{
            success             = [bool]$entry.success
            sunshineInstalled   = [bool]$entry.sunshineInstalled
            sunshineConfigDir   = [string]$entry.sunshineConfigDir
            sunshineAppsJson    = [string]$entry.sunshineAppsJson
            serviceImagePath    = [string]$entry.serviceImagePath
            configDirsPublished = @($entry.configDirsPublished | ForEach-Object { [string]$_ })
            coversCopied        = [int]$entry.coversCopied
            appsCount           = [int]$entry.appsCount
            serviceRestarted    = [bool]$entry.serviceRestarted
            serviceRestartError = [string]$entry.serviceRestartError
            verifiedOnDisk      = [bool]$entry.verifiedOnDisk
            candidatesTried     = @($entry.candidatesTried | ForEach-Object { [string]$_ })
            errors              = @($entry.errors | ForEach-Object { [string]$_ })
            warnings            = @($entry.warnings | ForEach-Object { [string]$_ })
            exception           = [string]$entry.exception
            note                = [string]$entry.note
        }
    }

    return [ordered]@{
        startedAt      = [string]$script:SyncRun.startedAt
        finishedAt     = [string]$script:SyncRun.finishedAt
        success        = [bool]$script:SyncRun.success
        appRoot        = [string]$script:SyncRun.appRoot
        steamPath      = [string]$script:SyncRun.steamPath
        libraries      = @($script:SyncRun.libraries | ForEach-Object { [string]$_ })
        gamesCount     = [int]$script:SyncRun.gamesCount
        coversOk       = [int]$script:SyncRun.coversOk
        coversFail     = [int]$script:SyncRun.coversFail
        sourceAppsJson = [string]$script:SyncRun.sourceAppsJson
        interactiveUser = [string]$script:SyncRun.interactiveUser
        interactiveUserSid = [string]$script:SyncRun.interactiveUserSid
        elevatedIdentity = [string]$script:SyncRun.elevatedIdentity
        publish        = $publish
        errors         = @($script:SyncRun.errors | ForEach-Object { [string]$_ })
        warnings       = @($script:SyncRun.warnings | ForEach-Object { [string]$_ })
    }
}

function Finish-HeadlessSteamSyncRun {
    if ($script:SyncRunFinished) {
        return
    }

    $script:SyncRun.finishedAt = (Get-Date).ToUniversalTime().ToString("o")
    $script:SyncRun.success = ($script:SyncExitCode -eq 0)
    $script:SyncRun.appRoot = (Get-HeadlessSteamAppRoot -FromScriptDir $PSScriptRoot)

    $logResult = Write-HeadlessSteamSyncLog -RunEntry (Get-SyncRunLogPayload) -FromScriptDir $PSScriptRoot
    if ($logResult.Written) {
        Write-Host "Log de sincronizacao gravado: $($logResult.Path)"
    } else {
        Write-Host "AVISO: Nao foi possivel gravar o log em $($logResult.Path)."
        if ($logResult.Error) {
            Write-Host "AVISO: $($logResult.Error)"
        }
    }

    $script:SyncRunFinished = $true
}

Add-Type -AssemblyName System.Drawing

$Script:CoverWidth = 600
$Script:CoverHeight = 900

function Test-ExistingGameCover {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        $file = Get-Item -LiteralPath $Path -ErrorAction Stop
        return $file.Length -ge 8192
    } catch {
        return $false
    }
}

function Test-ValidCoverImage {
    param(
        [string]$Path,
        [switch]$RequireVerticalPoster
    )

    try {
        $file = Get-Item $Path -ErrorAction Stop
        if ($file.Length -lt 4096) { return $false }

        $image = [System.Drawing.Image]::FromFile($Path)
        $valid = $image.Width -ge 150 -and $image.Height -ge 150
        if ($valid -and $RequireVerticalPoster) {
            $valid = $image.Height -ge [int][Math]::Round($image.Width * 1.1)
        }
        $image.Dispose()
        return $valid
    } catch {
        return $false
    }
}

function Test-VerticalPosterCoverPath {
    param([string]$Path)

    if (-not $Path) { return $false }
    $name = Split-Path -Leaf $Path
    if ($name -match '(?i)header|hero|logo|banner|background|event|wide') {
        return $false
    }
    if ($name -match '(?i)library_600x900|library_capsule|capsule_.*vertical|vertical') {
        return $true
    }
    return $null
}

function Get-HeadlessSteamCoverSourceAppId {
    param([Parameter(Mandatory = $true)][string]$AppId)

    $aliases = @{
        "312060" = "39210" # FINAL FANTASY XIV Free Trial -> capa do jogo principal
    }
    if ($aliases.ContainsKey($AppId)) {
        return $aliases[$AppId]
    }
    return $AppId
}

function Save-ImageFileAsPng {
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [switch]$RequireVerticalPoster
    )

    if (-not (Test-ValidCoverImage -Path $InputPath -RequireVerticalPoster:$RequireVerticalPoster)) {
        return $false
    }

    try {
        $source = [System.Drawing.Image]::FromFile($InputPath)

        try {
            if ($source.Width -eq $Script:CoverWidth -and $source.Height -eq $Script:CoverHeight) {
                $source.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
                return $true
            }

            $bitmap = New-Object System.Drawing.Bitmap($Script:CoverWidth, $Script:CoverHeight)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

            try {
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $graphics.Clear([System.Drawing.Color]::FromArgb(23, 26, 33))

                $scale = [Math]::Max(
                    $Script:CoverWidth / $source.Width,
                    $Script:CoverHeight / $source.Height
                )

                $drawWidth = [int][Math]::Round($source.Width * $scale)
                $drawHeight = [int][Math]::Round($source.Height * $scale)
                $offsetX = [int][Math]::Round(($Script:CoverWidth - $drawWidth) / 2)
                $offsetY = [int][Math]::Round(($Script:CoverHeight - $drawHeight) / 2)

                $graphics.DrawImage($source, $offsetX, $offsetY, $drawWidth, $drawHeight)
                $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
                return $true
            } finally {
                $graphics.Dispose()
                $bitmap.Dispose()
            }
        } finally {
            $source.Dispose()
        }
    } catch {
        return $false
    }
}

function Save-ImageUrlAsPng {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [switch]$RequireVerticalPoster
    )

    $tempFile = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        "sunshine-cover-" + [Guid]::NewGuid().ToString("N") + ".img"
    )

    try {
        Invoke-WebRequest -Uri $Url -OutFile $tempFile -UseBasicParsing -TimeoutSec 20 | Out-Null

        if (Save-ImageFileAsPng -InputPath $tempFile -OutputPath $OutputPath -RequireVerticalPoster:$RequireVerticalPoster) {
            return $true
        }
    } catch {
    } finally {
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    return $false
}

function Get-SteamCdnUrls {
    param([Parameter(Mandatory = $true)][string]$AppId)

    $files = @(
        "library_600x900_2x.jpg",
        "library_600x900.jpg",
        "library_hero.jpg",
        "header.jpg",
        "capsule_616x353.jpg",
        "capsule_231x87.jpg"
    )

    $hosts = @(
        "https://cdn.cloudflare.steamstatic.com/steam/apps",
        "https://shared.akamai.steamstatic.com/steam/apps"
    )

    $urls = New-Object System.Collections.Generic.List[string]
    foreach ($hostUrl in $hosts) {
        foreach ($file in $files) {
            $urls.Add("$hostUrl/$AppId/$file") | Out-Null
        }
    }

    return $urls
}

function Get-SteamStoreCoverUrls {
    param([Parameter(Mandatory = $true)][string]$AppId)

    $urls = New-Object System.Collections.Generic.List[string]

    try {
        $apiUrl = "https://store.steampowered.com/api/appdetails?appids=$AppId&l=english"
        $response = Invoke-RestMethod -Uri $apiUrl -TimeoutSec 20
        $entry = $response.$AppId

        if ($entry -and $entry.success -and $entry.data) {
            foreach ($field in @("capsule_imagev5", "capsule_image")) {
                $value = $entry.data.$field
                if ($value -and -not $urls.Contains($value)) {
                    $urls.Add($value) | Out-Null
                }
            }
        }
    } catch {
    }

    return $urls
}

function Get-LocalSteamCoverUrls {
    param([Parameter(Mandatory = $true)][string]$AppId)

    $urls = New-Object System.Collections.Generic.List[string]
    $patterns = New-Object System.Collections.Generic.List[string]
    $steamRoot = Get-SteamInstallPath

    if ($steamRoot) {
        $patterns.Add((Join-Path $steamRoot "userdata\*\config\librarycache\$AppId*")) | Out-Null
        $patterns.Add((Join-Path $steamRoot "appcache\librarycache\$AppId\**\*.jpg")) | Out-Null
        $patterns.Add((Join-Path $steamRoot "appcache\librarycache\$AppId\**\*.png")) | Out-Null
    }

    foreach ($libraryRoot in (Get-SteamLibraryRoots -Quiet)) {
        if (-not (Test-SteamLibraryRootAvailable $libraryRoot)) { continue }

        $patterns.Add((Join-Path $libraryRoot "steamapps\appcache\librarycache\$AppId\**\*.jpg")) | Out-Null
        $patterns.Add((Join-Path $libraryRoot "steamapps\appcache\librarycache\$AppId\**\*.png")) | Out-Null
    }

    foreach ($pattern in $patterns) {
        Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not $urls.Contains($_.FullName)) {
                $urls.Add($_.FullName) | Out-Null
            }
        }
    }

    return @($urls | Sort-Object {
        $hint = Test-VerticalPosterCoverPath -Path $_
        if ($hint -eq $true) { 0 }
        elseif ($hint -eq $false) { 2 }
        else { 1 }
    })
}

function Get-SteamStoreBrowseAssetsMap {
    param([Parameter(Mandatory = $true)][int[]]$AppIds)

    $map = @{}
    if ($AppIds.Count -eq 0) { return $map }

    $chunkSize = 50
    for ($offset = 0; $offset -lt $AppIds.Count; $offset += $chunkSize) {
        $chunk = $AppIds[$offset..([Math]::Min($offset + $chunkSize - 1, $AppIds.Count - 1))]
        $ids = $chunk | ForEach-Object { @{ appid = $_ } }

        $inputJson = @{
            ids          = $ids
            context      = @{ country_code = "US" }
            data_request = @{ include_assets = $true }
        } | ConvertTo-Json -Compress -Depth 6

        $url = "https://api.steampowered.com/IStoreBrowseService/GetItems/v1/?input_json=" +
            [uri]::EscapeDataString($inputJson)

        try {
            $response = Invoke-RestMethod -Uri $url -TimeoutSec 30
            foreach ($item in $response.response.store_items) {
                if ($item.appid -and $item.assets) {
                    $map[[string]$item.appid] = $item.assets
                }
            }
        } catch {
            Write-Host "AVISO: Steam GetItems falhou para lote de capas."
        }
    }

    return $map
}

function Get-SteamStoreBrowseCoverUrls {
    param($Assets)

    $urls = New-Object System.Collections.Generic.List[string]
    if (-not $Assets -or -not $Assets.asset_url_format) { return $urls }

    $hosts = @(
        "https://shared.steamstatic.com/store_item_assets/",
        "https://shared.akamai.steamstatic.com/store_item_assets/",
        "https://shared.fastly.steamstatic.com/store_item_assets/"
    )

    foreach ($field in @("library_capsule_2x", "library_capsule")) {
        $filename = $Assets.$field
        if (-not $filename) { continue }

        $path = $Assets.asset_url_format.Replace('${FILENAME}', $filename)
        foreach ($hostUrl in $hosts) {
            $urls.Add("$hostUrl$path") | Out-Null
        }
    }

    return $urls
}

function Get-SteamGridDbApiKey {
    $keyFile = Join-Path $PSScriptRoot "steamgriddb.key"
    if (Test-Path $keyFile) {
        return (Get-Content $keyFile -Raw).Trim()
    }
    if ($env:STEAMGRIDDB_API_KEY) {
        return $env:STEAMGRIDDB_API_KEY.Trim()
    }
    return $null
}

function Get-SteamGridDbCoverUrls {
    param([Parameter(Mandatory = $true)][string]$AppId)

    $urls = New-Object System.Collections.Generic.List[string]
    $apiKey = Get-SteamGridDbApiKey
    if (-not $apiKey) { return $urls }

    try {
        $uri = "https://www.steamgriddb.com/api/v2/grids/steam/$AppId" +
            "?dimensions=600x900&mimes=image/png,image/jpeg&types=static"
        $response = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $apiKey" } -TimeoutSec 20

        if ($response.success -and $response.data) {
            foreach ($grid in ($response.data | Sort-Object -Property score -Descending)) {
                if ($grid.url -and -not $urls.Contains($grid.url)) {
                    $urls.Add($grid.url) | Out-Null
                }
            }
        }
    } catch {
        Write-Host "SteamGridDB sem capa para app $AppId"
    }

    return $urls
}

function Get-ManualCoverPath {
    param([Parameter(Mandatory = $true)][string]$AppId)

    $manualDir = Join-Path $PSScriptRoot "covers\manual"
    foreach ($ext in @("png", "jpg", "jpeg", "webp")) {
        $path = Join-Path $manualDir "$AppId.$ext"
        if (Test-Path $path) { return $path }
    }

    return $null
}

function Save-GameCover {
    param(
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        $StoreBrowseAssets = $null
    )

    $coverAppId = Get-HeadlessSteamCoverSourceAppId -AppId $AppId

    $manualCover = Get-ManualCoverPath -AppId $AppId
    if (-not $manualCover) {
        $manualCover = Get-ManualCoverPath -AppId $coverAppId
    }
    if ($manualCover) {
        if (Save-ImageFileAsPng -InputPath $manualCover -OutputPath $OutputPath -RequireVerticalPoster) {
            return @{ Success = $true; Source = "Manual" }
        }
    }

    $urlCandidates = New-Object System.Collections.Generic.List[string]
    if ($coverAppId -eq $AppId) {
        foreach ($url in (Get-SteamStoreBrowseCoverUrls -Assets $StoreBrowseAssets)) {
            $urlCandidates.Add($url) | Out-Null
        }
    } else {
        $aliasAssets = Get-SteamStoreBrowseAssetsMap -AppIds @([int]$coverAppId)
        foreach ($url in (Get-SteamStoreBrowseCoverUrls -Assets $aliasAssets[[string]$coverAppId])) {
            $urlCandidates.Add($url) | Out-Null
        }
    }
    foreach ($url in (Get-SteamCdnUrls -AppId $coverAppId)) {
        $urlCandidates.Add($url) | Out-Null
    }

    foreach ($candidate in ($urlCandidates | Select-Object -Unique)) {
        if (-not $candidate) { continue }
        if (Save-ImageUrlAsPng -Url $candidate -OutputPath $OutputPath -RequireVerticalPoster) {
            $source = if ($candidate -match 'store_item_assets') { "Steam Assets" }
                      elseif ($candidate -match 'akamai|steamstatic') { "Steam CDN" }
                      else { "Steam Store" }
            return @{
                Success = $true
                Source  = $source
            }
        }
    }

    foreach ($path in (Get-LocalSteamCoverUrls -AppId $coverAppId)) {
        $hint = Test-VerticalPosterCoverPath -Path $path
        if ($hint -eq $false) { continue }
        if (Save-ImageFileAsPng -InputPath $path -OutputPath $OutputPath -RequireVerticalPoster) {
            return @{
                Success = $true
                Source  = "Cache local"
            }
        }
    }

    foreach ($url in (Get-SteamGridDbCoverUrls -AppId $coverAppId)) {
        if (Save-ImageUrlAsPng -Url $url -OutputPath $OutputPath -RequireVerticalPoster) {
            return @{
                Success = $true
                Source  = "SteamGridDB"
            }
        }
    }

    foreach ($url in (Get-SteamStoreCoverUrls -AppId $coverAppId)) {
        if (Save-ImageUrlAsPng -Url $url -OutputPath $OutputPath -RequireVerticalPoster) {
            return @{
                Success = $true
                Source  = "Steam Store API"
            }
        }
    }

    return @{
        Success = $false
        Source  = $null
    }
}

function Get-AvailableSteamLibraries {
    param([System.Collections.Generic.List[string]]$Paths)

    $available = New-Object System.Collections.Generic.List[string]

    foreach ($root in $Paths) {
        if (-not (Test-SteamLibraryRootAvailable $root)) {
            continue
        }

        $manifestDir = Join-Path $root "steamapps"
        if (Test-Path $manifestDir) {
            $available.Add($root) | Out-Null
        } else {
            Write-Host "Ignorando biblioteca (steamapps nao encontrado): $root"
        }
    }

    return $available
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$appsFile = Join-Path $scriptDir "apps.json"
$coversDir = Join-Path $scriptDir "covers"
$closeGameScript = Join-Path $scriptDir "close-steam-game.ps1"
$launchGameScript = Join-Path $scriptDir "launch-steam-game.ps1"
New-Item -ItemType Directory -Force -Path $coversDir | Out-Null

try {
$steamExePath = Get-SteamExePath
if (-not $steamExePath) {
    Add-SyncRunLine -Field errors -Line "Steam nao encontrado. Instale a Steam ou abra-a uma vez para registrar o caminho."
    $script:SyncExitCode = 1
} else {
$script:SyncRun.steamPath = $steamExePath
Write-Host "Steam detectada: $steamExePath"
Write-Host ""

$steamPaths = Get-AvailableSteamLibraries -Paths (Get-SteamLibraryRoots)
$script:SyncRun.libraries = @($steamPaths | ForEach-Object { [string]$_ })
Write-Host "Bibliotecas Steam: $($steamPaths -join ', ')"
Write-Host ""

$excludeNames = @(
    "Steamworks Common Redistributables",
    "Steamworks Shared",
    "Proton",
    "Steam Linux Runtime",
    "Wallpaper Engine"
)

$excludeAppIds = @(
    "431960"
)

$steamBp = [ordered]@{
    name          = "Steam Big Picture"
    cmd           = "steam://open/bigpicture"
    "prep-cmd"    = @([ordered]@{ do = ""; undo = "steam://close/bigpicture" })
    "auto-detach" = $true
    "wait-all"    = $true
    "image-path"  = "steam.png"
}

$gameApps = New-Object System.Collections.Generic.List[object]
$pendingGames = New-Object System.Collections.Generic.List[object]
$seen = @{}
$coverOk = 0
$coverFail = 0

foreach ($steamRoot in $steamPaths) {
    $manifestDir = Join-Path $steamRoot "steamapps"
    if (-not (Test-Path $manifestDir)) { continue }

    Get-ChildItem $manifestDir -Filter "appmanifest_*.acf" | ForEach-Object {
        $raw = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
        if ($raw -match '"appid"\s+"(\d+)"') { $appid = $Matches[1] } else { return }
        if ($raw -match '"name"\s+"([^"]+)"') { $name = $Matches[1] } else { return }
        $installDir = if ($raw -match '"installdir"\s+"([^"]+)"') { $Matches[1] } else { "" }
        $launcherPath = if ($raw -match '"LauncherPath"\s+"([^"]+)"') { $Matches[1] -replace '\\\\', '\' } else { "" }
        $steamExe = if ($launcherPath -and (Test-Path $launcherPath)) {
            $launcherPath
        } elseif (Test-Path (Join-Path $steamRoot "steam.exe")) {
            Join-Path $steamRoot "steam.exe"
        } else {
            $steamExePath
        }

        if (-not $appid -or -not $name) { return }
        if ($excludeAppIds -contains $appid) { return }
        if ($excludeNames -contains $name) { return }
        if ($seen.ContainsKey($appid)) { return }

        $seen[$appid] = $true
        $pendingGames.Add([pscustomobject]@{
            AppId      = $appid
            Name       = $name
            InstallDir = $installDir
            SteamRoot  = $steamRoot
            SteamExe   = $steamExe
        }) | Out-Null
    }
}

$gamesNeedingCovers = New-Object System.Collections.Generic.List[object]
foreach ($game in $pendingGames) {
    $coverPath = Join-Path $coversDir "$($game.AppId).png"
    if (-not $RefreshCovers -and (Test-ExistingGameCover -Path $coverPath)) {
        continue
    }
    $gamesNeedingCovers.Add($game) | Out-Null
}

$cachedCovers = $pendingGames.Count - $gamesNeedingCovers.Count
if ($cachedCovers -gt 0) {
    Write-Host "Capas em cache: $cachedCovers (pulando download)"
}

$assetsMap = @{}
if ($gamesNeedingCovers.Count -gt 0) {
    Write-Host "Buscando capas novas: $($gamesNeedingCovers.Count)"
    $assetsMap = Get-SteamStoreBrowseAssetsMap -AppIds @(
        $gamesNeedingCovers | ForEach-Object { [int]$_.AppId }
    )
}

foreach ($game in $pendingGames) {
    $appid = $game.AppId
    $name = $game.Name
    $installDir = $game.InstallDir
    $steamRoot = $game.SteamRoot
    $steamExe = $game.SteamExe

        $coverPath = Join-Path $coversDir "$appid.png"
        $imagePath = "steam.png"
        if (-not $RefreshCovers -and (Test-ExistingGameCover -Path $coverPath)) {
            $imagePath = "covers\$appid.png"
            $coverOk++
        } else {
            $browseAssets = $assetsMap[[string]$appid]
            $result = Save-GameCover -AppId $appid -OutputPath $coverPath -StoreBrowseAssets $browseAssets

            if ($result.Success) {
                $imagePath = "covers\$appid.png"
                $coverOk++
                Write-Host "Capa OK ($($result.Source)): $name"
            } else {
                $coverFail++
                Write-Host "Capa nao encontrada: $name (usa icone padrao)"
            }
        }

        $gameDir = if ($installDir) {
            Join-Path $steamRoot "steamapps\common\$installDir"
        } else {
            ""
        }

        $canTrackGame = $gameDir -and (Test-Path $gameDir) -and (Test-Path $steamExe)

        $entry = if ($canTrackGame) {
            $launchCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$launchGameScript`" -AppId $appid -InstallDir `"$gameDir`" -SteamExe `"$steamExe`""
            $hostSettings = Get-HeadlessSteamHostSettings
            if ($hostSettings.host_free_mode_enabled) {
                $launchCmd += " -HostFreeMode"
            } elseif ($hostSettings.keep_focus_enabled) {
                $launchCmd += " -KeepFocus"
            }
            [ordered]@{
                name          = $name
                cmd           = $launchCmd
                "auto-detach" = $false
                "wait-all"    = $true
                "image-path"  = $imagePath
            }
        } else {
            [ordered]@{
                name          = $name
                cmd           = "steam://rungameid/$appid"
                "auto-detach" = $true
                "wait-all"    = $true
                "image-path"  = $imagePath
            }
        }

        $undoCmd = if ($gameDir) {
            "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$closeGameScript`" -InstallDir `"$gameDir`" -AppId $appid"
        } else {
            ""
        }

        if ($undoCmd) {
            $entry["prep-cmd"] = @([ordered]@{ do = ""; undo = $undoCmd })
        }

        $gameApps.Add($entry) | Out-Null
}

$sortedGames = $gameApps | Sort-Object { $_.name }
$apps = @($steamBp) + $sortedGames

$output = @{
    env  = @{}
    apps = $apps
} | ConvertTo-Json -Depth 6

$output | Set-Content -Path $appsFile -Encoding UTF8

$script:SyncRun.sourceAppsJson = [string]$appsFile
$script:SyncRun.gamesCount = $sortedGames.Count
$script:SyncRun.coversOk = $coverOk
$script:SyncRun.coversFail = $coverFail

Write-Host ""
Write-Host "Jogos: $($sortedGames.Count) | Capas: $coverOk | Sem capa: $coverFail"
Write-Host "Lista salva em: $appsFile"

    $publishResult = Publish-SunshineAppsJson -AppsFile $appsFile -Quiet
    $script:SyncRun.publish = [ordered]@{
        success             = [bool]$publishResult.Success
        sunshineInstalled   = [bool]$publishResult.SunshineInstalled
        sunshineConfigDir   = [string]$publishResult.SunshineConfigDir
        sunshineAppsJson    = [string]$publishResult.SunshineAppsJson
        serviceImagePath    = [string]$publishResult.ServiceImagePath
        configDirsPublished = @($publishResult.ConfigDirsPublished | ForEach-Object { [string]$_ })
        coversCopied        = [int]$publishResult.CoversCopied
        appsCount           = [int]$publishResult.AppsCount
        serviceRestarted    = [bool]$publishResult.ServiceRestarted
        serviceRestartError = [string]$publishResult.ServiceRestartError
        verifiedOnDisk      = [bool]$publishResult.VerifiedOnDisk
        candidatesTried     = @($publishResult.CandidatesTried | ForEach-Object { [string]$_ })
        errors              = @($publishResult.Errors | ForEach-Object { [string]$_ })
        warnings            = @($publishResult.Warnings | ForEach-Object { [string]$_ })
    }

    foreach ($warn in @($publishResult.Warnings)) {
        if ($warn) { Add-SyncRunLine -Field warnings -Line ([string]$warn) }
    }

    if ($publishResult.Success) {
        $script:SyncExitCode = 0
    } elseif (-not $publishResult.SunshineInstalled) {
        Add-SyncRunLine -Field warnings -Line "Sunshine nao instalado; lista local salva em $appsFile"
        $script:SyncExitCode = 0
    } else {
        foreach ($err in @($publishResult.Errors)) {
            if ($err) { Add-SyncRunLine -Field errors -Line ([string]$err) }
        }
        if (@($script:SyncRun.errors).Count -eq 0) {
            Add-SyncRunLine -Field errors -Line "Falha ao aplicar apps.json no Sunshine."
        }
        $script:SyncExitCode = 1
    }
}
} catch {
    Add-SyncRunLine -Field errors -Line $_.Exception.Message
    if (-not $script:SyncRun.publish) {
        $script:SyncRun.publish = [ordered]@{
            success   = $false
            exception = [string]$_.Exception.Message
            note      = "Excecao antes de concluir Publish-SunshineAppsJson"
        }
    }
    $script:SyncExitCode = 1
} finally {
    Finish-HeadlessSteamSyncRun
}

if ($script:SyncExitCode -ne 0) {
    $message = if ($script:SyncRun.errors.Count -gt 0) {
        ($script:SyncRun.errors -join "; ")
    } else {
        "Falha ao sincronizar jogos."
    }
    Write-Error $message
}

exit $script:SyncExitCode
