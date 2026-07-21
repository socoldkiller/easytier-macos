#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PRODUCTS_DIR="${EASYTIER_APP_PRODUCTS_DIR:-$ROOT_DIR/.build/AppProducts}"
INSTALL_APP_PATH="${EASYTIER_INSTALL_APP_PATH:-/Applications/EasyTier.app}"
CODE_SIGN_KEYCHAIN="${EASYTIER_CODESIGN_KEYCHAIN:-}"

source "$ROOT_DIR/scripts/xcode-metadata-arguments.sh"

printf 'Building local Debug app: build=%s time=%s GUI/Gateway=%s Gateway=%s Core=%s (%s)\n' \
  "$EASYTIER_BUILD_NUMBER" \
  "$EASYTIER_BUILD_TIME" \
  "$EASYTIER_GUI_COMMIT" \
  "$EASYTIER_GATEWAY_VERSION" \
  "$EASYTIER_CORE_TAG" \
  "$EASYTIER_CORE_COMMIT"

EASYTIER_CODESIGN_KEYCHAIN="$CODE_SIGN_KEYCHAIN" \
"$ROOT_DIR/scripts/with-signing-keychain.sh" xcodebuild \
  -project "$ROOT_DIR/EasyTier.xcodeproj" \
  -scheme EasyTierMac \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$APP_PRODUCTS_DIR/DebugDerivedData" \
  "${EASYTIER_XCODE_METADATA_ARGS[@]}" \
  build

EASYTIER_INSTALL_APP_PATH="$INSTALL_APP_PATH" \
EASYTIER_OPEN_APP="${EASYTIER_OPEN_APP:-1}" \
"$ROOT_DIR/scripts/install-xcode-debug-app.sh" \
  "$APP_PRODUCTS_DIR/DebugDerivedData/Build/Products/Debug/EasyTier.app"
