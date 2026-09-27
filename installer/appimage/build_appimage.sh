#!/usr/bin/env bash
# Build the EasyPass Linux AppImage from the Flutter release bundle.
# Usage: build_appimage.sh <bundle_dir> <output_appimage>
#   bundle_dir      : path to build/linux/x64/release/bundle (or equivalent)
#   output_appimage : path to the produced .AppImage (e.g. dist/EasyPass-2.3.x-linux-x86_64.AppImage)
#
# Layout of the produced AppImage (matches the existing EasyPass-2.3.2 build):
#   AppRun                    -> exec usr/bin/easypass
#   easypass.desktop          -> desktop entry (Exec=easypass, Icon=easypass)
#   easypass.png              -> window/tray icon (same PNG as the bundled asset)
#   usr/bin/easypass          -> runner binary
#   usr/bin/{assets,data,lib} -> flutter bundle
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <bundle_dir> <output_appimage>" >&2
  exit 2
fi

BUNDLE="$1"
OUTPUT="$1" 2>/dev/null  # placeholder to make set -u happy; we override below
BUNDLE="$1"
OUTPUT="$2"

# Resolve to absolute paths so the AppRun readlink matches the squashfs root.
BUNDLE="$(readlink -f "$BUNDLE")"
OUTPUT="$(readlink -f "$OUTPUT")"

HERE="$(dirname "$(readlink -f "$0")")"
APPIMAGETOOL="${APPIMAGETOOL:-$HOME/tools/appimagetool.AppImage}"

# Pull the version out of pubspec.yaml — the source of truth for every other
# version display in the project.
VERSION="$(awk -F': ' '/^version:[[:space:]]*/ {print $2; exit}' "$HERE/../../pubspec.yaml")"

WORK="$(mktemp -d -t easypass-appimage.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

APPDIR="$WORK/AppDir"
mkdir -p "$APPDIR/usr/bin"

# Copy the Flutter bundle verbatim.
cp -r "$BUNDLE/." "$APPDIR/usr/bin/"

# Desktop entry + AppRun + icon.
cat > "$APPDIR/easypass.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=EasyPass
Comment=Secure password manager
Exec=easypass %U
Icon=easypass
Categories=Utility;Security;
Terminal=false
StartupWMClass=com.example.easypass
X-AppImage-Version=$VERSION
DESKTOP

cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/bash
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/easypass" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

# Reuse the same PNG the runner resolves for the tray icon, so the .desktop
# preview in file managers matches what users see in the system tray.
if [[ -f "$BUNDLE/assets/icons/Easypass.png" ]]; then
  cp "$BUNDLE/assets/icons/Easypass.png" "$APPDIR/easypass.png"
fi

mkdir -p "$(dirname "$OUTPUT")"

# Build the AppImage. ARCH=x86_64 is the only supported target on this host;
# appimagetool picks squashfs compression automatically.
ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$OUTPUT"
chmod +x "$OUTPUT"

echo "built $OUTPUT ($(stat -c%s "$OUTPUT") bytes)"
echo "sha256: $(sha256sum "$OUTPUT" | awk '{print $1}')"