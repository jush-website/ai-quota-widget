param(
  [int]$Port = 3456,
  [switch]$Background,
  [switch]$Launcher,
  [switch]$App,
  [switch]$Stop
)

$ErrorActionPreference = 'Stop'
$PidFile = Join-Path $PSScriptRoot '.usage.pid'
$LogDirectory = Join-Path $PSScriptRoot 'logs'

function Get-UsageProcess {
  if (-not (Test-Path -LiteralPath $PidFile)) { return $null }
  $SavedPid = (Get-Content -LiteralPath $PidFile -Raw).Trim()
  if ($SavedPid -notmatch '^\d+$') { return $null }
  $Process = Get-Process -Id ([int]$SavedPid) -ErrorAction SilentlyContinue
  if (-not $Process -or $Process.ProcessName -ne 'node') { return $null }
  $ProcessInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $SavedPid" -ErrorAction SilentlyContinue
  if (-not $ProcessInfo -or $ProcessInfo.CommandLine -notlike '*src/server.js*') { return $null }
  return $Process
}

function Get-ListeningProcessId([int]$LocalPort) {
  try {
    return Get-NetTCPConnection -State Listen -LocalPort $LocalPort -ErrorAction Stop |
      Select-Object -First 1 -ExpandProperty OwningProcess
  } catch { return $null }
}

function Test-DashboardProcess([int]$ProcessId) {
  if (-not $ProcessId) { return $false }
  $ProcessInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
  return [bool]($ProcessInfo -and $ProcessInfo.Name -eq 'node.exe' -and $ProcessInfo.CommandLine -like '*src/server.js*')
}

function Find-AvailablePort([int]$StartingPort) {
  for ($Candidate = $StartingPort; $Candidate -le [Math]::Min(65535, $StartingPort + 20); $Candidate += 1) {
    if (-not (Get-ListeningProcessId $Candidate)) { return $Candidate }
  }
  return $null
}

function Get-UsageUrls {
  $Urls = @("http://localhost:$Port")
  Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
    ForEach-Object { $Urls += "http://$($_.IPAddress):$Port" }
  return $Urls | Select-Object -Unique
}

