# Builds installer\out\ai-quota-widget-v<version>-windows.msi with WiX v5.
# Needs: dotnet tool install --global wix --version 5.0.2
#        wix extension add --global WixToolset.Util.wixext/5.0.2
#        runtime\node.exe (the bundled Node.js; not in git, see .gitignore)
param([string]$Version)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot
if (-not $Version) { $Version = (Get-Content -LiteralPath (Join-Path $Root 'VERSION.txt') -Raw).Trim() }
if (-not (Test-Path -LiteralPath (Join-Path $Root 'runtime\node.exe'))) { throw 'runtime\node.exe is missing: copy the bundled Node.js there first.' }

$Out = Join-Path $PSScriptRoot 'out'
$Stage = Join-Path $Out 'stage'
# Remove-Item -Force: OneDrive marks synced folders read-only, which [IO.Directory]::Delete refuses
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
New-Item -ItemType Directory -Path $Stage | Out-Null

# Same exclusions as the portable zip: per-machine state, dev folders, the installer itself, tests.
$Skip = 'logs', '.claude-flow', '.deep-research', 'node_modules', '.git', '.gitignore', 'installer', 'test',
  '.usage.pid', '.env', '.widget-style', '.widget-pinned', '.widget-top', '.widget-left', '.widget-edge'
Get-ChildItem -LiteralPath $Root -Force | Where-Object { $Skip -notcontains $_.Name } |
  ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Stage $_.Name) -Recurse -Force }
$Logo = Join-Path $Stage 'public\codex.png'   # unused third-party logo, never ship it
if (Test-Path -LiteralPath $Logo) { [IO.File]::Delete($Logo) }

$Msi = Join-Path $Out "ai-quota-widget-v$Version-windows.msi"
# WiX v5 build does not run ICE validation. If you run `wix msi validate`, expect ICE38/ICE64:
# they want HKCU key paths on every per-user component, which <Files> harvesting does not generate.
# Run from installer\: the out\stage\... paths in Product.wxs are resolved against the working directory.
Push-Location -LiteralPath $PSScriptRoot
try { wix build Product.wxs -arch x64 -ext WixToolset.Util.wixext -d "Version=$Version" -o $Msi }
finally { Pop-Location }
if ($LASTEXITCODE) { throw "wix build failed ($LASTEXITCODE)" }
Get-Item -LiteralPath $Msi
