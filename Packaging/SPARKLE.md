# Sparkle Signing Setup

EasyTier pins Sparkle 2.9.4. Release packaging requires an EdDSA public key,
and feed generation requires the matching private key.

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

Keep an offline backup of the private-key file. Never commit it to this
repository or store it in a build artifact.

For local signed packaging, pass the public value explicitly:

```bash
make app-release-signed \
  CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
  SPARKLE_PUBLIC_ED_KEY="base64-public-key"
```

The release workflow derives the Sparkle tools from the pinned Swift package,
signs the final notarized DMG, signs `appcast.xml`, and rejects a private key
that does not match the public key embedded in the app.
