@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0incident-1-start.ps1" %*
exit /b %ERRORLEVEL%
