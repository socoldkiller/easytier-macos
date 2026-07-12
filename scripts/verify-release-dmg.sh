#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_PATH="${1:-}"

if [[ -z "$DMG_PATH" ]]; then
  echo "Usage: scripts/verify-release-dmg.sh /path/to/EasyTier.dmg" >&2
  exit 2
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "Release DMG not found: $DMG_PATH" >&2
  exit 1
fi

for command in codesign hdiutil spctl xattr xcrun; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required to verify a release DMG." >&2
    exit 1
  fi
done

hdiutil verify "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

TMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
VERIFY_DIR="$(mktemp -d "$TMP_ROOT/easytier-release-dmg.XXXXXX")"
SIMULATED_DOWNLOAD="$VERIFY_DIR/EasyTier.dmg"
MOUNT_DIR="$VERIFY_DIR/mount"
DMG_ATTACHED=0

cleanup() {
  if [[ "$DMG_ATTACHED" == "1" ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$VERIFY_DIR"
}
trap cleanup EXIT

cp "$DMG_PATH" "$SIMULATED_DOWNLOAD"
xattr -w com.apple.quarantine '0083;00000000;Safari;' "$SIMULATED_DOWNLOAD"
mkdir -p "$MOUNT_DIR"
hdiutil attach "$SIMULATED_DOWNLOAD" \
  -readonly \
  -nobrowse \
  -mountpoint "$MOUNT_DIR" \
  -quiet
DMG_ATTACHED=1

APP_PATH="$MOUNT_DIR/EasyTier.app"
[[ -d "$APP_PATH" ]] || {
  echo "Release DMG does not contain EasyTier.app." >&2
  exit 1
}
[[ -e "$MOUNT_DIR/Applications" ]] || {
  echo "Release DMG does not contain the Applications alias." >&2
  exit 1
}

"$ROOT_DIR/scripts/verify-app.sh" "$APP_PATH"
xcrun stapler validate "$APP_PATH"

if ! GATEKEEPER_OUTPUT="$(spctl -a -vv -t exec "$APP_PATH" 2>&1)"; then
  printf '%s\n' "$GATEKEEPER_OUTPUT" >&2
  exit 1
fi
printf '%s\n' "$GATEKEEPER_OUTPUT"

if [[ "$GATEKEEPER_OUTPUT" != *"source=Notarized Developer ID"* ]]; then
  echo "Gatekeeper did not identify EasyTier.app as a notarized Developer ID app." >&2
  exit 1
fi

echo "Release DMG passed integrity, notarization, signing, helper, and Gatekeeper checks."
