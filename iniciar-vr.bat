@echo off
chcp 65001 >nul
title Es perfecto porque es imperfecto - Servidor WebXR
cd /d "%~dp0"

node --version >nul 2>nul
if errorlevel 1 (
  echo [Error] No se encontro Node.js en el sistema ^(PATH^).
  echo Instala Node.js e intentalo de nuevo.
  echo.
  pause
  exit /b 1
)

node "%~dp0server.js" --open
echo.
pause
