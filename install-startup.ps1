param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'AI Usage Dashboard.lnk'

if ($Remove) {
  Remove-Item -LiteralPath $ShortcutPath -Force -ErrorAction SilentlyContinue
  Write-Host 'Windows startup entry removed.'
  exit 0
}

$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
$Shortcut.Arguments = '"' + (Join-Path $PSScriptRoot 'startup.vbs') + '"'
$Shortcut.WorkingDirectory = $PSScriptRoot
$Shortcut.WindowStyle = 7
$Shortcut.Description = 'Start AI Usage Dashboard in the background after Windows sign-in'
$Shortcut.Save()

Write-Host "Windows startup entry installed: $ShortcutPath"

# Desktop shortcut: same hidden launcher, opens the bottom-right widget.
$Desktop = $WshShell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'AI Usage Widget.lnk'))
$Desktop.TargetPath = $Shortcut.TargetPath
$Desktop.Arguments = $Shortcut.Arguments
$Desktop.WorkingDirectory = $PSScriptRoot
$Desktop.IconLocation = Join-Path $PSScriptRoot 'app.ico'
$Desktop.Description = 'AI usage and system performance widget'
$Desktop.Save()
