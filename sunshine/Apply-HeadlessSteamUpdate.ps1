#Requires -Version 5.1
param(
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$RestartExe,
    [int]$ParentPid = 0
)

$ErrorActionPreference = "Stop"

$logDir = Join-Path $env:TEMP "HeadlessSteam-update"
$logPath = Join-Path $logDir "last-update.log"

function Write-UpdateLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    Write-Output $line
}

function Wait-ForParentProcess {
    param(
        [int]$ProcessId,
        [int]$TimeoutSeconds = 45
    )

    if ($ProcessId -le 0) {
        return
    }

    Write-UpdateLog "Aguardando encerramento do processo pai (PID $ProcessId)..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if (-not $proc) {
            Write-UpdateLog "Processo pai encerrado."
            return
        }
        Start-Sleep -Milliseconds 400
    }
    Write-UpdateLog "Timeout aguardando processo pai; seguindo com taskkill."
}

function Stop-HeadlessSteamUpdateBlockers {
    param([int]$Retries = 8)

    $prevErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        for ($attempt = 1; $attempt -le $Retries; $attempt++) {
            foreach ($image in @("HandlessSteam.exe", "HeadlessSteam.exe", "web-server.exe", "streamer.exe")) {
                cmd.exe /c "taskkill /F /IM $image /T >nul 2>nul"
            }
            Start-Sleep -Milliseconds 700
            $running = @(Get-Process -Name @("HandlessSteam", "HeadlessSteam", "web-server") -ErrorAction SilentlyContinue)
            if ($running.Count -eq 0) {
                return
            }
        }
    } finally {
        $ErrorActionPreference = $prevErrorAction
    }
}

try {
    $source = (Resolve-Path -LiteralPath $SourceDir).Path.TrimEnd('\')
    $target = (Resolve-Path -LiteralPath $TargetDir).Path.TrimEnd('\')
    $restart = (Resolve-Path -LiteralPath $RestartExe).Path

    if (-not (Test-Path -LiteralPath (Join-Path $source "HandlessSteam.exe"))) {
        throw "SourceDir invalido: HandlessSteam.exe nao encontrado em $source"
    }

    Write-UpdateLog "Iniciando atualizacao de $target"
    Write-UpdateLog "Origem: $source"

    Wait-ForParentProcess -ProcessId $ParentPid
    Stop-HeadlessSteamUpdateBlockers

    $dataPath = Join-Path $target "moonlight-web\package\server\data.json"
    $configPath = Join-Path $target "moonlight-web\package\server\config.json"
    $backupData = $null
    $backupConfig = $null

    if (Test-Path -LiteralPath $dataPath) {
        $backupData = Get-Content -LiteralPath $dataPath -Raw -Encoding UTF8
        Write-UpdateLog "Backup data.json do Moonlight preservado."
    }
    if (Test-Path -LiteralPath $configPath) {
        $backupConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        Write-UpdateLog "Backup config.json do Moonlight preservado."
    }

    $targetExe = Join-Path $target "HandlessSteam.exe"
    if (Test-Path -LiteralPath $targetExe) {
        $oldExe = "$targetExe.old"
        if (Test-Path -LiteralPath $oldExe) {
            Remove-Item -LiteralPath $oldExe -Force -ErrorAction SilentlyContinue
        }
        try {
            Move-Item -LiteralPath $targetExe -Destination $oldExe -Force
            Write-UpdateLog "Executavel antigo renomeado para HandlessSteam.exe.old"
        } catch {
            Write-UpdateLog "Nao foi possivel renomear executavel antigo; robocopy vai tentar sobrescrever."
        }
    }

    & robocopy.exe $source $target /E /IS /IT /R:8 /W:2 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    $robocopyExit = $LASTEXITCODE
    if ($robocopyExit -ge 8) {
        throw "robocopy falhou com codigo $robocopyExit. Veja $logPath"
    }

    Write-UpdateLog "robocopy concluido (codigo $robocopyExit)."

    if (-not (Test-Path -LiteralPath $targetExe)) {
        throw "Atualizacao incompleta: HandlessSteam.exe nao foi copiado para $target"
    }

    $oldExe = "$targetExe.old"
    if (Test-Path -LiteralPath $oldExe) {
        Remove-Item -LiteralPath $oldExe -Force -ErrorAction SilentlyContinue
    }

    if ($backupData) {
        [System.IO.File]::WriteAllText($dataPath, $backupData, [System.Text.UTF8Encoding]::new($false))
        Write-UpdateLog "data.json do Moonlight restaurado."
    }
    if ($backupConfig) {
        [System.IO.File]::WriteAllText($configPath, $backupConfig, [System.Text.UTF8Encoding]::new($false))
        Write-UpdateLog "config.json do Moonlight restaurado."
    }

    Start-Sleep -Milliseconds 500
    Start-Process -FilePath $restart -WorkingDirectory $target | Out-Null
    Write-UpdateLog "Reiniciado: $restart"
} catch {
    Write-UpdateLog "ERRO: $($_.Exception.Message)"
    throw
}
