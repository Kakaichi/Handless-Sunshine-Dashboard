param(
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [string]$AppId = ""
)

$ErrorActionPreference = "SilentlyContinue"

if (-not (Test-Path $InstallDir)) {
    exit 0
}

$gameDir = (Resolve-Path $InstallDir).Path.TrimEnd('\')

Get-CimInstance Win32_Process |
    Where-Object {
        $_.ExecutablePath -and
        $_.ExecutablePath.StartsWith($gameDir, [StringComparison]::OrdinalIgnoreCase)
    } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force
    }

exit 0
