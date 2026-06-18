@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0baseline-traffic.ps1" %*
exit /b %ERRORLEVEL%
