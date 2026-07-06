# Changelog

All notable changes to EasyTier for macOS are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Corrected the License string in the About pane: the app is MIT-licensed, not LGPL-3.0.
- Unified the minimum supported macOS version to 15.0 across `Package.swift`, the generated `Info.plist` (`LSMinimumSystemVersion`), the README badges, and the update-feed `minimumSystemVersion`. Previously the badge/prose/Info.plist claimed macOS 14+ while `Package.swift` required macOS 15.
- Aligned the README "App modes" section with the actual UI. The app now documents two modes — **Normal** and **Config Server** — instead of an unimplemented third "Remote" mode. Per-peer remote rename via RPC is described separately as a device-table capability.
- The privileged helper `LaunchDaemon` now ships with `RunAtLoad=false` so the daemon only starts on demand when a TUN network is requested, matching the README's description of helper behavior. Previously the helper launched at every login.

## [1.0.0] — Unreleased

Initial production release of EasyTier for macOS.

### Features
- **Menu bar resident**: real-time connection-state icon (gray stopped, pulsing connecting, green connected, red fault) with a popover panel for current network + device info.
- **Device table**: per-node view with device name and IP (click-to-copy), route type (P2P / Relay / Local), tunnel protocol (TCP / UDP / QUIC / …), latency, upload, download, packet loss, NAT type, and EasyTier version. Double-click a device name to rename it; the change is pushed to the remote node over RPC in real time.
- **Traffic charts**: upload/download area charts with hover values, per-second refresh, and auto-scaled Y axis to avoid spike flattening.
- **Multi-network configs**: each network saved as a separate TOML file with independent start/stop. Switch between configs with `Cmd+[` / `Cmd+]`. Import/export TOML — fully compatible with the CLI config format. Config validation covers listener conflicts and port-forward conflicts.
- **Workspace tabs**: Status / Traffic / Config / Peers / Logs.
- **Peers view**: per-peer state with outbound subscription import and protocol allowlist.
- **App modes**: 
  - **Normal** — run a local EasyTier node with its own listeners and RPC server.
  - **Config Server** — pull the network profile from a remote server on launch, for fleet-style config distribution.
- **Privileged helper**: guided install of a `LaunchDaemon` (via `SMAppService`) for TUN. Non-TUN mode (`no_tun`) does not require the helper. Helper launches on demand only when a TUN network is requested.
- **Software update**: manifest-driven update flow with SHA256 verification, DMG install, skip/remind-me controls, and auto-check on launch. CI publishes the signed update feed.
- **Logging panel**: combined EasyTier Core output and app-level action log with search/filter, copy-to-clipboard, and export to file.
- **Launch at login**: `SMAppService.mainApp`-based login item toggle.
- **VPN On Demand**: keep networks running after app quit when desired.
- **Magic DNS**: configured system resolver split (only names under the EasyTier suffix are resolved by EasyTier; everything else keeps using system DNS).
- **Sleep/wake recovery**: detects long sleeps and restarts affected networks automatically.
- **Runtime intent replay**: persists and reconciles hostname/intent changes against the live Core state on reconnect.
- **Global search**: fuzzy filter across networks and member list.
- **Accessibility**: VoiceOver labels/hints across the menu bar, status, traffic, peers, and logs views; reduce-motion and reduce-transparency are respected throughout.
- **Linux install guide**: in-app reference for installing EasyTier on remote Linux peers.
- **Distribution**: CI-built, Developer-ID-signed, notarized, stapled DMG; updates served from a signed manifest JSON with `minimumSystemVersion: 15.0`.

### Known limitations
- No app sandbox: distributed via Developer ID only, not the Mac App Store.
- No bundled privacy manifest (`PrivacyInfo.xcprivacy`); planned for a future release.
- English-only UI; localization is planned post-1.0.
- The `AppMode.remote(remoteRPCAddress:)` case is defined for legacy compatibility but not currently produced by the UI; per-peer remote rename via RPC remains available from the device table.