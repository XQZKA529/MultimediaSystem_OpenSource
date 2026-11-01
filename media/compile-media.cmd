@echo off
setlocal
cd /d "%~dp0"
pwsh -NoProfile -File "%~dp0build\run.ps1" -Stage all -RunTag release
if errorlevel 1 (
    echo.
    echo Build failed. Check Runs\syn_release\console.txt and Runs\phy_release\console.txt.
    pause
    exit /b 1
)
echo.
echo Qualified bit: Runs\phy_release\MultimediaSystem_media.bit
pause
