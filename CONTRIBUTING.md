# Contributing to EasyTier for macOS

Thanks for considering a contribution! This file is a short orientation for the build, test, and release flow.

## Build

Requires **Xcode 16+** (Swift 6), **Rust 1.95+ stable**, and the Protocol Buffers compiler (`protoc`). App packaging also requires a Developer ID Application certificate, a matching provisioning profile that authorizes the app's Keychain access group, and the production Sparkle public key. A final DMG additionally requires a valid `notarytool` profile; building the FFI and running tests do not.

```bash
git clone --recurse-submodules https://github.com/socoldkiller/easytier-macos.git
cd easytier-macos

make bootstrap   # verify the toolchain
make ffi         # build the isolated Core/Gateway Rust FFI archives
make test        # run the Swift and Rust test suites

open EasyTier.xcodeproj  # run the native app or inspect Product > Archive

export CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
export PROVISIONING_PROFILE="/path/to/EasyTier.provisionprofile"
export SPARKLE_PUBLIC_ED_KEY="base64-public-key"
make app-debug CODESIGN_IDENTITY="$CODESIGN_IDENTITY" PROVISIONING_PROFILE="$PROVISIONING_PROFILE" SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY"
make dmg CODESIGN_IDENTITY="$CODESIGN_IDENTITY" PROVISIONING_PROFILE="$PROVISIONING_PROFILE" SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" APP_VERSION=1.4.0
```

Output paths:
- App bundle: `.build/artifacts/EasyTier.app`
- EasyTier Core FFI library: `Vendor/Frameworks/static/libeasytier_core_ffi.a`
- Gateway FFI library: `Vendor/Frameworks/static/libgateway_ffi.a`
- DMG: `.build/artifacts/EasyTier-macOS-ARM64.dmg`

See the `Makefile` for the exact invocations.

## Test

```bash
make test-swift
make test-rust
make test-packaging

# Run both suites
make test
```

The Swift tests live under `Tests/EasyTierSharedTests/` and cover the platform-neutral `EasyTierShared` module. The GUI and privileged helper layers do not currently have automated tests — please exercise them manually before submitting a UI or daemon change.

## Project layout

```
Sources/
  EasyTierMac/              SwiftUI app, menu bar, settings, update flow
  EasyTierShared/           Models, RPC codec, persistence store (testable layer)
  EasyTierPrivilegedHelper/ XPC daemon running as root (LaunchDaemon) for TUN
  EasyTierCoreRuntime/      EasyTier Core runtime glue
  GatewayRuntime/           Independent Gateway runtime glue
  CEasyTierCoreFFI/         C shim exposing only EasyTier Core FFI
  CGatewayFFI/              C shim exposing only Gateway FFI
Rust/EasyTierGuiFFI/        Rust crate built as mutually exclusive Core/Gateway archives
EasyTier.xcodeproj/         Native App/Helper/FFI assembly and Archive scheme
Configurations/            Shared Xcode build and signing settings
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
3. Make sure `make test` passes locally.
4. PRs that touch the privileged helper or packaging scripts should be validated by a maintainer with signing credentials using `make smoke` for the app and `make dmg` for the final signed, notarized, stapled, and Gatekeeper-verified image. Both commands require the Developer ID identity, provisioning profile, and Sparkle public key described in [`Packaging/RELEASE.md`](Packaging/RELEASE.md).
5. Don't edit release version metadata or the update manifest yourself — the release tag supplies the version.

## Releasing

Releases are cut by maintainers via git tags. Local builds and `macos-app.yml` both call the same `scripts/release.sh` module for signing, notarization, stapling, DMG verification, release metadata, Sparkle signing, and feed validation. GitHub Actions remains a thin credential/artifact/Pages adapter. See [`Packaging/RELEASE.md`](Packaging/RELEASE.md) for the complete flow and required secrets. The update feeds publish `minimumSystemVersion: 15.0`, so the minimum supported OS is macOS 15.

## License

By contributing, you agree your contributions will be licensed under the project's MIT license (see `LICENSE`).
