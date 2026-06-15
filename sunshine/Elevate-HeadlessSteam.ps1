param(
    [string]$Action
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$batPath = Join-Path $scriptDir "gerenciar-servicos.bat"
$wtPath = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\wt.exe"

if (-not (Test-Path $wtPath)) {
    $wtCmd = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wtCmd) {
        $wtPath = $wtCmd.Source
    }
}

if (Test-Path $wtPath) {
    $wtArgs = @(
        "--title", "Handless Sunshine Dashboard",
        "-d", $scriptDir,
        "cmd", "/k", "`"$batPath`""
    )
    if ($Action) {
        $wtArgs += $Action
    }
    Start-Process -FilePath $wtPath -Verb RunAs -ArgumentList $wtArgs
} elseif ($Action) {
    Start-Process -FilePath $batPath -Verb RunAs -ArgumentList $Action
} else {
    Start-Process -FilePath $batPath -Verb RunAs
}
