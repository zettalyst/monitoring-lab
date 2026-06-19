@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify-live-mitigation.ps1" %*
exit /b %ERRORLEVEL%
