@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

set "TAILSCALE=C:\Program Files\Tailscale\tailscale.exe"
set "SUNSHINE=SunshineService"
set "SUNSHINE_CONF=C:\Program Files\Sunshine\config\sunshine.conf"
set "TAILSCALE_SVC=Tailscale"
set "MOONLIGHT_DIR=%~dp0..\moonlight-web"
set "MOONLIGHT_PKG=%MOONLIGHT_DIR%\package"
set "WEB_SERVER=web-server.exe"
set "SUNSHINE_WEB_PORT=47990"

if not "%~1"=="" (
    call :ensure_admin %~1
    if errorlevel 1 exit /b 1
    goto %~1
)

:menu
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Show-HeadlessSteamMenu.ps1" -Menu main
call :read_menu_choice OPCAO
if not defined OPCAO goto menu

if "%OPCAO%"=="1" goto ligar_tudo
if "%OPCAO%"=="2" goto desligar_tudo
if "%OPCAO%"=="3" goto alternar
if "%OPCAO%"=="4" goto menu_sunshine
if "%OPCAO%"=="5" goto menu_tailscale
if "%OPCAO%"=="6" goto menu_moonlight
if "%OPCAO%"=="7" goto instalar_deps
if "%OPCAO%"=="8" goto open_sunshine_web
if "%OPCAO%"=="0" exit /b 0
goto menu

:ensure_admin
set "ADMIN_ACTION=%~1"
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo.
    echo  Precisa de permissao de Administrador...
    if defined ADMIN_ACTION (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Elevate-HeadlessSteam.ps1" -Action "%ADMIN_ACTION%"
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Elevate-HeadlessSteam.ps1"
    )
    exit /b 1
)
exit /b 0

:read_menu_choice
set "%~1="
set "CHOICE_FILE=%TEMP%\headless-steam-menu-choice.txt"
if not exist "%CHOICE_FILE%" exit /b 0
set /p %~1=<"%CHOICE_FILE%"
del "%CHOICE_FILE%" >nul 2>&1
exit /b 0

:ligar_tudo
call :ensure_admin ligar_tudo
if errorlevel 1 goto menu
echo.
call :ensure_dependencies
if errorlevel 1 goto menu
echo.
echo Ligando Tailscale e Sunshine...
call :start_tailscale
call :atualizar_jogos
call :start_sunshine
echo.
echo Moonlight Web e opcional: use a opcao [6] se quiser jogar no navegador.
echo.
echo Concluido.
call :show_sunshine_urls
call :pausar
goto menu

:desligar_tudo
call :ensure_admin desligar_tudo
if errorlevel 1 goto menu
echo.
echo Desligando tudo...
call :stop_moonlight
call :stop_sunshine
call :stop_tailscale
echo.
echo Concluido.
call :pausar
goto menu

:alternar
call :ensure_admin alternar
if errorlevel 1 goto menu
set "ALGUM_LIGADO=0"
sc query "%SUNSHINE%" | findstr /C:"RUNNING" >nul && set "ALGUM_LIGADO=1"
sc query "%TAILSCALE_SVC%" | findstr /C:"RUNNING" >nul && set "ALGUM_LIGADO=1"
tasklist /FI "IMAGENAME eq %WEB_SERVER%" 2>nul | find /I "%WEB_SERVER%" >nul && set "ALGUM_LIGADO=1"
echo.
if "!ALGUM_LIGADO!"=="1" (
    echo Alternando: desligando...
    call :stop_moonlight
    call :stop_sunshine
    call :stop_tailscale
) else (
    echo Alternando: ligando...
    call :ensure_dependencies
    if errorlevel 1 goto menu
    call :start_tailscale
    call :atualizar_jogos
    call :start_sunshine
)
echo.
echo Concluido.
call :pausar
goto menu

