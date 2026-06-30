<div align="center">
  <br />
  <img src="Sources/EasyTierMac/Resources/easytier-icon.png" width="108" alt="EasyTier icon" />

  <h1>EasyTier for macOS</h1>

  <p>
    A native macOS desktop client for EasyTier. SwiftUI frontend, Rust FFI calling EasyTier Core under the hood.
  </p>
  <p>
    Put your home NAS, office machines, and cloud servers on one virtual LAN. No CLI memorization — open the app, see who's online, check the speeds.
  </p>

  <p>
    <img alt="macOS" src="https://img.shields.io/badge/macOS-14%2B-111111?style=for-the-badge&logo=apple&logoColor=white" />
    <img alt="Swift" src="https://img.shields.io/badge/Swift-Native-F05138?style=for-the-badge&logo=swift&logoColor=white" />
    <a href="https://github.com/socoldkiller/easytier-swift/stargazers">
      <img alt="Stars" src="https://img.shields.io/github/stars/socoldkiller/easytier-swift?style=for-the-badge&logo=github&label=Stars" />
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
    <a href="#architecture">Architecture</a>
    ·
    <a href="#star-history">Star History</a>
    ·
    <a href="#credits">Credits</a>
  </p>

  <br />
</div>

---

## Screenshots

Main window — sidebar for switching networks, content area for status, devices, traffic, and logs.

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

The menu bar icon shows connection state at a glance — gray means stopped, pulsing means connecting, green means all good, red means something's wrong. Click it for a quick panel with current network and device info, no need to open the full window.

### Device table

A table listing every node on the current network. Each row shows:
- Device name and IP (click to copy)
- Route type (P2P, Relay, Local)
- Tunnel protocol (TCP, UDP, QUIC, etc.)
- Latency, upload, download, packet loss
- NAT type and EasyTier version

Double-click a device name to rename it — changes propagate to the remote node over RPC in real time.

### Traffic chart

Upload and download trends as an area chart. Hover for exact values, refreshes every second. The Y axis auto-scales so a brief spike doesn't flatten the curve.

### Multi-network configs

Each network saved as a separate TOML file, start/stop independently. Switch between configs with Cmd+[ / Cmd+]. Import/export TOML — fully compatible with the CLI config format.

### Runtime logs

EasyTier Core output and app-level actions all land in one log panel. Copyable, searchable. At least you know where to look when something breaks.

### App modes

- **Normal** — run EasyTier locally, own the network
- **Remote** — connect to another device's RPC Portal, manage its networks remotely
- **Config Server** — pull configs from a remote server for fleet management

### Privileged helper

TUN interfaces need root. The app walks you through installing a privileged helper (LaunchDaemon) that only gets invoked when starting a TUN network. Non-TUN mode (`no_tun`) doesn't need it.

## Install

macOS 15 or later.

Grab the latest DMG from [Releases](https://github.com/socoldkiller/easytier-swift/releases) and drag it into Applications.

First launch:
1. macOS may block it as "unidentified developer" — go to System Settings → Privacy & Security → Open Anyway
2. The helper install prompt will appear — follow the macOS dialogs
3. If you have the firewall on, allow EasyTier's incoming connections

## Build

Requires Xcode 16+ (Swift 6) and the Rust nightly toolchain.

```bash
git clone --recurse-submodules https://github.com/socoldkiller/easytier-swift.git
cd easytier-swift

# Build the Rust FFI static library
make build-ffi

# Build the Swift app
make build

# Package as DMG
make dmg

# Run tests
swift test
cd Rust/EasyTierGuiFFI && cargo test
```

Output paths:
- App bundle: `.build/debug/EasyTierMac.app`
- FFI library: `Rust/EasyTierGuiFFI/target/`
- DMG: `easytier-mac.dmg`

## Architecture

```
┌────────────────────────────────┐
│  SwiftUI App (EasyTierMac)     │
│  Views / Menu Bar / Settings   │
├────────────────────────────────┤
│  EasyTierShared (Models / RPC) │
├──────────────┬─────────────────┤
│  Privileged  │  Static FFI     │
│  Helper (XPC)│  Client (C ABI) │
├──────────────┴─────────────────┤
│  CEasyTierFFI (C shim)         │
├────────────────────────────────┤
│  Rust FFI (EasyTierGuiFFI)     │
│  → easytier Core               │
└────────────────────────────────┘
```

Two paths to EasyTier Core:
1. **Direct** — Swift → C shim → Rust FFI → Core (StaticEasyTierFFIClient)
2. **Privileged** — Swift → XPC → helper daemon → Rust FFI → Core (for TUN)

Remote RPC also goes through FFI: Swift builds JSON-RPC payloads → C shim → Rust opens TCP to the remote RPC Portal.

## Star History

<div align="center">
  <a href="https://www.star-history.com/#socoldkiller/easytier-swift&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=socoldkiller/easytier-swift&type=Date&theme=dark" />
      <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=socoldkiller/easytier-swift&type=Date" />
      <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=socoldkiller/easytier-swift&type=Date" />
    </picture>
  </a>
</div>

## Credits

Built on top of [EasyTier](https://github.com/EasyTier/EasyTier). SwiftUI + Rust FFI for a native Mac feel.

Bugs and feature requests go in Issues. Pull requests welcome. Stars appreciated.

## License

MIT. EasyTier Core and its dependencies follow their own licenses.
