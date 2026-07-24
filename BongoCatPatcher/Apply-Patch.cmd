@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Patch-BongoCat.ps1"
set "patch_exit=%errorlevel%"
echo.
if not "%patch_exit%"=="0" echo Patch failed with exit code %patch_exit%.
pause
exit /b %patch_exit%
