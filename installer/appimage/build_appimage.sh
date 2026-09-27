#!/usr/bin/env bash
# Build the EasyPass Linux AppImage from the Flutter release bundle.
# Usage: build_appimage.sh <bundle_dir> <output_appimage>
#   bundle_dir      : path to build/linux/x64/release/bundle (or equivalent)
#   output_appimage : path to the produced .AppImage
#                     (e.g. release/EasyPass-2.3.3-linux-x86_64.AppImage)
#
# Run `flutter build linux --release` first; this script only packages.
#
# Layout of the produced AppImage:
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
OUTPUT="$2"

if [[ ! -d "$BUNDLE" ]]; then
  echo "$0: bundle dir does not exist: $BUNDLE" >&2
  echo "  (run 'flutter build linux --release' first)" >&2
  exit 2
fi

# The output file does not exist yet, so resolve its directory and keep the file
# name as given. `readlink -f "$OUTPUT"` would return an empty string for a path
# whose parent is missing, which used to send the .AppImage to a bogus location.
OUT_DIR="$(dirname "$OUTPUT")"
mkdir -p "$OUT_DIR"
OUT_DIR="$(readlink -f "$OUT_DIR")"
OUTPUT="$OUT_DIR/$(basename "$OUTPUT")"

# Resolve the bundle too: AppRun and the squashfs root must agree on absolute paths.
BUNDLE="$(readlink -f "$BUNDLE")"

HERE="$(dirname "$(readlink -f "$0")")"
APPIMAGETOOL="${APPIMAGETOOL:-$HOME/tools/appimagetool.AppImage}"

if [[ ! -x "$APPIMAGETOOL" ]]; then
  echo "$0: appimagetool not found or not executable: $APPIMAGETOOL" >&2
  echo "  download it, or point \$APPIMAGETOOL at it" >&2
  exit 2
fi

# Pull the version out of pubspec.yaml — the source of truth for every other
# version display in the project. `version: 2.3.3+13` -> 2.3.3 (+ build number).
PUBSPEC_VERSION="$(awk -F': ' '/^version:[[:space:]]*/ {print $2; exit}' "$HERE/../../pubspec.yaml")"
if [[ -z "${PUBSPEC_VERSION:-}" ]]; then
  echo "$0: cannot read 'version:' from pubspec.yaml" >&2
  exit 1
fi
VERSION="${PUBSPEC_VERSION%%+*}"

WORK="$(mktemp -d -t easypass-appimage.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

APPDIR="$WORK/AppDir"
mkdir -p "$APPDIR/usr/bin"

# Copy the Flutter bundle verbatim.
cp -r "$BUNDLE/." "$APPDIR/usr/bin/"

# Desktop entry + AppRun + icon.
# StartupWMClass must match the runner's application id (linux/CMakeLists.txt
# APPLICATION_ID, which GDK turns into the window class) — see
# lib/features/desktop_integration/linux_desktop_integration.dart.
cat > "$APPDIR/easypass.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=EasyPass
Comment=Secure password manager
Exec=easypass %U
Icon=easypass
Categories=Utility;Security;
Terminal=false
StartupWMClass=com.easypass.app
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
else
  echo "$0: warning: $BUNDLE/assets/icons/Easypass.png not found - the AppImage" >&2
  echo "  will ship without an icon file" >&2
fi

# Build the AppImage. ARCH=x86_64 is the only supported target on this host;
# appimagetool picks squashfs compression automatically.
ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$OUTPUT"
chmod +x "$OUTPUT"

echo "built $OUTPUT ($(stat -c%s "$OUTPUT") bytes)"
echo "version: $PUBSPEC_VERSION (AppImage X-AppImage-Version=$VERSION)"
echo "sha256: $(sha256sum "$OUTPUT" | awk '{print $1}')"
