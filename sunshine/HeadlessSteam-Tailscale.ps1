$script:HeadlessSteamTailscaleExe = "C:\Program Files\Tailscale\tailscale.exe"
$script:HeadlessSteamTailscaleFunnelAclUrl = "https://login.tailscale.com/admin/acls/file"
$script:HeadlessSteamTailscaleFunnelDnsUrl = "https://login.tailscale.com/admin/dns"

function Get-HeadlessSteamTailscaleFunnelAclUrl {
    return $script:HeadlessSteamTailscaleFunnelAclUrl
}

function Get-HeadlessSteamTailscaleFunnelDnsSetupUrl {
    return $script:HeadlessSteamTailscaleFunnelDnsUrl
}

function Get-HeadlessSteamTailscaleFunnelSetupUrl {
    return Get-HeadlessSteamTailscaleFunnelAclUrl
}

function Get-HeadlessSteamTailscaleExe {
    if (Test-Path -LiteralPath $script:HeadlessSteamTailscaleExe) {
        return $script:HeadlessSteamTailscaleExe
    }
    return $null
}

function Get-HeadlessSteamTailscaleIpv4Fast {
    foreach ($addr in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        if ($addr.IPAddress -match '^100\.' -and $addr.InterfaceAlias -match 'Tailscale') {
            return $addr.IPAddress
        }
    }

    foreach ($addr in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        if ($addr.IPAddress -match '^100\.') {
            return $addr.IPAddress
        }
    }

    return $null
}

function Get-HeadlessSteamTailscaleIpv4 {
    param([int]$TimeoutSeconds = 4)

    $ip = Get-HeadlessSteamTailscaleIpv4Fast
    if ($ip) {
        return $ip
    }

    $result = Invoke-HeadlessSteamTailscaleCommand -ArgumentList @("ip", "-4") -TimeoutSeconds $TimeoutSeconds
    if (-not $result.Output) {
        return $null
    }

    foreach ($line in ($result.Output -split "`n")) {
        $ip = $line.Trim()
        if ($ip) {
            return $ip
        }
    }

    return $null
}

