param(
    [switch]$Quick
)

$script:HeadlessSteamTailscaleExe = "C:\Program Files\Tailscale\tailscale.exe"
$script:HeadlessSteamSunshineService = "SunshineService"
$script:HeadlessSteamTailscaleService = "Tailscale"
$script:HeadlessSteamSunshineConf = Join-Path $env:ProgramFiles "Sunshine\config\sunshine.conf"
$script:HeadlessSteamWebServer = "web-server"
$script:HeadlessSteamSunshineWebPort = 47990

. (Join-Path $PSScriptRoot "HeadlessSteam-MoonlightSettings.ps1")
. (Join-Path $PSScriptRoot "HeadlessSteam-MoonlightRuntime.ps1")
. (Join-Path $PSScriptRoot "HeadlessSteam-Tailscale.ps1")
. (Join-Path $PSScriptRoot "HeadlessSteam-VirtualDisplay.ps1")
. (Join-Path $PSScriptRoot "HeadlessSteam-HostSettings.ps1")
. (Join-Path $PSScriptRoot "HeadlessSteam-Display.ps1")

function Get-HeadlessSteamLanIPv4 {
    foreach ($addr in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        $ip = $addr.IPAddress
        if ($ip -match '^(127\.|169\.254\.|100\.)') { continue }
        if ($addr.InterfaceAlias -match 'Tailscale|Loopback|vEthernet|VirtualBox|VMware|Hyper-V|WSL|Npcap') { continue }
        return $ip
    }
    return $null
}

. (Join-Path $PSScriptRoot "Sunshine-Config.ps1")

function Test-HeadlessSteamSunshineApiAuthRequired {
    param([int]$Port = 47990)

    if (-not ([System.Management.Automation.PSTypeName]'HeadlessSteamTrustAllCertsPolicy').Type) {
        Add-Type @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class HeadlessSteamTrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint,
        X509Certificate certificate,
        WebRequest request,
        int certificateProblem) {
        return true;
    }
}
'@
    }

    $previousPolicy = [System.Net.ServicePointManager]::CertificatePolicy
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object HeadlessSteamTrustAllCertsPolicy

    try {
        $request = [System.Net.HttpWebRequest]::Create("https://127.0.0.1:$Port/api/config")
        $request.Method = "GET"
        $request.Timeout = 4000
        $request.AllowAutoRedirect = $false
        $response = $request.GetResponse()
        $response.Close()
        return $false
    } catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if ($response) {
            try {
                $code = [int]$response.StatusCode
                $response.Close()
                if ($code -eq 401) {
                    return $true
                }
            } catch {
            }
        }
        return $null
    } finally {
        [System.Net.ServicePointManager]::CertificatePolicy = $previousPolicy
    }
}

function Get-HeadlessSteamSunshineConfigDirectory {
    $dir = Get-SunshineConfigDirectory
    if ($dir) {
        return $dir
    }
    return Join-Path $env:ProgramFiles "Sunshine\config"
}

function Get-HeadlessSteamSunshineAccountStateQuick {
    $configDir = Get-HeadlessSteamSunshineConfigDirectory
    $stateFile = Join-Path $configDir "sunshine_state.json"
    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$state.username) {
                return "needs_app_login"
            }
            if ($state.password -or $state.salt) {
                return "needs_app_login"
            }
        } catch {
        }
    }

    foreach ($dir in @(
        (Join-Path (Split-Path -Parent $configDir) "credentials"),
        (Join-Path $configDir "credentials")
    )) {
        if (-not (Test-Path $dir)) { continue }
        $items = @(Get-ChildItem $dir -Force -ErrorAction SilentlyContinue)
        if ($items.Count -gt 0) {
            return "needs_app_login"
        }
    }

    return "no_password"
}

function Get-HeadlessSteamSunshineAccountState {
    param([bool]$SunshineRunning = $false)

    $configDir = Get-HeadlessSteamSunshineConfigDirectory
    $stateFile = Join-Path $configDir "sunshine_state.json"
    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $username = [string]$state.username
            if (-not $username) {
                return "no_password"
            }
        } catch {
        }
    }

    if ($SunshineRunning) {
        $authRequired = Test-HeadlessSteamSunshineApiAuthRequired
        if ($authRequired -eq $true) {
            return "needs_app_login"
        }
        if ($authRequired -eq $false) {
            return "no_password"
        }
    }

    foreach ($dir in @(
        (Join-Path (Split-Path -Parent $configDir) "credentials"),
        (Join-Path $configDir "credentials")
    )) {
        if (-not (Test-Path $dir)) { continue }
        $items = @(Get-ChildItem $dir -Force -ErrorAction SilentlyContinue)
        if ($items.Count -gt 0) {
            return "needs_app_login"
        }
    }

    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($state.username) {
                return "needs_app_login"
            }
            if ($state.password -or $state.salt) {
                return "needs_app_login"
            }
        } catch {
        }
    }

    return "no_password"
}

