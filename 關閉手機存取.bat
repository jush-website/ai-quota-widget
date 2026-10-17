@echo off
cd /d "%~dp0"
title Remove Phone Access - AI Usage Dashboard

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0firewall.ps1" -Remove -Port 3456
echo.
echo Firewall access rule removed.
pause
