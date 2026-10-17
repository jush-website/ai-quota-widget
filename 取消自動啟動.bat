@echo off
cd /d "%~dp0"
title Remove AI Usage Dashboard Startup
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-startup.ps1" -Remove
echo.
echo Automatic startup has been removed.
pause
