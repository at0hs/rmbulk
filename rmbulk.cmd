@echo off
setlocal
rem Clear PSModulePath: when launched from PowerShell 7, its module paths are inherited and 5.1 fails to load built-in modules.
set "PSModulePath="
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rmbulk.ps1" %*
exit /b %ERRORLEVEL%
