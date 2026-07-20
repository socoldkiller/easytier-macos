#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
GUI_BINARY=""
HELPER_BINARY=""
GATEWAY_HELPER_BINARY=""
SPARKLE_FRAMEWORK=""
REQUIRED_FFI_SYMBOLS=(
  parse_config
  run_network_instance
  retain_network_instance
  stop_network_instance
  collect_network_infos
  connect_rpc_client
  call_json_rpc
  configure_rpc_portal
)
REQUIRED_SHARED_FFI_SYMBOLS=(
  free_string
)
REQUIRED_GATEWAY_SYMBOLS=(
  gateway_start
  gateway_apply_config
  gateway_stop
  gateway_status
  gateway_request_renewal
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

signing_authority() {
  local path="$1"
  codesign -dv --verbose=4 "$path" 2>&1 \
    | awk '/^Authority=/ && !found {sub(/^Authority=/, ""); print; found=1}'
}

verify_keychain_signing() {
  local embedded_profile="$APP_PATH/Contents/embedded.provisionprofile"
  [[ -f "$embedded_profile" ]] || fail "EasyTier.app must embed a Developer ID provisioning profile for the Data Protection Keychain."

  local temp_dir profile_plist signed_entitlements app_team expected_identifier wildcard_keychain_group
  local profile_team profile_identifier profile_groups signed_identifier signed_groups biometric
  local expiration expiration_epoch now_epoch
  temp_dir="$(mktemp -d)"
  profile_plist="$temp_dir/profile.plist"
  signed_entitlements="$temp_dir/entitlements.plist"
  security cms -D -i "$embedded_profile" -o "$profile_plist" >/dev/null
  codesign -d --entitlements :- "$APP_PATH" >"$signed_entitlements" 2>/dev/null

  app_team="$(signature_field "$APP_PATH" TeamIdentifier)"
  expected_identifier="$app_team.com.kkrainbow.easytier.mac"
  wildcard_keychain_group="$app_team.*"
  profile_team="$(plutil -extract TeamIdentifier.0 raw -o - "$profile_plist" 2>/dev/null || true)"
  profile_identifier="$(
    plutil -extract Entitlements.application-identifier raw -o - "$profile_plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$profile_plist" 2>/dev/null \
      || true
  )"
  profile_groups="$(plutil -extract Entitlements.keychain-access-groups json -o - "$profile_plist" 2>/dev/null || true)"
  signed_identifier="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$signed_entitlements" 2>/dev/null || true)"
  signed_groups="$(plutil -extract keychain-access-groups json -o - "$signed_entitlements" 2>/dev/null || true)"
  biometric="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.biometric' "$signed_entitlements" 2>/dev/null || true)"

  [[ "$profile_team" == "$app_team" ]] || fail "Provisioning profile Team ID does not match the app signature."
  [[ "$profile_identifier" == "$expected_identifier" ]] || fail "Provisioning profile does not target $expected_identifier."
  [[ "$profile_groups" == *"\"$expected_identifier\""* \
      || "$profile_groups" == *"\"$wildcard_keychain_group\""* ]] \
    || fail "Provisioning profile does not authorize Keychain group $expected_identifier."
  [[ "$signed_identifier" == "$expected_identifier" ]] || fail "Signed app is missing application identifier $expected_identifier."
  [[ "$signed_groups" == *"\"$expected_identifier\""* ]] || fail "Signed app is missing Keychain access group $expected_identifier."
  [[ "$biometric" == "true" ]] || fail "Signed app is missing the biometric entitlement."

  expiration="$(plutil -extract ExpirationDate raw -o - "$profile_plist" 2>/dev/null || true)"
  expiration_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expiration" '+%s' 2>/dev/null || true)"
  now_epoch="$(date -u '+%s')"
  [[ -n "$expiration_epoch" && "$expiration_epoch" -gt "$now_epoch" ]] || fail "Embedded provisioning profile is expired or unreadable: $expiration"

  rm -rf "$temp_dir"
  echo "Data Protection Keychain profile and entitlements are valid for $expected_identifier."
}

