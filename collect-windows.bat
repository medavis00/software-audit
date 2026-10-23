@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0collect-windows.ps1" %*
pause
