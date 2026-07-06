# Contributing to EasyTier for macOS

Thanks for considering a contribution! This file is a short orientation for the build, test, and release flow.

## Build

Requires **Xcode 16+** (Swift 6) and the **Rust nightly** toolchain.

```bash
git clone --recurse-submodules https://github.com/socoldkiller/easytier-macos.git
cd easytier-macos

# Build the Rust FFI static library
make build-ffi

# Build the Swift app
make build

# Package as DMG
make dmg
```

Output paths:
- App bundle: `.build/debug/EasyTierMac.app`
- FFI library: `Rust/EasyTierGuiFFI/target/`
- DMG: `easytier-mac.dmg`

See the `Makefile` for the exact invocations.

## Test

```bash
# Swift Testing suite (shared layer: config codec, RPC payloads, peer subscriptions, updater)
swift test --configuration release

# Rust FFI unit tests
cd Rust/EasyTierGuiFFI && cargo test
```

The Swift tests live under `Tests/EasyTierSharedTests/` and cover the platform-neutral `EasyTierShared` module. The GUI and privileged helper layers do not currently have automated tests — please exercise them manually before submitting a UI or daemon change.

## Project layout

```
Sources/
  EasyTierMac/              SwiftUI app, menu bar, settings, update flow
  EasyTierShared/           Models, RPC codec, persistence store (testable layer)
  EasyTierPrivilegedHelper/ XPC daemon running as root (LaunchDaemon) for TUN
  EasyTierRuntime/          In-process EasyTier runtime glue
  CEasyTierFFI/             C shim that exposes the Rust FFI
Rust/EasyTierGuiFFI/        Rust crate that links against EasyTier Core
scripts/                    Packaging / signing / notarization / verification
Packaging/                  Entitlements and packaging metadata
.github/workflows/          CI: build, test, sign, notarize, publish update feed
```

## Conventions

- Match the surrounding Swift style. The project uses Swift 6 strict concurrency; avoid `@MainActor` leaks and unannotated `Sendable` types.
- No `print()` for diagnostics in the GUI/daemon layers. Use `EasyTierAppStore.recordNotice` / `recordLog` so messages surface in the in-app log panel.
- Avoid force-unwraps (`URL(string:)!`, `as!`). Prefer `guard let` or `??`.
- Keep the test layer pure where possible — anything in `EasyTierShared` should be exercised by `Tests/EasyTierSharedTests/`.

## Submitting

1. Open an issue describing the change before working on a non-trivial PR.
2. Branch from `main`, keep commits focused.
3. Make sure `swift test --configuration release` and `cargo test` pass locally.
4. PRs that touch the privileged helper or the packaging scripts should be tested with a full `make dmg` + `spctl -a -vvv` dry run on your machine.
5. Don't bump the version number in `Package.swift` or the update manifest yourself — the maintainers will tag the release.

## Releasing

Releases are cut by maintainers via git tags; the `macos-app.yml` workflow handles signing, notarization, stapling, DMG layout, and the update feed upload. The CI also publishes `minimumSystemVersion: 15.0` in the update manifest, so the minimum supported OS is macOS 15.

## License

By contributing, you agree your contributions will be licensed under the project's MIT license (see `LICENSE`).