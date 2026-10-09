@echo off
rem Starts PGS Kiosk Manager. It asks for administrator rights if needed.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0PGS-Kiosk-Manager.ps1"
if errorlevel 1 pause
