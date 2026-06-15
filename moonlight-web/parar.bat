@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "TAILSCALE=C:\Program Files\Tailscale\tailscale.exe"

taskkill /F /IM web-server.exe >nul 2>&1
taskkill /F /IM streamer.exe >nul 2>&1

if exist "%TAILSCALE%" (
    "%TAILSCALE%" serve reset >nul 2>&1
)

echo Moonlight Web parado.
timeout /t 2 /nobreak >nul
