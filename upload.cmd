@echo off
chcp 65001 >nul
title Git Assistant
setlocal
set "ARGS="
:loop
if "%~1"=="" goto run
set "ARGS=%ARGS% "%~1""
shift
goto loop
:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0upload.ps1" %ARGS%
endlocal
echo.
pause
