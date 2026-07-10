# Contributing to EasyTier for macOS

Thanks for considering a contribution! This file is a short orientation for the build, test, and release flow.

## Build

Requires **Xcode 16+** (Swift 6), **Rust 1.95+ stable**, and the Protocol Buffers compiler (`protoc`).

```bash
git clone --recurse-submodules https://github.com/socoldkiller/easytier-macos.git
cd easytier-macos

make bootstrap   # verify the toolchain
make ffi         # build the current-architecture Rust FFI archive
make app-debug   # package an ad-hoc debug app
make dmg-adhoc   # package a single ad-hoc DMG
```

Output paths:
- App bundle: `.build/artifacts/EasyTier.app`
- FFI library: `Vendor/Frameworks/static/libeasytier_ffi.a`
- DMG: `.build/artifacts/EasyTier-macOS-$(uname -m).dmg`

See the `Makefile` for the exact invocations.

## Test

```bash
make test-swift
make test-rust

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
3. Make sure `make test` passes locally.
4. PRs that touch the privileged helper or packaging scripts should run `make smoke`; Developer ID release changes also need a `make dmg-signed ...` dry run by a maintainer with signing credentials.
5. Don't edit release version metadata or the update manifest yourself — the release tag supplies the version.

## Releasing

Releases are cut by maintainers via git tags; the `macos-app.yml` workflow handles signing, notarization, stapling, DMG layout, and the update feed upload. The CI also publishes `minimumSystemVersion: 15.0` in the update manifest, so the minimum supported OS is macOS 15.

## License

By contributing, you agree your contributions will be licensed under the project's MIT license (see `LICENSE`).
