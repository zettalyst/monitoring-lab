@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fault-clear.ps1" %*
exit /b %ERRORLEVEL%
