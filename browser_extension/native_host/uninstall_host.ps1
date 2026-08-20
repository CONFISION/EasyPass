# EasyPass Native Messaging Host - Uninstaller (Chrome / Edge, Windows)
#
# Removes the HKCU registry entries registered by install_host.ps1.
# Usage:
#   powershell -ExecutionPolicy Bypass -File uninstall_host.ps1

$ErrorActionPreference = "Stop"

$regPaths = @(
  "HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.easypass.app",
  "HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.easypass.app"
)

foreach ($regPath in $regPaths) {
  if (Test-Path $regPath) {
    Remove-Item -Path $regPath -Recurse -Force
    Write-Host "Removed: $regPath"
  }
}

# Remove the generated manifest (keep the folder).
$manifestPath = Join-Path $env:LOCALAPPDATA "EasyPass\com.easypass.app.json"
if (Test-Path $manifestPath) {
  Remove-Item -Path $manifestPath -Force
  Write-Host "Removed manifest: $manifestPath"
}

Write-Host "Uninstall complete."
