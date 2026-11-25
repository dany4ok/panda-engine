Option Explicit
Dim shell, fso, guiPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
guiPath = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "gui.ps1")
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & Chr(34) & guiPath & Chr(34)
shell.Run command, 0, False
