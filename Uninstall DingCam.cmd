@echo off
rem Double-click to remove the DingCam helper. Your Journey folder (clips and pictures) is kept.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0helper\Uninstall-DingCam.ps1"
pause
