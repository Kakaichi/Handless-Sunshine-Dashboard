. "$PSScriptRoot\HeadlessSteam-Paths.ps1"

function Get-HeadlessSteamSyncLogPath {
    param([string]$FromScriptDir = $PSScriptRoot)
    return Join-Path (Get-HeadlessSteamAppRoot -FromScriptDir $FromScriptDir) "sync-games.log.json"
}

function ConvertTo-HeadlessSteamLogData {
    param($InputObject)

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Management.Automation.PSObject]) {
        $base = $InputObject.BaseObject
        if ($base -is [string]) {
            return $base
        }
        if ($null -eq $base) {
            return $null
        }
        if ($base.GetType().IsValueType) {
            return $base
        }
        if ($base -ne $InputObject) {
            return ConvertTo-HeadlessSteamLogData $base
        }

        $result = [ordered]@{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $result[$prop.Name] = ConvertTo-HeadlessSteamLogData $prop.Value
        }
        if ($result.Count -gt 0) {
            return $result
        }
        return [string]$InputObject
    }

    if ($InputObject -is [string]) {
        return $InputObject
    }

    if ($InputObject -is [bool] -or $InputObject -is [ValueType]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($InputObject.Keys)) {
            $result[[string]$key] = ConvertTo-HeadlessSteamLogData $InputObject[$key]
        }
        return $result
    }

    if ($InputObject -is [System.Array]) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(ConvertTo-HeadlessSteamLogData $item)
        }
        return $items
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(ConvertTo-HeadlessSteamLogData $item)
        }
        return $items
    }

    return [string]$InputObject
}

function Format-HeadlessSteamLogRun {
    param($RunEntry)

    if ($RunEntry -is [System.Collections.IDictionary]) {
        return $RunEntry
    }

    return ConvertTo-HeadlessSteamLogData $RunEntry
}

function Write-TextFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $tempPath = "$Path.tmp"
    [System.IO.File]::WriteAllText($tempPath, $Content, [System.Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Write-HeadlessSteamSyncLog {
    param(
        [Parameter(Mandatory = $true)]
        $RunEntry,
        [string]$FromScriptDir = $PSScriptRoot,
        [int]$MaxRuns = 30
    )

    $logPath = Get-HeadlessSteamSyncLogPath -FromScriptDir $FromScriptDir
    $writeError = $null
    $written = $false

    try {
        $runs = @()

        if (Test-Path -LiteralPath $logPath) {
            try {
                $existing = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -ne $existing.runs) {
                    foreach ($item in @($existing.runs)) {
                        $runs += ,(Format-HeadlessSteamLogRun $item)
                    }
                }
            } catch {
                $writeError = "Log anterior invalido; iniciando novo historico. Detalhe: $($_.Exception.Message)"
            }
        }

        $runs += ,(Format-HeadlessSteamLogRun $RunEntry)
        if ($runs.Count -gt $MaxRuns) {
            $runs = @($runs | Select-Object -Last $MaxRuns)
        }

        $document = [ordered]@{
            version   = 1
            logFile   = $logPath
            appRoot   = (Get-HeadlessSteamAppRoot -FromScriptDir $FromScriptDir)
            updatedAt = (Get-Date).ToUniversalTime().ToString("o")
            runs      = $runs
        }

        if ($writeError) {
            $document.warnings = @($writeError)
        }

        $json = $document | ConvertTo-Json -Depth 16
        Write-TextFileAtomic -Path $logPath -Content $json

        if (-not (Test-Path -LiteralPath $logPath)) {
            throw "Arquivo de log nao encontrado apos gravacao: $logPath"
        }

        $written = $true
    } catch {
        $fallbackError = $_.Exception.Message
        try {
            $summary = Format-HeadlessSteamLogRun $RunEntry
            if ($summary -is [System.Collections.IDictionary]) {
                if (-not $summary.Contains("errors") -or -not $summary.errors) {
                    $summary.errors = @($fallbackError)
                } else {
                    $summary.errors = @($summary.errors) + @($fallbackError)
                }
                $summary.note = "Log simplificado apos falha de serializacao completa."
            } else {
                $summary = [ordered]@{
                    startedAt = (Get-Date).ToUniversalTime().ToString("o")
                    success   = $false
                    errors    = @($fallbackError)
                    note      = "Entrada de fallback; log completo nao pode ser serializado."
                }
            }

            $fallback = [ordered]@{
                version   = 1
                logFile   = $logPath
                appRoot   = (Get-HeadlessSteamAppRoot -FromScriptDir $FromScriptDir)
                updatedAt = (Get-Date).ToUniversalTime().ToString("o")
                runs      = @($summary)
            }
            $fallbackJson = $fallback | ConvertTo-Json -Depth 8
            Write-TextFileAtomic -Path $logPath -Content $fallbackJson
            $written = Test-Path -LiteralPath $logPath
            if ($written) {
                $writeError = if ($writeError) { "$writeError | Fallback: $fallbackError" } else { $fallbackError }
            }
        } catch {
            $writeError = if ($writeError) { "$writeError | Fallback: $($_.Exception.Message)" } else { $_.Exception.Message }
        }
    }

    return [pscustomobject]@{
        Path    = $logPath
        Written = $written
        Error   = $writeError
    }
}
