@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fault-latency.ps1" %*
exit /b %ERRORLEVEL%
