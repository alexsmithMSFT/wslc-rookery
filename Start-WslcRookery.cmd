@echo off
REM Double-click launcher for WSLC Rookery (PowerShell 7 / pwsh).
REM Starts the GUI without a console window.
REM pwsh -WindowStyle Hidden still allocates a console host that lingers empty
REM for the app's lifetime, so launch via wscript (SW_HIDE) which never shows one.
start "" wscript "%~dp0Start-WslcRookery.vbs"
