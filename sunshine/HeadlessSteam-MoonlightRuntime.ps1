$script:HeadlessSteamWebServerProcess = "web-server"
$script:HeadlessSteamWebServerPort = 8080

function Test-MoonlightWebProcessRunning {
    return $null -ne (Get-Process -Name $script:HeadlessSteamWebServerProcess -ErrorAction SilentlyContinue)
}

function Stop-MoonlightWebProcesses {
    param([int]$WaitSeconds = 5)

    $imageNames = @(
        "$($script:HeadlessSteamWebServerProcess).exe",
        "streamer.exe"
    )

    foreach ($image in $imageNames) {
        & taskkill.exe /F /IM $image /T 2>$null | Out-Null
    }

    foreach ($name in @($script:HeadlessSteamWebServerProcess, "streamer")) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Stop-Process -Id $_.Id -Force -ErrorAction Stop
            } catch {
            }
        }
    }

    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $WaitSeconds))
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-MoonlightWebProcessRunning) -and -not (Test-MoonlightWebPortReady)) {
            return $true
        }
        Start-Sleep -Milliseconds 300
    }

    return (-not (Test-MoonlightWebProcessRunning))
}

function Test-MoonlightWebActive {
    return (Test-MoonlightWebProcessRunning) -or (Test-MoonlightWebPortReady)
}

function Test-MoonlightWebPortReady {
    param(
        [int]$Port = $script:HeadlessSteamWebServerPort,
        [int]$TimeoutMs = 500
    )

    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $connect = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        $connected = $connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($connected -and $client.Connected) {
            return $true
        }
    } catch {
    } finally {
        if ($client) {
            $client.Close()
        }
    }

    return $false
}

function Test-MoonlightWebReady {
    return (Test-MoonlightWebProcessRunning) -and (Test-MoonlightWebPortReady)
}

function Wait-MoonlightWebReady {
    param([int]$TimeoutSeconds = 45)

    for ($elapsed = 0; $elapsed -lt ($TimeoutSeconds * 1000); $elapsed += 500) {
        if (Test-MoonlightWebReady) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }

    return $false
}

# Compatibilidade com scripts antigos.
function Test-MoonlightWebRunning {
    return Test-MoonlightWebProcessRunning
}

function Wait-MoonlightWebRunning {
    param([int]$TimeoutSeconds = 45)

    return Wait-MoonlightWebReady -TimeoutSeconds $TimeoutSeconds
}
