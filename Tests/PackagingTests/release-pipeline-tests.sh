#!/usr/bin/env bash
set -euo pipefail

# Fixtures define their own release context and must not inherit workflow state.
unset \
  EASYTIER_RELEASE_CHANNEL \
  EASYTIER_APP_VERSION \
  EASYTIER_BUILD_NUMBER \
  EASYTIER_BUILD_TIME \
  EASYTIER_GUI_REVISION \
  EASYTIER_CORE_REVISION \
  EASYTIER_CORE_VERSION

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

cat > "$FAKE_HELPERS/archive-app" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcode-archive\n' >> "$TRACE_FILE"
mkdir -p "$EASYTIER_EXPORT_APP_DIR/Contents/MacOS"
printf '#!/usr/bin/env bash\n' > "$EASYTIER_EXPORT_APP_DIR/Contents/MacOS/EasyTierMac"
chmod +x "$EASYTIER_EXPORT_APP_DIR/Contents/MacOS/EasyTierMac"
python3 - "$EASYTIER_EXPORT_APP_DIR/Contents/Info.plist" <<'PY'
import pathlib
import plistlib
import os
import sys

path = pathlib.Path(sys.argv[1])
with path.open("wb") as handle:
    plistlib.dump(
        {
            "CFBundleShortVersionString": os.environ.get("EASYTIER_APP_VERSION", "1.4.0"),
            "CFBundleVersion": os.environ.get("EASYTIER_BUILD_NUMBER", "20260714010203"),
            "EasyTierBuildChannel": os.environ.get("EASYTIER_BUILD_CHANNEL", "stable"),
            "EasyTierBuildTime": os.environ.get("EASYTIER_BUILD_TIME", "2026-07-14T01:02:03Z"),
            "EasyTierCoreCommit": os.environ.get("EASYTIER_CORE_REVISION", "b" * 40),
            "EasyTierCoreTag": os.environ.get("EASYTIER_CORE_VERSION", "v2.6.4"),
            "EasyTierGUICommit": os.environ.get("EASYTIER_GUI_REVISION", "a" * 40),
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

cat > "$FAKE_HELPERS/verify-app" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
app_path="$1"
stage="${2:-signed}"
[[ "$stage" == "notarized" ]] || {
  echo "Expected notarized App verification, got: $stage" >&2
  exit 1
}
[[ -f "$app_path.stapled" ]] || {
  echo "App verification ran before stapling." >&2
  exit 1
}
printf 'codesign-app\n' >> "$TRACE_FILE"
printf 'gatekeeper-app\n' >> "$TRACE_FILE"
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
    if [[ "${TRANSIENT_APP_NOTARY:-0}" == "1" && ! -f "$TRANSIENT_NOTARY_STATE" ]]; then
      touch "$TRANSIENT_NOTARY_STATE"
      echo 'Error: abortedUpload: Connection reset by peer' >&2
      exit 1
    fi
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
  EASYTIER_RELEASE_ARCHIVE_APP_SCRIPT="$FAKE_HELPERS/archive-app" \
  EASYTIER_RELEASE_CREATE_DMG_SCRIPT="$FAKE_HELPERS/create-dmg" \
  EASYTIER_RELEASE_VERIFY_APP_SCRIPT="$FAKE_HELPERS/verify-app" \
  EASYTIER_RELEASE_VERIFY_DMG_SCRIPT="$FAKE_HELPERS/verify-dmg" \
  EASYTIER_CODESIGN_IDENTITY="Developer ID Application: Test (ABCDEFGHIJ)" \
  EASYTIER_PROVISIONING_PROFILE="$PROFILE_PATH" \
  EASYTIER_SPARKLE_PUBLIC_ED_KEY="$PUBLIC_KEY" \
  EASYTIER_APP_VERSION="${TEST_APP_VERSION:-1.4.0}" \
  EASYTIER_BUILD_NUMBER="${TEST_BUILD_NUMBER:-20260714010203}" \
  "$ROOT_DIR/scripts/release.sh" artifact
}

APPLE_NOTARY_KEY=fake-private-key \
APPLE_NOTARY_KEY_ID=FAKEKEY123 \
APPLE_NOTARY_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
run_artifact > "$TEST_ROOT/ci-artifact.log"

cat > "$TEST_ROOT/expected-trace.txt" <<'EOF'
xcode-archive
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
TRANSIENT_NOTARY_STATE="$TEST_ROOT/transient-notary-state"
rm -f "$TRANSIENT_NOTARY_STATE"
APPLE_NOTARY_KEY=fake-private-key \
APPLE_NOTARY_KEY_ID=FAKEKEY123 \
APPLE_NOTARY_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
TRANSIENT_APP_NOTARY=1 \
TRANSIENT_NOTARY_STATE="$TRANSIENT_NOTARY_STATE" \
EASYTIER_NOTARY_RETRY_DELAY_SECONDS=0 \
run_artifact > "$TEST_ROOT/retried-artifact.log" 2>&1
[[ "$(grep -c '^notary-app$' "$TRACE_FILE")" == "2" ]] || {
  echo "Transient notarization upload was not retried exactly once." >&2
  exit 1
}
test -s "$ARTIFACTS_DIR/EasyTier-macOS-ARM64.dmg"

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

rm -rf "$ARTIFACTS_DIR"
mkdir -p "$ARTIFACTS_DIR"
: > "$TRACE_FILE"
: > "$ARGS_TRACE"
TEST_BUILD_NUMBER=20260715020000 \
EASYTIER_RELEASE_CHANNEL=nightly \
EASYTIER_BUILD_TIME=2026-07-15T02:00:00Z \
EASYTIER_GUI_REVISION=dddddddddddddddddddddddddddddddddddddddd \
EASYTIER_CORE_REVISION=cccccccccccccccccccccccccccccccccccccccc \
EASYTIER_CORE_VERSION=v2.6.4-40-gc0ffee00 \
EASYTIER_NOTARY_KEYCHAIN_PROFILE=easytier-notary \
EASYTIER_NOTARY_KEYCHAIN="$KEYCHAIN_PATH" \
run_artifact > "$TEST_ROOT/nightly-artifact.log"

NIGHTLY_ARTIFACT="$ARTIFACTS_DIR/EasyTier-macOS-ARM64-nightly-20260715020000.dmg"
NIGHTLY_METADATA="${NIGHTLY_ARTIFACT%.dmg}.metadata.json"
test -s "$NIGHTLY_ARTIFACT"
python3 - "$NIGHTLY_METADATA" <<'PY'
import json
import pathlib
import sys

metadata = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert metadata["channel"] == "nightly"
assert metadata["build"] == "20260715020000"
assert metadata["guiCommit"] == "d" * 40
assert metadata["coreCommit"] == "c" * 40
PY

PUBLISH_ARTIFACTS="$TEST_ROOT/publish-artifacts"
PAGES_DIR="$TEST_ROOT/pages"
SPARKLE_TOOLS="$TEST_ROOT/sparkle-tools"
REMOTE_DMG_SOURCE="$TEST_ROOT/remote-release/EasyTier-macOS-ARM64.dmg"
CURRENT_FEED="$TEST_ROOT/current-update.json"
CURRENT_PAGES="$TEST_ROOT/current-pages"
PUBLISH_TRACE="$TEST_ROOT/publish-trace.txt"
mkdir -p "$PUBLISH_ARTIFACTS" "$SPARKLE_TOOLS" "$CURRENT_PAGES" "$(dirname "$REMOTE_DMG_SOURCE")"
printf 'new local build bytes\n' > "$PUBLISH_ARTIFACTS/EasyTier-macOS-ARM64.dmg"
printf 'already published immutable bytes\n' > "$REMOTE_DMG_SOURCE"
printf '{"tag":"v1.3.3","build":"20260713010203","channel":"stable"}\n' > "$CURRENT_FEED"
cp "$CURRENT_FEED" "$CURRENT_PAGES/update.json"
cat > "$CURRENT_PAGES/appcast.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0" sparkle:signature="old-feed-signature">
  <channel>
    <item>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <enclosure url="https://example.invalid/old.dmg" length="1" sparkle:version="20260713010203" sparkle:shortVersionString="1.3.3" sparkle:edSignature="old-signature" />
    </item>
  </channel>
</rss>
EOF
cat > "$PUBLISH_ARTIFACTS/EasyTier-macOS-ARM64.metadata.json" <<'EOF'
{
  "architecture": "ARM64",
  "build": "20260714010203",
  "buildTime": "2026-07-14T01:02:03Z",
  "channel": "stable",
  "coreCommit": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "coreVersion": "v2.6.4",
  "guiCommit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "notarized": true,
  "schemaVersion": 2,
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
  if [[ "${PUBLISH_RELEASE_EXISTS:-1}" == "0" ]]; then
    exit 1
  fi
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
if [[ "$1" == "release" && "$2" == "create" ]]; then
  [[ "${PUBLISH_RELEASE_EXISTS:-1}" == "0" ]]
  [[ " $* " != *" --prerelease "* ]]
  printf 'gh-create-stable\n' >> "$PUBLISH_TRACE"
  exit 0
fi
if [[ "$1" == "release" && "$2" == "upload" ]]; then
  [[ "${PUBLISH_RELEASE_EXISTS:-1}" == "0" ]]
  printf 'gh-upload-stable\n' >> "$PUBLISH_TRACE"
  exit 0
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
if [[ "${PUBLISH_RELEASE_EXISTS:-1}" == "0" ]]; then
  cmp -s "$dmg" "$LOCAL_DMG_SOURCE" || {
    echo "Sparkle did not receive the initial local DMG." >&2
    exit 1
  }
  printf 'generate-appcast-from-local\n' >> "$PUBLISH_TRACE"
else
  cmp -s "$dmg" "$REMOTE_DMG_SOURCE" || {
    echo "Sparkle did not receive the immutable remote DMG." >&2
    exit 1
  }
  printf 'generate-appcast-from-remote\n' >> "$PUBLISH_TRACE"
fi
size="$(wc -c < "$dmg" | tr -d ' ')"
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
  if [[ "${PUBLISH_RELEASE_EXISTS:-1}" == "0" ]]; then
    cmp -s "$file_path" "$LOCAL_DMG_SOURCE"
    printf 'verify-local-signature\n' >> "$PUBLISH_TRACE"
  else
    cmp -s "$file_path" "$REMOTE_DMG_SOURCE"
    printf 'verify-remote-signature\n' >> "$PUBLISH_TRACE"
  fi
elif [[ "$file_path" == *.xml ]]; then
  printf 'verify-appcast-signature\n' >> "$PUBLISH_TRACE"
else
  echo "Could not find the signed file in sign_update arguments." >&2
  exit 1
fi
EOF

chmod +x "$FAKE_BIN/gh" "$FAKE_HELPERS/verify-publish-dmg" "$SPARKLE_TOOLS"/*

run_stable_publish_fixture() {
  local trace_path="$1"
  local pages_path="$2"
  local current_pages_path="$3"
  local allow_missing_current_feed="${4:-0}"
  local release_exists="${5:-1}"

  PATH="$FAKE_BIN:$PATH" \
  PUBLISH_TRACE="$trace_path" \
  REMOTE_DMG_SOURCE="$REMOTE_DMG_SOURCE" \
  LOCAL_DMG_SOURCE="$PUBLISH_ARTIFACTS/EasyTier-macOS-ARM64.dmg" \
  PUBLISH_RELEASE_EXISTS="$release_exists" \
  EASYTIER_ARTIFACTS_DIR="$PUBLISH_ARTIFACTS" \
  EASYTIER_PAGES_DIR="$pages_path" \
  EASYTIER_RELEASE_TEMP_PARENT="$TEMP_PARENT" \
  EASYTIER_RELEASE_VERIFY_DMG_SCRIPT="$FAKE_HELPERS/verify-publish-dmg" \
  EASYTIER_SPARKLE_TOOLS_DIR="$SPARKLE_TOOLS" \
  EASYTIER_CURRENT_FEED_PATH="$CURRENT_FEED" \
  EASYTIER_CURRENT_PAGES_DIR="$current_pages_path" \
  EASYTIER_ALLOW_MISSING_CURRENT_FEED="$allow_missing_current_feed" \
  SPARKLE_EDDSA_PRIVATE_KEY=fake-sparkle-private-key \
  TAG_NAME=v1.4.0 \
  REPOSITORY=socoldkiller/easytier-macos \
  GH_TOKEN=fake-token \
  "$ROOT_DIR/scripts/release.sh" publish
}

run_stable_publish_fixture "$PUBLISH_TRACE" "$PAGES_DIR" "$CURRENT_PAGES" > "$TEST_ROOT/publish.log"

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

BOOTSTRAP_CURRENT_PAGES="$TEST_ROOT/bootstrap-current-pages"
BOOTSTRAP_PAGES="$TEST_ROOT/bootstrap-pages"
BOOTSTRAP_FAILURE_TRACE="$TEST_ROOT/bootstrap-failure-trace.txt"
BOOTSTRAP_SUCCESS_TRACE="$TEST_ROOT/bootstrap-success-trace.txt"
mkdir -p "$BOOTSTRAP_CURRENT_PAGES"
cp "$CURRENT_FEED" "$BOOTSTRAP_CURRENT_PAGES/update.json"
: > "$BOOTSTRAP_FAILURE_TRACE"
: > "$BOOTSTRAP_SUCCESS_TRACE"

if run_stable_publish_fixture \
  "$BOOTSTRAP_FAILURE_TRACE" \
  "$BOOTSTRAP_PAGES" \
  "$BOOTSTRAP_CURRENT_PAGES" \
  0 \
  0 > "$TEST_ROOT/bootstrap-failure.log" 2>&1; then
  echo "Stable publish unexpectedly bootstrapped a missing appcast without an override." >&2
  exit 1
fi
grep -F "Could not load the existing appcast; refusing to replace another update channel." \
  "$TEST_ROOT/bootstrap-failure.log" >/dev/null

run_stable_publish_fixture \
  "$BOOTSTRAP_SUCCESS_TRACE" \
  "$BOOTSTRAP_PAGES" \
  "$BOOTSTRAP_CURRENT_PAGES" \
  1 \
  0 > "$TEST_ROOT/bootstrap-success.log"
test -s "$BOOTSTRAP_PAGES/appcast.xml"
test -s "$BOOTSTRAP_PAGES/update.json"
grep -F 'sparkle:shortVersionString="1.4.0"' "$BOOTSTRAP_PAGES/appcast.xml" >/dev/null
grep -F "generate-appcast-from-local" "$BOOTSTRAP_SUCCESS_TRACE" >/dev/null
grep -F "verify-local-signature" "$BOOTSTRAP_SUCCESS_TRACE" >/dev/null
grep -F "gh-create-stable" "$BOOTSTRAP_SUCCESS_TRACE" >/dev/null
grep -F "gh-upload-stable" "$BOOTSTRAP_SUCCESS_TRACE" >/dev/null
grep -F \
  "EASYTIER_ALLOW_MISSING_CURRENT_FEED: \${{ needs.build.outputs.tag_name == 'v1.4.0' && '1' || '0' }}" \
  "$ROOT_DIR/.github/workflows/macos-app.yml" >/dev/null

if find "$TEMP_PARENT" -mindepth 1 -print -quit | grep -q .; then
  echo "Temporary Sparkle credentials survived Stable appcast bootstrap." >&2
  exit 1
fi

NIGHTLY_ARTIFACTS="$TEST_ROOT/nightly-artifacts"
NIGHTLY_PAGES="$TEST_ROOT/nightly-pages"
NIGHTLY_CURRENT_PAGES="$TEST_ROOT/nightly-current-pages"
NIGHTLY_CURRENT_FEED="$TEST_ROOT/current-nightly.json"
NIGHTLY_DMG="$NIGHTLY_ARTIFACTS/EasyTier-macOS-ARM64-nightly-20260715020000.dmg"
NIGHTLY_TRACE="$TEST_ROOT/nightly-trace.txt"
GUI_REVISION="dddddddddddddddddddddddddddddddddddddddd"
CORE_REVISION="cccccccccccccccccccccccccccccccccccccccc"
mkdir -p "$NIGHTLY_ARTIFACTS" "$NIGHTLY_CURRENT_PAGES"
cp -R "$PAGES_DIR/." "$NIGHTLY_CURRENT_PAGES/"
cp "$NIGHTLY_CURRENT_PAGES/update.json" "$TEST_ROOT/stable-feed-before-nightly.json"
printf 'nightly dmg bytes\n' > "$NIGHTLY_DMG"
cat > "$NIGHTLY_ARTIFACTS/EasyTier-macOS-ARM64-nightly-20260715020000.metadata.json" <<EOF
{
  "architecture": "ARM64",
  "build": "20260715020000",
  "buildTime": "2026-07-15T02:00:00Z",
  "channel": "nightly",
  "coreCommit": "$CORE_REVISION",
  "coreVersion": "v2.6.4-40-gc0ffee00",
  "guiCommit": "$GUI_REVISION",
  "notarized": true,
  "schemaVersion": 2,
  "signing": "developer-id",
  "version": "1.4.0"
}
EOF
cat > "$NIGHTLY_CURRENT_FEED" <<'EOF'
{
  "build": "20260714020000",
  "channel": "nightly",
  "coreCommit": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
  "guiCommit": "ffffffffffffffffffffffffffffffffffffffff",
  "tag": "nightly-20260714020000"
}
EOF
cp "$NIGHTLY_CURRENT_FEED" "$NIGHTLY_CURRENT_PAGES/nightly.json"
: > "$NIGHTLY_TRACE"

cat > "$FAKE_HELPERS/verify-nightly-dmg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmp -s "$1" "$NIGHTLY_DMG"
printf 'verify-nightly-dmg\n' >> "$NIGHTLY_TRACE"
EOF

cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "release" && "$2" == "view" ]]; then
  printf 'gh-view-nightly\n' >> "$NIGHTLY_TRACE"
  exit 1
fi
if [[ "$1" == "release" && "$2" == "create" ]]; then
  [[ " $* " == *" --prerelease "* ]]
  [[ " $* " == *" --target $GUI_REVISION "* ]]
  [[ " $* " == *" --title Nightly 2026-07-15 "* ]]
  printf 'gh-create-nightly\n' >> "$NIGHTLY_TRACE"
  exit 0
fi
if [[ "$1" == "release" && "$2" == "upload" ]]; then
  printf 'gh-upload-nightly\n' >> "$NIGHTLY_TRACE"
  exit 0
fi
echo "Unexpected nightly gh invocation: $*" >&2
exit 1
EOF

cat > "$SPARKLE_TOOLS/generate_appcast" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
prefix=""
input=""
channel=""
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
    --channel)
      channel="$2"
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
[[ "$channel" == "nightly" ]]
dmg="$input/EasyTier-macOS-ARM64-nightly-20260715020000.dmg"
cmp -s "$dmg" "$NIGHTLY_DMG"
size="$(wc -c < "$dmg" | tr -d ' ')"
stable_dmg_size="$(wc -c < "$REMOTE_STABLE_DMG" | tr -d ' ')"
printf 'generate-nightly-appcast\n' >> "$NIGHTLY_TRACE"
cat > "$output" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0" sparkle:signature="combined-feed-signature">
  <channel>
    <item>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <enclosure url="https://github.com/socoldkiller/easytier-macos/releases/download/v1.4.0/EasyTier-macOS-ARM64.dmg" length="$stable_dmg_size" sparkle:version="20260714010203" sparkle:shortVersionString="1.4.0" sparkle:edSignature="stable-signature" />
    </item>
    <item>
      <sparkle:channel>nightly</sparkle:channel>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <enclosure url="${prefix}EasyTier-macOS-ARM64-nightly-20260715020000.dmg" length="$size" sparkle:version="20260715020000" sparkle:shortVersionString="1.4.0" sparkle:edSignature="nightly-signature" />
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
  cmp -s "$file_path" "$NIGHTLY_DMG"
  printf 'verify-nightly-signature\n' >> "$NIGHTLY_TRACE"
elif [[ "$file_path" == *.xml ]]; then
  printf 'verify-combined-appcast-signature\n' >> "$NIGHTLY_TRACE"
else
  exit 1
fi
EOF

chmod +x "$FAKE_BIN/gh" "$FAKE_HELPERS/verify-nightly-dmg" "$SPARKLE_TOOLS"/*

PATH="$FAKE_BIN:$PATH" \
NIGHTLY_DMG="$NIGHTLY_DMG" \
NIGHTLY_TRACE="$NIGHTLY_TRACE" \
REMOTE_STABLE_DMG="$REMOTE_DMG_SOURCE" \
GUI_REVISION="$GUI_REVISION" \
EASYTIER_ARTIFACTS_DIR="$NIGHTLY_ARTIFACTS" \
EASYTIER_PAGES_DIR="$NIGHTLY_PAGES" \
EASYTIER_CURRENT_PAGES_DIR="$NIGHTLY_CURRENT_PAGES" \
EASYTIER_CURRENT_FEED_PATH="$NIGHTLY_CURRENT_FEED" \
EASYTIER_RELEASE_TEMP_PARENT="$TEMP_PARENT" \
EASYTIER_RELEASE_VERIFY_DMG_SCRIPT="$FAKE_HELPERS/verify-nightly-dmg" \
EASYTIER_SPARKLE_TOOLS_DIR="$SPARKLE_TOOLS" \
SPARKLE_EDDSA_PRIVATE_KEY=fake-sparkle-private-key \
TAG_NAME=nightly-20260715020000 \
REPOSITORY=socoldkiller/easytier-macos \
GH_TOKEN=fake-token \
"$ROOT_DIR/scripts/release.sh" publish > "$TEST_ROOT/nightly-publish.log"

cat > "$TEST_ROOT/expected-nightly-trace.txt" <<'EOF'
verify-nightly-dmg
gh-view-nightly
generate-nightly-appcast
verify-nightly-signature
verify-combined-appcast-signature
gh-create-nightly
gh-upload-nightly
EOF
diff -u "$TEST_ROOT/expected-nightly-trace.txt" "$NIGHTLY_TRACE"
cmp "$TEST_ROOT/stable-feed-before-nightly.json" "$NIGHTLY_PAGES/update.json"

python3 - "$NIGHTLY_PAGES/appcast.xml" "$NIGHTLY_PAGES/nightly.json" <<'PY'
import json
import pathlib
import sys
import xml.etree.ElementTree as ET

appcast = ET.parse(sys.argv[1]).getroot()
channels = []
for item in appcast.findall("./channel/item"):
    channel = next((child.text for child in item if child.tag.endswith("channel")), None)
    channels.append(channel or "stable")
assert sorted(channels) == ["nightly", "stable"]

nightly = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
assert nightly["channel"] == "nightly"
assert nightly["tag"] == "nightly-20260715020000"
assert nightly["guiCommit"] == "dddddddddddddddddddddddddddddddddddddddd"
assert nightly["coreCommit"] == "cccccccccccccccccccccccccccccccccccccccc"
PY

PRUNE_TRACE="$TEST_ROOT/prune-trace.txt"
: > "$PRUNE_TRACE"
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "release" && "$2" == "list" ]]; then
  index=16
  while [[ "$index" -ge 1 ]]; do
    printf 'nightly-202607%02d020000\n' "$index"
    index=$((index - 1))
  done
  exit 0
fi
if [[ "$1" == "release" && "$2" == "delete" ]]; then
  printf '%s\n' "$3" >> "$PRUNE_TRACE"
  exit 0
fi
exit 1
EOF
chmod +x "$FAKE_BIN/gh"

PATH="$FAKE_BIN:$PATH" \
PRUNE_TRACE="$PRUNE_TRACE" \
REPOSITORY=socoldkiller/easytier-macos \
EASYTIER_NIGHTLY_RELEASES_TO_KEEP=14 \
"$ROOT_DIR/scripts/release.sh" prune-nightlies > "$TEST_ROOT/prune.log"

cat > "$TEST_ROOT/expected-prune-trace.txt" <<'EOF'
nightly-20260702020000
nightly-20260701020000
EOF
diff -u "$TEST_ROOT/expected-prune-trace.txt" "$PRUNE_TRACE"

echo "Stable, Nightly, feed-preservation, and retention state-machine tests passed."
