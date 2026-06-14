# EasyTier Native Mac

Native SwiftUI macOS client for EasyTier. The app is intentionally separate from the upstream EasyTier monorepo while reusing EasyTier's Rust FFI layer from `Vendor/EasyTier/easytier-contrib/easytier-ffi`.

Minimum deployment target: macOS 14.0.

## What is implemented

- SwiftUI macOS app shell with sidebar, toolbar, menu bar extra, Status / Config / Logs views.
- Swift data models mirroring the existing EasyTier web GUI network config and runtime status shape.
- JSON persistence under `Application Support/EasyTier/state.json`.
- TOML import/export for EasyTier configs.
- Static FFI bridge through `CEasyTierFFI`; the GUI links EasyTier into the app binary instead of loading a runtime dylib.
- Scripts for bootstrap, FFI XCFramework creation, and tests.

## Quick start

```sh
./scripts/bootstrap.sh
./scripts/build-ffi.sh
swift test
swift run EasyTierMac
```

## CI/CD

GitHub Actions workflow `.github/workflows/macos-app.yml` builds and uploads a
macOS app artifact on pushes to `main` / `master`, pull requests, and manual
workflow runs.

The workflow runs these steps on macOS:

```sh
./scripts/bootstrap.sh
./scripts/build-ffi.sh
swift test --configuration release
EASYTIER_BUILD_CONFIGURATION=release ./scripts/package-app.sh
```

Download the packaged app from the workflow artifact named
`EasyTier-macOS-<arch>`. Pushing a version tag such as `v0.1.0` also publishes
the same `.app.zip` to the GitHub Release for that tag.

The vendored EasyTier core is built from tag `v2.6.4` by default. Override it
for a one-off core upgrade with `EASYTIER_CORE_TAG=vX.Y.Z ./scripts/build-ffi.sh`.

The Rust FFI is built as a universal static library and static XCFramework:

```sh
./scripts/build-ffi.sh
```

SwiftPM links `Vendor/Frameworks/static/libeasytier_ffi.a` through the local `CEasyTierFFI` C module. No EasyTier dylib is required at runtime.

## Notes

- This is the practical v1 surface: normal runtime through FFI, config editing, status polling, config-server hooks, logs, and native macOS controls.
- Service-mode install/start/stop parity depends on additional upstream FFI exports and is represented in the UI/model for the next implementation pass.
- ACL editing and graph visualization are intentionally deferred.
