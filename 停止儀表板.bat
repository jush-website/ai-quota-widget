@echo off
cd /d "%~dp0"
title Stop AI Usage Dashboard

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" -Stop
timeout /t 2 /nobreak >nul 2>&1
exit /b 0
