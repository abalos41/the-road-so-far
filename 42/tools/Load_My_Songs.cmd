@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-SingleplayerPlaylist.ps1"
if errorlevel 1 (
    echo.
    echo Playlist generation failed. Check the error message above.
    pause
    exit /b 1
)
echo.
pause
