#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="${1:-}"
DESTINATION_APP="${EASYTIER_INSTALL_APP_PATH:-/Applications/EasyTier.app}"
OPEN_APP="${EASYTIER_OPEN_APP:-0}"
STOP_RUNNING_APPS="${EASYTIER_STOP_RUNNING_APPS:-1}"

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

signature_field() {
  local path="$1"
  local field="$2"
  codesign -dv --verbose=4 "$path" 2>&1 | sed -n "s/^$field=//p" | tail -n 1
}

verify_signature() {
  local path="$1"
  local output
  if ! output="$(codesign --verify --deep --strict --verbose=2 "$path" 2>&1)"; then
    printf '%s\n' "$output" >&2
    die "Code signature verification failed: $path"
  fi
}

[[ -n "$SOURCE_APP" ]] || die "Usage: scripts/install-xcode-debug-app.sh /path/to/EasyTier.app"
[[ -d "$SOURCE_APP" ]] || die "Xcode Debug app not found: $SOURCE_APP"
[[ "$DESTINATION_APP" == *.app ]] || die "Debug install destination must be an .app bundle: $DESTINATION_APP"
[[ "$SOURCE_APP" != "$DESTINATION_APP" ]] || die "Source and destination app paths must differ."
[[ -x "$SOURCE_APP/Contents/MacOS/EasyTierMac" ]] || die "EasyTierMac is missing from $SOURCE_APP"
[[ -x "$SOURCE_APP/Contents/MacOS/EasyTierPrivilegedHelper" ]] || die "The privileged helper is missing from $SOURCE_APP"
[[ -x "$SOURCE_APP/Contents/MacOS/GatewayPrivilegedHelper" ]] || die "The Gateway privileged helper is missing from $SOURCE_APP"
[[ -f "$SOURCE_APP/Contents/embedded.provisionprofile" ]] \
  || die "The Debug app has no embedded provisioning profile. Configure Configurations/Signing.local.xcconfig."

temp_dir="$(mktemp -d)"
staging_app="$DESTINATION_APP.installing.$$"
cleanup() {
  rm -rf "$temp_dir" "$staging_app"
}
trap cleanup EXIT

entitlements_plist="$temp_dir/entitlements.plist"
profile_plist="$temp_dir/profile.plist"
codesign -d --entitlements :- "$SOURCE_APP" >"$entitlements_plist" 2>/dev/null
security cms -D -i "$SOURCE_APP/Contents/embedded.provisionprofile" -o "$profile_plist" >/dev/null

team_id="$(signature_field "$SOURCE_APP" TeamIdentifier)"
[[ -n "$team_id" && "$team_id" != "not set" ]] \
  || die "The Debug app is ad-hoc signed. Configure Configurations/Signing.local.xcconfig."
expected_identifier="$team_id.com.kkrainbow.easytier.mac"
signed_identifier="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$entitlements_plist" 2>/dev/null || true)"
signed_groups="$(plutil -extract keychain-access-groups json -o - "$entitlements_plist" 2>/dev/null || true)"
profile_team="$(plutil -extract TeamIdentifier.0 raw -o - "$profile_plist" 2>/dev/null || true)"

[[ "$signed_identifier" == "$expected_identifier" ]] \
  || die "The Debug app is missing the Data Protection Keychain application identifier $expected_identifier."
[[ "$signed_groups" == *"\"$expected_identifier\""* ]] \
  || die "The Debug app is missing the Keychain access group $expected_identifier."
[[ "$profile_team" == "$team_id" ]] \
  || die "The embedded profile Team ID does not match the Debug app signature."

signature_details="$(codesign -dv --verbose=4 "$SOURCE_APP" 2>&1)"
if [[ "$signature_details" == *"(runtime)"* ]]; then
  die "The Debug app enables Hardened Runtime without a development profile; LLDB cannot attach reliably."
fi

verify_signature "$SOURCE_APP"

# A second process with the same bundle identifier can cause AppKit to activate
# the stale copy and immediately exit the installed one. Stop all debug copies.
if [[ "$STOP_RUNNING_APPS" == "1" ]]; then
  running_pids="$(pgrep -x EasyTierMac || true)"
  if [[ -n "$running_pids" ]]; then
    kill $running_pids 2>/dev/null || true
    for _ in {1..50}; do
      pgrep -x EasyTierMac >/dev/null || break
      sleep 0.1
    done
    pgrep -x EasyTierMac >/dev/null \
      && die "EasyTierMac is still running or paused by LLDB. Press Stop in Xcode, then run again."
  fi
fi

installed_binary="$DESTINATION_APP/Contents/MacOS/EasyTierMac"
if [[ -x "$installed_binary" ]]; then
  if ! unregister_output="$(
    EASYTIER_SKIP_LEGACY_HELPER_UNINSTALL=1 \
      "$installed_binary" --unregister-helper 2>&1
  )"; then
    printf '%s\n' "$unregister_output" >&2
    die "Failed to unregister the installed privileged helpers before replacing the app."
  fi
  printf '%s\n' "$unregister_output"
fi

mkdir -p "$(dirname "$DESTINATION_APP")"
ditto --noextattr --norsrc "$SOURCE_APP" "$staging_app"
xattr -cr "$staging_app"
verify_signature "$staging_app"
rm -rf "$DESTINATION_APP"
mv "$staging_app" "$DESTINATION_APP"

installed_binary="$DESTINATION_APP/Contents/MacOS/EasyTierMac"
if ! register_output="$("$installed_binary" --register-helper 2>&1)"; then
  printf '%s\n' "$register_output" >&2
  die "Failed to register the privileged helpers from the newly installed app."
fi
printf '%s\n' "$register_output"

printf 'Installed signed Xcode Debug app: %s\n' "$DESTINATION_APP"
printf 'Data Protection Keychain identifier: %s\n' "$expected_identifier"

if [[ "$OPEN_APP" == "1" ]]; then
  open "$DESTINATION_APP"
fi