verify_developer_id_signatures() {
  local app_team item authority team details
  app_team="$(signature_field "$APP_PATH" TeamIdentifier)"
  [[ -n "$app_team" && "$app_team" != "not set" ]] || fail "Developer ID verification requires an Apple Team ID on EasyTier.app."

  local signed_items=(
    "$APP_PATH"
    "$HELPER_BINARY"
    "$GATEWAY_HELPER_BINARY"
    "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
    "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
    "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
    "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
    "$SPARKLE_FRAMEWORK"
  )

  for item in "${signed_items[@]}"; do
    authority="$(signing_authority "$item")"
    team="$(signature_field "$item" TeamIdentifier)"
    details="$(codesign -dv --verbose=4 "$item" 2>&1)"
    [[ "$authority" == "Developer ID Application:"* ]] || fail "$item must be signed with a Developer ID Application identity: $authority"
    [[ "$team" == "$app_team" ]] || fail "TeamIdentifier mismatch for $item: app=$app_team component=$team"
    [[ "$details" == *"(runtime)"* ]] || fail "$item must enable the hardened runtime."
    [[ "$details" == *"Timestamp="* ]] || fail "$item must include a secure signing timestamp."
  done

  echo "App, helper, and Sparkle components passed Developer ID checks with TeamIdentifier $app_team."
}

