#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
GUI_BINARY=""
HELPER_BINARY=""
VERIFY_INSTALLABLE_HELPER="${EASYTIER_VERIFY_INSTALLABLE_HELPER:-0}"
REQUIRED_FFI_SYMBOLS=(
  parse_config
  run_network_instance
  retain_network_instance
  stop_network_instance
  collect_network_infos
  free_string
  connect_rpc_client
  call_json_rpc
  configure_rpc_portal
)

if [[ -z "$APP_PATH" ]]; then
  echo "Usage: scripts/verify-app.sh /path/to/EasyTier.app" >&2
  exit 2
fi

fail() {
  echo "$1" >&2
  exit 1
}

archs_for() {
  local path="$1"
  local archs
  archs="$(lipo -archs "$path" 2>/dev/null || true)"
  if [[ -n "$archs" ]]; then
    echo "$archs"
    return
  fi
  file "$path" | sed -n 's/.*Mach-O .* \([^ ]*\)$/\1/p'
}

has_symbol() {
  local path="$1"
  local symbol="$2"
  local archs="$3"

  for arch in $archs; do
    if (nm -arch "$arch" "$path" 2>/dev/null || true) | grep -F "_$symbol" >/dev/null; then
      return 0
    fi
  done
  return 1
}

signature_field() {
  local path="$1"
  local field="$2"
  codesign -dv --verbose=4 "$path" 2>&1 | sed -n "s/^$field=//p" | tail -n 1
}

verify_installable_helper_signature() {
  if [[ "$VERIFY_INSTALLABLE_HELPER" != "1" ]]; then
    return
  fi

  local app_team helper_team
  app_team="$(signature_field "$APP_PATH" TeamIdentifier)"
  helper_team="$(signature_field "$HELPER_BINARY" TeamIdentifier)"

  [[ -n "$app_team" && "$app_team" != "not set" ]] || fail "Installable helper verification requires an Apple Team ID on EasyTier.app."
  [[ -n "$helper_team" && "$helper_team" != "not set" ]] || fail "Installable helper verification requires an Apple Team ID on EasyTierPrivilegedHelper."
  [[ "$app_team" == "$helper_team" ]] || fail "App/helper TeamIdentifier mismatch: app=$app_team helper=$helper_team"

  echo "Installable helper signing check passed with TeamIdentifier $app_team."
}

verify_app_bundle() {
  [[ -d "$APP_PATH" ]] || fail "Packaged app not found: $APP_PATH"

  GUI_BINARY="$APP_PATH/Contents/MacOS/EasyTierMac"
  HELPER_BINARY="$APP_PATH/Contents/MacOS/EasyTierPrivilegedHelper"
  local launch_daemon="$APP_PATH/Contents/Library/LaunchDaemons/com.kkrainbow.easytier.mac.helper.plist"

  [[ -x "$GUI_BINARY" ]] || fail "Missing or non-executable GUI binary: $GUI_BINARY"
  [[ -x "$HELPER_BINARY" ]] || fail "Missing or non-executable privileged helper: $HELPER_BINARY"
  [[ -e "$launch_daemon" ]] || fail "Missing LaunchDaemon plist: $launch_daemon"
  [[ ! -e "$APP_PATH/Contents/MacOS/EasyTierValidator" ]] || fail "Packaged app must not include the removed EasyTierValidator binary."

  local bundle_version
  bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
  [[ "$bundle_version" != "1" ]] || fail "Packaged app must use a fresh CFBundleVersion, not the static value 1."

  local bundle_icon
  bundle_icon="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP_PATH/Contents/Info.plist")"
  [[ "$bundle_icon" == "EasyTier.icns" ]] || fail "Packaged app must use the official EasyTier dock icon: $bundle_icon"
  [[ -f "$APP_PATH/Contents/Resources/$bundle_icon" ]] || fail "Missing dock icon resource: Contents/Resources/$bundle_icon"
  [[ -f "$APP_PATH/Contents/Resources/easytier-icon.png" ]] || fail "Missing About icon resource: Contents/Resources/easytier-icon.png"

  local build_time
  build_time="$(/usr/libexec/PlistBuddy -c 'Print :EasyTierBuildTime' "$APP_PATH/Contents/Info.plist")" || fail "Packaged app must include EasyTierBuildTime."
  [[ "$build_time" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail "EasyTierBuildTime must be an ISO-8601 UTC timestamp: $build_time"

  local compact_build_time
  compact_build_time="$(printf '%s' "$build_time" | tr -d ':TZ-')"
  [[ "$bundle_version" == "$compact_build_time" ]] || fail "CFBundleVersion must match EasyTierBuildTime: $bundle_version != $compact_build_time"

  local helper_identifier
  helper_identifier="$(codesign -dv --verbose=4 "$HELPER_BINARY" 2>&1 | sed -n 's/^Identifier=//p')"
  [[ "$helper_identifier" == "com.kkrainbow.easytier.mac.helper" ]] || fail "Unexpected helper code signature identifier: $helper_identifier"

  local helper_info_plist
  helper_info_plist="$(codesign -dv --verbose=4 "$HELPER_BINARY" 2>&1 | sed -n '/^Info.plist/p')"
  [[ -n "$helper_info_plist" && "$helper_info_plist" != *"not bound"* ]] || fail "Privileged helper must embed an Info.plist so SMAppService can identify its bundle."

  local helper_bundle_identifier
  helper_bundle_identifier="$(sfltool csinfo "$HELPER_BINARY" 2>/dev/null | sed -n 's/^Bundle Identifier: //p')"
  [[ "$helper_bundle_identifier" == "com.kkrainbow.easytier.mac.helper" ]] || fail "Unexpected helper bundle identifier: $helper_bundle_identifier"

  codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null
  verify_installable_helper_signature
}

verify_binary_symbols() {
  local gui_archs helper_archs
  gui_archs="$(archs_for "$GUI_BINARY")"
  helper_archs="$(archs_for "$HELPER_BINARY")"
  [[ -n "$gui_archs" ]] || fail "Could not determine architectures for $GUI_BINARY."
  [[ -n "$helper_archs" ]] || fail "Could not determine architectures for $HELPER_BINARY."

  for symbol in "${REQUIRED_FFI_SYMBOLS[@]}"; do
    has_symbol "$GUI_BINARY" "$symbol" "$gui_archs" || fail "EasyTierMac must contain EasyTier FFI symbol: $symbol"
    has_symbol "$HELPER_BINARY" "$symbol" "$helper_archs" || fail "EasyTierPrivilegedHelper must contain EasyTier FFI symbol: $symbol"
  done

  echo "Binary symbol checks passed: both GUI and helper contain EasyTier FFI."
}

verify_app_bundle
verify_binary_symbols

echo "Packaged app contains GUI, privileged helper, LaunchDaemon plist, and the expected FFI linkage split."
