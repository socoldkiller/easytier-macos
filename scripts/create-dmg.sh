#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${EASYTIER_EXPORT_APP_DIR:-$HOME/Applications/EasyTier.app}}"
OUTPUT_DMG="${2:-$ROOT_DIR/.build/artifacts/EasyTier-macOS.dmg}"
VOLUME_NAME="${EASYTIER_DMG_VOLUME_NAME:-EasyTier}"
APP_NAME="EasyTier.app"

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

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easytier-dmg.XXXXXX")"
DMG_ROOT="$STAGING_DIR/$VOLUME_NAME"
MOUNT_DIR="$STAGING_DIR/mount"
RW_DMG="$STAGING_DIR/$VOLUME_NAME-rw.dmg"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

mkdir -p "$DMG_ROOT" "$MOUNT_DIR" "$(dirname "$OUTPUT_DMG")"

ditto --noextattr --norsrc "$APP_PATH" "$DMG_ROOT/$APP_NAME"
xattr -cr "$DMG_ROOT/$APP_NAME" 2>/dev/null || true

codesign --verify --deep --strict "$DMG_ROOT/$APP_NAME"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDRW \
  "$RW_DMG" >/dev/null

hdiutil attach "$RW_DMG" \
  -mountpoint "$MOUNT_DIR" \
  -noverify \
  -nobrowse \
  -quiet >/dev/null

detach_mounted_image() {
  hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
}
trap 'detach_mounted_image; cleanup' EXIT

sync

if command -v osascript >/dev/null 2>&1; then
  osascript >/dev/null <<EOF || true
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {160, 120, 1180, 742}

    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 132
    set text size of viewOptions to 13
    set label position of viewOptions to bottom

    set position of item "$APP_NAME" of container window to {510, 295}
    close
  end tell
end tell
EOF
fi

sync
detach_mounted_image

hdiutil convert "$RW_DMG" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$OUTPUT_DMG" >/dev/null

echo "$OUTPUT_DMG"
