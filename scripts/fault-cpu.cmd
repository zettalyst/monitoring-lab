@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fault-cpu.ps1" %*
exit /b %ERRORLEVEL%
