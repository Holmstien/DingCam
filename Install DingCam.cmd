@echo off
rem Double-click to install or update the DingCam helper (no admin rights needed).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0helper\Install-DingCam.ps1"
pause
