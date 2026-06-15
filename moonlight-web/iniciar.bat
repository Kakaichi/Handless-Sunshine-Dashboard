@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0package"

set "TAILSCALE=C:\Program Files\Tailscale\tailscale.exe"
set "WEB_SERVER=web-server.exe"

for /f "delims=" %%i in ('"%TAILSCALE%" ip -4 2^>nul') do set "TS_IP=%%i"

if not defined TS_IP (
    echo ERRO: Tailscale nao esta conectado. Conecte antes de iniciar.
    pause
    exit /b 1
)

tasklist /FI "IMAGENAME eq %WEB_SERVER%" 2>nul | find /I "%WEB_SERVER%" >nul
if %errorlevel% equ 0 (
    echo Moonlight Web ja esta rodando.
    goto show_urls
)

echo Iniciando Moonlight Web Stream...
echo IP Tailscale: %TS_IP%
echo.

start "Moonlight Web" /MIN cmd /c "%WEB_SERVER% -c server/config.json --bind-address 0.0.0.0:8080 --webrtc-nat-1to1-host %TS_IP% --webrtc-port-range 40000:40010 run"

timeout /t 3 /nobreak >nul

tasklist /FI "IMAGENAME eq %WEB_SERVER%" 2>nul | find /I "%WEB_SERVER%" >nul
if errorlevel 1 (
    echo ERRO: Moonlight Web nao iniciou.
    pause
    exit /b 1
)

echo Configurando Tailscale Serve (HTTPS na rede Tailscale)...
start /B "" "%TAILSCALE%" serve reset >nul 2>&1
start /B "" "%TAILSCALE%" serve --bg 8080 >nul 2>&1
timeout /t 1 /nobreak >nul
echo (Se HTTPS nao funcionar, habilite Serve em login.tailscale.com)

:show_urls
echo.
echo ========================================
echo  Moonlight Web - URLs de acesso
echo ========================================
echo.
echo  No PC (local):     http://localhost:8080
echo  Via Tailscale:     http://%TS_IP%:8080
echo  Via Tailscale HTTPS (recomendado):
echo                     https://hicaro
echo                     (ou o nome MagicDNS do seu PC)
echo.
echo  Primeira vez:
echo    1. Crie usuario/senha (primeiro = admin)
echo    2. Adicione PC: host localhost, porta 47989
echo    3. Pareie com PIN no Sunshine
echo    4. Inicie um jogo
echo.
echo  Controle no navegador precisa de HTTPS (use Tailscale Serve).
echo ========================================
echo.
pause
