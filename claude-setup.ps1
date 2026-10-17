param(
  [switch]$Check,
  [switch]$Prompt
)

$ErrorActionPreference = 'Stop'

function Find-ClaudeCode {
  if ($env:CLAUDE_CLI_PATH -and (Test-Path -LiteralPath $env:CLAUDE_CLI_PATH)) {
    return (Resolve-Path -LiteralPath $env:CLAUDE_CLI_PATH).Path
  }

  $Command = Get-Command claude -ErrorAction SilentlyContinue
  if ($Command) { return $Command.Source }

  $Candidates = @(
    (Join-Path $HOME '.local\bin\claude.exe'),
    (Join-Path $env:APPDATA 'npm\claude.cmd')
  )
  if ($env:LOCALAPPDATA) {
    $Candidates += Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Packages\Claude_*\LocalCache\Roaming\Claude\claude-code\*\claude.exe') -File -ErrorAction SilentlyContinue |
      Sort-Object { [version]($_.Directory.Name -replace '[^0-9.]', '') } -Descending |
      Select-Object -ExpandProperty FullName
  }
  return $Candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

function Test-ClaudeLogin([string]$ClaudePath) {
  try {
    $Status = (& $ClaudePath auth status --json 2>$null) | Out-String | ConvertFrom-Json
    return [bool]$Status.loggedIn
  } catch { return $false }
}

$ClaudePath = Find-ClaudeCode
if (-not $ClaudePath) {
  if (-not $Check) {
    Write-Host ''
    Write-Host '找不到 Claude Code。' -ForegroundColor Yellow
    Write-Host '若已安裝 Claude 桌面版，請先更新至含 Claude Code 的版本。'
    Write-Host '官方安裝說明：https://docs.anthropic.com/en/docs/claude-code/getting-started'
  }
  exit 3
}

if (Test-ClaudeLogin $ClaudePath) {
  if (-not $Check -and -not $Prompt) { Write-Host 'Claude Code 已連結，可以顯示使用量。' -ForegroundColor Green }
  exit 0
}

if ($Check) { exit 2 }

if ($Prompt) {
  Write-Host ''
  Write-Host '偵測到 Claude，但 Claude Code 尚未連結帳號。' -ForegroundColor Yellow
  $Answer = Read-Host '現在開啟 Claude 官方登入嗎？輸入 Y 繼續，直接按 Enter 略過'
  if ($Answer -notmatch '^(y|yes)$') { exit 2 }
}

Write-Host ''
Write-Host '即將開啟瀏覽器，請登入使用者自己的 Claude Pro／Max 帳號。' -ForegroundColor Cyan
Write-Host '儀表板不會儲存密碼，只會讀取 Claude Code 官方建立的本機 OAuth 憑證。'
& $ClaudePath auth login

if ($LASTEXITCODE -eq 0 -and (Test-ClaudeLogin $ClaudePath)) {
  Write-Host ''
  Write-Host 'Claude Code 連結完成。重新整理儀表板後即可看到使用量。' -ForegroundColor Green
  exit 0
}

Write-Host ''
Write-Host '登入尚未完成；稍後可重新執行「啟動儀表板.bat」。' -ForegroundColor Yellow
exit 2
