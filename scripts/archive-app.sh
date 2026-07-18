#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${EASYTIER_XCODE_PROJECT:-$ROOT_DIR/EasyTier.xcodeproj}"
SCHEME="${EASYTIER_XCODE_SCHEME:-EasyTierMac}"
APP_PRODUCTS_DIR="${EASYTIER_APP_PRODUCTS_DIR:-/tmp/EasyTierAppProducts}"
DERIVED_DATA_DIR="${EASYTIER_XCODE_DERIVED_DATA_DIR:-$APP_PRODUCTS_DIR/DerivedData}"
ARCHIVE_PATH="${EASYTIER_XCODE_ARCHIVE_PATH:-$APP_PRODUCTS_DIR/EasyTier.xcarchive}"
ARCHIVE_APP_PATH="$ARCHIVE_PATH/Products/Applications/EasyTier.app"
EXPORT_APP_DIR="${EASYTIER_EXPORT_APP_DIR:-$HOME/Applications/EasyTier.app}"
BUILD_CONFIGURATION="${EASYTIER_BUILD_CONFIGURATION:-release}"
APP_VERSION="${EASYTIER_APP_VERSION:-}"
BUILD_NUMBER="${EASYTIER_BUILD_NUMBER:-}"
BUILD_TIME_UTC="${EASYTIER_BUILD_TIME:-}"
BUILD_CHANNEL="${EASYTIER_BUILD_CHANNEL:-stable}"
GUI_REVISION="${EASYTIER_GUI_REVISION:-}"
CORE_REVISION="${EASYTIER_CORE_REVISION:-}"
CORE_VERSION="${EASYTIER_CORE_VERSION:-}"
GATEWAY_SOURCE_VERSION="${GATEWAY_VERSION:-}"
CODE_SIGN_IDENTITY="${EASYTIER_CODESIGN_IDENTITY:-}"
CODE_SIGN_KEYCHAIN="${EASYTIER_CODESIGN_KEYCHAIN:-}"
PROVISIONING_PROFILE="${EASYTIER_PROVISIONING_PROFILE:-}"
SPARKLE_FEED_URL="${EASYTIER_SPARKLE_FEED_URL:-https://socoldkiller.github.io/easytier-macos/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${EASYTIER_SPARKLE_PUBLIC_ED_KEY:-}"
CLEAN_HELPER_STATE="${EASYTIER_CLEAN_HELPER_STATE:-0}"
RESET_BTM_STATE="${EASYTIER_RESET_BTM:-0}"
PROFILE_PLIST="$APP_PRODUCTS_DIR/EasyTier.provisioning.plist"
PROFILE_INSTALL_DIR="${EASYTIER_XCODE_PROVISIONING_PROFILE_DIR:-$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles}"
INSTALLED_PROFILE_PATH=""
SIGNING_TEAM_ID=""
PROFILE_SPECIFIER=""

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required."
}

cleanup() {
  if [[ -n "$INSTALLED_PROFILE_PATH" && -f "$INSTALLED_PROFILE_PATH" ]]; then
    rm -f "$INSTALLED_PROFILE_PATH"
  fi
}
trap cleanup EXIT

git_revision() {
  local path="$1"
  local configured_revision="${2:-}"
  local ignore_submodules="${3:-0}"
  local revision status
  revision="$(git -C "$path" rev-parse HEAD 2>/dev/null || true)"
  [[ -n "$revision" ]] || revision="unknown"

  if [[ -n "$configured_revision" ]]; then
    [[ "$configured_revision" =~ ^[0-9a-f]{40}$ ]] \
      || die "Configured source revision must be a full lowercase Git SHA: $configured_revision"
    [[ "$revision" == "$configured_revision" ]] \
      || die "Configured source revision does not match $path: $configured_revision != $revision"
  fi

  if [[ "$ignore_submodules" == "1" ]]; then
    status="$(git -C "$path" status --short --untracked-files=no --ignore-submodules=all 2>/dev/null || true)"
  else
    status="$(git -C "$path" status --short --untracked-files=no 2>/dev/null || true)"
  fi
  if [[ -n "$status" ]]; then
    if [[ -n "$configured_revision" ]]; then
      die "Source tree has tracked changes despite an explicit revision: $path"
    fi
    revision="$revision-dirty"
  fi
  printf '%s\n' "$revision"
}

