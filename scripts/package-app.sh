#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PRODUCTS_DIR="${EASYTIER_APP_PRODUCTS_DIR:-/tmp/EasyTierAppProducts}"
APP_DIR="$APP_PRODUCTS_DIR/EasyTier.app"
STAGING_DIR="$APP_PRODUCTS_DIR/EasyTier.staging"
EXPORT_APP_DIR="${EASYTIER_EXPORT_APP_DIR:-$HOME/Applications/EasyTier.app}"
EXPORT_CODESIGN_CERT_PATH="${EASYTIER_EXPORT_CODESIGN_CERT_PATH:-}"
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
CODE_SIGN_KEYCHAIN="${EASYTIER_CODESIGN_KEYCHAIN:-}"
REQUIRE_DISTRIBUTION_SIGNING="${EASYTIER_REQUIRE_DISTRIBUTION_SIGNING:-0}"
CODE_SIGN_TIMESTAMP="${EASYTIER_CODESIGN_TIMESTAMP:-1}"
CLEAN_HELPER_STATE="${EASYTIER_CLEAN_HELPER_STATE:-}"
ALLOW_UNINSTALLABLE_HELPER="${EASYTIER_ALLOW_UNINSTALLABLE_HELPER:-0}"
AUTO_CODESIGN_IDENTITY="${EASYTIER_AUTO_CODESIGN_IDENTITY:-1}"
RESET_BTM_STATE="${EASYTIER_RESET_BTM:-0}"
REQUIRE_TEAM_ID="${EASYTIER_REQUIRE_TEAM_ID:-$REQUIRE_DISTRIBUTION_SIGNING}"
USE_LOCAL_CODESIGN="${EASYTIER_USE_LOCAL_CODESIGN:-1}"
LOCAL_CODESIGN_IDENTITY="${EASYTIER_LOCAL_CODESIGN_IDENTITY:-EasyTierLocalCodeSigning}"
LOCAL_SIGNING_DIR="${EASYTIER_LOCAL_SIGNING_DIR:-$HOME/Library/Application Support/easytier/LocalSigning}"
LOCAL_SIGNING_KEYCHAIN="$LOCAL_SIGNING_DIR/easytier-local-signing.keychain-db"
LOCAL_SIGNING_PASSWORD_FILE="$LOCAL_SIGNING_DIR/keychain-password.txt"
SECURITY_COMMAND_TIMEOUT="${EASYTIER_SECURITY_TIMEOUT:-120}"
USING_LOCAL_CODESIGN=0
TRUST_LOCAL_CODESIGN_CERT="${EASYTIER_TRUST_LOCAL_CODESIGN_CERT:-}"
CLEAN_LOCAL_CODESIGN_KEYCHAIN="${EASYTIER_CLEAN_LOCAL_CODESIGN_KEYCHAIN:-}"

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

if [[ -z "$TRUST_LOCAL_CODESIGN_CERT" ]]; then
  if [[ "${GITHUB_ACTIONS:-}" == "true" || "${CI:-}" == "true" ]]; then
    TRUST_LOCAL_CODESIGN_CERT=0
  else
    TRUST_LOCAL_CODESIGN_CERT=1
  fi
fi

