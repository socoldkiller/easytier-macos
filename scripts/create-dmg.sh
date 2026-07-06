#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${EASYTIER_EXPORT_APP_DIR:-$HOME/Applications/EasyTier.app}}"
OUTPUT_DMG="${2:-$ROOT_DIR/.build/artifacts/EasyTier-macOS.dmg}"
VOLUME_NAME="${EASYTIER_DMG_VOLUME_NAME:-EasyTier}"
APP_NAME="EasyTier.app"
DMG_DS_STORE_TEMPLATE="$ROOT_DIR/Packaging/DMG.DS_Store"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

if [[ ! -x "$APP_PATH/Contents/MacOS/EasyTierMac" ]]; then
  echo "EasyTierMac executable not found in app bundle: $APP_PATH" >&2
  exit 1
fi

if ! command -v hdiutil >/dev/null 2>&1; then
  echo "hdiutil is required to create a macOS DMG." >&2
  exit 1
fi

if [[ ! -f "$DMG_DS_STORE_TEMPLATE" ]]; then
  echo "DMG Finder layout template not found: $DMG_DS_STORE_TEMPLATE" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easytier-dmg.XXXXXX")"
DMG_ROOT="$STAGING_DIR/$VOLUME_NAME"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

mkdir -p "$DMG_ROOT" "$(dirname "$OUTPUT_DMG")"

ditto --noextattr --norsrc "$APP_PATH" "$DMG_ROOT/$APP_NAME"
xattr -cr "$DMG_ROOT/$APP_NAME" 2>/dev/null || true
ln -s /Applications "$DMG_ROOT/Applications"
cp "$DMG_DS_STORE_TEMPLATE" "$DMG_ROOT/.DS_Store"

codesign --verify --deep --strict "$DMG_ROOT/$APP_NAME"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$OUTPUT_DMG" >/dev/null

echo "$OUTPUT_DMG"