:menu_sunshine
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Show-HeadlessSteamMenu.ps1" -Menu sunshine
call :read_menu_choice OPCAO
if not defined OPCAO goto menu
if "%OPCAO%"=="1" (
    call :ensure_admin sunshine_ligar
    if errorlevel 1 goto menu
    goto sunshine_ligar
)
if "%OPCAO%"=="2" (
    call :ensure_admin sunshine_desligar
    if errorlevel 1 goto menu
    goto sunshine_desligar
)
if "%OPCAO%"=="3" (
    call :ensure_admin gamepad_ds4
    if errorlevel 1 goto menu
    goto gamepad_ds4
)
if "%OPCAO%"=="4" (
    call :ensure_admin gamepad_x360
    if errorlevel 1 goto menu
    goto gamepad_x360
)
if "%OPCAO%"=="5" goto open_sunshine_web
goto menu

:sunshine_ligar
call :ensure_dependencies
if errorlevel 1 goto menu
call :atualizar_jogos
call :start_sunshine
call :show_sunshine_urls
call :pausar
goto menu

:sunshine_desligar
call :stop_sunshine
call :pausar
goto menu

:gamepad_ds4
call :set_gamepad ds4
call :pausar
goto menu

:gamepad_x360
call :set_gamepad x360
call :pausar
goto menu

:menu_tailscale
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Show-HeadlessSteamMenu.ps1" -Menu tailscale
call :read_menu_choice OPCAO
if not defined OPCAO goto menu
if "%OPCAO%"=="1" (
    call :ensure_admin tailscale_ligar
    if errorlevel 1 goto menu
    goto tailscale_ligar
)
if "%OPCAO%"=="2" (
    call :ensure_admin tailscale_desligar
    if errorlevel 1 goto menu
    goto tailscale_desligar
)
goto menu

:tailscale_ligar
call :start_tailscale
call :pausar
goto menu

:tailscale_desligar
call :stop_tailscale
call :pausar
goto menu

:menu_moonlight
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Show-HeadlessSteamMenu.ps1" -Menu moonlight
call :read_menu_choice OPCAO
if not defined OPCAO goto menu
if "%OPCAO%"=="1" (
    call :ensure_admin moonlight_ligar
    if errorlevel 1 goto menu
    goto moonlight_ligar
)
if "%OPCAO%"=="2" (
    call :stop_moonlight
    call :pausar
)
goto menu

:moonlight_ligar
call :ensure_dependencies
if errorlevel 1 goto menu
call :atualizar_jogos
call :start_moonlight
call :show_moonlight_urls
call :pausar
goto menu

:show_status
call :show_sunshine_status
call :show_sunshine_urls
call :show_tailscale_status
call :show_moonlight_status
exit /b 0

:show_sunshine_urls
sc query "%SUNSHINE%" | findstr /C:"RUNNING" >nul
if errorlevel 1 exit /b 0

echo.
echo   Painel Sunshine ^(HTTPS, porta %SUNSHINE_WEB_PORT%^):
echo   Local:         https://localhost:%SUNSHINE_WEB_PORT%
exit /b 0

:open_sunshine_web
sc query "%SUNSHINE%" | findstr /C:"RUNNING" >nul
if errorlevel 1 (
    echo.
    echo   Sunshine esta desligado. Use [1] ou [4] para ligar primeiro.
    call :pausar
    goto menu
)
echo.
echo   Abrindo https://localhost:%SUNSHINE_WEB_PORT% ...
start "" "https://localhost:%SUNSHINE_WEB_PORT%"
timeout /t 1 /nobreak >nul
goto menu

:show_sunshine_status
sc query "%SUNSHINE%" | findstr /C:"RUNNING" >nul
if %errorlevel% equ 0 (
    echo   Sunshine:      LIGADO
) else (
    echo   Sunshine:      DESLIGADO
)
exit /b 0

:show_gamepad_status
set "GAMEPAD_MODE=auto (padrao)"
if exist "%SUNSHINE_CONF%" (
    for /f "tokens=1,* delims==" %%a in ('findstr /i /b "gamepad" "%SUNSHINE_CONF%" 2^>nul') do (
        for /f "tokens=* delims= " %%v in ("%%b") do set "GAMEPAD_MODE=%%v"
    )
)
echo   Gamepad:       !GAMEPAD_MODE!
exit /b 0

