#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_DIR="${EASYTIER_TRACE_ARTIFACTS_DIR:-$ROOT_DIR/.build/artifacts/debug-trace}"
APP_PATH="${EASYTIER_TRACE_APP_PATH:-$ARTIFACTS_DIR/EasyTier-debug.app}"
DMG_PATH="${EASYTIER_TRACE_DMG_PATH:-$ARTIFACTS_DIR/EasyTier-debug-trace.dmg}"
DSYM_DIR="${EASYTIER_TRACE_DSYM_DIR:-$ARTIFACTS_DIR/dSYMs}"
DSYM_ZIP="${EASYTIER_TRACE_DSYM_ZIP:-$ARTIFACTS_DIR/EasyTier-debug-trace-dSYMs.zip}"
CODE_SIGN_IDENTITY="${EASYTIER_CODESIGN_IDENTITY:-}"

cd "$ROOT_DIR"

require_command() {
  local command="$1"
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required." >&2
    exit 1
  fi
}

make_dsym() {
  local binary="$1"
  local output="$2"

  if [[ ! -x "$binary" ]]; then
    echo "Trace symbol source not found: $binary" >&2
    exit 1
  fi

  rm -rf "$output"
  xcrun dsymutil "$binary" -o "$output"
}

require_command swift
require_command xcrun
require_command zip

if [[ "$CODE_SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
  echo "EASYTIER_CODESIGN_IDENTITY must name a Developer ID Application identity." >&2
  exit 1
fi

mkdir -p "$ARTIFACTS_DIR"

echo "Building Rust FFI with symbols preserved for trace analysis." >&2
EASYTIER_RUST_PROFILE_DEBUG="${EASYTIER_RUST_PROFILE_DEBUG:-2}" \
EASYTIER_RUST_OPT_LEVEL="${EASYTIER_RUST_OPT_LEVEL:-1}" \
EASYTIER_RUST_LTO="${EASYTIER_RUST_LTO:-off}" \
EASYTIER_RUST_CODEGEN_UNITS="${EASYTIER_RUST_CODEGEN_UNITS:-16}" \
EASYTIER_STRIP_STATIC_LIBS="${EASYTIER_STRIP_STATIC_LIBS:-0}" \
EASYTIER_USE_FFI_CACHE="${EASYTIER_USE_FFI_CACHE:-1}" \
"$ROOT_DIR/scripts/build-ffi.sh"

echo "Packaging Swift debug app." >&2
EASYTIER_BUILD_CONFIGURATION=debug \
EASYTIER_EXPORT_APP_DIR="$APP_PATH" \
EASYTIER_CODESIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
EASYTIER_DEAD_STRIP_RELEASE=0 \
EASYTIER_STRIP_RELEASE_BINARIES=0 \
"$ROOT_DIR/scripts/package-app.sh" >/dev/null

rm -rf "$DSYM_DIR"
mkdir -p "$DSYM_DIR"
make_dsym "$APP_PATH/Contents/MacOS/EasyTierMac" "$DSYM_DIR/EasyTierMac.dSYM"
make_dsym "$APP_PATH/Contents/MacOS/EasyTierPrivilegedHelper" "$DSYM_DIR/EasyTierPrivilegedHelper.dSYM"

rm -f "$DSYM_ZIP"
(
  cd "$DSYM_DIR"
  zip -qry "$DSYM_ZIP" EasyTierMac.dSYM EasyTierPrivilegedHelper.dSYM
)

echo "Creating debug trace DMG." >&2
EASYTIER_DMG_VOLUME_NAME="${EASYTIER_DMG_VOLUME_NAME:-EasyTier Debug}" \
"$ROOT_DIR/scripts/create-dmg.sh" "$APP_PATH" "$DMG_PATH" >/dev/null

cat <<EOF
App: $APP_PATH
DMG: $DMG_PATH
dSYM: $DSYM_ZIP
Signing identity: $CODE_SIGN_IDENTITY
EOF
