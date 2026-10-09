@echo off
cd /d "%~dp0"
net session >nul 2>&1
if errorlevel 1 (
 echo Please right-click this file and select Run as administrator.
 pause
 exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0PGS-Kiosk-Manager.ps1"
pause
