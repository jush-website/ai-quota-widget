param(
  [switch]$Ensure,
  [switch]$Remove,
  [int]$Port = 3456
)

$ErrorActionPreference = 'Stop'
$RuleName = 'AI Usage Dashboard'

function Test-Administrator {
  $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
  return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Elevated {
  param([string]$Action)
  $Arguments = @(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', ('"' + $PSCommandPath + '"'), $Action, '-Port', $Port
  )
  $Process = Start-Process -FilePath 'powershell.exe' -ArgumentList $Arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
  exit $Process.ExitCode
}

if ($Ensure) {
  $Existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue |
    Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' } |
    Select-Object -First 1
  $ExistingPort = if ($Existing) { $Existing | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue }
  if ($Existing -and $ExistingPort.Protocol -eq 'TCP' -and $ExistingPort.LocalPort -contains [string]$Port) {
    Write-Host 'Phone firewall access is already enabled.'
    exit 0
  }
  if (-not (Test-Administrator)) { Invoke-Elevated '-Ensure' }

  Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  New-NetFirewallRule `
    -DisplayName $RuleName `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalPort $Port `
    -RemoteAddress LocalSubnet `
    -Profile Any | Out-Null
  Write-Host "Phone firewall access enabled on TCP $Port for LocalSubnet."
  exit 0
}

if ($Remove) {
  if (-not (Test-Administrator)) { Invoke-Elevated '-Remove' }
  Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  Write-Host 'Phone firewall access removed.'
  exit 0
}

Write-Host 'Specify -Ensure or -Remove.'
exit 1
