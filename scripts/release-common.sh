#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
RELEASE_FEED_HELPER="${EASYTIER_RELEASE_FEED_HELPER:-$ROOT_DIR/scripts/release_feed.py}"
ARCHIVE_APP_SCRIPT="${EASYTIER_RELEASE_ARCHIVE_APP_SCRIPT:-$ROOT_DIR/scripts/archive-app.sh}"
CREATE_DMG_SCRIPT="${EASYTIER_RELEASE_CREATE_DMG_SCRIPT:-$ROOT_DIR/scripts/create-dmg.sh}"
VERIFY_DMG_SCRIPT="${EASYTIER_RELEASE_VERIFY_DMG_SCRIPT:-$ROOT_DIR/scripts/verify-release-dmg.sh}"
VERIFY_APP_SCRIPT="${EASYTIER_RELEASE_VERIFY_APP_SCRIPT:-$ROOT_DIR/scripts/verify-app.sh}"

ARTIFACTS_DIR="${EASYTIER_ARTIFACTS_DIR:-$ROOT_DIR/.build/artifacts}"
PAGES_DIR="${EASYTIER_PAGES_DIR:-$ROOT_DIR/.build/pages}"
MINIMUM_SYSTEM_VERSION="${EASYTIER_MINIMUM_SYSTEM_VERSION:-15.0}"
UPDATE_BASE_URL="${EASYTIER_UPDATE_BASE_URL:-https://socoldkiller.github.io/easytier-macos}"
REPOSITORY="${REPOSITORY:-${GITHUB_REPOSITORY:-socoldkiller/easytier-macos}}"
CORE_REPOSITORY="${EASYTIER_CORE_REPOSITORY:-EasyTier/EasyTier}"
RELEASE_CHANNEL="${EASYTIER_RELEASE_CHANNEL:-stable}"
PUBLISH_BUILD_TIME=""
PUBLISH_GUI_REVISION=""

TEMP_ROOT=""
RELEASE_ARCHITECTURE=""
APP_PATH=""
DMG_PATH=""
METADATA_PATH=""
FOUND_DMG=""
FOUND_METADATA=""
CANONICAL_DMG=""
RELEASE_EXISTS=0
REMOTE_ASSET_EXISTS=0
SPARKLE_TOOLS_DIR=""
SPARKLE_PRIVATE_KEY_FILE=""
NOTARY_ARGS=()

log() {
  printf '[release] %s\n' "$*"
}

die() {
  printf '[release] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT"
  fi
}
trap cleanup EXIT

ensure_temp_root() {
  if [[ -n "$TEMP_ROOT" ]]; then
    return
  fi
  local parent="${EASYTIER_RELEASE_TEMP_PARENT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
  mkdir -p "$parent"
  TEMP_ROOT="$(mktemp -d "$parent/easytier-release.XXXXXX")"
  chmod 700 "$TEMP_ROOT"
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || die "$command_name is required."
}

require_executable() {
  local path="$1"
  [[ -x "$path" ]] || die "Required release helper is not executable: $path"
}

configure_release_channel() {
  [[ "$RELEASE_CHANNEL" == "stable" || "$RELEASE_CHANNEL" == "nightly" ]] \
    || die "EASYTIER_RELEASE_CHANNEL must be stable or nightly: $RELEASE_CHANNEL"
  export EASYTIER_BUILD_CHANNEL="$RELEASE_CHANNEL"
}