:set_gamepad
set "GAMEPAD_TARGET=%~1"
if not exist "%SUNSHINE_CONF%" (
    type nul > "%SUNSHINE_CONF%"
)

findstr /i /b "gamepad" "%SUNSHINE_CONF%" >nul 2>&1
if %errorlevel% equ 0 (
    powershell -NoProfile -Command "(Get-Content '%SUNSHINE_CONF%') -replace '(?i)^gamepad\s*=.*', 'gamepad = %GAMEPAD_TARGET%' | Set-Content '%SUNSHINE_CONF%' -Encoding UTF8"
) else (
    echo gamepad = %GAMEPAD_TARGET%>>"%SUNSHINE_CONF%"
)

if /i "%GAMEPAD_TARGET%"=="ds4" (
    findstr /i /b "motion_as_ds4" "%SUNSHINE_CONF%" >nul 2>&1
    if errorlevel 1 echo motion_as_ds4 = enabled>>"%SUNSHINE_CONF%"
    findstr /i /b "touchpad_as_ds4" "%SUNSHINE_CONF%" >nul 2>&1
    if errorlevel 1 echo touchpad_as_ds4 = enabled>>"%SUNSHINE_CONF%"
)

echo.
echo   Gamepad configurado: %GAMEPAD_TARGET%
echo   Reiniciando Sunshine...
call :stop_sunshine
timeout /t 2 /nobreak >nul
call :start_sunshine
echo   Reinicie o stream no navegador para aplicar.
exit /b 0

:show_tailscale_status
sc query "%TAILSCALE_SVC%" | findstr /C:"RUNNING" >nul
if %errorlevel% neq 0 (
    echo   Tailscale:     DESLIGADO
    exit /b 0
)
set "TS_CONNECTED=0"
if exist "%TAILSCALE%" (
    for /f "delims=" %%i in ('"%TAILSCALE%" ip -4 2^>nul') do (
        set "TS_CONNECTED=1"
        echo   Tailscale:     CONECTADO
        echo                  IP: %%i
    )
)
if "!TS_CONNECTED!"=="0" (
    echo   Tailscale:     SERVICO ATIVO (VPN desconectada)
)
exit /b 0

:show_moonlight_status
tasklist /FI "IMAGENAME eq %WEB_SERVER%" 2>nul | find /I "%WEB_SERVER%" >nul
if %errorlevel% equ 0 (
    echo   Moonlight Web: LIGADO  (porta 8080)
) else (
    echo   Moonlight Web: DESLIGADO
)
exit /b 0

:show_moonlight_urls
if not exist "%TAILSCALE%" exit /b 0
for /f "delims=" %%i in ('"%TAILSCALE%" ip -4 2^>nul') do set "TS_IP=%%i"
if not defined TS_IP exit /b 0
echo.
echo   Acesso local:  http://localhost:8080
echo   Via Tailscale: http://!TS_IP!:8080
exit /b 0

:instalar_deps
call :ensure_admin instalar_deps
if errorlevel 1 goto menu
echo.
echo Instalando dependencias faltantes...
call :ensure_dependencies
echo.
call :pausar
goto menu

:ensure_dependencies
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0instalar-dependencias.ps1" -InstallMissing
if errorlevel 1 exit /b 1
exit /b 0

:start_moonlight
if not exist "%MOONLIGHT_PKG%\%WEB_SERVER%" (
    echo   ERRO: Moonlight Web nao encontrado em %MOONLIGHT_PKG%
    exit /b 1
)

tasklist /FI "IMAGENAME eq %WEB_SERVER%" 2>nul | find /I "%WEB_SERVER%" >nul
if %errorlevel% equ 0 (
    echo   Moonlight Web ja estava ligado.
    exit /b 0
)

