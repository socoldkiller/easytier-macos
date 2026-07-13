#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/easytier-release-tests.XXXXXX")"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_HELPERS="$TEST_ROOT/helpers"
ARTIFACTS_DIR="$TEST_ROOT/artifacts"
TEMP_PARENT="$TEST_ROOT/temporary"
TRACE_FILE="$TEST_ROOT/trace.txt"
ARGS_TRACE="$TEST_ROOT/arguments.txt"
PROFILE_PATH="$TEST_ROOT/EasyTier.provisionprofile"
KEYCHAIN_PATH="$TEST_ROOT/easytier-signing.keychain-db"
PUBLIC_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN" "$FAKE_HELPERS" "$ARTIFACTS_DIR" "$TEMP_PARENT"
touch "$PROFILE_PATH" "$KEYCHAIN_PATH" "$TRACE_FILE" "$ARGS_TRACE"

cat > "$FAKE_HELPERS/build-ffi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'build-ffi\n' >> "$TRACE_FILE"
EOF

cat > "$FAKE_HELPERS/package-app" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'package-app\n' >> "$TRACE_FILE"
mkdir -p "$EASYTIER_EXPORT_APP_DIR/Contents/MacOS"
printf '#!/usr/bin/env bash\n' > "$EASYTIER_EXPORT_APP_DIR/Contents/MacOS/EasyTierMac"
chmod +x "$EASYTIER_EXPORT_APP_DIR/Contents/MacOS/EasyTierMac"
python3 - "$EASYTIER_EXPORT_APP_DIR/Contents/Info.plist" <<'PY'
import pathlib
import plistlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open("wb") as handle:
    plistlib.dump(
        {
            "CFBundleShortVersionString": "1.4.0",
            "CFBundleVersion": "20260714010203",
        },
        handle,
    )
PY
EOF

cat > "$FAKE_HELPERS/create-dmg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
app_path="$1"
dmg_path="$2"
[[ -f "$app_path.stapled" ]] || {
  echo "DMG creation ran before the app was stapled." >&2
  exit 1
}
printf 'create-dmg\n' >> "$TRACE_FILE"
mkdir -p "$(dirname "$dmg_path")"
printf 'fake dmg\n' > "$dmg_path"
EOF

cat > "$FAKE_HELPERS/verify-dmg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dmg_path="$1"
[[ -f "$dmg_path.stapled" ]] || {
  echo "Release verification ran before the DMG was stapled." >&2
  exit 1
}
printf 'verify-dmg\n' >> "$TRACE_FILE"
EOF

cat > "$FAKE_BIN/ditto" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
for argument in "$@"; do
  output="$argument"
done
printf 'archive-app\n' >> "$TRACE_FILE"
printf 'fake archive\n' > "$output"
EOF

cat > "$FAKE_BIN/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$ARGS_TRACE"
if [[ "$1" == "notarytool" && "$2" == "submit" ]]; then
  if [[ "$3" == *.dmg ]]; then
    printf 'notary-dmg\n' >> "$TRACE_FILE"
    if [[ "${FAIL_DMG_NOTARY:-0}" == "1" ]]; then
      exit 42
    fi
  else
    printf 'notary-app\n' >> "$TRACE_FILE"
  fi
  printf '{"status":"Accepted","id":"fake-submission"}\n'
  exit 0
fi
if [[ "$1" == "stapler" && "$2" == "staple" ]]; then
  if [[ "$3" == *.dmg ]]; then
    printf 'staple-dmg\n' >> "$TRACE_FILE"
  else
    printf 'staple-app\n' >> "$TRACE_FILE"
  fi
  touch "$3.stapled"
  exit 0
fi
if [[ "$1" == "stapler" && "$2" == "validate" ]]; then
  [[ -f "$3.stapled" ]]
  if [[ "$3" == *.dmg ]]; then
    printf 'validate-dmg\n' >> "$TRACE_FILE"
  else
    printf 'validate-app\n' >> "$TRACE_FILE"
  fi
  exit 0
