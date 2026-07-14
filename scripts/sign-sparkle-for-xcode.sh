#!/usr/bin/env bash
set -euo pipefail

if [[ "${CODE_SIGNING_ALLOWED:-NO}" != "YES" ]]; then
  exit 0
fi

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  exit 0
fi

FRAMEWORK="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}/Sparkle.framework"
[[ -d "$FRAMEWORK" ]] || {
  printf 'Embedded Sparkle framework not found: %s\n' "$FRAMEWORK" >&2
  exit 1
}

SIGN_ARGS=(
  --force
  --timestamp
  --options runtime
  --preserve-metadata=identifier,entitlements
  --sign "$IDENTITY"
)
if [[ -n "${EASYTIER_CODE_SIGN_KEYCHAIN:-}" ]]; then
  SIGN_ARGS+=(--keychain "$EASYTIER_CODE_SIGN_KEYCHAIN")
fi

for item in \
  "$FRAMEWORK/Versions/B/Autoupdate" \
  "$FRAMEWORK/Versions/B/Updater.app" \
  "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
  "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
  "$FRAMEWORK"; do
  [[ -e "$item" ]] || {
    printf 'Required Sparkle component not found: %s\n' "$item" >&2
    exit 1
  }
  codesign "${SIGN_ARGS[@]}" "$item"
done
