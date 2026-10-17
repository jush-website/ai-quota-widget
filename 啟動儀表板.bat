@echo off
cd /d "%~dp0"
title AI Usage Dashboard

rem Files extracted from a downloaded zip carry Mark-of-the-Web; clear it so Windows does not block the scripts.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -File | Unblock-File" >nul 2>&1

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-setup.ps1" -Prompt

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-startup.ps1" >nul 2>&1

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" -Background -App -Launcher
if errorlevel 1 (
  echo.
  echo Startup failed. Press any key to close.
  pause >nul
  exit /b 1
)

exit /b 0
