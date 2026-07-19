#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CODESIGN_IDENTITY="${EASYTIER_CODESIGN_IDENTITY:-${CODESIGN_IDENTITY:-}}"
CODESIGN_KEYCHAIN="${EASYTIER_CODESIGN_KEYCHAIN:-${CODESIGN_KEYCHAIN:-}}"
PROFILE_PATH="${EASYTIER_PROVISIONING_PROFILE:-${PROVISIONING_PROFILE:-}}"
PROFILE_BASE64="${APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64:-}"
SWIFT_BUILD_DIR="${EASYTIER_SWIFT_BUILD_DIR:-$ROOT_DIR/.build/keychain-integration}"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/easytier-keychain-test.XXXXXX")"
ORIGINAL_DEFAULT_KEYCHAIN=""

cleanup() {
  if [[ -n "$ORIGINAL_DEFAULT_KEYCHAIN" ]]; then
    security default-keychain -d user -s "$ORIGINAL_DEFAULT_KEYCHAIN" >/dev/null 2>&1 || true
  fi
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

die() {
  echo "[keychain-integration] $*" >&2
  exit 1
}

[[ -n "$CODESIGN_IDENTITY" ]] || die "EASYTIER_CODESIGN_IDENTITY or CODESIGN_IDENTITY is required."

if [[ -n "$PROFILE_BASE64" ]]; then
  PROFILE_PATH="$TEMP_ROOT/EasyTier.provisionprofile"
  printf '%s' "$PROFILE_BASE64" | base64 --decode > "$PROFILE_PATH"
  chmod 600 "$PROFILE_PATH"
fi
[[ -f "$PROFILE_PATH" ]] || die "A Developer ID provisioning profile is required."

PROFILE_PLIST="$TEMP_ROOT/profile.plist"
ENTITLEMENTS_PLIST="$TEMP_ROOT/entitlements.plist"
security cms -D -i "$PROFILE_PATH" -o "$PROFILE_PLIST" >/dev/null
plutil -extract Entitlements xml1 -o "$ENTITLEMENTS_PLIST" "$PROFILE_PLIST"

TEAM_ID="$(plutil -extract TeamIdentifier.0 raw -o - "$PROFILE_PLIST")"
APPLICATION_IDENTIFIER="$(
  plutil -extract Entitlements.application-identifier raw -o - "$PROFILE_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST"
)"
EXPECTED_IDENTIFIER="$TEAM_ID.com.kkrainbow.easytier.mac"
[[ "$APPLICATION_IDENTIFIER" == "$EXPECTED_IDENTIFIER" ]] \
  || die "Provisioning profile targets $APPLICATION_IDENTIFIER, expected $EXPECTED_IDENTIFIER."
/usr/libexec/PlistBuddy \
  -c "Set :keychain-access-groups:0 $APPLICATION_IDENTIFIER" \
  "$ENTITLEMENTS_PLIST"
ACCESS_GROUP="$APPLICATION_IDENTIFIER"

swift build \
  --package-path "$ROOT_DIR" \
  --scratch-path "$SWIFT_BUILD_DIR" \
  --configuration release \
  --product EasyTierKeychainIntegrationHarness

BIN_DIR="$(
  swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$SWIFT_BUILD_DIR" \
    --configuration release \
    --show-bin-path
)"
HARNESS_BINARY="$BIN_DIR/EasyTierKeychainIntegrationHarness"
[[ -x "$HARNESS_BINARY" ]] || die "Harness binary was not produced at $HARNESS_BINARY."

APP_PATH="$TEMP_ROOT/EasyTierKeychainIntegration.app"
APP_BINARY="$APP_PATH/Contents/MacOS/EasyTierKeychainIntegrationHarness"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
mkdir -p "$APP_PATH/Contents/MacOS"
ditto "$HARNESS_BINARY" "$APP_BINARY"
ditto "$PROFILE_PATH" "$APP_PATH/Contents/embedded.provisionprofile"

plutil -create xml1 "$INFO_PLIST"
plutil -insert CFBundleExecutable -string EasyTierKeychainIntegrationHarness "$INFO_PLIST"
plutil -insert CFBundleIdentifier -string com.kkrainbow.easytier.mac "$INFO_PLIST"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$INFO_PLIST"
plutil -insert CFBundleName -string EasyTierKeychainIntegration "$INFO_PLIST"
plutil -insert CFBundlePackageType -string APPL "$INFO_PLIST"
plutil -insert CFBundleShortVersionString -string 1.0 "$INFO_PLIST"
plutil -insert CFBundleVersion -string 1 "$INFO_PLIST"

CODESIGN_ARGS=(
  --force
  --options runtime
  --timestamp
  --entitlements "$ENTITLEMENTS_PLIST"
  --sign "$CODESIGN_IDENTITY"
)
if [[ -n "$CODESIGN_KEYCHAIN" ]]; then
  CODESIGN_ARGS+=(--keychain "$CODESIGN_KEYCHAIN")
fi
codesign "${CODESIGN_ARGS[@]}" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ -n "$CODESIGN_KEYCHAIN" ]]; then
  ORIGINAL_DEFAULT_KEYCHAIN="$(
    security default-keychain -d user \
      | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'
  )"
  security default-keychain -d user -s "$CODESIGN_KEYCHAIN"
fi

TEST_SERVICE="com.kkrainbow.easytier.mac.keychain-integration.$(uuidgen | tr '[:upper:]' '[:lower:]')"
EASYTIER_KEYCHAIN_TEST_SERVICE="$TEST_SERVICE" \
EASYTIER_KEYCHAIN_ACCESS_GROUP="$ACCESS_GROUP" \
  "$APP_BINARY"
