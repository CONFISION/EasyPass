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
#
# IMPORTANT: Chrome/Edge do NOT accept wildcards in "allowed_origins" -- the
# manifest must list the concrete extension origin. The ID below is fixed by
# the "key" field in browser_extension/manifest.json (see extension_private_key.pem,
# which is gitignored). After loading the extension, chrome://extensions must
# show this exact ID.

param(
  [string]$ExePath = ""
)

$ErrorActionPreference = "Stop"

# Fixed extension ID, derived from the "key" in browser_extension/manifest.json.
$ExtensionId = "hlkbbdlgaocmnjlgpafkimobnkfniike"

function Resolve-EasyPassExe {
  $candidates = @(
    $ExePath,
    # The per-user install location (where the installer puts the app).
    (Join-Path $env:LOCALAPPDATA "Programs\EasyPass\easypass.exe"),
    # Development build outputs -- only used when no installed copy exists
    # (e.g. running from a source checkout on a machine without the installer).
    (Join-Path $PSScriptRoot "..\..\build\windows\x64\runner\Release\easypass.exe"),
    (Join-Path $PSScriptRoot "..\..\build\windows\runner\Release\easypass.exe")
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
  }
  throw "easypass.exe not found. Install EasyPass, build it first (flutter build windows), or pass -ExePath."
}

$exe = Resolve-EasyPassExe
Write-Host "Using host executable: $exe"

# 2.0: the browser launches the console BRIDGE (easypass_native_host.exe,
# same directory as easypass.exe), which forwards stdio to the background
# daemon (easypass.exe --service). The bridge is x86 so 32-bit browsers
# inherit its stdio handles reliably.
$exeDir = Split-Path $exe -Parent
$bridge = Join-Path $exeDir "easypass_native_host.exe"
if (-not (Test-Path $bridge)) {
  Write-Error "Bridge host not found next to easypass.exe: $bridge"
  Write-Error "Build it first: browser_extension\native_host\build_bridge.bat"
  exit 1
}
Write-Host "Bridge host: $bridge"

# Where the generated manifest lives.
$manifestDir = Join-Path $env:LOCALAPPDATA "EasyPass"
New-Item -ItemType Directory -Force -Path $manifestDir | Out-Null
$manifestPath = Join-Path $manifestDir "com.easypass.app.json"

$manifest = @{
  name        = "com.easypass.app"
  description = "EasyPass Password Manager Native Messaging Host"
  path        = $bridge
  type        = "stdio"
  # Concrete extension origins only. Chromium's manifest parser (Chrome and
  # Edge) accepts ONLY the "chrome-extension://<id>/" form -- any other scheme
  # (e.g. "extension://" or "extensions://") fails the whole manifest and the
  # browser reports "Specified native messaging host not found". Edge's
  # DevTools may DISPLAY the origin as "extensions://<id>/", but the real
  # origin scheme is chrome-extension://.
  allowed_origins = @("chrome-extension://$ExtensionId/")
} | ConvertTo-Json -Depth 3

# Write UTF-8 WITHOUT a BOM: Set-Content -Encoding UTF8 (Windows PowerShell
# 5.1) prefixes the BOM bytes, and Chromium's JSON parser REJECTS a BOM in
# the native messaging manifest ("Specified native messaging host not found").
[System.IO.File]::WriteAllText(
  $manifestPath, $manifest, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Manifest written to: $manifestPath"

# Register for Chrome and Edge (current user).
$hosts = @{
  "Google\Chrome"   = "chrome-extension://*"
  "Microsoft\Edge"  = "extension://*"
}

foreach ($entry in $hosts.GetEnumerator()) {
  # Register BOTH registry views: 64-bit browsers read
  # HKCU\Software\... while 32-bit browsers (e.g. Edge x86, installed under
  # Program Files (x86)) read the redirected HKCU\Software\WOW6432Node\...
  # view. Missing either one yields "Specified native messaging host not found".
  $regPaths = @(
    "HKCU:\Software\$($entry.Key)\NativeMessagingHosts\com.easypass.app",
    "HKCU:\Software\WOW6432Node\$($entry.Key)\NativeMessagingHosts\com.easypass.app"
  )
  foreach ($regPath in $regPaths) {
    New-Item -Path $regPath -Force | Out-Null
    Set-ItemProperty -Path $regPath -Name "(default)" -Value $manifestPath
    Write-Host "Registered: $regPath"
  }
}

Write-Host ""
Write-Host "Done. Restart the browser, then reload the EasyPass extension."
Write-Host "Verify the extension ID shown in chrome://extensions is: $ExtensionId"
Write-Host "To remove:  powershell -ExecutionPolicy Bypass -File uninstall_host.ps1"