for /f "delims=" %%i in ('"%TAILSCALE%" ip -4 2^>nul') do set "TS_IP=%%i"
if not defined TS_IP (
    echo   AVISO: Tailscale sem IP. Iniciando Moonlight Web mesmo assim...
    set "TS_IP=127.0.0.1"
)

pushd "%MOONLIGHT_PKG%"
start "Moonlight Web" /MIN cmd /c "%WEB_SERVER% -c server/config.json --bind-address 0.0.0.0:8080 --webrtc-nat-1to1-host !TS_IP! --webrtc-port-range 40000:40010 run"
popd
timeout /t 3 /nobreak >nul

tasklist /FI "IMAGENAME eq %WEB_SERVER%" 2>nul | find /I "%WEB_SERVER%" >nul
if errorlevel 1 (
    echo   ERRO: Moonlight Web nao iniciou. Verifique moonlight-web\package\
    exit /b 1
)

if exist "%TAILSCALE%" (
    start /B "" "%TAILSCALE%" serve --bg 8080 >nul 2>&1
    timeout /t 1 /nobreak >nul
    echo   Tailscale Serve: tentativa em background na tailnet
    echo   Se Serve nao estiver habilitado, use http://!TS_IP!:8080
)

echo   Moonlight Web iniciado.
exit /b 0

:atualizar_jogos
echo.
echo Atualizando jogos e capas da Steam...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-steam-games.ps1"
if errorlevel 1 (
    echo   AVISO: Falha ao atualizar jogos.
    exit /b 1
)
echo   Jogos atualizados.
exit /b 0

:stop_moonlight
taskkill /F /IM web-server.exe >nul 2>&1
taskkill /F /IM streamer.exe >nul 2>&1
if exist "%TAILSCALE%" (
    "%TAILSCALE%" serve reset >nul 2>&1
)
echo   Moonlight Web parado.
exit /b 0

:start_sunshine
net start "%SUNSHINE%" >nul 2>&1
if %errorlevel% equ 0 (
    echo   Sunshine iniciado.
) else (
    sc query "%SUNSHINE%" | findstr /C:"RUNNING" >nul
    if !errorlevel! equ 0 (
        echo   Sunshine ja estava ligado.
    ) else (
        echo   ERRO ao iniciar Sunshine.
    )
)
exit /b 0

:stop_sunshine
echo   Parando Sunshine...
net stop "%SUNSHINE%" >nul 2>&1
if %errorlevel% equ 0 (
    echo   Sunshine parado.
    exit /b 0
)
sc query "%SUNSHINE%" | findstr /C:"STOPPED" >nul
if !errorlevel! equ 0 (
    echo   Sunshine ja estava desligado.
    exit /b 0
)
echo   ERRO ao parar Sunshine ^(precisa de Administrador^).
net stop "%SUNSHINE%" >nul 2>&1
exit /b 1

:stop_tailscale
echo   Desconectando VPN Tailscale...
if exist "%TAILSCALE%" (
    "%TAILSCALE%" down >nul 2>&1
)
echo   Parando servico Tailscale...
net stop "%TAILSCALE_SVC%" >nul 2>&1
if %errorlevel% equ 0 (
    echo   Tailscale parado.
    exit /b 0
)
sc query "%TAILSCALE_SVC%" | findstr /C:"STOPPED" >nul
if !errorlevel! equ 0 (
    echo   Tailscale ja estava desligado.
    exit /b 0
)
echo   ERRO ao parar Tailscale ^(precisa de Administrador^).
net stop "%TAILSCALE_SVC%" >nul 2>&1
exit /b 1

:start_tailscale
net start "%TAILSCALE_SVC%" >nul 2>&1
timeout /t 2 /nobreak >nul
if exist "%TAILSCALE%" (
    "%TAILSCALE%" up >nul 2>&1
)
sc query "%TAILSCALE_SVC%" | findstr /C:"RUNNING" >nul
if %errorlevel% equ 0 (
    echo   Tailscale iniciado.
) else (
    echo   ERRO ao iniciar Tailscale.
)
exit /b 0

:pausar
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Write-HeadlessSteamPause.ps1"
exit /b 0