# Bottom-right desktop widget (widget.ps1 keeps a single instance itself).
function Open-AppWindow([int]$AppPort) {
  New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
  Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $LogDirectory 'widget.log') `
    -RedirectStandardError (Join-Path $LogDirectory 'widget-error.log') -ArgumentList @(
    '-NoLogo', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
    '-File', ('"' + (Join-Path $PSScriptRoot 'widget.ps1') + '"'), '-Port', $AppPort)
}

function Show-LauncherDialog {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $Form = New-Object System.Windows.Forms.Form
    $Form.Text = 'AI Usage Dashboard'
    $Form.StartPosition = 'CenterScreen'
    $Form.FormBorderStyle = 'FixedDialog'
    $Form.MaximizeBox = $false
    $Form.MinimizeBox = $false
    $Form.ClientSize = New-Object System.Drawing.Size(480, 190)

    $Title = New-Object System.Windows.Forms.Label
    $Title.Text = 'Dashboard is running in the background'
    $Title.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $Title.AutoSize = $true
    $Title.Location = New-Object System.Drawing.Point(22, 20)
    $Form.Controls.Add($Title)

    $Hint = New-Object System.Windows.Forms.Label
    $Hint.Text = 'Click an address to open it. This launcher will then close.'
    $Hint.AutoSize = $true
    $Hint.ForeColor = [System.Drawing.Color]::DimGray
    $Hint.Location = New-Object System.Drawing.Point(24, 53)
    $Form.Controls.Add($Hint)

    $Top = 82
    foreach ($Url in Get-UsageUrls) {
      $Link = New-Object System.Windows.Forms.LinkLabel
      $Link.Text = $Url
      $Link.Font = New-Object System.Drawing.Font('Segoe UI', 11)
      $Link.AutoSize = $true
      $Link.Location = New-Object System.Drawing.Point(24, $Top)
      [void]$Link.Links.Add(0, $Url.Length, $Url)
      $Link.Add_LinkClicked({
        param($Sender, $EventArgs)
        Start-Process $EventArgs.Link.LinkData
        $Form.Close()
      })
      $Form.Controls.Add($Link)
      $Top += 30
    }
    $Form.ClientSize = New-Object System.Drawing.Size(480, ([Math]::Max(150, $Top + 18)))
    [void]$Form.ShowDialog()
  } catch {
    Write-Host 'Open one of the URLs above, then press Enter to close this launcher.'
    [void](Read-Host)
  }
}

if ($Stop) {
  $RunningProcess = Get-UsageProcess
  if ($RunningProcess) {
    Stop-Process -Id $RunningProcess.Id
    Write-Host "AI usage dashboard stopped (PID $($RunningProcess.Id))."
  } else {
    Write-Host 'AI usage dashboard is not running.'
  }
  Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
  exit 0
}

$BundledNode = Join-Path $PSScriptRoot 'runtime\node.exe'
if (Test-Path -LiteralPath $BundledNode) {
  $NodePath = $BundledNode
} else {
  $Node = Get-Command node -ErrorAction SilentlyContinue
  $NodePath = if ($Node) { $Node.Source } else { $null }
}
if (-not $NodePath) {
  Write-Host 'Node.js was not found. Please install Node.js 20 or newer.' -ForegroundColor Red
  exit 1
}

$RunningProcess = Get-UsageProcess
if ($RunningProcess) {
  Write-Host "AI usage dashboard is already running (PID $($RunningProcess.Id))."
  $RunningPort = Get-NetTCPConnection -State Listen -OwningProcess $RunningProcess.Id -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty LocalPort
  if ($RunningPort) { $Port = $RunningPort }
  Get-UsageUrls | ForEach-Object { Write-Host "URL: $_" }
  if ($App) { Open-AppWindow $Port }
  if ($Launcher) { Show-LauncherDialog }
  exit 0
}
Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue

$PortOwner = Get-ListeningProcessId $Port
if ($PortOwner) {
  if (Test-DashboardProcess $PortOwner) {
    Write-Host "Another AI usage dashboard is already running on port $Port (PID $PortOwner)."
    Get-UsageUrls | ForEach-Object { Write-Host "URL: $_" }
    if ($App) { Open-AppWindow $Port }
    if ($Launcher) { Show-LauncherDialog }
    exit 0
  }

  $RequestedPort = $Port
  $Port = Find-AvailablePort ($Port + 1)
  if (-not $Port) {
    Write-Host "Ports $RequestedPort through $([Math]::Min(65535, $RequestedPort + 20)) are unavailable." -ForegroundColor Red
    exit 1
  }
  Write-Host "Port $RequestedPort is in use by another program. Using port $Port instead." -ForegroundColor Yellow
}

# Phone (LAN) access only. Querying firewall rules takes several seconds, so it runs after the
# server and widget are already up instead of delaying them.
function Ensure-PhoneFirewall {
  $FirewallScript = Join-Path $PSScriptRoot 'firewall.ps1'
  if (Test-Path -LiteralPath $FirewallScript) {
    try { & $FirewallScript -Ensure -Port $Port } catch { Write-Host 'Phone firewall permission was not enabled. Dashboard startup will continue.' -ForegroundColor Yellow }
  }
}

$env:PORT = $Port
Set-Location -LiteralPath $PSScriptRoot

if ($Background) {
  New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
  $OutLog = Join-Path $LogDirectory 'server.log'
  $ErrorLog = Join-Path $LogDirectory 'server-error.log'
  $Process = Start-Process `
    -FilePath $NodePath `
    -ArgumentList 'src/server.js' `
    -WorkingDirectory $PSScriptRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $OutLog `
    -RedirectStandardError $ErrorLog `
    -PassThru
  Set-Content -LiteralPath $PidFile -Value $Process.Id -Encoding ascii
  Start-Sleep -Milliseconds 800
  if ($Process.HasExited) {
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Write-Host 'Startup failed. Check logs\server-error.log.' -ForegroundColor Red
    exit 1
  }
  Write-Host "AI usage dashboard started in background (PID $($Process.Id))."
  Write-Host "Local URL: http://localhost:$Port"
  Get-UsageUrls | Where-Object { $_ -notlike 'http://localhost:*' } | ForEach-Object { Write-Host "LAN URL: $_" }
  Write-Host 'Use the stop dashboard launcher to stop the service.'
  if ($App) { Open-AppWindow $Port }
  Ensure-PhoneFirewall
  if ($Launcher) { Show-LauncherDialog }
  exit 0
}

Ensure-PhoneFirewall
node src/server.js
