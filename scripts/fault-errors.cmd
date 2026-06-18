@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fault-errors.ps1" %*
exit /b %ERRORLEVEL%
