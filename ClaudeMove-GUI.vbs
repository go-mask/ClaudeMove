' ClaudeMove GUI silent launcher (no console window)
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
sh.Run "pwsh -NoProfile -ExecutionPolicy Bypass -File """ & dir & "claudemove-gui.ps1""", 0, False