if [[ -z "$CLEAN_LOCAL_CODESIGN_KEYCHAIN" ]]; then
  if [[ -n "${RUNNER_TEMP:-}" && "$LOCAL_SIGNING_DIR" == "$RUNNER_TEMP"/* ]]; then
    CLEAN_LOCAL_CODESIGN_KEYCHAIN=1
  else
    CLEAN_LOCAL_CODESIGN_KEYCHAIN=0
  fi
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

security_step() {
  local label="$1"
  local log_file
  shift

  echo "$label." >&2
  log_file="$(mktemp "${TMPDIR:-/tmp}/easytier-security.XXXXXX")"
  set +e
  run_with_timeout "$SECURITY_COMMAND_TIMEOUT" "$@" >"$log_file" 2>&1
  local status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    echo "$label failed with exit code $status." >&2
    cat "$log_file" >&2
    rm -f "$log_file"
    return "$status"
  fi

  if [[ "${EASYTIER_VERBOSE_SECURITY:-0}" == "1" ]]; then
    cat "$log_file" >&2
  fi
  rm -f "$log_file"
}

add_local_keychain_to_search_list() {
  local keychain
  local keychains=()

  while IFS= read -r keychain; do
    keychain="${keychain#\"}"
    keychain="${keychain%\"}"
    [[ -n "$keychain" ]] || continue
    [[ -e "$keychain" ]] || continue
    [[ "$keychain" == "$LOCAL_SIGNING_KEYCHAIN" ]] && continue
    keychains+=("$keychain")
  done < <(security list-keychains -d user 2>/dev/null | sed 's/^ *//')

  security_step "Adding local signing keychain to user search list" \
    security list-keychains -d user -s "$LOCAL_SIGNING_KEYCHAIN" "${keychains[@]}"
}

cleanup_local_codesigning_keychain() {
  [[ "$CLEAN_LOCAL_CODESIGN_KEYCHAIN" == "1" ]] || return 0

  local keychain
  local keychains=()

  while IFS= read -r keychain; do
    keychain="${keychain#\"}"
    keychain="${keychain%\"}"
    [[ -n "$keychain" ]] || continue
    [[ "$keychain" == "$LOCAL_SIGNING_KEYCHAIN" ]] && continue
    [[ -e "$keychain" ]] || continue
    keychains+=("$keychain")
  done < <(security list-keychains -d user 2>/dev/null | sed 's/^ *//')

  security list-keychains -d user -s "${keychains[@]}" >/dev/null 2>&1 || true
  security delete-keychain "$LOCAL_SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$LOCAL_SIGNING_DIR"
}

trap cleanup_local_codesigning_keychain EXIT

local_codesign_identity_is_valid() {
  [[ -f "$LOCAL_SIGNING_KEYCHAIN" ]] || return 1
  security find-certificate -c "$LOCAL_CODESIGN_IDENTITY" "$LOCAL_SIGNING_KEYCHAIN" >/dev/null 2>&1
}

local_codesign_identity_hash() {
  local identity_hash
  identity_hash="$(security find-identity -v -p codesigning "$LOCAL_SIGNING_KEYCHAIN" 2>/dev/null \
    | awk -v name="$LOCAL_CODESIGN_IDENTITY" '$0 ~ "\\\"" name "\\\"" { print $2; exit }')"
  if [[ -n "$identity_hash" ]]; then
    echo "$identity_hash"
    return
  fi
  security find-certificate -c "$LOCAL_CODESIGN_IDENTITY" -Z "$LOCAL_SIGNING_KEYCHAIN" 2>/dev/null \
    | awk '/SHA-1 hash:/ { print $3; exit }'
}

unlock_local_codesigning_keychain() {
  [[ -f "$LOCAL_SIGNING_PASSWORD_FILE" ]] || return 1
  local password
  password="$(cat "$LOCAL_SIGNING_PASSWORD_FILE")"
  security_step "Unlocking local signing keychain" \
    security unlock-keychain -p "$password" "$LOCAL_SIGNING_KEYCHAIN" || return $?
  security_step "Allowing codesign to use local signing key" \
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$LOCAL_SIGNING_KEYCHAIN" || return $?
}

create_local_codesigning_identity() {
  local password key_path cert_path p12_path openssl_config

  rm -rf "$LOCAL_SIGNING_DIR"
  mkdir -p "$LOCAL_SIGNING_DIR"
  chmod 700 "$LOCAL_SIGNING_DIR"

  password="$(uuidgen)-$(uuidgen)"
  key_path="$LOCAL_SIGNING_DIR/easytier-local.key"
  cert_path="$LOCAL_SIGNING_DIR/easytier-local.crt"
  p12_path="$LOCAL_SIGNING_DIR/easytier-local.p12"
  openssl_config="$LOCAL_SIGNING_DIR/openssl.cnf"

  printf '%s' "$password" > "$LOCAL_SIGNING_PASSWORD_FILE"
  chmod 600 "$LOCAL_SIGNING_PASSWORD_FILE"

  cat > "$openssl_config" <<EOF
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[ dn ]
CN = $LOCAL_CODESIGN_IDENTITY
O = EasyTier Local Development

[ v3_req ]
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, keyCertSign
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

  echo "Generating local self-signed code signing certificate." >&2
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$key_path" \
    -out "$cert_path" \
    -config "$openssl_config" >/dev/null

  local pkcs12_args=(pkcs12 -export)
  if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
    pkcs12_args+=(-legacy)
  fi
  pkcs12_args+=(
    -inkey "$key_path"
    -in "$cert_path"
    -out "$p12_path"
    -passout pass:"$password"
    -name "$LOCAL_CODESIGN_IDENTITY"
  )
  echo "Exporting local code signing identity." >&2
  openssl "${pkcs12_args[@]}" >/dev/null

  security_step "Creating local signing keychain" \
    security create-keychain -p "$password" "$LOCAL_SIGNING_KEYCHAIN"
  add_local_keychain_to_search_list
  security_step "Configuring local signing keychain timeout" \
    security set-keychain-settings -lut 21600 "$LOCAL_SIGNING_KEYCHAIN"
  security_step "Unlocking local signing keychain" \
    security unlock-keychain -p "$password" "$LOCAL_SIGNING_KEYCHAIN"
  security_step "Importing local code signing identity" \
    security import "$p12_path" -k "$LOCAL_SIGNING_KEYCHAIN" -P "$password" -A -T /usr/bin/codesign
  if [[ "$TRUST_LOCAL_CODESIGN_CERT" == "1" ]]; then
    security_step "Trusting local code signing certificate" \
      security add-trusted-cert -r trustRoot -p codeSign -k "$LOCAL_SIGNING_KEYCHAIN" "$cert_path"
  else
    echo "Skipping local code signing certificate trust in CI." >&2
  fi
  security_step "Allowing codesign to use local signing key" \
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$LOCAL_SIGNING_KEYCHAIN"
}

use_local_codesigning_identity() {
  local identity_hash

  if ! unlock_local_codesigning_keychain || ! local_codesign_identity_is_valid; then
    echo "Creating local EasyTier development code signing identity: $LOCAL_CODESIGN_IDENTITY" >&2
    create_local_codesigning_identity
  fi

  add_local_keychain_to_search_list
  unlock_local_codesigning_keychain
  if ! local_codesign_identity_is_valid; then
    echo "Local code signing identity is not valid: $LOCAL_CODESIGN_IDENTITY" >&2
    exit 1
  fi

  identity_hash="$(local_codesign_identity_hash)"
  if [[ -z "$identity_hash" ]]; then
    echo "Could not resolve local code signing identity hash: $LOCAL_CODESIGN_IDENTITY" >&2
    exit 1
  fi

  CODE_SIGN_IDENTITY="$identity_hash"
  CODE_SIGN_KEYCHAIN="$LOCAL_SIGNING_KEYCHAIN"
  CODE_SIGN_TIMESTAMP=0
  USING_LOCAL_CODESIGN=1
  echo "Using local development code signing identity: $LOCAL_CODESIGN_IDENTITY ($CODE_SIGN_IDENTITY)" >&2
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
  elif [[ "$ALLOW_UNINSTALLABLE_HELPER" != "1" && "$USE_LOCAL_CODESIGN" == "1" && "$REQUIRE_DISTRIBUTION_SIGNING" != "1" ]]; then
    use_local_codesigning_identity
  fi
fi

if [[ "$CODE_SIGN_IDENTITY" == "$LOCAL_CODESIGN_IDENTITY" ]]; then
  use_local_codesigning_identity
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
this script to use a local development identity by leaving
EASYTIER_USE_LOCAL_CODESIGN=1.

For CI/symbol verification only, set EASYTIER_ALLOW_UNINSTALLABLE_HELPER=1.
EOF
  exit 1
fi

if [[ -z "$CLEAN_HELPER_STATE" ]]; then
  CLEAN_HELPER_STATE=0
fi

signature_field() {
  local path="$1"
  local field="$2"
  codesign -dv --verbose=4 "$path" 2>&1 | sed -n "s/^$field=//p" | tail -n 1
}

validate_installable_helper_signature() {
  local app_path="$1"
  local helper_path="$app_path/Contents/MacOS/EasyTierPrivilegedHelper"
  local app_team helper_team

  if [[ "$ALLOW_UNINSTALLABLE_HELPER" != "1" ]]; then
    if codesign -dv --verbose=4 "$app_path" 2>&1 | grep -q '^Signature=adhoc'; then
      echo "Packaged EasyTier.app is ad-hoc signed and cannot install a privileged helper." >&2
      exit 1
    fi
    if codesign -dv --verbose=4 "$helper_path" 2>&1 | grep -q '^Signature=adhoc'; then
      echo "Packaged privileged helper is ad-hoc signed and cannot be launched by SMAppService." >&2
      exit 1
    fi
  fi

  if [[ "$REQUIRE_TEAM_ID" != "1" ]]; then
    return
  fi

  app_team="$(signature_field "$app_path" TeamIdentifier)"
  helper_team="$(signature_field "$helper_path" TeamIdentifier)"

  if [[ -z "$app_team" || "$app_team" == "not set" || -z "$helper_team" || "$helper_team" == "not set" ]]; then
    cat >&2 <<EOF
Packaged EasyTier.app is signed, but app/helper do not have an Apple Team ID.

Developer ID release builds must sign the app and privileged helper with an Apple-issued identity from the same team.

App TeamIdentifier: ${app_team:-missing}
Helper TeamIdentifier: ${helper_team:-missing}
EOF
    exit 1
  fi

  if [[ "$app_team" != "$helper_team" ]]; then
    cat >&2 <<EOF
Packaged EasyTier.app has mismatched app/helper Team IDs.

App TeamIdentifier: $app_team
Helper TeamIdentifier: $helper_team

Sign both binaries with the same Apple team so SMAppService can launch the privileged helper.
EOF
    exit 1
  fi
}

verify_exported_app_signature() {
  local output

  if output="$(codesign --verify --deep --strict --verbose=2 "$EXPORT_APP_DIR" 2>&1)"; then
    return 0
  fi

  if [[ "$output" == *"resource fork, Finder information, or similar detritus not allowed"* \
    && "$output" == *"Disallowed xattr"* ]]; then
    cat >&2 <<EOF
Warning: exported EasyTier.app gained File Provider/Finder metadata after export:
$output

The signed staging app was already verified successfully before export. Move the
app outside synced folders such as Documents/iCloud, or build with
ARTIFACTS_DIR=/tmp/easytier-artifacts, if macOS refuses to launch this debug app.
EOF
    return 0
  fi

  printf '%s\n' "$output" >&2
  return 1
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

  if [[ -n "$CODE_SIGN_KEYCHAIN" ]]; then
    codesign_args+=(--keychain "$CODE_SIGN_KEYCHAIN")
  fi

  codesign_args+=(--sign "$CODE_SIGN_IDENTITY" --identifier "$identifier")

  if [[ -n "$entitlements" ]]; then
    codesign_args+=(--entitlements "$entitlements")
  fi

  codesign "${codesign_args[@]}" "$path"
}

export_codesigning_certificate_if_requested() {
  if [[ -z "$EXPORT_CODESIGN_CERT_PATH" ]]; then
    return
  fi
  if [[ "$USING_LOCAL_CODESIGN" != "1" ]]; then
    echo "EASYTIER_EXPORT_CODESIGN_CERT_PATH is only supported for the local self-signed development identity." >&2
    return
  fi
  local cert_path="$LOCAL_SIGNING_DIR/easytier-local.crt"
  [[ -f "$cert_path" ]] || return
  mkdir -p "$(dirname "$EXPORT_CODESIGN_CERT_PATH")"
  openssl x509 -in "$cert_path" -outform der -out "$EXPORT_CODESIGN_CERT_PATH"
  echo "Exported local code signing certificate: $EXPORT_CODESIGN_CERT_PATH" >&2
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
      "$binary" --unregister-helper >/dev/null 2>&1 || true
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
rm -rf "$ROOT_DIR/.build/AppProducts/EasyTier.app" "$ROOT_DIR/.build/AppProducts/EasyTier.staging"
GUI_COMMIT="$(git_revision "$ROOT_DIR")"
CORE_TAG="$(git_exact_tag "$ROOT_DIR/Vendor/EasyTier")"
CORE_COMMIT="$(git_revision "$ROOT_DIR/Vendor/EasyTier")"
SWIFT_BUILD_ARGS=(--configuration "$BUILD_CONFIGURATION")
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
cp "$ROOT_DIR/Sources/EasyTierMac/Resources/MenuBarConnectionGlyphTemplate.png" "$RESOURCES_DIR/MenuBarConnectionGlyphTemplate.png"
cp "$ROOT_DIR/Sources/EasyTierMac/Resources/MenuBarConnectionGlyphTemplate@2x.png" "$RESOURCES_DIR/MenuBarConnectionGlyphTemplate@2x.png"
cp "$ROOT_DIR/Sources/EasyTierMac/Resources/MenuBarConnectionGlyphTemplate@3x.png" "$RESOURCES_DIR/MenuBarConnectionGlyphTemplate@3x.png"

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
sign_macho "$HELPER_IDENTIFIER" "$MACOS_DIR/EasyTierPrivilegedHelper"
clear_finder_info "$STAGING_DIR"
sign_macho "$BUNDLE_IDENTIFIER" "$STAGING_DIR" "$APP_ENTITLEMENTS"
mv "$STAGING_DIR" "$APP_DIR"
xattr -cr "$APP_DIR"
clear_codesign_blocking_xattrs "$APP_DIR"
clear_finder_info "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null
validate_installable_helper_signature "$APP_DIR"
clear_codesign_blocking_xattrs "$APP_DIR"
clear_finder_info "$APP_DIR"

rm -rf "$EXPORT_APP_DIR"
mkdir -p "$(dirname "$EXPORT_APP_DIR")"
ditto --noextattr --norsrc "$APP_DIR" "$EXPORT_APP_DIR"
clear_codesign_blocking_xattrs "$EXPORT_APP_DIR"
clear_finder_info "$EXPORT_APP_DIR"
verify_exported_app_signature
validate_installable_helper_signature "$EXPORT_APP_DIR"
export_codesigning_certificate_if_requested

echo "$EXPORT_APP_DIR"
