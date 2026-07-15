@echo off
REM Double-click launcher for WSLC Rookery (PowerShell 7 / pwsh).
REM /B avoids creating a second console. The script immediately calls FreeConsole
REM via -NoConsole, allowing this briefly-created launcher window to close while
REM the WPF application continues running.
start "" /B pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0WslcRookery.ps1" -NoConsole
