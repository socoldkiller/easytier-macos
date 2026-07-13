# Sparkle Signing Setup

EasyTier pins Sparkle 2.9.4. Release packaging requires an EdDSA public key,
and feed generation requires the matching private key. The signing and appcast
commands themselves are owned by `scripts/release.sh`; this document only
describes durable key provisioning.

Generate the production key once on a trusted Mac:

```bash
swift package resolve
TOOLS=.build/artifacts/sparkle/Sparkle/bin
"$TOOLS/generate_keys" --account easytier-macos
"$TOOLS/generate_keys" --account easytier-macos -x /secure/offline/location/easytier-sparkle-private-key
```

The first command prints the base64 `SUPublicEDKey`. Configure GitHub with:

- Repository variable `SPARKLE_PUBLIC_ED_KEY`: the printed public key.
- Environment secret `SPARKLE_EDDSA_PRIVATE_KEY`: the exact contents of the
  exported private-key file.
- Repository secret `APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64`: the
  base64-encoded Developer ID profile that authorizes the app's Keychain group.

Keep an offline backup of the private-key file. Never commit it to this
repository or store it in a build artifact.

For local signed packaging, pass the public value explicitly:

```bash
make app-release-signed \
  CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
  PROVISIONING_PROFILE="/path/to/EasyTier.provisionprofile" \
  SPARKLE_PUBLIC_ED_KEY="base64-public-key"
```

For a final local DMG, use `make dmg` as documented in
[`Packaging/RELEASE.md`](RELEASE.md). The release module resolves the Sparkle
tools from the pinned Swift package, signs the final notarized DMG and appcast,
and rejects a private key that does not match the public key embedded in the
app.
