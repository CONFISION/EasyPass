#!/usr/bin/env bash
# Build the EasyPass Linux .deb from a release bundle.
#
#   installer/deb/build_deb.sh [bundle-dir] [output.deb]
#
# Defaults:
#   bundle-dir  build/linux/x64/release/bundle   (from `flutter build linux --release`
#                                                 + `tool/build_core.sh`)
#   output      dist/easypass_<version>_<arch>.deb
#
# Why a .deb and not an AppImage: the AppImage has to satisfy FUSE, an ever-moving
# libc/GTK baseline and its own runtime loader, which kept getting in the way of a
# desktop app that ships a GTK runner + a separately built core service. The .deb
# installs into /opt/easypass and uses the distribution's GTK/appindicator/secret
# libraries, so every dependency is declared once and resolved by apt.
#
# Layout installed by the package:
#   /opt/easypass/                     the Flutter bundle, verbatim (incl. core/)
#   /usr/bin/easypass                  symlink → /opt/easypass/easypass
#   /usr/bin/easypass-core             wrapper that exports the bundle's lib dir
#                                      (the AOT core resolves libsqlite3.so by
#                                      name, so it needs LD_LIBRARY_PATH)
#   /usr/bin/easypass-native-host      wrapper for browser native messaging
#   /usr/share/applications/easypass.desktop
#   /usr/share/icons/hicolor/<n>/apps/easypass.png
#   /etc/opt/chrome|chromium/native-messaging-hosts/com.easypass.app.json
#   /usr/lib/mozilla/native-messaging-hosts/com.easypass.app.json
#
# Exit code is non-zero unless the produced .deb can be inspected by dpkg-deb.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
cd "$REPO_ROOT"

BUNDLE_DIR="${1:-build/linux/x64/release/bundle}"
VERSION="$(awk -F': *' '/^version:[[:space:]]*/ {print $2; exit}' pubspec.yaml)"
VERSION="${VERSION%%+*}"
if [[ -z "$VERSION" ]]; then
  echo "build_deb: ERROR: cannot read version from pubspec.yaml" >&2
  exit 1
fi

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) DEB_ARCH="amd64" ;;
  aarch64|arm64) DEB_ARCH="arm64" ;;
  *) DEB_ARCH="$ARCH_RAW" ;;
esac

OUT_DEB="${2:-dist/easypass_${VERSION}_${DEB_ARCH}.deb}"
PKG_NAME="easypass"
APP_DIR="/opt/easypass"

die() { echo "build_deb: ERROR: $*" >&2; exit 1; }

[[ -d "$BUNDLE_DIR" ]] || die "bundle directory not found: $BUNDLE_DIR (run 'flutter build linux --release' first)"
[[ -x "$BUNDLE_DIR/easypass" ]] || die "bundle has no 'easypass' executable: $BUNDLE_DIR"
[[ -x "$BUNDLE_DIR/core/easypass_core" ]] || die "bundle has no 'core/easypass_core' (run 'tool/build_core.sh --out-dir $BUNDLE_DIR' first)"

icon_src=""
for candidate in "$BUNDLE_DIR/assets/icons/Easypass.png" "assets/icons/Easypass.png"; do
  [[ -f "$candidate" ]] && { icon_src="$candidate"; break; }
done
[[ -n "$icon_src" ]] || die "icon not found (looked for assets/icons/Easypass.png in the bundle and the repo)"

# The extension id is the native-messaging allowlist; take it from the single Dart
# source of truth instead of hard-coding it here.
# The extension id is the native-messaging allowlist; read it from the checked-in
# host registration (the same file the Windows installer ships) instead of
# duplicating it in this script.
EXT_ID="$(python3 - <<'PY'
import json
data = json.load(open('browser_extension/native_host/com.easypass.app.json'))
origins = data.get('allowed_origins') or []
first = origins[0] if origins else ''
print(first.replace('chrome-extension://', '').strip('/'))
PY
)"
[[ -n "$EXT_ID" ]] || die "cannot read the extension id from browser_extension/native_host/com.easypass.app.json"

STAGE="$REPO_ROOT/build/deb/${PKG_NAME}_${VERSION}_${DEB_ARCH}"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE$APP_DIR" "$STAGE/usr/bin" \
  "$STAGE/usr/share/applications" "$STAGE/usr/share/icons/hicolor/1024x1024/apps" \
  "$STAGE/etc/opt/chrome/native-messaging-hosts" \
  "$STAGE/etc/opt/chromium/native-messaging-hosts" \
  "$STAGE/usr/lib/mozilla/native-messaging-hosts"

echo "build_deb: staging bundle → $STAGE$APP_DIR"
cp -a "$BUNDLE_DIR/." "$STAGE$APP_DIR/"

# /usr/bin entries.
ln -sf "$APP_DIR/easypass" "$STAGE/usr/bin/easypass"

