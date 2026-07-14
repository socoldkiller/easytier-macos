<div align="center">
  <br />
  <img src="Sources/EasyTierMac/Resources/easytier-icon.png" width="108" alt="EasyTier icon" />

  <h1>EasyTier for macOS</h1>

  <p>
    Put your home NAS, office machines, and cloud servers on a single virtual LAN. Devices talk to each other like they're plugged into the same switch, wherever they are.
  </p>

  <p>
    <img alt="macOS" src="https://img.shields.io/badge/macOS-15%2B-111111?style=for-the-badge&logo=apple&logoColor=white" />
    <img alt="Swift" src="https://img.shields.io/badge/Swift-Native-F05138?style=for-the-badge&logo=swift&logoColor=white" />
    <a href="https://github.com/socoldkiller/easytier-macos/stargazers">
      <img alt="Stars" src="https://img.shields.io/github/stars/socoldkiller/easytier-macos?style=for-the-badge&logo=github&label=Stars" />
    </a>
    <a href="LICENSE">
      <img alt="License" src="https://img.shields.io/badge/License-MIT-34D399?style=for-the-badge" />
    </a>
  </p>

  <p>
    <a href="#screenshots">Screenshots</a>
    ·
    <a href="#features">Features</a>
    ·
    <a href="#install">Install</a>
    ·
    <a href="#build">Build</a>
    ·
    <a href="#star-history">Star History</a>
    ·
    <a href="#credits">Credits</a>
  </p>

  <br />
</div>

---

## Screenshots

<div align="center">
  <img src="pictures/status-overview.png" width="920" alt="Status overview" />

  <br /><br />

  <img src="pictures/config-editor.png" width="420" alt="Config editor" />
  &nbsp;
  <img src="pictures/traffic-view.png" width="420" alt="Traffic view" />

  <br /><br />

  <img src="pictures/menu-bar-panel.png" width="420" alt="Menu bar panel" />
  &nbsp;
  <img src="pictures/mode-settings.png" width="420" alt="Mode settings" />

  <br /><br />

  <img src="pictures/runtime-logs.png" width="420" alt="Runtime logs" />
</div>

## Features

### Menu bar

The menu bar icon shows connection state — gray stopped, green connected, red error. Click it for a panel with network name, local IP, and online device count.

### Device table

Every node on the current network in one table:

- Hostname, role (Self / Peer / Public Server), and Peer ID
- Virtual IPv4 — click to copy
- Route type: Local, P2P, Relay
- Tunnel protocol: TCP, UDP, QUIC, etc.
- Latency, upload, download, packet loss
- NAT type and EasyTier version

Double-click a device name to rename it. The change propagates to the remote node over RPC.

### Traffic chart

Upload and download trends as a per-second area chart. Hover for exact values. Top bar shows current rate and sample count.

### Multi-network configs

Each network gets its own configuration. Start and stop them independently.
- Network name and secret
- Initial node list — add or remove as needed
- Magic DNS, tunnel protocol, and other advanced options
- TOML format, compatible with the EasyTier CLI

### Peer subscriptions

Paste a subscription URL or JSON to import peer addresses. Each source shows as a card — refresh on demand.

### Magic DNS

Configure DNS suffix, split DNS routing, and local resolver. Only names under the suffix go through EasyTier; everything else stays on system DNS.

### Runtime logs

App actions and EasyTier Core output go to a single panel. Search, clear, copy, export.

### Privileged helper

TUN interfaces need root. Starting a TUN network shows an inline prompt to install a privileged helper (LaunchDaemon) that communicates over XPC. Non-TUN mode doesn't need it.

## Install

macOS 15 or later.

