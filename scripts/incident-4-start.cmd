@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0incident-4-start.ps1" %*
exit /b %ERRORLEVEL%
