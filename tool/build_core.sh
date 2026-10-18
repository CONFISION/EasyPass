#!/usr/bin/env bash
# Build the EasyPass core service into <bundle>/core/ and its runtime libraries
# into <bundle>/lib/ (Linux counterpart of tool/build_core.ps1).
#
# Why not `dart compile exe`: the dependency graph contains packages with build
# hooks (sqlite3 / objective_c) and the SDK answers
#   "'dart compile' does not support build hooks, use 'dart build' instead".
# `dart build cli` is the supported path (verified with Dart SDK 3.13.4).
#
# `dart build cli -o <dir>` produces a bundle:
#   <dir>/bundle/bin/easypass_core     the executable
#   <dir>/bundle/lib/*                 build-hook dynamic libraries
#
# WHY THE CORE LIVES IN A SUBDIRECTORY
# ------------------------------------
# package:sqlite3 is compiled with `@ffi.DefaultAsset`, so the runtime resolves
# a bundled library as a path relative to the EXECUTABLE:
#     <exe_dir>/../lib/<name>
# This was measured on Windows x64 / Dart 3.13.4 (the library next to the exe
# alone FAILS; `<exe_dir>/../lib/<name>` works; a native_assets.json sidecar is
# ignored). The layout below satisfies the lookup and keeps everything inside
# the application directory:
#
#   <out>/easypass                    the UI (Flutter build, untouched)
#   <out>/core/easypass_core          the core service
#   <out>/lib/*                       the core's libraries -- and already the
#                                     Flutter bundle's lib dir, so the existing
#                                     libsqlite3.so is reused, never clobbered
#
# In the AppImage the bundle is copied verbatim into usr/bin/, so the lookup
# becomes usr/bin/core/../lib = usr/bin/lib (Flutter's own lib dir).
#
# On Linux the vault lives in $XDG_DATA_HOME/easypass (see
# lib/core/platform/app_paths.dart), so the core's own directory does not matter
# for data coordinates.
#
# NOT VERIFIED ON LINUX: no Linux host was available. The hook is configured
# `source: {linux: system}` in pubspec.yaml, so the Linux CLI bundle may carry
# no sqlite3 library at all and fall back to the system libsqlite3.so; this
# script only mirrors the layout, it cannot prove the loader finds it.
#
# Usage:
#   tool/build_core.sh [--out-dir DIR] [--entry FILE] [--build-dir DIR]
#
# Defaults:
#   --out-dir    build/linux/x64/release/bundle   (the Flutter release bundle)
#   --entry      bin/easypass_core.dart
#   --build-dir  build/core                       (incremental intermediate)
#
# Exits non-zero unless the core is in place, every library from the CLI bundle
# is at the path the runtime resolves, and `--version` runs.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

OUT_DIR="$REPO_ROOT/build/linux/x64/release/bundle"
ENTRY="bin/easypass_core.dart"
BUILD_DIR="build/core"
EXE_NAME="easypass_core"
CORE_SUBDIR="core"
LIB_SUBDIR="lib"