fi
echo "Unexpected xcrun invocation: $*" >&2
exit 1
EOF

cat > "$FAKE_BIN/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'codesign-app\n' >> "$TRACE_FILE"
EOF

cat > "$FAKE_BIN/spctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gatekeeper-app\n' >> "$TRACE_FILE"
EOF

chmod +x "$FAKE_BIN"/* "$FAKE_HELPERS"/*

run_artifact() {
  PATH="$FAKE_BIN:$PATH" \
  TRACE_FILE="$TRACE_FILE" \
  ARGS_TRACE="$ARGS_TRACE" \
  EASYTIER_ARTIFACTS_DIR="$ARTIFACTS_DIR" \
  EASYTIER_RELEASE_TEMP_PARENT="$TEMP_PARENT" \
  EASYTIER_RELEASE_ARCHITECTURE=ARM64 \
  EASYTIER_RELEASE_BUILD_FFI_SCRIPT="$FAKE_HELPERS/build-ffi" \
  EASYTIER_RELEASE_PACKAGE_APP_SCRIPT="$FAKE_HELPERS/package-app" \
  EASYTIER_RELEASE_CREATE_DMG_SCRIPT="$FAKE_HELPERS/create-dmg" \
  EASYTIER_RELEASE_VERIFY_DMG_SCRIPT="$FAKE_HELPERS/verify-dmg" \
  EASYTIER_CODESIGN_IDENTITY="Developer ID Application: Test (ABCDEFGHIJ)" \
  EASYTIER_PROVISIONING_PROFILE="$PROFILE_PATH" \
  EASYTIER_SPARKLE_PUBLIC_ED_KEY="$PUBLIC_KEY" \
  EASYTIER_APP_VERSION=1.4.0 \
  EASYTIER_BUILD_NUMBER=20260714010203 \
  "$ROOT_DIR/scripts/release.sh" artifact
}

APPLE_NOTARY_KEY=fake-private-key \
APPLE_NOTARY_KEY_ID=FAKEKEY123 \
APPLE_NOTARY_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
run_artifact > "$TEST_ROOT/ci-artifact.log"

cat > "$TEST_ROOT/expected-trace.txt" <<'EOF'
build-ffi
package-app
archive-app
notary-app
staple-app
validate-app
codesign-app
gatekeeper-app
create-dmg
notary-dmg
staple-dmg
validate-dmg
verify-dmg
EOF

diff -u "$TEST_ROOT/expected-trace.txt" "$TRACE_FILE"
test -s "$ARTIFACTS_DIR/EasyTier-macOS-ARM64.dmg"
test -s "$ARTIFACTS_DIR/EasyTier-macOS-ARM64.metadata.json"
if find "$TEMP_PARENT" -mindepth 1 -print -quit | grep -q .; then
  echo "Temporary notarization credentials were not removed." >&2
  exit 1
fi

rm -rf "$ARTIFACTS_DIR"
mkdir -p "$ARTIFACTS_DIR"
: > "$TRACE_FILE"
: > "$ARGS_TRACE"
if APPLE_NOTARY_KEY=fake-private-key \
   APPLE_NOTARY_KEY_ID=FAKEKEY123 \
   APPLE_NOTARY_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
   FAIL_DMG_NOTARY=1 \
   run_artifact > "$TEST_ROOT/failing-artifact.log" 2>&1; then
  echo "Artifact creation unexpectedly survived a failed DMG notarization." >&2
  exit 1
fi
if grep -q '^verify-dmg$' "$TRACE_FILE"; then
  echo "Release verification ran after a failed notarization." >&2
  exit 1
fi
test ! -e "$ARTIFACTS_DIR/EasyTier-macOS-ARM64.metadata.json"
if find "$TEMP_PARENT" -mindepth 1 -print -quit | grep -q .; then
  echo "Temporary credentials survived a failed artifact build." >&2
  exit 1
fi

rm -rf "$ARTIFACTS_DIR"
mkdir -p "$ARTIFACTS_DIR"
: > "$TRACE_FILE"
: > "$ARGS_TRACE"
EASYTIER_NOTARY_KEYCHAIN_PROFILE=easytier-notary \
EASYTIER_NOTARY_KEYCHAIN="$KEYCHAIN_PATH" \
run_artifact > "$TEST_ROOT/local-artifact.log"

if ! grep -q -- '--keychain-profile easytier-notary' "$ARGS_TRACE"; then
  echo "Local notarization did not use the configured Keychain profile." >&2
  exit 1
fi
if ! grep -q -- "--keychain $KEYCHAIN_PATH" "$ARGS_TRACE"; then
  echo "Local notarization did not use the configured signing Keychain." >&2
  exit 1
fi

PUBLISH_ARTIFACTS="$TEST_ROOT/publish-artifacts"
PAGES_DIR="$TEST_ROOT/pages"
SPARKLE_TOOLS="$TEST_ROOT/sparkle-tools"
REMOTE_DMG_SOURCE="$TEST_ROOT/remote-release/EasyTier-macOS-ARM64.dmg"
CURRENT_FEED="$TEST_ROOT/current-update.json"
PUBLISH_TRACE="$TEST_ROOT/publish-trace.txt"
mkdir -p "$PUBLISH_ARTIFACTS" "$SPARKLE_TOOLS" "$(dirname "$REMOTE_DMG_SOURCE")"
printf 'new local build bytes\n' > "$PUBLISH_ARTIFACTS/EasyTier-macOS-ARM64.dmg"
printf 'already published immutable bytes\n' > "$REMOTE_DMG_SOURCE"
printf '{"tag":"v1.3.3","build":"20260713010203"}\n' > "$CURRENT_FEED"
cat > "$PUBLISH_ARTIFACTS/EasyTier-macOS-ARM64.metadata.json" <<'EOF'
{
  "architecture": "ARM64",
  "build": "20260714010203",
  "notarized": true,
  "schemaVersion": 1,
  "signing": "developer-id",
  "version": "1.4.0"
}
EOF
: > "$PUBLISH_TRACE"

cat > "$FAKE_HELPERS/verify-publish-dmg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if cmp -s "$1" "$REMOTE_DMG_SOURCE"; then
  printf 'verify-remote-dmg\n' >> "$PUBLISH_TRACE"
else
  printf 'verify-local-dmg\n' >> "$PUBLISH_TRACE"
fi
EOF

cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "release" && "$2" == "view" ]]; then
  printf 'gh-view\n' >> "$PUBLISH_TRACE"
  printf 'EasyTier-macOS-ARM64.dmg\n'
  exit 0
fi
if [[ "$1" == "release" && "$2" == "download" ]]; then
  destination=""
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == "--dir" ]]; then
      destination="$2"
      break
    fi
    shift
  done
  [[ -n "$destination" ]]
  printf 'gh-download\n' >> "$PUBLISH_TRACE"
  cp "$REMOTE_DMG_SOURCE" "$destination/$(basename "$REMOTE_DMG_SOURCE")"
  exit 0
fi
if [[ "$1" == "release" && "$2" == "edit" ]]; then
  printf 'gh-edit\n' >> "$PUBLISH_TRACE"
  exit 0
fi
if [[ "$1" == "release" && ( "$2" == "upload" || "$2" == "create" ) ]]; then
  echo "A rerun must not create or replace an existing DMG release asset." >&2
  exit 1
fi
echo "Unexpected gh invocation: $*" >&2
exit 1
EOF

cat > "$SPARKLE_TOOLS/generate_appcast" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
prefix=""
input=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    --download-url-prefix)
      prefix="$2"
      shift 2
      ;;
    --ed-key-file|--maximum-versions)
      shift 2
      ;;
    --embed-release-notes)
      shift
      ;;
    *)
      input="$1"
      shift
      ;;
  esac
done
dmg="$input/EasyTier-macOS-ARM64.dmg"
cmp -s "$dmg" "$REMOTE_DMG_SOURCE" || {
  echo "Sparkle did not receive the immutable remote DMG." >&2
  exit 1
}
size="$(wc -c < "$dmg" | tr -d ' ')"
printf 'generate-appcast-from-remote\n' >> "$PUBLISH_TRACE"
cat > "$output" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0" sparkle:signature="feed-signature">
  <channel>
    <item>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <enclosure url="${prefix}EasyTier-macOS-ARM64.dmg" length="$size" sparkle:version="20260714010203" sparkle:shortVersionString="1.4.0" sparkle:edSignature="archive-signature" />
    </item>
  </channel>
</rss>
XML
EOF

cat > "$SPARKLE_TOOLS/sign_update" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
file_path=""
for argument in "$@"; do
  if [[ "$argument" == *.dmg || "$argument" == *.xml ]]; then
    file_path="$argument"
    break
  fi
done
if [[ "$file_path" == *.dmg ]]; then
  cmp -s "$file_path" "$REMOTE_DMG_SOURCE"
  printf 'verify-remote-signature\n' >> "$PUBLISH_TRACE"
elif [[ "$file_path" == *.xml ]]; then
  printf 'verify-appcast-signature\n' >> "$PUBLISH_TRACE"
else
  echo "Could not find the signed file in sign_update arguments." >&2
  exit 1
fi
EOF

chmod +x "$FAKE_BIN/gh" "$FAKE_HELPERS/verify-publish-dmg" "$SPARKLE_TOOLS"/*

PATH="$FAKE_BIN:$PATH" \
PUBLISH_TRACE="$PUBLISH_TRACE" \
REMOTE_DMG_SOURCE="$REMOTE_DMG_SOURCE" \
EASYTIER_ARTIFACTS_DIR="$PUBLISH_ARTIFACTS" \
EASYTIER_PAGES_DIR="$PAGES_DIR" \
EASYTIER_RELEASE_TEMP_PARENT="$TEMP_PARENT" \
EASYTIER_RELEASE_VERIFY_DMG_SCRIPT="$FAKE_HELPERS/verify-publish-dmg" \
EASYTIER_SPARKLE_TOOLS_DIR="$SPARKLE_TOOLS" \
EASYTIER_CURRENT_FEED_PATH="$CURRENT_FEED" \
SPARKLE_EDDSA_PRIVATE_KEY=fake-sparkle-private-key \
TAG_NAME=v1.4.0 \
REPOSITORY=socoldkiller/easytier-macos \
GH_TOKEN=fake-token \
"$ROOT_DIR/scripts/release.sh" publish > "$TEST_ROOT/publish.log"

cat > "$TEST_ROOT/expected-publish-trace.txt" <<'EOF'
verify-local-dmg
gh-view
gh-download
verify-remote-dmg
generate-appcast-from-remote
verify-remote-signature
verify-appcast-signature
gh-edit
EOF
diff -u "$TEST_ROOT/expected-publish-trace.txt" "$PUBLISH_TRACE"

python3 - "$PAGES_DIR/update.json" "$REMOTE_DMG_SOURCE" <<'PY'
import hashlib
import json
import pathlib
import sys

feed_path = pathlib.Path(sys.argv[1])
dmg_path = pathlib.Path(sys.argv[2])
feed = json.loads(feed_path.read_text(encoding="utf-8"))
expected = hashlib.sha256(dmg_path.read_bytes()).hexdigest()
assert feed["assets"]["arm64"]["sha256"] == expected
assert feed["assets"]["arm64"]["size"] == dmg_path.stat().st_size
PY

if find "$TEMP_PARENT" -mindepth 1 -print -quit | grep -q .; then
  echo "Temporary Sparkle credentials survived publish." >&2
  exit 1
fi

echo "Release artifact and rerun state-machine tests passed."
