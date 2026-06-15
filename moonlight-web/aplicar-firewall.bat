@echo off
setlocal EnableExtensions
cd /d "%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Precisa de permissao de Administrador...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo Aplicando regras de firewall para streaming seguro...
echo.

REM Bloqueia acesso externo ao Moonlight Web (so localhost + Tailscale Serve)
netsh advfirewall firewall delete rule name="Moonlight Web - Bloquear LAN" >nul 2>&1
netsh advfirewall firewall add rule name="Moonlight Web - Bloquear LAN" dir=in action=block protocol=TCP localport=8080 remoteip=LocalSubnet profile=any >nul

REM WebRTC: permitir apenas na interface Tailscale (rede 100.x.x.x)
netsh advfirewall firewall delete rule name="Moonlight WebRTC - Tailscale UDP" >nul 2>&1
netsh advfirewall firewall add rule name="Moonlight WebRTC - Tailscale UDP" dir=in action=allow protocol=UDP localport=40000-40010 remoteip=100.64.0.0/10 profile=any >nul

netsh advfirewall firewall delete rule name="Moonlight WebRTC - Bloquear LAN UDP" >nul 2>&1
netsh advfirewall firewall add rule name="Moonlight WebRTC - Bloquear LAN UDP" dir=in action=block protocol=UDP localport=40000-40010 remoteip=LocalSubnet profile=any >nul

echo Regras aplicadas:
echo   - Porta 8080 bloqueada na rede local (Wi-Fi/LAN)
echo   - WebRTC UDP 40000-40010 permitido so via Tailscale (100.x.x.x)
echo   - Acesso remoto: use Tailscale Serve (https://hicaro)
echo.
echo IMPORTANTE: Nunca use "tailscale funnel" - isso expoe na internet publica.
echo.
pause