function Test-HeadlessSteamSunshineNeedsSetup {
    param([bool]$SunshineRunning = $false)

    return (Get-HeadlessSteamSunshineAccountState -SunshineRunning:$SunshineRunning) -eq "no_password"
}

function Get-HeadlessSteamSunshineUsername {
    $stateFile = Join-Path (Get-HeadlessSteamSunshineConfigDirectory) "sunshine_state.json"
    if (-not (Test-Path $stateFile)) { return $null }
    try {
        $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $name = [string]$state.username
        if ($name) { return $name }
    } catch {
    }
    return $null
}

function Get-HeadlessSteamStatus {
    param([switch]$Quick)

    $sunshineRunning = $false
    $sunshineSvc = Get-Service -Name $script:HeadlessSteamSunshineService -ErrorAction SilentlyContinue
    if ($sunshineSvc -and $sunshineSvc.Status -eq "Running") {
        $sunshineRunning = $true
    }

    $tailscaleRunning = $false
    $tailscaleConnected = $false
    $tailscaleIp = $null
    $tailscaleHealth = $null
    $tailscaleNeedsLogin = $false
    $tailscaleIsStarting = $false
    $tailscaleConn = Get-HeadlessSteamTailscaleConnectionState
    $tailscaleRunning = [bool]$tailscaleConn.ServiceRunning -and (
        $tailscaleConn.Connected -or $tailscaleConn.IsStarting -or $tailscaleConn.NeedsLogin -or
        ($tailscaleConn.BackendState -match '(?i)Running|Starting')
    )
    if (-not $tailscaleRunning) {
        $tailscaleRunning = Test-HeadlessSteamTailscaleVpnActive
    }
    $tailscaleIp = $tailscaleConn.Ip
    $tailscaleConnected = [bool]$tailscaleConn.Connected
    $tailscaleHealth = $tailscaleConn.HealthMessage
    $tailscaleNeedsLogin = [bool]$tailscaleConn.NeedsLogin
    $tailscaleIsStarting = [bool]$tailscaleConn.IsStarting
    if ($tailscaleRunning -and -not $tailscaleIp) {
        $tailscaleIp = Get-HeadlessSteamTailscaleIpv4Fast
        if ($tailscaleIp) {
            $tailscaleConnected = $true
        }
    }

    $moonlightRunning = Test-MoonlightWebProcessRunning

    $moonlightSettings = Get-HeadlessSteamMoonlightSettings
    $moonlightFunnelEnabled = [bool]$moonlightSettings.public_funnel_enabled
    $tailscaleFunnelAllowed = $false
    $moonlightFunnelUrl = $null
    $moonlightFunnelActive = $false
    $tailscaleFunnelAclOk = $false
    $tailscaleMagicDnsOk = $false
    $tailscaleHttpsOk = $false
    $tailscaleFunnelRequirementsMet = $false
    $tailscaleFunnelDnsSetupUrl = (Get-HeadlessSteamTailscaleFunnelDnsSetupUrl)

    if ($tailscaleRunning -and -not $Quick) {
        $funnelReqs = Get-HeadlessSteamTailscaleFunnelRequirements
        if ($funnelReqs.Checked) {
            $tailscaleFunnelAclOk = [bool]$funnelReqs.AclFunnel
            $tailscaleMagicDnsOk = [bool]$funnelReqs.MagicDns
            $tailscaleHttpsOk = [bool]$funnelReqs.HttpsCerts
            $tailscaleFunnelRequirementsMet = [bool]$funnelReqs.AllMet
        }
    }

    if ($moonlightFunnelEnabled) {
        if ($Quick) {
            $funnelQuick = Get-HeadlessSteamTailscaleFunnelQuickStatus
            $tailscaleFunnelAllowed = [bool]$funnelQuick.Allowed
            $moonlightFunnelUrl = $funnelQuick.Url
            $moonlightFunnelActive = $null -ne $moonlightFunnelUrl
        } else {
            $tailscaleFunnelAllowed = Test-HeadlessSteamTailscaleFunnelAllowed
            $moonlightFunnelUrl = Get-HeadlessSteamMoonlightFunnelUrl
            $moonlightFunnelActive = $null -ne $moonlightFunnelUrl
        }
    }

    $gamepadMode = "auto"
    if (Test-Path $script:HeadlessSteamSunshineConf) {
        $line = Select-String -Path $script:HeadlessSteamSunshineConf -Pattern '^\s*gamepad\s*=' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($line) {
            $gamepadMode = ($line.Line -replace '(?i)^gamepad\s*=\s*', '').Trim()
        }
    }

    if ($Quick) {
        $sunshineAccountState = Get-HeadlessSteamSunshineAccountStateQuick
        $sunshineNeedsSetup = ($sunshineAccountState -eq "no_password")
        $lanIp = $null
    } else {
        $sunshineAccountState = Get-HeadlessSteamSunshineAccountStateQuick
        $sunshineNeedsSetup = ($sunshineAccountState -eq "no_password")
        $lanIp = Get-HeadlessSteamLanIPv4
    }
    $sunshineUsername = Get-HeadlessSteamSunshineUsername

    $hostFreeStatus = Get-HeadlessSteamHostFreeStatus -Quick:$Quick

    return [pscustomobject]@{
        SunshineRunning    = $sunshineRunning
        TailscaleRunning   = $tailscaleRunning
        TailscaleConnected = $tailscaleConnected
        TailscaleIp        = $tailscaleIp
        TailscaleHealth    = $tailscaleHealth
        TailscaleNeedsLogin = $tailscaleNeedsLogin
        TailscaleIsStarting = $tailscaleIsStarting
        MoonlightRunning   = $moonlightRunning
        GamepadMode        = $gamepadMode
        LanIp              = $lanIp
        SunshineWebPort    = $script:HeadlessSteamSunshineWebPort
        SunshinePanelUrl   = "https://localhost:$($script:HeadlessSteamSunshineWebPort)"
        SunshineNeedsSetup = $sunshineNeedsSetup
        SunshineAccountState = $sunshineAccountState
        SunshineUsername   = $sunshineUsername
        MoonlightLocalUrl  = "http://localhost:8080"
        MoonlightTailscaleUrl = if ($tailscaleIp) { "http://${tailscaleIp}:8080" } else { $null }
        MoonlightFunnelEnabled = $moonlightFunnelEnabled
        MoonlightFunnelActive = $moonlightFunnelActive
        MoonlightFunnelUrl = $moonlightFunnelUrl
        MoonlightSkipLoginEnabled = [bool]$moonlightSettings.skip_login_enabled
        TailscaleFunnelAllowed = $tailscaleFunnelAllowed
        TailscaleFunnelSetupUrl = (Get-HeadlessSteamTailscaleFunnelSetupUrl)
        TailscaleFunnelAclSetupUrl = (Get-HeadlessSteamTailscaleFunnelAclSetupUrl)
        TailscaleFunnelAclOk = $tailscaleFunnelAclOk
        TailscaleMagicDnsOk = $tailscaleMagicDnsOk
        TailscaleHttpsOk = $tailscaleHttpsOk
        TailscaleFunnelRequirementsMet = $tailscaleFunnelRequirementsMet
        TailscaleFunnelDnsSetupUrl = $tailscaleFunnelDnsSetupUrl
        HostFreeModeEnabled = [bool]$hostFreeStatus.HostFreeModeEnabled
        VirtualDisplayInstalled = [bool]$hostFreeStatus.VirtualDisplayInstalled
        VirtualDisplayActive = [bool]$hostFreeStatus.VirtualDisplayActive
        StreamOutputConfigured = [bool]$hostFreeStatus.StreamOutputConfigured
        HostFreeReady = [bool]$hostFreeStatus.HostFreeReady
        HostFreeStatusMessage = [string]$hostFreeStatus.HostFreeStatusMessage
        HostFreeRebootRequired = [bool]$hostFreeStatus.HostFreeRebootRequired
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $status = Get-HeadlessSteamStatus -Quick:$Quick
    $status | ConvertTo-Json -Compress
}
