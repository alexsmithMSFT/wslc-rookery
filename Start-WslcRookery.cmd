@echo off
REM Double-click launcher for WSLC Rookery (PowerShell 7 / pwsh).
REM conhost --headless supplies pwsh with a console without creating a visible
REM terminal window. START returns immediately so this launcher can close.
start "" conhost.exe --headless pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0WslcRookery.ps1"