Grab the DMG from [Releases](https://github.com/socoldkiller/easytier-macos/releases) and drop it into Applications.

Starting with v1.4.0, later releases can be verified, installed, and relaunched from `EasyTier > Check for Updates…` without opening Finder or dragging another DMG. v1.3.3 and earlier do not contain Sparkle, so moving v1.4.0 into Applications is the final manual upgrade.

First launch:
1. Release DMGs are Developer ID signed and Apple-notarized. If macOS cannot verify the developer, do not bypass Gatekeeper; download the DMG again and report the release issue.
2. TUN mode prompts for the privileged helper → follow the dialogs
3. If your firewall is on → allow incoming connections for EasyTier

## Build

### Prerequisites

Xcode 16+, Swift 6, Rust 1.95+ stable, and the Protocol Buffers compiler (`protoc`). Tests do not require signing credentials. App packaging requires a Developer ID Application certificate, a matching provisioning profile, and the Sparkle public key; a final DMG also requires a valid `notarytool` profile.

```bash
git clone --recurse-submodules https://github.com/socoldkiller/easytier-macos.git
cd easytier-macos
make bootstrap   # verify toolchain
make ffi         # build the Rust FFI static lib for this Mac
make test        # run Swift and Rust tests
```

The distributable app is defined by a native Xcode project:

```bash
open EasyTier.xcodeproj
```

The `EasyTierMac` scheme includes the macOS app, privileged helper, and Rust FFI build dependency. Debug is available for local builds; `Product > Archive` uses Release and requires the Developer ID identity plus the matching provisioning profile. SwiftPM remains the owner of the Shared/Runtime modules and tests so the business dependency graph is not duplicated in Xcode.

To debug the Data Protection Keychain, first create the ignored per-machine signing configuration:

```bash
cp Configurations/Signing.example.xcconfig Configurations/Signing.local.xcconfig
```

The regular `EasyTierMac` scheme supports GUI, Keychain, and `no_tun` debugging. A TUN network must register its privileged helper from a stable installed path; select `EasyTierMac-InstalledDebug` in Xcode to install the signed Debug app at `/Applications/EasyTier.app` and launch that copy under LLDB. The first helper installation still requires approval in System Settings → General → Login Items & Extensions. `make debug-install` provides the equivalent command-line flow.

Output paths:
- App bundle: `.build/artifacts/EasyTier.app`
- Xcode archive: `.build/AppProducts/EasyTier.xcarchive`
- DMG: `.build/artifacts/EasyTier-macOS-ARM64.dmg`
- FFI lib: `Vendor/Frameworks/static/libeasytier_ffi.a`

Developer ID packaging:

```bash
export CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
export PROVISIONING_PROFILE="/path/to/EasyTier.provisionprofile"
export SPARKLE_PUBLIC_ED_KEY="base64-public-key-from-generate_keys"
make app-debug \
  CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
  PROVISIONING_PROFILE="$PROVISIONING_PROFILE" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY"

# An exact version tag supplies a stable version/build. Set APP_VERSION before the tag exists.
make dmg \
  CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
  PROVISIONING_PROFILE="$PROVISIONING_PROFILE" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  APP_VERSION=1.4.0
```

See [`Packaging/RELEASE.md`](Packaging/RELEASE.md) for the complete local and CI release configuration and [`Packaging/SPARKLE.md`](Packaging/SPARKLE.md) for production key provisioning.

`make dmg` now emits only a final release artifact: the app is notarized and stapled before DMG creation, then the DMG is notarized, stapled, and exercised through the quarantine/Gatekeeper verifier. There is no public target for a merely signed, unnotarized DMG. The provisioning profile must authorize the app's private Keychain access group for the Data Protection Keychain; never commit it to the repository. Packaging fails instead of producing a downgraded build when signing configuration is missing or invalid.

### Call path

The SwiftUI app talks to EasyTier Core through a C shim (CEasyTierFFI) backed by a Rust FFI library. In TUN mode, the app communicates with a privileged helper over XPC, and the helper calls into the same FFI layer. Remote RPC builds JSON-RPC payloads in Swift and sends them through the C shim to a remote RPC Portal.

## Star History

<div align="center">
  <a href="https://www.star-history.com/#socoldkiller/easytier-macos&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=socoldkiller/easytier-macos&type=Date&theme=dark" />
      <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=socoldkiller/easytier-macos&type=Date" />
      <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=socoldkiller/easytier-macos&type=Date" />
    </picture>
  </a>
</div>

## Credits

Built on [EasyTier](https://github.com/EasyTier/EasyTier). SwiftUI frontend, Rust FFI calling EasyTier Core.

Bugs and feature requests go in Issues. Pull requests welcome.

## License

MIT. EasyTier Core and its dependencies follow their own licenses.
