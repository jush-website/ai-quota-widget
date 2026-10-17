Option Explicit
Dim shell, fileSystem, projectPath, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
projectPath = fileSystem.GetParentFolderName(WScript.ScriptFullName)
command = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File """ & projectPath & "\start.ps1"" -Background -App"
shell.Run command, 0, False
