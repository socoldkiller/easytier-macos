#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/debug"
APP_PRODUCTS_DIR="$ROOT_DIR/.build/AppProducts"
APP_DIR="$APP_PRODUCTS_DIR/EasyTier.app"
STAGING_DIR="$APP_PRODUCTS_DIR/EasyTier.staging"
EXPORT_APP_DIR="${EASYTIER_EXPORT_APP_DIR:-/tmp/EasyTier.app}"
CONTENTS_DIR="$STAGING_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
LAUNCH_DAEMONS_DIR="$CONTENTS_DIR/Library/LaunchDaemons"
BUNDLE_IDENTIFIER="com.kkrainbow.easytier.mac"
HELPER_IDENTIFIER="com.kkrainbow.easytier.mac.helper"
VALIDATOR_IDENTIFIER="com.kkrainbow.easytier.mac.validator"
BUILD_NUMBER="${EASYTIER_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"

git_revision() {
  local path="$1"
  local revision
  revision="$(git -C "$path" rev-parse --short HEAD 2>/dev/null || true)"
  if [[ -z "$revision" ]]; then
    echo "unknown"
    return
  fi
  if [[ -n "$(git -C "$path" status --short --untracked-files=no 2>/dev/null || true)" ]]; then
    revision="$revision-dirty"
  fi
  echo "$revision"
}

git_exact_tag() {
  local path="$1"
  local tag
  tag="$(git -C "$path" describe --tags --exact-match HEAD 2>/dev/null || true)"
  if [[ -z "$tag" ]]; then
    echo "unknown"
    return
  fi
  if [[ -n "$(git -C "$path" status --short --untracked-files=no 2>/dev/null || true)" ]]; then
    tag="$tag-dirty"
  fi
  echo "$tag"
}

clear_finder_info() {
  local path="$1"
  for _ in $(seq 1 20); do
    xattr -d com.apple.FinderInfo "$path" 2>/dev/null || true
    if ! xattr -p com.apple.FinderInfo "$path" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
}

clear_codesign_blocking_xattrs() {
  local path="$1"
  while IFS= read -r -d '' item; do
    xattr -d com.apple.FinderInfo "$item" 2>/dev/null || true
    xattr -d 'com.apple.fileprovider.dir#N' "$item" 2>/dev/null || true
    xattr -d 'com.apple.fileprovider.fpfs#P' "$item" 2>/dev/null || true
    xattr -d com.apple.provenance "$item" 2>/dev/null || true
    xattr -d com.apple.quarantine "$item" 2>/dev/null || true
  done < <(find "$path" -print0)
}

cd "$ROOT_DIR"
GUI_COMMIT="$(git_revision "$ROOT_DIR")"
CORE_TAG="$(git_exact_tag "$ROOT_DIR/Vendor/EasyTier")"
CORE_COMMIT="$(git_revision "$ROOT_DIR/Vendor/EasyTier")"

swift build --product EasyTierMac
swift build --product EasyTierValidator
swift build --product EasyTierPrivilegedHelper

rm -rf "$APP_DIR" "$STAGING_DIR"
mkdir -p "$APP_PRODUCTS_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$LAUNCH_DAEMONS_DIR"
cp "$BUILD_DIR/EasyTierMac" "$MACOS_DIR/EasyTierMac"
cp "$BUILD_DIR/EasyTierValidator" "$MACOS_DIR/EasyTierValidator"
cp "$BUILD_DIR/EasyTierPrivilegedHelper" "$MACOS_DIR/EasyTierPrivilegedHelper"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>EasyTierMac</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>EasyTier</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>EasyTierGUICommit</key>
    <string>$GUI_COMMIT</string>
    <key>EasyTierCoreTag</key>
    <string>$CORE_TAG</string>
    <key>EasyTierCoreCommit</key>
    <string>$CORE_COMMIT</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <true/>
</dict>
</plist>
PLIST

cat > "$LAUNCH_DAEMONS_DIR/com.kkrainbow.easytier.mac.helper.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$HELPER_IDENTIFIER</string>
    <key>MachServices</key>
    <dict>
        <key>$HELPER_IDENTIFIER</key>
        <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>$BUNDLE_IDENTIFIER</string>
    </array>
    <key>BundleProgram</key>
    <string>Contents/MacOS/EasyTierPrivilegedHelper</string>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/easytier-helper.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/easytier-helper.log</string>
</dict>
</plist>
PLIST

xattr -cr "$STAGING_DIR"
clear_codesign_blocking_xattrs "$STAGING_DIR"
clear_finder_info "$STAGING_DIR"
codesign --force --sign - --identifier "$VALIDATOR_IDENTIFIER" "$MACOS_DIR/EasyTierValidator"
codesign --force --sign - --identifier "$HELPER_IDENTIFIER" "$MACOS_DIR/EasyTierPrivilegedHelper"
clear_finder_info "$STAGING_DIR"
codesign --force --sign - --identifier "$BUNDLE_IDENTIFIER" "$STAGING_DIR"
mv "$STAGING_DIR" "$APP_DIR"
xattr -cr "$APP_DIR"
clear_codesign_blocking_xattrs "$APP_DIR"
clear_finder_info "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null
clear_codesign_blocking_xattrs "$APP_DIR"
clear_finder_info "$APP_DIR"

rm -rf "$EXPORT_APP_DIR"
ditto --noextattr --norsrc "$APP_DIR" "$EXPORT_APP_DIR"
clear_codesign_blocking_xattrs "$EXPORT_APP_DIR"
clear_finder_info "$EXPORT_APP_DIR"
codesign --verify --deep --strict --verbose=2 "$EXPORT_APP_DIR" >/dev/null

echo "$EXPORT_APP_DIR"
