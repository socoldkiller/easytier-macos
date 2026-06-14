#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift test
swift build --product EasyTierValidator
swift build --product EasyTierPrivilegedHelper
BUILD_DIR="$(swift build --show-bin-path)"

"$BUILD_DIR/EasyTierValidator" validate <<'TOML'
instance_name = "easytier"
instance_id = "11111111-1111-1111-1111-111111111111"
dhcp = true
listeners = ["tcp://0.0.0.0:11010", "udp://0.0.0.0:11010", "wg://0.0.0.0:11011"]

[network_identity]
network_name = "easytier"
network_secret = ""

[flags]
accept_dns = false
bind_device = true
disable_kcp_input = false
disable_p2p = false
disable_quic_input = false
disable_sym_hole_punching = false
disable_tcp_hole_punching = false
disable_udp_hole_punching = false
disable_upnp = false
enable_encryption = true
enable_exit_node = false
enable_ipv6 = true
enable_kcp_proxy = false
enable_quic_proxy = false
enable_udp_broadcast_relay = false
latency_first = false
lazy_p2p = false
multi_thread = true
need_p2p = false
no_tun = false
p2p_only = false
private_mode = false
proxy_forward_by_system = false
relay_all_peer_rpc = false
use_smoltcp = false
TOML

if [[ -f Vendor/Frameworks/static/libeasytier_ffi.a ]]; then
  for symbol in parse_config run_network_instance retain_network_instance collect_network_infos get_error_msg free_string; do
    if ! (nm -arch arm64 Vendor/Frameworks/static/libeasytier_ffi.a 2>/dev/null || true) | grep -q "_$symbol"; then
      echo "Missing FFI symbol: $symbol" >&2
      exit 1
    fi
  done
  echo "Static FFI library found and required symbols are exported."
else
  echo "Static FFI library not found; run ./scripts/build-ffi.sh before building the app."
  exit 1
fi

APP_PATH="$(./scripts/package-app.sh | tail -n 1)"
for file in \
  "$APP_PATH/Contents/MacOS/EasyTierMac" \
  "$APP_PATH/Contents/MacOS/EasyTierValidator" \
  "$APP_PATH/Contents/MacOS/EasyTierPrivilegedHelper" \
  "$APP_PATH/Contents/Library/LaunchDaemons/com.kkrainbow.easytier.mac.helper.plist"; do
  if [[ ! -e "$file" ]]; then
    echo "Missing packaged app component: $file" >&2
    exit 1
  fi
done

bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
if [[ "$bundle_version" == "1" ]]; then
  echo "Packaged app must use a fresh CFBundleVersion, not the static value 1." >&2
  exit 1
fi

helper_identifier="$(codesign -dv --verbose=4 "$APP_PATH/Contents/MacOS/EasyTierPrivilegedHelper" 2>&1 | sed -n 's/^Identifier=//p')"
if [[ "$helper_identifier" != "com.kkrainbow.easytier.mac.helper" ]]; then
  echo "Unexpected helper code signature identifier: $helper_identifier" >&2
  exit 1
fi

echo "Packaged app contains GUI, validator, privileged helper, and LaunchDaemon plist."
