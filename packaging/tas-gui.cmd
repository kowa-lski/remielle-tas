@echo off
rem Opens the remielle-tas launcher (tas-gui.ps1 in this folder).
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0tas-gui.ps1"
