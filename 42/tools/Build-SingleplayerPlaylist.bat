@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-SingleplayerPlaylist.ps1"
if errorlevel 1 (
    echo.
    echo No se pudo generar la playlist. Revisa el error anterior.
    pause
    exit /b 1
)
echo.
pause
