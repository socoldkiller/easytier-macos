#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-}"
FFI_LIBRARY="$ROOT_DIR/Vendor/Frameworks/static/libeasytier_ffi.a"
GUI_BINARY=""
HELPER_BINARY=""
VERIFY_INSTALLABLE_HELPER="${EASYTIER_VERIFY_INSTALLABLE_HELPER:-0}"
REQUIRED_FFI_SYMBOLS=(
  parse_config
  run_network_instance
  retain_network_instance
  collect_network_infos
  free_string
)

if [[ -z "$APP_PATH" ]]; then
  echo "Usage: scripts/verify-app.sh /path/to/EasyTier.app" >&2
  exit 2
fi

cd "$ROOT_DIR"

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

verify_static_ffi_library() {
  [[ -f "$FFI_LIBRARY" ]] || fail "Static FFI library not found; run ./scripts/build-ffi.sh before building the app."

  local archs
  archs="$(archs_for "$FFI_LIBRARY")"
  [[ -n "$archs" ]] || fail "Could not determine architectures for $FFI_LIBRARY."

  for symbol in "${REQUIRED_FFI_SYMBOLS[@]}"; do
    has_symbol "$FFI_LIBRARY" "$symbol" "$archs" || fail "Missing FFI symbol in static library: $symbol"
  done
  echo "Static FFI library found and required symbols are exported."
}

verify_target_graph() {
  local package_json
  package_json="$(mktemp)"
  trap 'rm -f "$package_json"' RETURN

  swift package describe --type json > "$package_json"
  python3 - "$package_json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    package = json.load(handle)

targets = {target["name"]: target for target in package["targets"]}

def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)

def deps(name):
    target = targets.get(name)
    if target is None:
        fail(f"Missing SwiftPM target: {name}")
    return set(target.get("target_dependencies", [])) | set(target.get("product_dependencies", []))

if "EasyTierCore" in targets:
    fail("EasyTierCore target must not exist after splitting shared/runtime modules.")

mac_deps = deps("EasyTierMac")
forbidden_mac_deps = {"CEasyTierFFI"}
# EasyTierMac may depend on EasyTierRuntime so it can run no_tun instances in-process via StaticEasyTierFFIClient.
forbidden_found = sorted(mac_deps & forbidden_mac_deps)
if forbidden_found:
    fail(f"EasyTierMac must not depend on FFI/runtime targets: {', '.join(forbidden_found)}")

shared_deps = deps("EasyTierShared")
forbidden_shared_deps = {"EasyTierRuntime", "CEasyTierFFI"}
forbidden_found = sorted(shared_deps & forbidden_shared_deps)
if forbidden_found:
    fail(f"EasyTierShared must remain FFI-free: {', '.join(forbidden_found)}")

runtime_deps = deps("EasyTierRuntime")
if "CEasyTierFFI" not in runtime_deps:
    fail("EasyTierRuntime must depend on CEasyTierFFI.")
if "EasyTierShared" not in runtime_deps:
    fail("EasyTierRuntime must depend on EasyTierShared.")

helper_deps = deps("EasyTierPrivilegedHelper")
if "EasyTierRuntime" not in helper_deps or "EasyTierShared" not in helper_deps:
    fail("EasyTierPrivilegedHelper must depend on EasyTierShared and EasyTierRuntime.")

print("SwiftPM target graph keeps EasyTierMac FFI-free and helper runtime-enabled.")
PY
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
  [[ -f "$APP_PATH/Contents/Resources/MenuBarConnectionGlyphTemplate.png" ]] || fail "Missing menu bar icon resource: Contents/Resources/MenuBarConnectionGlyphTemplate.png"
  [[ -f "$APP_PATH/Contents/Resources/MenuBarConnectionGlyphTemplate@2x.png" ]] || fail "Missing menu bar icon resource: Contents/Resources/MenuBarConnectionGlyphTemplate@2x.png"
  [[ -f "$APP_PATH/Contents/Resources/MenuBarConnectionGlyphTemplate@3x.png" ]] || fail "Missing menu bar icon resource: Contents/Resources/MenuBarConnectionGlyphTemplate@3x.png"

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
    if has_symbol "$GUI_BINARY" "$symbol" "$gui_archs"; then
      fail "EasyTierMac must not contain EasyTier FFI symbol: $symbol"
    fi
    has_symbol "$HELPER_BINARY" "$symbol" "$helper_archs" || fail "EasyTierPrivilegedHelper must contain EasyTier FFI symbol: $symbol"
  done

  echo "Binary symbol checks passed: GUI is FFI-free and helper contains EasyTier FFI."
}

verify_static_ffi_library
verify_target_graph
verify_app_bundle
verify_binary_symbols

echo "Packaged app contains GUI, privileged helper, LaunchDaemon plist, and the expected FFI linkage split."