function Invoke-HeadlessSteamTailscaleCommand {
    param(
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [int]$TimeoutSeconds = 20
    )

    $exe = Get-HeadlessSteamTailscaleExe
    if (-not $exe) {
        return [pscustomobject]@{
            Success  = $false
            ExitCode = -1
            TimedOut = $false
            Output   = ""
            Error    = "Tailscale nao instalado."
        }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ($ArgumentList | ForEach-Object {
        if ($_ -match '\s') { "`"$_`"" } else { $_ }
    }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $timedOut = -not $proc.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)
    if ($timedOut) {
        try { $proc.Kill() } catch { }
    }

    [void]$stdoutTask.Wait(2500)
    [void]$stderrTask.Wait(2500)
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($stdout -and $stdout.Length -ge 1 -and [int][char]$stdout[0] -eq 0xFEFF) {
        $stdout = $stdout.Substring(1)
    }

    if ($timedOut -and -not [string]::IsNullOrWhiteSpace($stdout)) {
        return [pscustomobject]@{
            Success  = $true
            ExitCode = 0
            TimedOut = $false
            Output   = [string]$stdout
            Error    = [string]$stderr
        }
    }

    if ($timedOut) {
        return [pscustomobject]@{
            Success  = $false
            ExitCode = -1
            TimedOut = $true
            Output   = ""
            Error    = "Tailscale nao respondeu em ${TimeoutSeconds}s ($($ArgumentList -join ' '))."
        }
    }

    return [pscustomobject]@{
        Success  = ($proc.ExitCode -eq 0)
        ExitCode = $proc.ExitCode
        TimedOut = $false
        Output   = [string]$stdout
        Error    = [string]$stderr
    }
}

function ConvertFrom-HeadlessSteamTailscaleJson {
    param([string]$Text)

    if (-not $Text) {
        return $null
    }

    $raw = $Text.Trim()
    if ($raw.Length -ge 1 -and [int][char]$raw[0] -eq 0xFEFF) {
        $raw = $raw.Substring(1)
    }

    try {
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Test-HeadlessSteamTailscaleFunnelStatusTextIsPublic {
    param([string]$Text)

    if (-not $Text) {
        return $false
    }

    if ($Text -match '(?i)tailnet only|within your tailnet|Available within your tailnet|somente na tailnet') {
        return $false
    }

    if ($Text -match '(?i)Available on the internet|on the internet|disponivel na internet|\(Funnel on\)|# Funnel on:|Funnel started') {
        return $true
    }

    return $false
}

function Test-HeadlessSteamTailscaleNodeHasFunnelCapability {
    param($Self)

    if (-not $Self) {
        return $false
    }

    $caps = @($Self.Capabilities)
    if ($caps -contains "funnel") {
        return $true
    }

    if ($Self.CapMap -and ($Self.CapMap.PSObject.Properties.Name -contains "funnel")) {
        return $true
    }

    $capMap = $Self.CapMap
    if ($capMap -and ($capMap.PSObject.Properties | Where-Object { $_.Name -like '*funnel*' })) {
        return $true
    }

    return $false
}

function Test-HeadlessSteamTailscaleNodeFunnelCapabilityQuick {
    $statusResult = Invoke-HeadlessSteamTailscaleCommand -ArgumentList @("status", "--json") -TimeoutSeconds 6
    if ($statusResult.TimedOut -or -not $statusResult.Output) {
        return $false
    }

    $status = ConvertFrom-HeadlessSteamTailscaleJson -Text $statusResult.Output
    if (-not $status) {
        return $false
    }

    return Test-HeadlessSteamTailscaleNodeHasFunnelCapability -Self $status.Self
}

function Test-HeadlessSteamTailscaleFunnelAllowedOnNode {
    $statusResult = Invoke-HeadlessSteamTailscaleCommand -ArgumentList @("status", "--json") -TimeoutSeconds 12
    if (-not $statusResult.TimedOut -and $statusResult.Output) {
        $status = ConvertFrom-HeadlessSteamTailscaleJson -Text $statusResult.Output
        if (Test-HeadlessSteamTailscaleNodeHasFunnelCapability -Self $status.Self) {
            return $true
        }
    }

    $funnelJsonResult = Invoke-HeadlessSteamTailscaleCommand -ArgumentList @("funnel", "status", "--json") -TimeoutSeconds 12
    if (-not $funnelJsonResult.TimedOut -and $funnelJsonResult.Output) {
        $funnelStatus = ConvertFrom-HeadlessSteamTailscaleJson -Text $funnelJsonResult.Output
        if ($funnelStatus -and $funnelStatus.AllowFunnel) {
            foreach ($prop in $funnelStatus.AllowFunnel.PSObject.Properties) {
                if ($prop.Value -eq $true) {
                    return $true
                }
            }
        }
    }

    $funnelTextResult = Invoke-HeadlessSteamTailscaleCommand -ArgumentList @("funnel", "status") -TimeoutSeconds 12
    if (-not $funnelTextResult.TimedOut -and $funnelTextResult.Output) {
        if (Test-HeadlessSteamTailscaleFunnelStatusTextIsPublic -Text $funnelTextResult.Output) {
            return $true
        }
    }

    return $false
}

function Get-HeadlessSteamTailscaleSelfHttpsUrl {
    $statusResult = Invoke-HeadlessSteamTailscaleCommand -ArgumentList @("status", "--json") -TimeoutSeconds 12
    if ($statusResult.TimedOut -or -not $statusResult.Output) {
        return $null
    }

    $status = ConvertFrom-HeadlessSteamTailscaleJson -Text $statusResult.Output
    if (-not $status -or -not $status.Self -or -not $status.Self.DNSName) {
        return $null
    }

    $dnsName = [string]$status.Self.DNSName
    if (-not $dnsName) {
        return $null
    }

    return "https://$dnsName".TrimEnd('/')
}

function Get-HeadlessSteamTailscalePublicFunnelUrlFromJson {
    param([string]$JsonText)

    $json = ConvertFrom-HeadlessSteamTailscaleJson -Text $JsonText
    if (-not $json) {
        return $null
    }

    $publicHosts = New-Object System.Collections.Generic.List[string]
    if ($json.AllowFunnel) {
        foreach ($prop in $json.AllowFunnel.PSObject.Properties) {
            if ($prop.Value -eq $true) {
                $hostName = ($prop.Name -split ':')[0]
                if ($hostName) {
                    $publicHosts.Add($hostName) | Out-Null
                }
            }
        }
    }

    if ($publicHosts.Count -gt 0) {
        return "https://$($publicHosts[0])".TrimEnd('/')
    }

    if ($json.Web) {
        foreach ($prop in $json.Web.PSObject.Properties) {
            $hostName = ($prop.Name -split ':')[0]
            if ($hostName -match '\.ts\.net$') {
                return "https://$hostName".TrimEnd('/')
            }
        }
    }

    return $null
}

function Get-HeadlessSteamTailscaleServeStatusJson {
    param([string[]]$Command = @("funnel", "status", "--json"))

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $result = Invoke-HeadlessSteamTailscaleCommand -ArgumentList $Command -TimeoutSeconds 12
        if (-not $result.TimedOut -and $result.Output) {
            $raw = $result.Output.Trim()
            if ($raw -and $raw -ne '{}' -and $raw -notmatch '(?i)No serve config') {
                return $raw
            }
        }
        if ($attempt -eq 0) {
            Start-Sleep -Milliseconds 250
        }
    }

    return $null
}

function Test-HeadlessSteamTailscalePublicFunnelConfigured {
    foreach ($command in @(
        @("funnel", "status", "--json"),
        @("serve", "status", "--json")
    )) {
        $jsonText = Get-HeadlessSteamTailscaleServeStatusJson -Command $command
        if (-not $jsonText) {
            continue
        }

        $json = ConvertFrom-HeadlessSteamTailscaleJson -Text $jsonText
        if (-not $json -or -not $json.AllowFunnel) {
            continue
        }

        foreach ($prop in $json.AllowFunnel.PSObject.Properties) {
            if ($prop.Value -eq $true) {
                return $true
            }
        }
    }

    return $false
}

function Get-HeadlessSteamTailscalePublicFunnelUrl {
    foreach ($command in @(
        @("funnel", "status", "--json"),
        @("serve", "status", "--json")
    )) {
        $jsonText = Get-HeadlessSteamTailscaleServeStatusJson -Command $command
        if (-not $jsonText) {
            continue
        }

        $fromJson = Get-HeadlessSteamTailscalePublicFunnelUrlFromJson -JsonText $jsonText
        if ($fromJson) {
            return $fromJson
        }
    }

    foreach ($command in @(
        @("funnel", "status"),
        @("serve", "status")
    )) {
        $result = Invoke-HeadlessSteamTailscaleCommand -ArgumentList $command -TimeoutSeconds 12
        if ($result.TimedOut -or -not $result.Output) {
            continue
        }

        $text = [string]$result.Output
        if (-not (Test-HeadlessSteamTailscaleFunnelStatusTextIsPublic -Text $text)) {
            continue
        }

        $match = [regex]::Match($text, '(https://[^\s]+\.ts\.net)')
        if ($match.Success) {
            return $match.Groups[1].Value.TrimEnd('/')
        }
    }

    if (Test-HeadlessSteamTailscalePublicFunnelConfigured) {
        return Get-HeadlessSteamTailscaleSelfHttpsUrl
    }

    return $null
}

function Get-HeadlessSteamTailscaleFunnelQuickStatus {
    $allowed = Test-HeadlessSteamTailscaleNodeFunnelCapabilityQuick
    $url = $null

    foreach ($command in @(
        @("funnel", "status", "--json"),
        @("serve", "status", "--json")
    )) {
        $jsonText = Get-HeadlessSteamTailscaleServeStatusJson -Command $command
        if (-not $jsonText) {
            continue
        }

        $candidate = Get-HeadlessSteamTailscalePublicFunnelUrlFromJson -JsonText $jsonText
        if ($candidate) {
            $url = $candidate
            $allowed = $true
            break
        }
    }

    if (-not $url -and (Test-HeadlessSteamTailscalePublicFunnelConfigured)) {
        $url = Get-HeadlessSteamTailscaleSelfHttpsUrl
        if ($url) {
            $allowed = $true
        }
    }

    return [pscustomobject]@{
        Allowed = $allowed
        Url     = $url
    }
}

function Test-HeadlessSteamTailscaleExposureConfigured {
    foreach ($command in @(
        @("funnel", "status", "--json"),
        @("serve", "status", "--json")
    )) {
        $jsonText = Get-HeadlessSteamTailscaleServeStatusJson -Command $command
        if (-not $jsonText) {
            continue
        }

        try {
            $json = ConvertFrom-HeadlessSteamTailscaleJson -Text $jsonText
            if ($json.Web -and @($json.Web.PSObject.Properties).Count -gt 0) {
                return $true
            }
            if ($json.TCP -and @($json.TCP.PSObject.Properties).Count -gt 0) {
                return $true
            }
        } catch {
        }
    }

    return $false
}

function Reset-HeadlessSteamTailscaleExposure {
    if (-not (Get-HeadlessSteamTailscaleExe)) {
        return
    }

    $tsSvc = Get-Service -Name "Tailscale" -ErrorAction SilentlyContinue
    if (-not $tsSvc -or $tsSvc.Status -ne "Running") {
        return
    }

    $serveReset = Invoke-HeadlessSteamTailscaleCommand -ArgumentList @("serve", "reset") -TimeoutSeconds 10
    if ($serveReset.TimedOut) {
        Write-Output "AVISO: tailscale serve reset expirou; continuando."
    }

    if (Test-HeadlessSteamTailscaleExposureConfigured) {
        $funnelReset = Invoke-HeadlessSteamTailscaleCommand -ArgumentList @("funnel", "reset") -TimeoutSeconds 10
        if ($funnelReset.TimedOut) {
            Write-Output "AVISO: tailscale funnel reset expirou; continuando."
        }
    }

    Start-Sleep -Milliseconds 300
}

function Get-HeadlessSteamTailscaleFunnelFailureHint {
    param([string]$CombinedOutput)

    if (-not $CombinedOutput) {
        return $null
    }

    if ($CombinedOutput -match '(?i)Funnel not available|"funnel" node attribute not set|funnel node attribute not set') {
        return "ACL_FUNNEL_NODEATTRS"
    }

    if ($CombinedOutput -match '(?i)MagicDNS|HTTPS certificates|certificates are not enabled') {
        return "TAILSCALE_HTTPS_OR_DNS"
    }

    return $null
}

function Test-HeadlessSteamTailscaleHttpsCertsEnabled {
    param($Status)

    if (-not $Status) {
        return $false
    }

    $certDomains = @($Status.CertDomains)
    if ($certDomains.Count -gt 0) {
        return $true
    }

    foreach ($line in @($Status.Health)) {
        if ($line -match '(?i)certificates are not enabled|enable https|HTTPS certificates') {
            return $false
        }
    }

    $funnelResult = Invoke-HeadlessSteamTailscaleCommand -ArgumentList @("funnel", "status") -TimeoutSeconds 8
    $combined = ([string]$funnelResult.Output + "`n" + [string]$funnelResult.Error).Trim()
    if ((Get-HeadlessSteamTailscaleFunnelFailureHint -CombinedOutput $combined) -eq "TAILSCALE_HTTPS_OR_DNS") {
        return $false
    }

    if ($Status.CurrentTailnet -and $Status.CurrentTailnet.MagicDNSEnabled -and $Status.Self -and $Status.Self.DNSName) {
        if ($Status.Self.DNSName -match '\.ts\.net') {
            return $true
        }
    }

    return $false
}

function Get-HeadlessSteamTailscaleFunnelRequirements {
    $result = [ordered]@{
        Checked     = $false
        AclFunnel   = $false
        MagicDns    = $false
        HttpsCerts  = $false
        AllMet      = $false
        AclSetupUrl = (Get-HeadlessSteamTailscaleFunnelAclUrl)
        DnsSetupUrl = (Get-HeadlessSteamTailscaleFunnelDnsSetupUrl)
        Note        = ""
    }

    if (-not (Get-HeadlessSteamTailscaleExe)) {
        $result.Note = "Tailscale nao instalado."
        return [pscustomobject]$result
    }

    $tsSvc = Get-Service -Name "Tailscale" -ErrorAction SilentlyContinue
    if (-not $tsSvc -or $tsSvc.Status -ne "Running") {
        $result.Note = "Ligue o Tailscale para verificar os requisitos."
        return [pscustomobject]$result
    }

    $statusResult = Invoke-HeadlessSteamTailscaleCommand -ArgumentList @("status", "--json") -TimeoutSeconds 10
    if ($statusResult.TimedOut -or -not $statusResult.Output) {
        $result.Note = "Tailscale nao respondeu ao status --json."
        return [pscustomobject]$result
    }

    $status = ConvertFrom-HeadlessSteamTailscaleJson -Text $statusResult.Output
    if (-not $status) {
        $result.Note = "Resposta invalida do tailscale status --json."
        return [pscustomobject]$result
    }

    $result.Checked = $true
    $result.AclFunnel = Test-HeadlessSteamTailscaleNodeHasFunnelCapability -Self $status.Self
    if ($status.CurrentTailnet) {
        $result.MagicDns = [bool]$status.CurrentTailnet.MagicDNSEnabled
    }
    $result.HttpsCerts = Test-HeadlessSteamTailscaleHttpsCertsEnabled -Status $status
    $result.AllMet = $result.AclFunnel -and $result.MagicDns -and $result.HttpsCerts

    return [pscustomobject]$result
}
