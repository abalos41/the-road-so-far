@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-SoundDurations.ps1"
if errorlevel 1 (
    echo.
    echo Duration update failed. Check the error message above.
    pause
    exit /b 1
)
echo.
pause
