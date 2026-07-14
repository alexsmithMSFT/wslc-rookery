' Launches WSLC Rookery (WslcRookery.ps1) with no console window at all.
' wscript + WshShell.Run(..., 0, False) uses SW_HIDE, so pwsh's console host
' is never shown for the lifetime of the WPF app (unlike -WindowStyle Hidden,
' which allocates a console first and can leave an empty window lingering).
Dim shell, here, cmd
Set shell = CreateObject("WScript.Shell")
here = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
cmd = "pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "WslcRookery.ps1"""
shell.Run cmd, 0, False
