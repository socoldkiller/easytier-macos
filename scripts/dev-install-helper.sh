#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${EASYTIER_EXPORT_APP_DIR:-$HOME/Applications/EasyTier.app}"
PACKAGE_FIRST="${EASYTIER_PACKAGE_FIRST:-1}"
OPEN_APP="${EASYTIER_OPEN_APP:-0}"
APP_BINARY="$APP_PATH/Contents/MacOS/EasyTierMac"
RESET_BTM_STATE="${EASYTIER_RESET_BTM:-1}"

open_login_items_settings() {
  echo "Opening Login Items & Extensions. Allow EasyTier there, then rerun this script." >&2
  open 'x-apple.systempreferences:com.apple.LoginItems-Settings.extension' >/dev/null 2>&1 || true
}

needs_user_approval() {
  local output="$1"
  [[ "$output" == *"requiresApproval"* \
    || "$output" == *"Operation not permitted"* \
    || "$output" == *"has not allowed"* \
    || "$output" == *"disallowed"* \
    || "$output" == *"not allowed"* ]]
}

cd "$ROOT_DIR"

if [[ "$PACKAGE_FIRST" == "1" ]]; then
  APP_PATH="$(EASYTIER_RESET_BTM="$RESET_BTM_STATE" ./scripts/package-app.sh | tail -n 1)"
  APP_BINARY="$APP_PATH/Contents/MacOS/EasyTierMac"
fi

if [[ ! -x "$APP_BINARY" ]]; then
  echo "EasyTier app binary not found: $APP_BINARY" >&2
  echo "Run ./scripts/package-app.sh first, or leave EASYTIER_PACKAGE_FIRST=1." >&2
  exit 1
fi

echo "Using app: $APP_PATH"

status_output="$($APP_BINARY --helper-status 2>&1 || true)"
echo "$status_output"

if ! register_output="$($APP_BINARY --register-helper 2>&1)"; then
  echo "$register_output" >&2
  status_output="$($APP_BINARY --helper-status 2>&1 || true)"
  echo "$status_output" >&2

  if needs_user_approval "$status_output
$register_output"; then
    echo "macOS requires approval before EasyTier's privileged helper can run." >&2
    open_login_items_settings
  fi
  exit 1
fi
echo "$register_output"

if needs_user_approval "$register_output"; then
  echo "macOS requires approval before EasyTier's privileged helper can run." >&2
  open_login_items_settings
  exit 1
fi

if ! ping_output="$($APP_BINARY --ping-helper 2>&1)"; then
  echo "$ping_output" >&2
  echo "Helper registration did not produce a responding XPC service." >&2
  if needs_user_approval "$ping_output"; then
    echo "macOS requires approval before EasyTier's privileged helper can run." >&2
    open_login_items_settings
  fi
  echo "launchctl state:" >&2
  launchctl print system/com.kkrainbow.easytier.mac.helper 2>&1 | sed -n '1,120p' >&2 || true
  exit 1
fi
echo "$ping_output"

if [[ "$OPEN_APP" == "1" ]]; then
  open "$APP_PATH"
fi

echo "Privileged helper is installed and responding."
