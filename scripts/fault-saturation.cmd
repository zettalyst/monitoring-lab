@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fault-saturation.ps1" %*
exit /b %ERRORLEVEL%
