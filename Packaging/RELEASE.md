# Release Pipeline

EasyTier has one release implementation: `scripts/release.sh`. Xcode owns the
native App archive and nested signing; local builds and GitHub Actions provide
credentials to the same release module for notarization, DMG, and Sparkle.

## Final DMG on a trusted Mac

Required local assets:

- A Developer ID Application certificate and private key.
- A Developer ID provisioning profile for `com.kkrainbow.easytier.mac` that
  authorizes the app's Data Protection Keychain group.
- The production Sparkle public key.
- A valid `notarytool` Keychain profile.

Build from an exact version tag so the app version and 14-digit build number are
derived deterministically:

```bash
git switch --detach v1.4.0

make dmg \
  CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
  PROVISIONING_PROFILE="/path/to/EasyTier.provisionprofile" \
  SPARKLE_PUBLIC_ED_KEY="base64-public-key"
```

`make dmg` defaults to the `easytier-notary` profile. If the credentials are in
a dedicated Keychain, pass it explicitly:

```bash
make dmg \
  CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
  CODESIGN_KEYCHAIN="$HOME/Library/Keychains/easytier-signing.keychain-db" \
  PROVISIONING_PROFILE="/path/to/EasyTier.provisionprofile" \
  SPARKLE_PUBLIC_ED_KEY="base64-public-key" \
  NOTARY_PROFILE="easytier-notary" \
  NOTARY_KEYCHAIN="$HOME/Library/Keychains/easytier-signing.keychain-db"
```

The Makefile automatically uses that dedicated Keychain path when it exists.
For an untagged pre-release build, set `APP_VERSION=1.4.0`; optionally set a
stable `BUILD_NUMBER=YYYYMMDDhhmmss` as well.

The final outputs are:

```text
.build/AppProducts/EasyTier.xcarchive
.build/artifacts/EasyTier.app
.build/artifacts/EasyTier-macOS-ARM64.dmg
.build/artifacts/EasyTier-macOS-ARM64.metadata.json
```

`scripts/archive-app.sh` temporarily installs the supplied provisioning profile
in Xcode's user profile directory, archives `EasyTierMac`, copies the app from
`Products/Applications`, verifies it, and removes only the temporary installed
profile. The Xcode project owns bundle assembly and nested code signing; the
release module never rebuilds the app layout by hand.

The DMG target is not a shortcut for an intermediate signed image. It always
runs this complete state machine:

```text
Xcode archive/sign/verify App
-> notarize and staple App
-> create DMG from the stapled App
-> notarize and staple DMG
-> simulate a quarantined download and verify Gatekeeper
-> write release metadata
```

Any failed stage stops the pipeline. It never emits metadata that claims a
partially completed DMG is releasable.

## GitHub configuration

Tag builds require these repository secrets:

- `APPLE_DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`
- `APPLE_DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD`
- `APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64`
- `APPLE_KEYCHAIN_PASSWORD`
- `APPLE_CODESIGN_IDENTITY`
- `APPLE_NOTARY_KEY`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`

They also require:

- Repository variable `SPARKLE_PUBLIC_ED_KEY`.
- `github-pages` environment or repository secret
  `SPARKLE_EDDSA_PRIVATE_KEY`.

The workflow keeps only the platform adapters: checkout, certificate import,
artifact transfer, and the official GitHub Pages actions. It calls:

```bash
./scripts/release.sh artifact
./scripts/release.sh publish
./scripts/release.sh verify-deployed-feeds
./scripts/release.sh prune-nightlies
```

`publish` verifies the downloaded DMG again, enforces monotonic build numbers,
generates release notes, updates only the selected branch in the signed Sparkle
appcast, and then creates the GitHub Release. Stable publication updates the
legacy-compatible `update.json`; Nightly publication updates `nightly.json` and
preserves `update.json` byte-for-byte.

Tag reruns are recoverable. If an immutable DMG already exists on the GitHub
Release, the pipeline downloads and verifies that exact asset and generates the
feeds from its original bytes. It does not compare it with or replace a newly
built DMG, whose signing timestamps and notarization tickets may differ.

## Stable and Nightly channels

Numeric `v*` tags publish Stable releases from the GUI repository's pinned
EasyTier submodule. The appcast item has no explicit Sparkle channel.

The scheduled workflow starts daily at 02:00 Asia/Shanghai. It checks out the
workflow's exact GUI `main` SHA and the exact EasyTier Core `origin/main` SHA,
then builds and tests that pair. If both SHAs match `nightly.json`, the workflow
finishes without signing or publishing a duplicate. Otherwise it may publish:

- Version: the most recent reachable numeric GUI tag.
- Build: the workflow run creation time as UTC `YYYYMMDDHHMMSS`.
- Tag: `nightly-YYYYMMDDHHMMSS`.
- Asset: an immutable, signed, notarized Nightly DMG.
- Release: a GitHub prerelease targeting the exact GUI SHA.

Set repository variable `NIGHTLY_RELEASES_ENABLED=true` after the first manual
Nightly validation. Scheduled runs always build and test, but only publish when
that variable is enabled. A `workflow_dispatch` run with mode `nightly` may
publish before the schedule is enabled.

Both channels share one signed `appcast.xml`. Publication downloads the current
Pages state after acquiring the global feed concurrency lock, retains one
latest item per channel, and fails closed if an existing channel cannot be
preserved. `prune-nightlies` runs only after Pages verification and keeps the
newest 14 Nightly prereleases and tags.

## Credential handling

The CI API key and decoded provisioning profile are written only into a mode
`0700` temporary directory with mode `0600` files. A process exit trap removes
them on success or failure. Local `notarytool` profiles avoid exposing the
notarization private key to the process environment.

Sparkle key creation and backup are documented in `Packaging/SPARKLE.md`.
Never commit certificates, profiles, private keys, passwords, or exported
Sparkle seeds. Do not copy the low-level release commands into a second manual;
keep operational notes limited to credential locations and the unified command.

## Verification

Credential-free release logic is covered by:

```bash
make test-packaging
```

Data Protection Keychain routing is also covered by a signed app-like harness.
It uses a unique test service/account, verifies a protected write and a one-way
legacy migration, then precisely removes both test backends:

```bash
make test-keychain-integration \
  CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
  PROVISIONING_PROFILE="/path/to/EasyTier.provisionprofile"
```

Publishing CI runs this gate after importing the Developer ID certificate and
before building, notarizing, or uploading the release artifact. Ordinary pull
requests continue to run the credential-free query-construction tests.

Those tests exercise metadata, per-channel version ordering, Stable/Nightly
release notes, combined appcast fields, feed preservation, the App/DMG
notarization order, cleanup on failure, immutable-asset reuse, and Nightly
retention.
