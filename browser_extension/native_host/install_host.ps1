# EasyPass Native Messaging Host - Installer (Chrome / Edge, Windows)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File install_host.ps1
#   powershell -ExecutionPolicy Bypass -File install_host.ps1 -ExePath "C:\path\to\easypass.exe"
#
# Registers the host for the current user only (HKCU) - no admin needed.
# It generates a manifest JSON with an absolute path to easypass.exe and
# points the browser's NativeMessagingHosts registry key at it.
#
# The host runs as `easypass.exe --native-host` (see lib/main.dart) and
# reads/writes the same easypass.db next to the executable.

param(
  [string]$ExePath = ""
)

$ErrorActionPreference = "Stop"

function Resolve-EasyPassExe {
  $candidates = @(
    $ExePath,
    (Join-Path $PSScriptRoot "..\..\build\windows\x64\runner\Release\easypass.exe"),
    (Join-Path $PSScriptRoot "..\..\build\windows\runner\Release\easypass.exe")
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
  }
  throw "easypass.exe not found. Build it first (flutter build windows) or pass -ExePath."
}

$exe = Resolve-EasyPassExe
Write-Host "Using host executable: $exe"

# Where the generated manifest lives.
$manifestDir = Join-Path $env:LOCALAPPDATA "EasyPass"
New-Item -ItemType Directory -Force -Path $manifestDir | Out-Null
$manifestPath = Join-Path $manifestDir "com.easypass.app.json"

$manifest = @{
  name        = "com.easypass.app"
  description = "EasyPass Password Manager Native Messaging Host"
  path        = $exe
  args        = @("--native-host")
  type        = "stdio"
  allowed_origins      = @("chrome-extension://*")
  allowed_origins_edge = @("extension://*")
} | ConvertTo-Json -Depth 3

$manifest | Set-Content -Path $manifestPath -Encoding UTF8
Write-Host "Manifest written to: $manifestPath"

# Register for Chrome and Edge (current user).
$hosts = @{
  "Google\Chrome"   = "chrome-extension://*"
  "Microsoft\Edge"  = "extension://*"
}

foreach ($entry in $hosts.GetEnumerator()) {
  $regPath = "HKCU:\Software\$($entry.Key)\NativeMessagingHosts\com.easypass.app"
  New-Item -Path $regPath -Force | Out-Null
  Set-ItemProperty -Path $regPath -Name "(default)" -Value $manifestPath
  Write-Host "Registered: $regPath"
}

Write-Host ""
Write-Host "Done. Restart the browser, then reload the EasyPass extension."
Write-Host "To remove:  powershell -ExecutionPolicy Bypass -File uninstall_host.ps1"
