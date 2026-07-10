#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PRODUCTS_DIR="${EASYTIER_APP_PRODUCTS_DIR:-/tmp/EasyTierAppProducts}"
SWIFT_BUILD_DIR="${EASYTIER_SWIFT_BUILD_DIR:-$APP_PRODUCTS_DIR/SwiftBuild}"
APP_DIR="$APP_PRODUCTS_DIR/EasyTier.app"
STAGING_DIR="$APP_PRODUCTS_DIR/EasyTier.staging"
EXPORT_APP_DIR="${EASYTIER_EXPORT_APP_DIR:-$HOME/Applications/EasyTier.app}"
CONTENTS_DIR="$STAGING_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
LAUNCH_DAEMONS_DIR="$CONTENTS_DIR/Library/LaunchDaemons"
BUNDLE_IDENTIFIER="com.kkrainbow.easytier.mac"
HELPER_IDENTIFIER="com.kkrainbow.easytier.mac.helper"
APP_ENTITLEMENTS="$ROOT_DIR/Packaging/EasyTierMac.entitlements"
BUILD_CONFIGURATION="${EASYTIER_BUILD_CONFIGURATION:-debug}"
APP_VERSION="${EASYTIER_APP_VERSION:-}"
DEAD_STRIP_RELEASE="${EASYTIER_DEAD_STRIP_RELEASE:-1}"
STRIP_RELEASE_BINARIES="${EASYTIER_STRIP_RELEASE_BINARIES:-1}"
CODE_SIGN_IDENTITY="${EASYTIER_CODESIGN_IDENTITY:--}"
REQUIRE_DISTRIBUTION_SIGNING="${EASYTIER_REQUIRE_DISTRIBUTION_SIGNING:-0}"
CODE_SIGN_TIMESTAMP="${EASYTIER_CODESIGN_TIMESTAMP:-1}"
CLEAN_HELPER_STATE="${EASYTIER_CLEAN_HELPER_STATE:-}"
ALLOW_UNINSTALLABLE_HELPER="${EASYTIER_ALLOW_UNINSTALLABLE_HELPER:-0}"
AUTO_CODESIGN_IDENTITY="${EASYTIER_AUTO_CODESIGN_IDENTITY:-1}"
RESET_BTM_STATE="${EASYTIER_RESET_BTM:-0}"

if [[ "$BUILD_CONFIGURATION" != "debug" && "$BUILD_CONFIGURATION" != "release" ]]; then
  echo "EASYTIER_BUILD_CONFIGURATION must be 'debug' or 'release'." >&2
  exit 1
fi

