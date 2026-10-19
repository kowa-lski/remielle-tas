@echo off
rem Builds remielle-tas and copies it into a game folder:
rem   install.cmd "D:\Games\ZZZ"     (the folder with ZenlessZoneZeroBeta.exe and remielle.exe)
rem tas.txt is copied only if the game folder has none, so existing settings are kept.
setlocal
cd /d "%~dp0"
if "%~1"=="" (
  echo usage: install.cmd "game folder"
  exit /b 1
)
if not exist "%~1\ZenlessZoneZeroBeta.exe" (
  echo "%~1" has no ZenlessZoneZeroBeta.exe
  exit /b 1
)
zig build -Doptimize=ReleaseFast || exit /b 1
copy /y "zig-out\bin\remielle-tas.dll" "%~1\" >nul || exit /b 1
copy /y "zig-out\bin\tas-inject.exe" "%~1\" >nul || exit /b 1
copy /y "zig-out\bin\tas-gui.exe" "%~1\" >nul || exit /b 1
if not exist "%~1\tas.txt" copy "packaging\tas.txt" "%~1\" >nul
echo Installed into %~1. Start the game with remielle.exe, then open tas-gui.exe (or run tas-inject.exe).
