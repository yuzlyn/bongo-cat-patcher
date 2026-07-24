@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-BongoCatPatcher.ps1" -Action Restore
exit /b %errorlevel%