if [[ -z "$APP_VERSION" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  APP_VERSION="${GITHUB_REF_NAME:-}"
fi
APP_VERSION="${APP_VERSION#v}"
APP_VERSION="${APP_VERSION:-0.1.0}"
if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "EASYTIER_APP_VERSION must be a numeric version like 0.2.0; got '$APP_VERSION'." >&2
  exit 1
fi

identity_names_matching() {
  local pattern="$1"
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^ *[0-9]*) [A-Fa-f0-9]* "\(.*\)"$/\1/p' \
    | grep -E "$pattern" || true
}

run_with_timeout() {
  local seconds="$1"
  shift
  "$@" &
  local command_pid="$!"
  (
    sleep "$seconds"
    kill "$command_pid" >/dev/null 2>&1 || true
  ) &
  local watchdog_pid="$!"
  wait "$command_pid"
  local status="$?"
  kill "$watchdog_pid" >/dev/null 2>&1 || true
  wait "$watchdog_pid" 2>/dev/null || true
  return "$status"
}

select_codesign_identity() {
  if [[ "$REQUIRE_DISTRIBUTION_SIGNING" == "1" ]]; then
    identity_names_matching '^Developer ID Application:' | head -n 1
    return
  fi

  {
    identity_names_matching '^Apple Development:'
    identity_names_matching '^Developer ID Application:'
    identity_names_matching '^Mac Developer:'
  } | head -n 1
}

if [[ "$CODE_SIGN_IDENTITY" == "-" && "$AUTO_CODESIGN_IDENTITY" == "1" ]]; then
  AUTO_SELECTED_IDENTITY="$(select_codesign_identity)"
  if [[ -n "$AUTO_SELECTED_IDENTITY" ]]; then
    CODE_SIGN_IDENTITY="$AUTO_SELECTED_IDENTITY"
    echo "Using code signing identity: $CODE_SIGN_IDENTITY" >&2
  fi
fi

if [[ "$REQUIRE_DISTRIBUTION_SIGNING" == "1" && "$ALLOW_UNINSTALLABLE_HELPER" == "1" ]]; then
  echo "EASYTIER_ALLOW_UNINSTALLABLE_HELPER cannot be used when EASYTIER_REQUIRE_DISTRIBUTION_SIGNING=1." >&2
  exit 1
fi

if [[ "$REQUIRE_DISTRIBUTION_SIGNING" == "1" && ( -z "$CODE_SIGN_IDENTITY" || "$CODE_SIGN_IDENTITY" == "-" ) ]]; then
  echo "Release packaging requires EASYTIER_CODESIGN_IDENTITY with a Developer ID Application certificate." >&2
  exit 1
fi

if [[ "$ALLOW_UNINSTALLABLE_HELPER" != "1" && ( -z "$CODE_SIGN_IDENTITY" || "$CODE_SIGN_IDENTITY" == "-" ) ]]; then
  cat >&2 <<EOF
Packaging an installable privileged helper requires a code signing identity.

Install an Apple Development or Developer ID Application certificate, or allow
an ad-hoc app without helper installation by setting
EASYTIER_ALLOW_UNINSTALLABLE_HELPER=1 and EASYTIER_AUTO_CODESIGN_IDENTITY=0.
EOF
  exit 1
fi

if [[ -z "$CLEAN_HELPER_STATE" ]]; then
  CLEAN_HELPER_STATE=0
fi

verify_packaged_app() {
  local app_path="$1"
  local verify_installable_helper=0

  if [[ "$ALLOW_UNINSTALLABLE_HELPER" != "1" ]]; then
    verify_installable_helper=1
  fi

  EASYTIER_VERIFY_INSTALLABLE_HELPER="$verify_installable_helper" \
    "$ROOT_DIR/scripts/verify-app.sh" "$app_path"
}

sign_macho() {
  local identifier="$1"
  local path="$2"
  local entitlements="${3:-}"
  local codesign_args=(--force)

  if [[ "$CODE_SIGN_IDENTITY" != "-" && "$CODE_SIGN_TIMESTAMP" == "1" ]]; then
    codesign_args+=(--timestamp --options runtime)
  elif [[ "$CODE_SIGN_IDENTITY" != "-" ]]; then
    codesign_args+=(--options runtime)
  fi

  codesign_args+=(--sign "$CODE_SIGN_IDENTITY" --identifier "$identifier")

  if [[ -n "$entitlements" ]]; then
    codesign_args+=(--entitlements "$entitlements")
  fi

  codesign "${codesign_args[@]}" "$path"
}

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

git_version() {
  local path="$1"
  local version
  version="$(git -C "$path" describe --tags --always 2>/dev/null || true)"
  [[ -n "$version" ]] || version="unknown"
  if [[ -n "$(git -C "$path" status --short --untracked-files=no 2>/dev/null || true)" ]]; then
    version="$version-dirty"
  fi
  echo "$version"
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

strip_release_macho() {
  local path="$1"
  if [[ "$BUILD_CONFIGURATION" != "release" || "$STRIP_RELEASE_BINARIES" != "1" ]]; then
    return
  fi
  xcrun strip -x "$path"
}

clean_development_helper_state() {
  if [[ "$CLEAN_HELPER_STATE" != "1" ]]; then
    return
  fi

  local candidates=(
    "$ROOT_DIR/.build/AppProducts/EasyTier.app/Contents/MacOS/EasyTierMac"
    "$APP_DIR/Contents/MacOS/EasyTierMac"
    "$EXPORT_APP_DIR/Contents/MacOS/EasyTierMac"
  )

  for binary in "${candidates[@]}"; do
    if [[ -x "$binary" ]]; then
      EASYTIER_SKIP_LEGACY_HELPER_UNINSTALL=1 "$binary" --unregister-helper >/dev/null 2>&1 || true
    fi
  done

  pkill -x EasyTierMac >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    if ! pgrep -x EasyTierMac >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done

  if [[ "$RESET_BTM_STATE" == "1" ]]; then
    echo "Resetting macOS Background Task Management state with sfltool resetbtm." >&2
    echo "This is a global development cleanup for stale SMAppService/LWCR records." >&2
    run_with_timeout 10 sfltool resetbtm >/dev/null 2>&1 || true
  fi
}

cd "$ROOT_DIR"
clean_development_helper_state
if [[ -e "$EXPORT_APP_DIR" && ! -w "$EXPORT_APP_DIR" ]]; then
  echo "Existing export path is not writable: $EXPORT_APP_DIR" >&2
  echo "Remove it with the account that created it, or set EASYTIER_EXPORT_APP_DIR to a writable path." >&2
  exit 1
fi
rm -rf "$EXPORT_APP_DIR"
GUI_COMMIT="$(git_revision "$ROOT_DIR")"
CORE_VERSION="$(git_version "$ROOT_DIR/Vendor/EasyTier")"
CORE_COMMIT="$(git_revision "$ROOT_DIR/Vendor/EasyTier")"
SWIFT_BUILD_ARGS=(--scratch-path "$SWIFT_BUILD_DIR" --configuration "$BUILD_CONFIGURATION")
swift --version >&2
if [[ "$BUILD_CONFIGURATION" == "release" && "$DEAD_STRIP_RELEASE" == "1" ]]; then
  SWIFT_BUILD_ARGS+=(-Xlinker -dead_strip)
  echo "Swift release linker: -dead_strip"
fi
BUILD_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
rm -f \
  "$BUILD_DIR/EasyTierMac" \
  "$BUILD_DIR/EasyTierPrivilegedHelper"

swift build "${SWIFT_BUILD_ARGS[@]}" --product EasyTierMac
swift build "${SWIFT_BUILD_ARGS[@]}" --product EasyTierPrivilegedHelper

BUILD_TIME_UTC="$(date -u -r "$BUILD_DIR/EasyTierMac" +%Y-%m-%dT%H:%M:%SZ)"
BUILD_NUMBER="$(date -u -r "$BUILD_DIR/EasyTierMac" +%Y%m%d%H%M%S)"

rm -rf "$APP_DIR" "$STAGING_DIR"
mkdir -p "$APP_PRODUCTS_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$LAUNCH_DAEMONS_DIR"
cp "$BUILD_DIR/EasyTierMac" "$MACOS_DIR/EasyTierMac"
cp "$BUILD_DIR/EasyTierPrivilegedHelper" "$MACOS_DIR/EasyTierPrivilegedHelper"
strip_release_macho "$MACOS_DIR/EasyTierMac"
strip_release_macho "$MACOS_DIR/EasyTierPrivilegedHelper"
cp "$ROOT_DIR/Assets/easytier-icon.icns" "$RESOURCES_DIR/EasyTier.icns"
cp "$ROOT_DIR/Sources/EasyTierMac/Resources/easytier-icon.png" "$RESOURCES_DIR/easytier-icon.png"

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
    <key>CFBundleIconFile</key>
    <string>EasyTier.icns</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>EasyTier</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>EasyTierBuildTime</key>
    <string>$BUILD_TIME_UTC</string>
    <key>EasyTierGUICommit</key>
    <string>$GUI_COMMIT</string>
    <key>EasyTierCoreTag</key>
    <string>$CORE_VERSION</string>
    <key>EasyTierCoreCommit</key>
    <string>$CORE_COMMIT</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
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
    <false/>
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
sign_macho "$HELPER_IDENTIFIER" "$MACOS_DIR/EasyTierPrivilegedHelper"
clear_finder_info "$STAGING_DIR"
sign_macho "$BUNDLE_IDENTIFIER" "$STAGING_DIR" "$APP_ENTITLEMENTS"
mv "$STAGING_DIR" "$APP_DIR"
xattr -cr "$APP_DIR"
clear_codesign_blocking_xattrs "$APP_DIR"
clear_finder_info "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null
clear_codesign_blocking_xattrs "$APP_DIR"
clear_finder_info "$APP_DIR"

mkdir -p "$(dirname "$EXPORT_APP_DIR")"
ditto --noextattr --norsrc "$APP_DIR" "$EXPORT_APP_DIR"
clear_codesign_blocking_xattrs "$EXPORT_APP_DIR"
clear_finder_info "$EXPORT_APP_DIR"
verify_packaged_app "$EXPORT_APP_DIR"

echo "$EXPORT_APP_DIR"