git_version() {
  local path="$1"
  local version
  version="$(git -C "$path" describe --tags --always 2>/dev/null || true)"
  [[ -n "$version" ]] || version="unknown"
  if [[ -n "$(git -C "$path" status --short --untracked-files=no 2>/dev/null || true)" ]]; then
    version="$version-dirty"
  fi
  printf '%s\n' "$version"
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

clean_development_helper_state() {
  [[ "$CLEAN_HELPER_STATE" == "1" ]] || return 0

  local binary
  for binary in \
    "$ARCHIVE_APP_PATH/Contents/MacOS/EasyTierMac" \
    "$EXPORT_APP_DIR/Contents/MacOS/EasyTierMac"; do
    if [[ -x "$binary" ]]; then
      EASYTIER_SKIP_LEGACY_HELPER_UNINSTALL=1 "$binary" --unregister-helper >/dev/null 2>&1 || true
    fi
  done

  pkill -x EasyTierMac >/dev/null 2>&1 || true
  if [[ "$RESET_BTM_STATE" == "1" ]]; then
    printf '%s\n' "Resetting macOS Background Task Management state with sfltool resetbtm." >&2
    run_with_timeout 10 sfltool resetbtm >/dev/null 2>&1 || true
  fi
}

configure_version() {
  if [[ -z "$APP_VERSION" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
    APP_VERSION="${GITHUB_REF_NAME:-}"
  fi
  APP_VERSION="${APP_VERSION#v}"
  APP_VERSION="${APP_VERSION:-0.1.0}"
  [[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] \
    || die "EASYTIER_APP_VERSION must be a numeric version like 1.4.0; got '$APP_VERSION'."

  if [[ -z "$BUILD_NUMBER" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
    local tag_commit_epoch
    tag_commit_epoch="$(git -C "$ROOT_DIR" show -s --format=%ct "${GITHUB_REF_NAME:-HEAD}")"
    BUILD_NUMBER="$(date -u -r "$tag_commit_epoch" +%Y%m%d%H%M%S)"
  fi
  BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
  [[ "$BUILD_NUMBER" =~ ^[0-9]{14}$ ]] \
    || die "EASYTIER_BUILD_NUMBER must be a 14-digit UTC timestamp; got '$BUILD_NUMBER'."

  BUILD_TIME_UTC="${BUILD_TIME_UTC:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  [[ "$BUILD_TIME_UTC" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || die "EASYTIER_BUILD_TIME must be an ISO-8601 UTC timestamp; got '$BUILD_TIME_UTC'."
  [[ "$BUILD_CHANNEL" == "stable" || "$BUILD_CHANNEL" == "nightly" ]] \
    || die "EASYTIER_BUILD_CHANNEL must be stable or nightly; got '$BUILD_CHANNEL'."
}

configure_source_packages_dir() {
  local swift_build_dir="${EASYTIER_SWIFT_BUILD_DIR:-}"
  if [[ -n "${EASYTIER_XCODE_SOURCE_PACKAGES_DIR:-}" ]]; then
    SOURCE_PACKAGES_DIR="$EASYTIER_XCODE_SOURCE_PACKAGES_DIR"
  elif [[ -n "$swift_build_dir" && -d "$swift_build_dir/checkouts" ]]; then
    SOURCE_PACKAGES_DIR="$swift_build_dir"
  elif [[ -d "$ROOT_DIR/.build/AppProducts/SwiftBuild/checkouts" ]]; then
    SOURCE_PACKAGES_DIR="$ROOT_DIR/.build/AppProducts/SwiftBuild"
  elif [[ -d "$ROOT_DIR/.build/checkouts" ]]; then
    SOURCE_PACKAGES_DIR="$ROOT_DIR/.build"
  else
    SOURCE_PACKAGES_DIR="$APP_PRODUCTS_DIR/SourcePackages"
  fi
}

validate_signing_inputs() {
  [[ "$CODE_SIGN_IDENTITY" == "Developer ID Application:"* ]] \
    || die "EASYTIER_CODESIGN_IDENTITY must name a Developer ID Application identity."
  if [[ "$CODE_SIGN_IDENTITY" =~ \(([A-Z0-9]{10})\)$ ]]; then
    SIGNING_TEAM_ID="${BASH_REMATCH[1]}"
  else
    die "Could not extract the Team ID from EASYTIER_CODESIGN_IDENTITY: $CODE_SIGN_IDENTITY"
  fi

  if [[ -n "$CODE_SIGN_KEYCHAIN" ]]; then
    [[ -f "$CODE_SIGN_KEYCHAIN" ]] || die "EASYTIER_CODESIGN_KEYCHAIN does not exist: $CODE_SIGN_KEYCHAIN"
    security find-identity -v -p codesigning "$CODE_SIGN_KEYCHAIN" \
      | grep -F "\"$CODE_SIGN_IDENTITY\"" >/dev/null \
      || die "The signing identity is not available in $CODE_SIGN_KEYCHAIN: $CODE_SIGN_IDENTITY"
  else
    security find-identity -v -p codesigning \
      | grep -F "\"$CODE_SIGN_IDENTITY\"" >/dev/null \
      || die "The signing identity is not available in the Keychain search list: $CODE_SIGN_IDENTITY"
  fi

  [[ -f "$PROVISIONING_PROFILE" ]] \
    || die "Set EASYTIER_PROVISIONING_PROFILE to the Developer ID profile for com.kkrainbow.easytier.mac."
  [[ "$SPARKLE_FEED_URL" =~ ^https:// ]] \
    || die "EASYTIER_SPARKLE_FEED_URL must use HTTPS; got '$SPARKLE_FEED_URL'."
  [[ "$SPARKLE_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    || die "EASYTIER_SPARKLE_PUBLIC_ED_KEY must contain the production Sparkle Ed25519 public key."
}

prepare_provisioning_profile() {
  local expected_identifier wildcard_group profile_team profile_identifier profile_groups
  local expiration expiration_epoch now_epoch profile_uuid

  mkdir -p "$APP_PRODUCTS_DIR"
  security cms -D -i "$PROVISIONING_PROFILE" -o "$PROFILE_PLIST"
  profile_team="$(plutil -extract TeamIdentifier.0 raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  expected_identifier="$SIGNING_TEAM_ID.com.kkrainbow.easytier.mac"
  wildcard_group="$SIGNING_TEAM_ID.*"
  profile_identifier="$(
    plutil -extract Entitlements.application-identifier raw -o - "$PROFILE_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST" 2>/dev/null \
      || true
  )"
  profile_groups="$(plutil -extract Entitlements.keychain-access-groups json -o - "$PROFILE_PLIST" 2>/dev/null || true)"

  [[ "$profile_team" == "$SIGNING_TEAM_ID" ]] \
    || die "Provisioning profile Team ID mismatch: profile=$profile_team signing=$SIGNING_TEAM_ID"
  [[ "$profile_identifier" == "$expected_identifier" ]] \
    || die "Provisioning profile application identifier mismatch: expected $expected_identifier, got $profile_identifier"
  [[ "$profile_groups" == *"\"$expected_identifier\""* || "$profile_groups" == *"\"$wildcard_group\""* ]] \
    || die "Provisioning profile does not authorize Keychain access group $expected_identifier."

  expiration="$(plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  expiration_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expiration" '+%s' 2>/dev/null || true)"
  now_epoch="$(date -u '+%s')"
  [[ -n "$expiration_epoch" && "$expiration_epoch" -gt "$now_epoch" ]] \
    || die "Provisioning profile is expired or has an unreadable ExpirationDate: $expiration"

  profile_uuid="$(plutil -extract UUID raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  [[ -n "$profile_uuid" ]] || die "Provisioning profile is missing its UUID."
  PROFILE_SPECIFIER="$profile_uuid"

  mkdir -p "$PROFILE_INSTALL_DIR"
  local destination="$PROFILE_INSTALL_DIR/$profile_uuid.provisionprofile"
  if [[ -f "$destination" ]]; then
    cmp -s "$PROVISIONING_PROFILE" "$destination" \
      || die "A different provisioning profile is already installed with UUID $profile_uuid."
  else
    cp "$PROVISIONING_PROFILE" "$destination"
    chmod 600 "$destination"
    INSTALLED_PROFILE_PATH="$destination"
  fi
}

archive_app() {
  local xcode_configuration="Release"
  [[ "$BUILD_CONFIGURATION" == "debug" ]] && xcode_configuration="Debug"
  [[ "$BUILD_CONFIGURATION" == "debug" || "$BUILD_CONFIGURATION" == "release" ]] \
    || die "EASYTIER_BUILD_CONFIGURATION must be 'debug' or 'release'."

  local gui_commit core_version core_commit gateway_version signing_flags=""
  gui_commit="$(git_revision "$ROOT_DIR" "$GUI_REVISION" 1)"
  core_version="${CORE_VERSION:-$(git_version "$ROOT_DIR/Vendor/EasyTier")}"
  core_commit="$(git_revision "$ROOT_DIR/Vendor/EasyTier" "$CORE_REVISION")"
  gateway_version="${GATEWAY_SOURCE_VERSION:-$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$ROOT_DIR/Rust/EasyTierGuiFFI/Cargo.toml" | head -n 1)}"
  [[ -n "$gateway_version" ]] || die "Could not determine the Gateway helper version."
  if [[ -n "$CODE_SIGN_KEYCHAIN" ]]; then
    signing_flags="--keychain $CODE_SIGN_KEYCHAIN"
  fi

  rm -rf "$ARCHIVE_PATH" "$DERIVED_DATA_DIR"
  mkdir -p "$(dirname "$ARCHIVE_PATH")" "$SOURCE_PACKAGES_DIR"

  local args=(
    -project "$PROJECT_PATH"
    -scheme "$SCHEME"
    -configuration "$xcode_configuration"
    -destination "generic/platform=macOS"
    -derivedDataPath "$DERIVED_DATA_DIR"
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR"
    -disableAutomaticPackageResolution
    -onlyUsePackageVersionsFromResolvedFile
    -archivePath "$ARCHIVE_PATH"
    "MARKETING_VERSION=$APP_VERSION"
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
    "EASYTIER_BUILD_TIME=$BUILD_TIME_UTC"
    "EASYTIER_BUILD_CHANNEL=$BUILD_CHANNEL"
    "EASYTIER_GUI_COMMIT=$gui_commit"
    "GATEWAY_BUILD_TIME=$BUILD_TIME_UTC"
    "GATEWAY_COMMIT=$gui_commit"
    "GATEWAY_VERSION=$gateway_version"
    "EASYTIER_CORE_TAG=$core_version"
    "EASYTIER_CORE_COMMIT=$core_commit"
    "EASYTIER_SPARKLE_FEED_URL=$SPARKLE_FEED_URL"
    "EASYTIER_SPARKLE_PUBLIC_ED_KEY=$SPARKLE_PUBLIC_ED_KEY"
    "EASYTIER_DEVELOPMENT_TEAM=$SIGNING_TEAM_ID"
    "EASYTIER_CODE_SIGN_ENTITLEMENTS=Packaging/EasyTierMac.entitlements"
    "EASYTIER_CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY"
    "EASYTIER_CODE_SIGN_KEYCHAIN=$CODE_SIGN_KEYCHAIN"
    "EASYTIER_PROVISIONING_PROFILE_SPECIFIER=$PROFILE_SPECIFIER"
    "EASYTIER_APPLICATION_IDENTIFIER=$SIGNING_TEAM_ID.com.kkrainbow.easytier.mac"
    "EASYTIER_OTHER_CODE_SIGN_FLAGS=$signing_flags"
  )
  [[ "${EASYTIER_XCODE_QUIET:-1}" == "1" ]] && args=(-quiet "${args[@]}")

  xcodebuild "${args[@]}" archive
  [[ -d "$ARCHIVE_APP_PATH" ]] || die "Xcode archive did not contain EasyTier.app: $ARCHIVE_APP_PATH"
}

export_and_verify_app() {
  if [[ -e "$EXPORT_APP_DIR" && ! -w "$EXPORT_APP_DIR" ]]; then
    die "Existing export path is not writable: $EXPORT_APP_DIR"
  fi
  rm -rf "$EXPORT_APP_DIR"
  mkdir -p "$(dirname "$EXPORT_APP_DIR")"
  ditto --noextattr --norsrc "$ARCHIVE_APP_PATH" "$EXPORT_APP_DIR"
  xattr -cr "$EXPORT_APP_DIR"
  "$ROOT_DIR/scripts/verify-app.sh" "$EXPORT_APP_DIR"
  printf '%s\n' "$EXPORT_APP_DIR"
}

for command_name in codesign ditto git grep plutil security xattr xcodebuild; do
  require_command "$command_name"
done
[[ -d "$PROJECT_PATH" ]] || die "Xcode project not found: $PROJECT_PATH"

cd "$ROOT_DIR"
configure_version
configure_source_packages_dir
validate_signing_inputs
prepare_provisioning_profile
clean_development_helper_state
archive_app
export_and_verify_app
