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
```

`publish` verifies the downloaded DMG again, enforces monotonic build numbers,
extracts release notes from `CHANGELOG.md`, generates and verifies the signed
Sparkle appcast and legacy `update.json`, and then creates the GitHub Release.

Tag reruns are recoverable. If an immutable DMG already exists on the GitHub
Release, the pipeline downloads and verifies that exact asset and generates the
feeds from its original bytes. It does not compare it with or replace a newly
built DMG, whose signing timestamps and notarization tickets may differ.

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

Those tests exercise metadata, version ordering, release notes, appcast fields,
the App/DMG notarization order, cleanup on failure, local and CI credential
adapters, and immutable-asset reuse on a tag rerun.