die() {
  echo "build_core: ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)   [[ $# -ge 2 ]] || die "--out-dir needs a value";   OUT_DIR="$2";  shift 2 ;;
    --entry)     [[ $# -ge 2 ]] || die "--entry needs a value";     ENTRY="$2";    shift 2 ;;
    --build-dir) [[ $# -ge 2 ]] || die "--build-dir needs a value"; BUILD_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

cd "$REPO_ROOT"

[[ -f "$ENTRY" ]] || die "entry point not found: $ENTRY (expected under $REPO_ROOT)"
command -v dart >/dev/null 2>&1 || die "dart is not on PATH (install the Flutter/Dart SDK)"

echo "build_core: dart build cli -o $BUILD_DIR -t $ENTRY"
dart build cli -o "$BUILD_DIR" -t "$ENTRY" || die "dart build cli failed"

SRC_EXE="$BUILD_DIR/bundle/bin/$EXE_NAME"
SRC_LIB="$BUILD_DIR/bundle/lib"
[[ -f "$SRC_EXE" ]] || die "dart build cli produced no $EXE_NAME (looked for $SRC_EXE)"

mkdir -p "$OUT_DIR"
OUT_ABS="$(readlink -f "$OUT_DIR")"
[[ -d "$OUT_ABS" ]] || die "output path is not a directory: $OUT_DIR"
CORE_DIR="$OUT_ABS/$CORE_SUBDIR"
# This IS the path the runtime resolves: <exe_dir> is <out>/core, so
# <exe_dir>/../lib == <out>/lib. On Linux that directory is also the Flutter
# bundle's lib dir, so existing libraries there are never overwritten.
LIB_DIR="$OUT_ABS/$LIB_SUBDIR"

file_size() { stat -c%s "$1" 2>/dev/null || echo '?'; }

# copy_libs <target_dir> <label> <overwrite: yes|no>
# Copies every library from the CLI bundle into <target_dir>. `overwrite=no`
# protects libraries the Flutter build already put there (its own
# libsqlite3.so), which the UI loads.
# Prints the number of files handled on stdout; log lines go to stderr.
copy_libs() {
  local target_dir="$1" label="$2" overwrite="$3" count=0
  if [[ ! -d "$SRC_LIB" ]]; then
    echo 0
    return 0
  fi
  mkdir -p "$target_dir" || die "cannot create $target_dir"
  shopt -s nullglob
  for lib in "$SRC_LIB"/*; do
    local name target
    name="$(basename "$lib")"
    target="$target_dir/$name"
    if [[ "$overwrite" == no && -e "$target" ]]; then
      echo "build_core: keep    $target ($(file_size "$target") bytes, already present)" >&2
      count=$((count + 1))
      continue
    fi
    cp -f "$lib" "$target" || die "cannot write $target"
    echo "build_core: $label $target ($(file_size "$target") bytes)" >&2
    count=$((count + 1))
  done
  shopt -u nullglob
  echo "$count"
}

# --- 1. the core executable: always replaced --------------------------------
mkdir -p "$CORE_DIR" || die "cannot create $CORE_DIR"
DST_EXE="$CORE_DIR/$EXE_NAME"
cp -f "$SRC_EXE" "$DST_EXE" || die "cannot write $DST_EXE (is a running easypass_core locking it?)"
chmod +x "$DST_EXE"
echo "build_core: core    $DST_EXE ($(file_size "$DST_EXE") bytes)"

# --- 2. the core's libraries: <out>/lib, never clobbering Flutter's ---------
libs="$(copy_libs "$LIB_DIR" 'lib    ' no)"

# --- 3. verify every bundle library is where the runtime looks --------------
if [[ -d "$SRC_LIB" ]]; then
  shopt -s nullglob
  missing=()
  for lib in "$SRC_LIB"/*; do
    [[ -e "$LIB_DIR/$(basename "$lib")" ]] || missing+=("$(basename "$lib")")
  done
  shopt -u nullglob
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "not loadable at runtime: ${missing[*]} missing from $LIB_DIR"
  fi
fi

if [[ ! -e "$LIB_DIR/libsqlite3.so" && ! -e "$OUT_ABS/libsqlite3.so" ]]; then
  echo "build_core: note: no libsqlite3.so in $LIB_DIR. The Linux build uses the" >&2
  echo "  system libsqlite3 (pubspec.yaml hook 'source: {linux: system}'), so the" >&2
  echo "  loader has to find it on the system." >&2
fi

# --- 4. smoke test: the produced binary must start --------------------------
# `--version` prints and exits before any vault access, so it is safe to run
# here (no daemon.json, no core.lock, no database).
version="$("$DST_EXE" --version)" || die "the produced core failed its --version smoke test"
echo "build_core: smoke   $version"

echo
echo "build_core: OK"
echo "  core        : $DST_EXE"
echo "  size        : $(file_size "$DST_EXE") bytes"
echo "  core libs   : $LIB_DIR ($libs file(s); loaded as ../lib/<name> relative to the exe)"
