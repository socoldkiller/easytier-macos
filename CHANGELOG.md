# Changelog

All notable changes to EasyTier for macOS are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Added `Latest Stable` and opt-in `Nightly` software-update tracks. Nightly packages exact GUI and EasyTier Core `main` revisions in one signed, notarized DMG.

### Changed
- TOML export now omits `network_secret` by default without opening Keychain. Including it requires an explicit plaintext warning and fresh authentication.
- Keychain authentication is scoped to each action: start/restart/wake may reuse a recent Touch ID device unlock for 10 seconds, while reveal, export, update, and delete require a fresh context.
- Extended the signed Sparkle appcast to preserve one Stable and one Nightly channel item, with immutable daily prereleases, duplicate-source suppression, and retention of the newest 14 Nightly builds.
- Unified local and GitHub release builds behind one tested signing, notarization, DMG, and Sparkle pipeline. Tag reruns now reuse an existing immutable GitHub Release DMG when recovering a failed feed or Pages deployment.
- Removed the unused Config Server and legacy Remote app-mode paths. EasyTier now keeps one local runtime mode, with per-peer hostname updates handled separately through RPC.
- Simplified macOS packaging to publish one DMG and require Developer ID signing and Apple notarization for every release.
- Removed non-Developer-ID packaging fallbacks; local App and DMG packaging now require a Developer ID Application identity, secure timestamp, hardened runtime, and an installable privileged helper.
- Replaced the generated XCFramework/header pipeline with one current-architecture Rust static library and the tracked C header.

### Fixed
- Fixed a macOS Keychain routing bug where legacy cleanup could also match and delete the newly saved Data Protection Keychain item. Modern and legacy operations now select their backends explicitly, verify protected writes before cleanup, and run through a signed release-gate integration harness.
- Legacy network-password entries now migrate in the safe order of read, protected write, verification, then precise legacy deletion. Cleanup failures no longer discard a verified modern password and are retried later.
- Sleep/wake recovery waits until both the macOS user session and the app are active before requesting authentication, and transient Keychain-loaded plaintext is cleared when the app becomes inactive.
- Passwords that were already deleted by version 1.4.1 cannot be recovered and must be entered again after installing this update.
- Corrected the License string in the About pane: the app is MIT-licensed, not LGPL-3.0.
- Unified the minimum supported macOS version to 15.0 across `Package.swift`, the generated `Info.plist` (`LSMinimumSystemVersion`), the README badges, and the update-feed `minimumSystemVersion`. Previously the badge/prose/Info.plist claimed macOS 14+ while `Package.swift` required macOS 15.
- The privileged helper `LaunchDaemon` now ships with `RunAtLoad=false` so the daemon only starts on demand when a TUN network is requested, matching the README's description of helper behavior. Previously the helper launched at every login.

## [1.4.1] — 2026-07-16

### Changed
- Network passwords entered while enabling or restarting a configuration are now saved to the macOS Keychain before the runtime starts, so they remain available after relaunches and privileged-helper approval.

### Fixed
- A failed Keychain save now stops the connection attempt and surfaces the error instead of starting with a password that cannot be recovered.
- Pending starts that wait for privileged-helper approval no longer retain plaintext passwords; they reload the saved value from Keychain after approval.
- Stable publication now creates a new GitHub Release from the verified local DMG before switching to immutable-asset reuse on reruns.

## [1.4.0] — Unreleased

### Added
- Replaced the manual DMG updater with Sparkle 2.9.4. Installed copies can now verify, install, and relaunch updates without opening Finder or dragging the app into Applications.
- Added EdDSA-signed update archives and signed appcast/release-note validation before extraction.
- Running network configurations are stopped safely before replacement and restored once after the updated app relaunches.

### Changed
- Software Update now uses Sparkle's standard macOS interface for release notes, progress, skip/remind controls, errors, keyboard navigation, and accessibility.
- Automatic checks remain enabled by default on a daily schedule, while background download and silent installation stay disabled.
- Release CI now publishes an immutable notarized DMG, signed `appcast.xml`, and the legacy `update.json` from the same artifact.

### Migration
- v1.3.3 and earlier do not contain Sparkle, so installing v1.4.0 requires one final manual DMG replacement. In-app installation applies to updates from v1.4.0 onward.

## [1.0.0] — Unreleased

Initial production release of EasyTier for macOS.

### Features
- **Menu bar resident**: real-time connection-state icon (gray stopped, pulsing connecting, green connected, red fault) with a popover panel for current network + device info.
- **Device table**: per-node view with device name and IP (click-to-copy), route type (P2P / Relay / Local), tunnel protocol (TCP / UDP / QUIC / …), latency, upload, download, packet loss, NAT type, and EasyTier version. Double-click a device name to rename it; the change is pushed to the remote node over RPC in real time.
- **Traffic charts**: upload/download area charts with hover values, per-second refresh, and auto-scaled Y axis to avoid spike flattening.
- **Multi-network configs**: each network saved as a separate TOML file with independent start/stop. Switch between configs with `Cmd+[` / `Cmd+]`. Import/export TOML — fully compatible with the CLI config format. Config validation covers listener conflicts and port-forward conflicts.
- **Workspace tabs**: Status / Traffic / Config / Peers / Logs.
- **Peers view**: per-peer state with outbound subscription import and protocol allowlist.
- **Local runtime**: run local EasyTier nodes with their own listeners and an optional RPC portal.
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
- **Distribution**: CI publishes one Developer ID signed and Apple-notarized DMG; updates are served from a manifest JSON with `minimumSystemVersion: 15.0`.

### Known limitations
- No app sandbox: the app is distributed outside the Mac App Store with Developer ID signing and Apple notarization.
- No bundled privacy manifest (`PrivacyInfo.xcprivacy`); planned for a future release.
- English-only UI; localization is planned post-1.0.
