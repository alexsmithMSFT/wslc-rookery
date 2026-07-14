@echo off
REM Double-click launcher for WSLC Rookery (PowerShell 7 / pwsh).
REM Starts the GUI hidden. -WindowStyle Hidden asks pwsh to hide its window, and
REM the script itself hides its console (SW_HIDE) via -Hidden, so no empty pwsh
REM console lingers while the app runs. A brief flash on startup is possible.
start "" pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0WslcRookery.ps1" -Hidden