cat > "$STAGE/usr/bin/easypass-core" <<EOF
#!/bin/sh
# EasyPass core service launcher.
#
# The core is an AOT image built with 'dart build cli'; it loads its native
# libraries by bare name (libsqlite3.so), so the bundle's lib directory has to be
# on the loader search path. The UI sets the same variable when it spawns the
# core itself — this wrapper exists for the CLI ('--status', '--lock', ...).
export LD_LIBRARY_PATH="$APP_DIR/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$APP_DIR/core/easypass_core" "\$@"
EOF
chmod 755 "$STAGE/usr/bin/easypass-core"

cat > "$STAGE/usr/bin/easypass-native-host" <<EOF
#!/bin/sh
# Native-messaging host for the browser extension (stdio ↔ core --bridge).
export LD_LIBRARY_PATH="$APP_DIR/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$APP_DIR/core/easypass_core" --bridge
EOF
chmod 755 "$STAGE/usr/bin/easypass-native-host"

# Desktop entry: mirrors lib/features/desktop_integration/linux_desktop_integration.dart
# (same Name / Icon / StartupWMClass), but Exec points at the system install.
cat > "$STAGE/usr/share/applications/easypass.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=EasyPass
GenericName=Password Manager
Comment=Local-first password manager
Exec=$APP_DIR/easypass %U
Icon=easypass
Terminal=false
Categories=Utility;Security;
Keywords=password;vault;security;totp;
StartupWMClass=com.easypass.app
EOF

cp "$icon_src" "$STAGE/usr/share/icons/hicolor/1024x1024/apps/easypass.png"
# Extra icon sizes are best-effort: only when ImageMagick is around.
if command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1; then
  convert_bin="$(command -v magick || command -v convert)"
  for size in 16 24 32 48 64 128 256 512; do
    mkdir -p "$STAGE/usr/share/icons/hicolor/${size}x${size}/apps"
    "$convert_bin" "$icon_src" -resize "${size}x${size}" \
      "$STAGE/usr/share/icons/hicolor/${size}x${size}/apps/easypass.png" || true
  done
  echo "build_deb: icons rendered for 16..512 px"
else
  echo "build_deb: note: ImageMagick not found; only the 1024px icon is installed"
fi

# System-wide native-messaging manifests (per-user manifests written by the app's
# own '--install-browser-host' still win, because browsers read the user dir first).
manifest_chrome=$(cat <<EOF
{
  "name": "com.easypass.app",
  "description": "EasyPass native messaging host",
  "path": "/usr/bin/easypass-native-host",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXT_ID/"]
}
EOF
)
printf '%s\n' "$manifest_chrome" > "$STAGE/etc/opt/chrome/native-messaging-hosts/com.easypass.app.json"
printf '%s\n' "$manifest_chrome" > "$STAGE/etc/opt/chromium/native-messaging-hosts/com.easypass.app.json"
cat > "$STAGE/usr/lib/mozilla/native-messaging-hosts/com.easypass.app.json" <<EOF
{
  "name": "com.easypass.app",
  "description": "EasyPass native messaging host",
  "path": "/usr/bin/easypass-native-host",
  "type": "stdio",
  "allowed_extensions": ["$EXT_ID"]
}
EOF

INSTALLED_SIZE="$(du -sk "$STAGE" | awk '{print $1}')"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: $DEB_ARCH
Installed-Size: $INSTALLED_SIZE
Maintainer: EasyPass Maintainers <maintainers@easypass.invalid>
Homepage: https://github.com/CONFISION/EasyPass
Depends: libc6, libstdc++6, libglib2.0-0, libgtk-3-0, libayatana-appindicator3-1, libsecret-1-0, zlib1g
Recommends: libayatana-appindicator3-1, xdg-utils
Description: local-first password manager
 EasyPass is a local-first password manager: the vault is a single encrypted
 SQLite database on this machine, and the master password never leaves it.
 .
 Desktop integration: tray icon, close-to-tray, XDG autostart, and a native
 messaging host for the EasyPass browser extension.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
exit 0
EOF

cat > "$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
exit 0
EOF

cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
# The UI and the core are long-running; ask the core to exit so an upgrade can
# replace /opt/easypass. Best-effort: never fail the package operation.
if [ -x /usr/bin/easypass-core ]; then
  /usr/bin/easypass-core --shutdown >/dev/null 2>&1 || true
fi
exit 0
EOF

chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm" "$STAGE/DEBIAN/prerm"

mkdir -p "$(dirname "$OUT_DEB")"
rm -f "$OUT_DEB"
# --root-owner-group: the package must be owned by root, but this script runs as
# the build user.
dpkg-deb --root-owner-group -Zxz --build "$STAGE" "$OUT_DEB" >/dev/null
dpkg-deb --info "$OUT_DEB" | sed -n '1,20p'
echo
echo "build_deb: OK  $OUT_DEB"
echo "  version : $VERSION ($DEB_ARCH)"
echo "  size    : $(du -h "$OUT_DEB" | awk '{print $1}')"
echo "  install : sudo apt install ./$(basename "$OUT_DEB")   # or: sudo dpkg -i <file> && sudo apt -f install"