verify_app_bundle() {
  [[ -d "$APP_PATH" ]] || fail "Packaged app not found: $APP_PATH"

  GUI_BINARY="$APP_PATH/Contents/MacOS/EasyTierMac"
  HELPER_BINARY="$APP_PATH/Contents/MacOS/EasyTierPrivilegedHelper"
  GATEWAY_HELPER_BINARY="$APP_PATH/Contents/MacOS/GatewayPrivilegedHelper"
  SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  local launch_daemon="$APP_PATH/Contents/Library/LaunchDaemons/com.kkrainbow.easytier.mac.helper.plist"
  local gateway_launch_daemon="$APP_PATH/Contents/Library/LaunchDaemons/com.coldkiller.gateway.helper.plist"

  [[ -x "$GUI_BINARY" ]] || fail "Missing or non-executable GUI binary: $GUI_BINARY"
  [[ -x "$HELPER_BINARY" ]] || fail "Missing or non-executable privileged helper: $HELPER_BINARY"
  [[ -x "$GATEWAY_HELPER_BINARY" ]] || fail "Missing or non-executable Gateway helper: $GATEWAY_HELPER_BINARY"
  [[ -d "$SPARKLE_FRAMEWORK" ]] || fail "Missing embedded Sparkle.framework: $SPARKLE_FRAMEWORK"
  [[ -e "$launch_daemon" ]] || fail "Missing LaunchDaemon plist: $launch_daemon"
  [[ -e "$gateway_launch_daemon" ]] || fail "Missing Gateway LaunchDaemon plist: $gateway_launch_daemon"
  [[ ! -e "$APP_PATH/Contents/MacOS/EasyTierValidator" ]] || fail "Packaged app must not include the removed EasyTierValidator binary."

  local bundle_version
  bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
  [[ "$bundle_version" =~ ^[0-9]{14}$ ]] || fail "CFBundleVersion must be a 14-digit UTC build number: $bundle_version"

  local bundle_identifier
  bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
  [[ "$bundle_identifier" == "com.kkrainbow.easytier.mac" ]] || fail "Unexpected app bundle identifier: $bundle_identifier"

  local bundle_icon
  bundle_icon="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP_PATH/Contents/Info.plist")"
  [[ "$bundle_icon" == "easytier-icon.icns" ]] || fail "Packaged app must use the official EasyTier dock icon: $bundle_icon"
  [[ -f "$APP_PATH/Contents/Resources/$bundle_icon" ]] || fail "Missing dock icon resource: Contents/Resources/$bundle_icon"
  [[ -f "$APP_PATH/Contents/Resources/easytier-icon.png" ]] || fail "Missing About icon resource: Contents/Resources/easytier-icon.png"

  local build_time
  build_time="$(/usr/libexec/PlistBuddy -c 'Print :EasyTierBuildTime' "$APP_PATH/Contents/Info.plist")" || fail "Packaged app must include EasyTierBuildTime."
  [[ "$build_time" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail "EasyTierBuildTime must be an ISO-8601 UTC timestamp: $build_time"

  local sparkle_feed_url sparkle_public_key scheduled_interval
  sparkle_feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP_PATH/Contents/Info.plist")" || fail "Packaged app must include SUFeedURL."
  sparkle_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_PATH/Contents/Info.plist")" || fail "Packaged app must include SUPublicEDKey."
  scheduled_interval="$(/usr/libexec/PlistBuddy -c 'Print :SUScheduledCheckInterval' "$APP_PATH/Contents/Info.plist")" || fail "Packaged app must include SUScheduledCheckInterval."
  [[ "$sparkle_feed_url" == https://* ]] || fail "SUFeedURL must use HTTPS: $sparkle_feed_url"
  [[ "$sparkle_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail "SUPublicEDKey is not a base64 Ed25519 public key."
  [[ "$scheduled_interval" == "86400" ]] || fail "SUScheduledCheckInterval must be 86400: $scheduled_interval"

  local bool_key bool_value
  for bool_key in SUEnableAutomaticChecks SUVerifyUpdateBeforeExtraction SURequireSignedFeed; do
    bool_value="$(/usr/libexec/PlistBuddy -c "Print :$bool_key" "$APP_PATH/Contents/Info.plist")" || fail "Packaged app must include $bool_key."
    [[ "$bool_value" == "true" ]] || fail "$bool_key must be true."
  done
  for bool_key in SUAutomaticallyUpdate SUAllowsAutomaticUpdates; do
    bool_value="$(/usr/libexec/PlistBuddy -c "Print :$bool_key" "$APP_PATH/Contents/Info.plist")" || fail "Packaged app must include $bool_key."
    [[ "$bool_value" == "false" ]] || fail "$bool_key must be false."
  done

  [[ -L "$SPARKLE_FRAMEWORK/Sparkle" ]] || fail "Sparkle.framework binary symlink was not preserved."
  [[ -x "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" ]] || fail "Sparkle Autoupdate executable is missing."
  [[ -d "$SPARKLE_FRAMEWORK/Versions/B/Updater.app" ]] || fail "Sparkle Updater.app is missing."
  [[ -d "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" ]] || fail "Sparkle Downloader.xpc is missing."
  [[ -d "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc" ]] || fail "Sparkle Installer.xpc is missing."

  local autoupdate_entitlements
  autoupdate_entitlements="$(codesign -d --entitlements - "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" 2>/dev/null)"
  [[ "$autoupdate_entitlements" == *"org.sparkle-project.Sparkle.Autoupdate"* ]] || fail "Sparkle Autoupdate signing entitlements were not preserved."

  local linked_libraries load_commands
  linked_libraries="$(otool -L "$GUI_BINARY" | tail -n +2)"
  load_commands="$(otool -l "$GUI_BINARY")"
  [[ "$linked_libraries" == *"@rpath/Sparkle.framework/Versions/B/Sparkle"* ]] || fail "EasyTierMac does not link Sparkle via @rpath."
  [[ "$linked_libraries" != *"/.build/"* ]] || fail "EasyTierMac links a Sparkle framework from the build directory."
  [[ "$load_commands" == *"@executable_path/../Frameworks"* ]] || fail "EasyTierMac is missing the app Frameworks rpath."

  local helper_identifier
  helper_identifier="$(codesign -dv --verbose=4 "$HELPER_BINARY" 2>&1 | sed -n 's/^Identifier=//p')"
  [[ "$helper_identifier" == "com.kkrainbow.easytier.mac.helper" ]] || fail "Unexpected helper code signature identifier: $helper_identifier"

  local helper_info_plist
  helper_info_plist="$(codesign -dv --verbose=4 "$HELPER_BINARY" 2>&1 | sed -n '/^Info.plist/p')"
  [[ -n "$helper_info_plist" && "$helper_info_plist" != *"not bound"* ]] || fail "Privileged helper must embed an Info.plist so SMAppService can identify its bundle."

  local helper_bundle_identifier
  helper_bundle_identifier="$(sfltool csinfo "$HELPER_BINARY" 2>/dev/null | sed -n 's/^Bundle Identifier: //p')"
  [[ "$helper_bundle_identifier" == "com.kkrainbow.easytier.mac.helper" ]] || fail "Unexpected helper bundle identifier: $helper_bundle_identifier"

  local gateway_helper_identifier gateway_helper_bundle_identifier gateway_helper_info_plist
  gateway_helper_identifier="$(codesign -dv --verbose=4 "$GATEWAY_HELPER_BINARY" 2>&1 | sed -n 's/^Identifier=//p')"
  [[ "$gateway_helper_identifier" == "com.coldkiller.gateway.helper" ]] || fail "Unexpected Gateway helper code signature identifier: $gateway_helper_identifier"
  gateway_helper_info_plist="$(codesign -dv --verbose=4 "$GATEWAY_HELPER_BINARY" 2>&1 | sed -n '/^Info.plist/p')"
  [[ -n "$gateway_helper_info_plist" && "$gateway_helper_info_plist" != *"not bound"* ]] || fail "Gateway helper must embed an Info.plist."
  gateway_helper_bundle_identifier="$(sfltool csinfo "$GATEWAY_HELPER_BINARY" 2>/dev/null | sed -n 's/^Bundle Identifier: //p')"
  [[ "$gateway_helper_bundle_identifier" == "com.coldkiller.gateway.helper" ]] || fail "Unexpected Gateway helper bundle identifier: $gateway_helper_bundle_identifier"

  verify_keychain_signing
  codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null
  verify_developer_id_signatures
}

verify_binary_symbols() {
  local gui_archs helper_archs gateway_helper_archs
  gui_archs="$(archs_for "$GUI_BINARY")"
  helper_archs="$(archs_for "$HELPER_BINARY")"
  gateway_helper_archs="$(archs_for "$GATEWAY_HELPER_BINARY")"
  [[ -n "$gui_archs" ]] || fail "Could not determine architectures for $GUI_BINARY."
  [[ -n "$helper_archs" ]] || fail "Could not determine architectures for $HELPER_BINARY."
  [[ -n "$gateway_helper_archs" ]] || fail "Could not determine architectures for $GATEWAY_HELPER_BINARY."
  [[ "$gui_archs" == "arm64" ]] || fail "EasyTierMac release must be ARM64-only; found: $gui_archs"
  [[ "$helper_archs" == "arm64" ]] || fail "EasyTierPrivilegedHelper release must be ARM64-only; found: $helper_archs"
  [[ "$gateway_helper_archs" == "arm64" ]] || fail "GatewayPrivilegedHelper release must be ARM64-only; found: $gateway_helper_archs"

  for symbol in "${REQUIRED_SHARED_FFI_SYMBOLS[@]}"; do
    ! has_symbol "$GUI_BINARY" "$symbol" "$gui_archs" || fail "EasyTierMac must not contain shared FFI symbol: $symbol"
    has_symbol "$HELPER_BINARY" "$symbol" "$helper_archs" || fail "EasyTierPrivilegedHelper must contain shared FFI symbol: $symbol"
    has_symbol "$GATEWAY_HELPER_BINARY" "$symbol" "$gateway_helper_archs" || fail "GatewayPrivilegedHelper must contain shared FFI symbol: $symbol"
  done

  for symbol in "${REQUIRED_FFI_SYMBOLS[@]}"; do
    ! has_symbol "$GUI_BINARY" "$symbol" "$gui_archs" || fail "EasyTierMac must not contain EasyTier FFI symbol: $symbol"
    has_symbol "$HELPER_BINARY" "$symbol" "$helper_archs" || fail "EasyTierPrivilegedHelper must contain EasyTier FFI symbol: $symbol"
    ! has_symbol "$GATEWAY_HELPER_BINARY" "$symbol" "$gateway_helper_archs" || fail "GatewayPrivilegedHelper must not contain EasyTier FFI symbol: $symbol"
  done

  for symbol in "${REQUIRED_GATEWAY_SYMBOLS[@]}"; do
    ! has_symbol "$GUI_BINARY" "$symbol" "$gui_archs" || fail "EasyTierMac must not contain Gateway FFI symbol: $symbol"
    has_symbol "$GATEWAY_HELPER_BINARY" "$symbol" "$gateway_helper_archs" || fail "GatewayPrivilegedHelper must contain Gateway FFI symbol: $symbol"
    ! has_symbol "$HELPER_BINARY" "$symbol" "$helper_archs" || fail "EasyTierPrivilegedHelper must not contain Gateway FFI symbol: $symbol"
  done

  echo "Binary symbol checks passed: the GUI is FFI-free and each helper contains only its own FFI entry points."
}

verify_app_bundle
verify_binary_symbols

echo "Packaged app contains an FFI-free GUI plus isolated EasyTier and Gateway privileged helpers."
