#!/usr/bin/env bash
# One-shot Linux release build: Flutter bundle → core service → .deb.
#
#   tool/build_release_linux.sh [--skip-tests]
#
# Steps (each one fails loudly):
#   1. flutter pub get
#   2. flutter analyze          (skip with --skip-tests)
#   3. flutter test             (skip with --skip-tests)
#   4. flutter build linux --release
#   5. tool/build_core.sh       → bundle/core/easypass_core
#   6. installer/deb/build_deb.sh → dist/easypass_<version>_<arch>.deb
#
# Requirements (Debian/Ubuntu):
#   build-essential clang cmake ninja-build pkg-config \
#   libgtk-3-dev liblzma-dev libayatana-appindicator3-dev libsecret-1-dev \
#   fakeroot dpkg-dev imagemagick
#
# Note: the Linux runner has no CMake POST_BUILD hook for the core (Windows does),
# so step 5 is a separate command here and in CI. Keep the order: the Flutter
# build wipes build/linux/.../bundle, so the core must be copied in afterwards.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
cd "$REPO_ROOT"

SKIP_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --skip-tests) SKIP_TESTS=1 ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "build_release_linux: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

command -v flutter >/dev/null 2>&1 || {
  echo "build_release_linux: flutter is not on PATH" >&2
  exit 1
}

echo "== 1/6 flutter pub get"
flutter pub get

# `browser_host_installer_test.dart` 用临时 $HOME 断言 vendor 根/manifest 落在那里，
# 而 `install()` 会回落到环境里的 $XDG_CONFIG_HOME —— 一旦本机导出了它，测试就写进真实
# ~/.config 并连带 8~9 条假失败。CI runner 不导出这两个变量，这里对齐。
TEST_ENV=(env -u XDG_CONFIG_HOME -u XDG_DATA_HOME)

if [ "$SKIP_TESTS" -eq 0 ]; then
  echo "== 2/6 flutter analyze"
  flutter analyze --no-pub
  echo "== 3/6 flutter test"
  "${TEST_ENV[@]}" flutter test --no-pub
else
  echo "== 2-3/6 tests skipped (--skip-tests)"
fi

echo "== 4/6 flutter build linux --release"
flutter build linux --release

echo "== 5/6 build core service"
bash tool/build_core.sh --out-dir build/linux/x64/release/bundle

echo "== 6/6 package .deb"
bash installer/deb/build_deb.sh

echo
echo "build_release_linux: done — artifact in dist/"
ls -lh dist/*.deb 2>/dev/null || true
echo "install with: sudo apt install ./dist/$(ls dist/*.deb 2>/dev/null | xargs -r -n1 basename | tail -1)"
