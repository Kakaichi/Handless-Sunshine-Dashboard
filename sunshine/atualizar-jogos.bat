@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions
cd /d "%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo.
    echo  Precisa de permissao de Administrador.
    echo  Clique em Sim na janela que abrir...
    echo.
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo ========================================
echo  Sunshine - Jogos e Capas da Steam
echo ========================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-steam-games.ps1"
if errorlevel 1 (
    echo.
    echo  ERRO ao atualizar.
    echo.
    echo Pressione qualquer tecla para continuar...
    pause >nul
    exit /b 1
)

echo.
echo Pressione qualquer tecla para continuar...
pause >nul
