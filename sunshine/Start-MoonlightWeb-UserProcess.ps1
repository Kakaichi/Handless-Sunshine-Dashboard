# Inicia o Moonlight Web na sessao interativa do usuario logado.
# De processos elevados (HeadlessSteam.exe) tenta cmd start (igual iniciar.bat),
# depois UserSessionProcess e Scheduled Task com RunLevel Limited.

param(
    [ValidateSet("start", "stop")]
    [string]$Action = "start",
    [string]$ScriptDir = $PSScriptRoot,
    [string]$AppRoot = "",
    [string]$TailscaleIp = $null
)

$ErrorActionPreference = "Stop"

. (Join-Path $ScriptDir "HeadlessSteam-Paths.ps1")
. (Join-Path $ScriptDir "HeadlessSteam-MoonlightSettings.ps1")
. (Join-Path $ScriptDir "HeadlessSteam-MoonlightRuntime.ps1")
. (Join-Path $ScriptDir "HeadlessSteam-InteractiveUser.ps1")

if ($AppRoot) {
    $env:HEADLESS_STEAM_APP_ROOT = $AppRoot.Trim().TrimEnd('\')
}

$moonlightPkg = Get-HeadlessSteamMoonlightPackageDir -FromScriptDir $ScriptDir
$webServerExe = "web-server.exe"
$webServerProcess = "web-server"
$scheduledTaskName = "HeadlessSteam_MoonlightWeb"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Remove-HeadlessSteamMoonlightScheduledTask {
    Unregister-ScheduledTask -TaskName $scheduledTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Start-HeadlessSteamMoonlightWebViaCmd {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $argString = if ($ArgumentList) { " $ArgumentList" } else { "" }
    $innerCmd = "`"$FilePath`"$argString"
    Start-Process -FilePath "cmd.exe" `
        -ArgumentList @('/c', "start `"Moonlight Web`" /MIN $innerCmd") `
        -WorkingDirectory $WorkingDirectory `
        -WindowStyle Hidden `
        -ErrorAction Stop | Out-Null
    Start-Sleep -Seconds 2
    return Test-MoonlightWebProcessRunning
}

function Start-HeadlessSteamMoonlightWebServer {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $attemptErrors = New-Object System.Collections.Generic.List[string]

    try {
        if (Start-HeadlessSteamMoonlightWebViaCmd `
                -FilePath $FilePath `
                -ArgumentList $ArgumentList `
                -WorkingDirectory $WorkingDirectory) {
            return "CmdStart"
        }
        $attemptErrors.Add("CmdStart: web-server nao detectado apos cmd start.") | Out-Null
    } catch {
        $attemptErrors.Add("CmdStart: $($_.Exception.Message)") | Out-Null
    }

    if (-not (Test-IsAdministrator)) {
        $details = ($attemptErrors | ForEach-Object { [string]$_ }) -join " | "
        throw "Moonlight Web nao iniciou. $details"
    }

    $userSessionScript = Join-Path $ScriptDir "Start-UserSessionProcess.ps1"
    if (Test-Path -LiteralPath $userSessionScript) {
        try {
            . $userSessionScript
            $processId = Start-UserSessionProcess `
                -FilePath $FilePath `
                -ArgumentList $ArgumentList `
                -WorkingDirectory $WorkingDirectory
            if ($processId -gt 0) {
                Start-Sleep -Seconds 2
                if (Test-MoonlightWebProcessRunning) {
                    return "UserSessionProcess"
                }
                $attemptErrors.Add("UserSessionProcess: processo $processId iniciou, mas web-server nao foi detectado.") | Out-Null
            } else {
                $win32 = [SunshineUserProcess]::LastWin32Error
                $attemptErrors.Add("UserSessionProcess: falhou (codigo $processId, Win32=$win32).") | Out-Null
            }
        } catch {
            $attemptErrors.Add("UserSessionProcess: $($_.Exception.Message)") | Out-Null
        }
    }

    $taskError = $null
    try {
        Remove-HeadlessSteamMoonlightScheduledTask

        $interactiveUser = Get-HeadlessSteamInteractiveUserInfo
        $taskUserId = if ($interactiveUser -and $interactiveUser.Sid) {
            $interactiveUser.Sid
        } elseif ($interactiveUser -and $interactiveUser.UserName) {
            $interactiveUser.UserName
        } else {
            [Security.Principal.WindowsIdentity]::GetCurrent().Name
        }
        $taskAction = New-ScheduledTaskAction -Execute $FilePath -Argument $ArgumentList -WorkingDirectory $WorkingDirectory
        $taskPrincipal = New-ScheduledTaskPrincipal `
            -UserId $taskUserId `
            -LogonType Interactive `
            -RunLevel Limited
        $taskSettings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -ExecutionTimeLimit ([TimeSpan]::Zero)

        Register-ScheduledTask `
            -TaskName $scheduledTaskName `
            -Action $taskAction `
            -Principal $taskPrincipal `
            -Settings $taskSettings `
            -Force -ErrorAction Stop | Out-Null

        Start-ScheduledTask -TaskName $scheduledTaskName -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 2

        if (Test-MoonlightWebProcessRunning) {
            return "ScheduledTask"
        }

        $taskError = "Scheduled task criada, mas web-server nao respondeu."
    } catch {
        $taskError = $_.Exception.Message
    }

    if ($taskError) {
        $attemptErrors.Add("ScheduledTask: $taskError") | Out-Null
    }
    Remove-HeadlessSteamMoonlightScheduledTask

    $details = ($attemptErrors | ForEach-Object { [string]$_ }) -join " | "
    throw "Moonlight Web nao iniciou. $details"
}

function Stop-HeadlessSteamMoonlightWebServer {
    Remove-HeadlessSteamMoonlightScheduledTask

    $stopped = $false
    if (Get-Command Stop-MoonlightWebProcesses -ErrorAction SilentlyContinue) {
        $stopped = Stop-MoonlightWebProcesses -WaitSeconds 6
    } else {
        Stop-Process -Name $webServerProcess -Force -ErrorAction SilentlyContinue
        Stop-Process -Name "streamer" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        $stopped = -not (Test-MoonlightWebProcessRunning)
    }

    if (-not $stopped -and (Test-IsAdministrator)) {
        $userSessionScript = Join-Path $ScriptDir "Start-UserSessionProcess.ps1"
        if (Test-Path -LiteralPath $userSessionScript) {
            try {
                . $userSessionScript
                Start-UserSessionProcess -FilePath "cmd.exe" -ArgumentList "/c taskkill /F /IM web-server.exe /IM streamer.exe /T" -WorkingDirectory $env:SystemRoot | Out-Null
                Start-Sleep -Seconds 2
                $stopped = -not (Test-MoonlightWebProcessRunning)
            } catch {
            }
        }
    }

    if (-not $stopped) {
        throw "Moonlight Web ainda esta em execucao apos tentativa de parar."
    }
}

function Complete-MoonlightWebLog {
    param(
        [bool]$Success,
        [string[]]$Errors = @(),
        [string[]]$Warnings = @(),
        [hashtable]$Details = @{}
    )

    $entry = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        success   = $Success
        action    = $Action
        appRoot   = (Get-HeadlessSteamAppRoot -FromScriptDir $ScriptDir)
        package   = $moonlightPkg
        errors    = @($Errors | ForEach-Object { [string]$_ })
        warnings  = @($Warnings | ForEach-Object { [string]$_ })
        details   = $Details
    }

    $logPath = Write-HeadlessSteamMoonlightLog -RunEntry ([pscustomobject]$entry) -FromScriptDir $ScriptDir
    if ($Success) {
        Write-Output "Log Moonlight Web: $logPath"
    }
    return $logPath
}

$logWarnings = New-Object System.Collections.Generic.List[string]
$logDetails = @{}

if ($Action -eq "stop") {
    $wasRunning = if (Get-Command Test-MoonlightWebActive -ErrorAction SilentlyContinue) {
        Test-MoonlightWebActive
    } else {
        Test-MoonlightWebProcessRunning
    }
    try {
        Stop-HeadlessSteamMoonlightWebServer
    } catch {
        Complete-MoonlightWebLog -Success $false -Errors @($_.Exception.Message) -Details @{ wasRunning = $wasRunning } | Out-Null
        Write-Error $_.Exception.Message
        exit 1
    }
    Complete-MoonlightWebLog -Success $true -Details @{ wasRunning = $wasRunning } | Out-Null
    if ($wasRunning) {
        Write-Output "Moonlight Web parado."
    } else {
        Write-Output "Moonlight Web ja estava desligado."
    }
    exit 0
}

try {
    $runtime = Initialize-HeadlessSteamMoonlightRuntime -FromScriptDir $ScriptDir
    $moonlightPkg = $runtime.PackageDir
    foreach ($warn in @($runtime.Warnings)) {
        if ($warn) { $logWarnings.Add([string]$warn) | Out-Null }
    }

    try {
        Apply-HeadlessSteamMoonlightSettings -ScriptDir $ScriptDir
    } catch {
        $logWarnings.Add("Config Moonlight Web: $($_.Exception.Message)") | Out-Null
    }

    $serverPath = $runtime.ServerExe
    if (Test-MoonlightWebProcessRunning) {
        Complete-MoonlightWebLog -Success $true -Warnings @($logWarnings) -Details @{ note = "Ja estava ligado" } | Out-Null
        Write-Output "Moonlight Web ja estava ligado."
        exit 0
    }

    if (-not $TailscaleIp) {
        $TailscaleIp = Get-HeadlessSteamTailscaleIPv4 -PreferredIp $TailscaleIp
    }
    if (-not $TailscaleIp) {
        $logWarnings.Add("Tailscale sem IP detectavel; usando 127.0.0.1 para WebRTC NAT.") | Out-Null
        Write-Output "AVISO: Tailscale sem IP. Iniciando Moonlight Web mesmo assim..."
        $TailscaleIp = "127.0.0.1"
    }

    $interactiveUser = Get-HeadlessSteamInteractiveUserInfo
    if ($interactiveUser) {
        $logDetails.interactiveUser = $interactiveUser.UserName
        $logDetails.interactiveUserSid = $interactiveUser.Sid
        $logDetails.interactiveUserSource = $interactiveUser.Source
        $logDetails.consoleSessionId = $interactiveUser.ConsoleSessionId
    } else {
        $logWarnings.Add("Usuario interativo do console nao detectado; fallback para identidade elevada.") | Out-Null
    }
    $logDetails.elevatedIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name

    $serverArgs = "-c server/config.json --bind-address 0.0.0.0:8080 --webrtc-nat-1to1-host $TailscaleIp --webrtc-port-range 40000:40010 run"
    $startMethod = Start-HeadlessSteamMoonlightWebServer `
        -FilePath $serverPath `
        -ArgumentList $serverArgs `
        -WorkingDirectory $moonlightPkg

    $logDetails.startMethod = $startMethod
    $logDetails.tailscaleIp = $TailscaleIp

    if ($moonlightPkg -match 'OneDrive') {
        $logWarnings.Add("App em OneDrive ($moonlightPkg). Se falhar ao iniciar, mova para pasta local (ex.: C:\HandlessSunshine).") | Out-Null
    }

    if (-not (Wait-MoonlightWebReady -TimeoutSeconds 45)) {
        throw "Moonlight Web nao respondeu na porta 8080 apos 45 segundos."
    }

    $logPath = Complete-MoonlightWebLog -Success $true -Warnings @($logWarnings) -Details $logDetails
    Write-Output "Moonlight Web iniciado."
    Write-Output "Acesso local: http://localhost:8080"
    exit 0
} catch {
    $message = $_.Exception.Message
    $logPath = Complete-MoonlightWebLog -Success $false -Errors @($message) -Warnings @($logWarnings) -Details $logDetails
    Write-Output "Log Moonlight Web: $logPath"
    throw "ERRO: $message"
}
