# EasyTier Native Mac

Native SwiftUI macOS client for EasyTier. The app is intentionally separate from the upstream EasyTier monorepo while reusing EasyTier's Rust FFI layer from `Vendor/EasyTier/easytier-contrib/easytier-ffi`.

Minimum deployment target: macOS 14.0.

## What is implemented

- SwiftUI macOS app shell with sidebar, toolbar, menu bar extra, Status / Config / Logs views.
- Swift data models mirroring the existing EasyTier web GUI network config and runtime status shape.
- JSON persistence under `Application Support/EasyTier/state.json`.
- TOML import/export for EasyTier configs.
- Privileged helper runtime through `CEasyTierFFI`; the GUI talks to the helper over XPC and does not link the EasyTier FFI static library.
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

Pull request and branch artifacts are self-signed developer-mode builds. They
are not Developer ID signed or Apple notarized, but the artifact includes
`EasyTierLocalCodeSigning.cer` and `SELF_SIGNED_INSTALL.txt` so technical users
can explicitly trust the self-signed certificate and test the privileged helper.
Tag releases require Developer ID signing and notarization secrets.

For a self-signed artifact, install and trust the included certificate before
using the privileged helper:

```sh
security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  EasyTierLocalCodeSigning.cer
```

Then open `EasyTier.app` with Control-click > Open, click **Install Helper** in
EasyTier, and approve EasyTier in System Settings > General > Login Items &
Extensions if macOS asks. This self-signed path is for developer-mode testing;
normal public distribution still requires Developer ID signing and notarization.

For a local development app that only needs bundle/symbol verification, package
the app normally:

```sh
./scripts/package-app.sh
open ~/Applications/EasyTier.app
```

To install and verify the privileged helper during development, use the helper
installer script. It packages the app, uses a local development code-signing
identity when no Apple identity is available, clears stale development
Background Task Management state, registers the privileged helper, pings it, and
opens System Settings if macOS requires approval:

```sh
./scripts/dev-install-helper.sh
EASYTIER_OPEN_APP=1 ./scripts/dev-install-helper.sh
```

Disable the development Background Task Management reset with
`EASYTIER_RESET_BTM=0 ./scripts/dev-install-helper.sh` if you specifically want
to preserve existing Login Items & Extensions state.

You can also sign with an Apple-issued development identity when available:

```sh
EASYTIER_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/package-app.sh
```

Release tags require a Developer ID Application certificate and notarization.

During local development, stale macOS Background Task Management / lightweight
code requirement records can make `SMAppService` report the helper as enabled
while launchd refuses to start it with `OS_REASON_CODESIGNING` or `Launch
Constraint Violation`, or can leave the helper in `requiresApproval` / disallowed
state. Keep development cleanup in scripts, not in the app binary. Debug
packaging unregisters the old helper and quits any running `EasyTierMac` before
replacing `~/Applications/EasyTier.app`:

```sh
./scripts/package-app.sh
open ~/Applications/EasyTier.app
```

For `package-app.sh`, the stronger Background Task Management reset remains
explicit:

```sh
EASYTIER_RESET_BTM=1 ./scripts/package-app.sh
```

`EASYTIER_RESET_BTM=1` calls `sfltool resetbtm`, which is a global development
cleanup of Background Task Management state.

Download the packaged app from the workflow artifact named
`EasyTier-macOS-<arch>`. Pushing a version tag such as `v0.1.0` also publishes
the same `.app.zip` to the GitHub Release for that tag.

The vendored EasyTier core is built from tag `v2.6.4` by default. Override it
for a one-off core upgrade with `EASYTIER_CORE_TAG=vX.Y.Z ./scripts/build-ffi.sh`.

The Rust FFI is built as a universal static library and static XCFramework:

```sh
./scripts/build-ffi.sh
```

SwiftPM links `Vendor/Frameworks/static/libeasytier_ffi.a` through the local `CEasyTierFFI` C module only in `EasyTierRuntime`, which is only used by `EasyTierPrivilegedHelper`. `EasyTierMac` depends on `EasyTierShared` and uses the privileged helper over XPC for validation, start/stop, retain, and runtime status collection. No EasyTier dylib is required at runtime.

## Notes

- This is the practical v1 surface: normal runtime through FFI, config editing, status polling, config-server hooks, logs, and native macOS controls.
- Service-mode state is retained only for compatibility with older saved data. The UI exposes Normal and Remote modes until the helper/runtime path supports service-mode start/stop properly.
- ACL editing and graph visualization are intentionally deferred.
