#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
RELEASE_FEED_HELPER="${EASYTIER_RELEASE_FEED_HELPER:-$ROOT_DIR/scripts/release_feed.py}"
ARCHIVE_APP_SCRIPT="${EASYTIER_RELEASE_ARCHIVE_APP_SCRIPT:-$ROOT_DIR/scripts/archive-app.sh}"
CREATE_DMG_SCRIPT="${EASYTIER_RELEASE_CREATE_DMG_SCRIPT:-$ROOT_DIR/scripts/create-dmg.sh}"
VERIFY_DMG_SCRIPT="${EASYTIER_RELEASE_VERIFY_DMG_SCRIPT:-$ROOT_DIR/scripts/verify-release-dmg.sh}"

ARTIFACTS_DIR="${EASYTIER_ARTIFACTS_DIR:-$ROOT_DIR/.build/artifacts}"
PAGES_DIR="${EASYTIER_PAGES_DIR:-$ROOT_DIR/.build/pages}"
MINIMUM_SYSTEM_VERSION="${EASYTIER_MINIMUM_SYSTEM_VERSION:-15.0}"
UPDATE_BASE_URL="${EASYTIER_UPDATE_BASE_URL:-https://socoldkiller.github.io/easytier-macos}"
REPOSITORY="${REPOSITORY:-${GITHUB_REPOSITORY:-socoldkiller/easytier-macos}}"

TEMP_ROOT=""
RELEASE_ARCHITECTURE=""
APP_PATH=""
DMG_PATH=""
METADATA_PATH=""
FOUND_DMG=""
FOUND_METADATA=""
CANONICAL_DMG=""
RELEASE_EXISTS=0
REMOTE_ASSET_EXISTS=0
SPARKLE_TOOLS_DIR=""
SPARKLE_PRIVATE_KEY_FILE=""
NOTARY_ARGS=()

log() {
  printf '[release] %s\n' "$*"
}

die() {
  printf '[release] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT"
  fi
}
trap cleanup EXIT

ensure_temp_root() {
  if [[ -n "$TEMP_ROOT" ]]; then
    return
  fi
  local parent="${EASYTIER_RELEASE_TEMP_PARENT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
  mkdir -p "$parent"
  TEMP_ROOT="$(mktemp -d "$parent/easytier-release.XXXXXX")"
  chmod 700 "$TEMP_ROOT"
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || die "$command_name is required."
}

require_executable() {
  local path="$1"
  [[ -x "$path" ]] || die "Required release helper is not executable: $path"
}

configure_paths() {
  local machine_architecture="${EASYTIER_RELEASE_ARCHITECTURE:-$(uname -m)}"
  case "$machine_architecture" in
    arm64|ARM64|aarch64)
      RELEASE_ARCHITECTURE="ARM64"
      ;;
    *)
      die "EasyTier release artifacts are ARM64-only; current architecture is $machine_architecture."
      ;;
  esac

  APP_PATH="${EASYTIER_EXPORT_APP_DIR:-$ARTIFACTS_DIR/EasyTier.app}"
  DMG_PATH="${EASYTIER_DMG_PATH:-$ARTIFACTS_DIR/EasyTier-macOS-$RELEASE_ARCHITECTURE.dmg}"
  METADATA_PATH="${EASYTIER_ARTIFACT_METADATA_PATH:-${DMG_PATH%.dmg}.metadata.json}"
}

configure_release_version() {
  local release_tag="${EASYTIER_RELEASE_TAG:-}"
  local exact_tag=""
  local head_commit=""
  local tag_commit=""
  local tag_commit_epoch=""

  if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
    release_tag="${GITHUB_REF_NAME:-}"
  elif [[ -z "$release_tag" ]]; then
    exact_tag="$(git -C "$ROOT_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"
    release_tag="$exact_tag"
  fi

  if [[ -n "$release_tag" ]]; then
    [[ "$release_tag" =~ ^[vV]?[0-9]+(\.[0-9]+){1,2}$ ]] \
      || die "Release tag must be a numeric version such as v1.4.0: $release_tag"
    head_commit="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
    tag_commit="$(git -C "$ROOT_DIR" rev-parse "$release_tag^{commit}" 2>/dev/null || true)"
    [[ -n "$head_commit" && "$tag_commit" == "$head_commit" ]] \
      || die "Release tag $release_tag does not resolve to the checked-out commit."
    export EASYTIER_APP_VERSION="${EASYTIER_APP_VERSION:-${release_tag#[vV]}}"
    if [[ -z "${EASYTIER_BUILD_NUMBER:-}" ]]; then
      tag_commit_epoch="$(git -C "$ROOT_DIR" show -s --format=%ct "$release_tag" 2>/dev/null || true)"
      [[ "$tag_commit_epoch" =~ ^[0-9]+$ ]] \
        || die "Could not derive a stable build number from release tag $release_tag."
      export EASYTIER_BUILD_NUMBER
      EASYTIER_BUILD_NUMBER="$(date -u -r "$tag_commit_epoch" +%Y%m%d%H%M%S)"
    fi
  elif [[ -z "${EASYTIER_APP_VERSION:-}" ]]; then
    cat >&2 <<'EOF'
[release] Refusing to create a release artifact with the package script's placeholder version.
[release] Build from an exact version tag, set EASYTIER_RELEASE_TAG=v1.4.0, or set
[release] EASYTIER_APP_VERSION and optionally EASYTIER_BUILD_NUMBER for a pre-release build.
EOF
    exit 1
  fi
}

prepare_provisioning_profile() {
  local profile_path="${EASYTIER_PROVISIONING_PROFILE:-}"
  local encoded_profile="${APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64:-}"

  if [[ -n "$profile_path" ]]; then
    [[ -f "$profile_path" ]] || die "Provisioning profile not found: $profile_path"
  elif [[ -n "$encoded_profile" ]]; then
    ensure_temp_root
    profile_path="$TEMP_ROOT/EasyTier.provisionprofile"
    umask 077
    if ! printf '%s' "$encoded_profile" | base64 -D > "$profile_path"; then
      die "APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64 is not valid base64."
    fi
  else
    die "Set EASYTIER_PROVISIONING_PROFILE or APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64."
  fi

  export EASYTIER_PROVISIONING_PROFILE="$profile_path"
}

prepare_notary_credentials() {
  local api_key_contents="${APPLE_NOTARY_KEY:-}"
  local api_key_file="${EASYTIER_NOTARY_KEY_FILE:-}"
  local api_key_id="${APPLE_NOTARY_KEY_ID:-}"
  local api_issuer="${APPLE_NOTARY_ISSUER_ID:-}"
  local keychain_profile="${EASYTIER_NOTARY_KEYCHAIN_PROFILE:-}"
  local keychain_path="${EASYTIER_NOTARY_KEYCHAIN:-}"

  if [[ -n "$keychain_profile" && ( -n "$api_key_contents" || -n "$api_key_file" ) ]]; then
    die "Choose either an Apple API key or a notarytool Keychain profile, not both."
  fi

  if [[ -n "$api_key_contents" || -n "$api_key_file" ]]; then
    [[ -n "$api_key_id" && -n "$api_issuer" ]] \
      || die "APPLE_NOTARY_KEY_ID and APPLE_NOTARY_ISSUER_ID are required with an API key."
    if [[ -n "$api_key_contents" && -n "$api_key_file" ]]; then
      die "Choose either APPLE_NOTARY_KEY or EASYTIER_NOTARY_KEY_FILE, not both."
    fi
    if [[ -n "$api_key_contents" ]]; then
      ensure_temp_root
      api_key_file="$TEMP_ROOT/AuthKey_${api_key_id}.p8"
      umask 077
      printf '%s' "$api_key_contents" > "$api_key_file"
    fi
    [[ -s "$api_key_file" ]] || die "Apple notarization API key is unavailable: $api_key_file"
    NOTARY_ARGS=(--key "$api_key_file" --key-id "$api_key_id" --issuer "$api_issuer")
  elif [[ -n "$keychain_profile" ]]; then
    NOTARY_ARGS=(--keychain-profile "$keychain_profile")
    if [[ -n "$keychain_path" ]]; then
      [[ -f "$keychain_path" ]] || die "Notary Keychain not found: $keychain_path"
      NOTARY_ARGS+=(--keychain "$keychain_path")
    fi
  else
    cat >&2 <<'EOF'
[release] Apple notarization credentials are required.
[release] CI: set APPLE_NOTARY_KEY, APPLE_NOTARY_KEY_ID, and APPLE_NOTARY_ISSUER_ID.
[release] Local: set EASYTIER_NOTARY_KEYCHAIN_PROFILE and optionally EASYTIER_NOTARY_KEYCHAIN.
EOF
    exit 1
  fi
}

notarize() {
  local path="$1"
  local label="$2"
  local result_path="$TEMP_ROOT/${label}-notary-result.json"

  log "Submitting $label for Apple notarization"
  xcrun notarytool submit "$path" \
    "${NOTARY_ARGS[@]}" \
    --wait \
    --output-format json > "$result_path"
  cat "$result_path"
  "$PYTHON_BIN" "$RELEASE_FEED_HELPER" validate-notary \
    --input "$result_path" \
    --label "$label"
}

staple_and_validate() {
  local path="$1"
  xcrun stapler staple "$path"
  xcrun stapler validate "$path"
}

artifact_preflight() {
  require_command base64
  require_command codesign
  require_command ditto
  require_command spctl
  require_command xcrun
  require_command "$PYTHON_BIN"
  require_executable "$RELEASE_FEED_HELPER"
  require_executable "$ARCHIVE_APP_SCRIPT"
  require_executable "$CREATE_DMG_SCRIPT"
  require_executable "$VERIFY_DMG_SCRIPT"
  [[ "${EASYTIER_CODESIGN_IDENTITY:-}" == "Developer ID Application:"* ]] \
    || die "EASYTIER_CODESIGN_IDENTITY must name a Developer ID Application identity."
  [[ "${EASYTIER_SPARKLE_PUBLIC_ED_KEY:-}" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    || die "EASYTIER_SPARKLE_PUBLIC_ED_KEY must contain the production Sparkle Ed25519 public key."
}

build_artifact() {
  configure_paths
  configure_release_version
  artifact_preflight
  ensure_temp_root
  prepare_provisioning_profile
  prepare_notary_credentials

  mkdir -p "$ARTIFACTS_DIR" "$(dirname "$APP_PATH")" "$(dirname "$DMG_PATH")" "$(dirname "$METADATA_PATH")"
  rm -rf "$APP_PATH"
  rm -f "$DMG_PATH" "$METADATA_PATH"

  log "Archiving and Developer ID signing EasyTier.app with Xcode"
  export EASYTIER_BUILD_CONFIGURATION=release
  export EASYTIER_EXPORT_APP_DIR="$APP_PATH"
  "$ARCHIVE_APP_SCRIPT"

  local app_archive="$TEMP_ROOT/EasyTier-app.zip"
  log "Archiving the signed app for notarization"
  ditto -c -k --keepParent --sequesterRsrc --zlibCompressionLevel 9 \
    "$APP_PATH" \
    "$app_archive"
  notarize "$app_archive" "EasyTier.app"
  log "Stapling and validating EasyTier.app"
  staple_and_validate "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  spctl -a -vvv -t exec "$APP_PATH"

  log "Creating the DMG from the stapled app"
  "$CREATE_DMG_SCRIPT" "$APP_PATH" "$DMG_PATH"
  notarize "$DMG_PATH" "EasyTier.dmg"
  log "Stapling and validating the release DMG"
  staple_and_validate "$DMG_PATH"
  "$VERIFY_DMG_SCRIPT" "$DMG_PATH"

  "$PYTHON_BIN" "$RELEASE_FEED_HELPER" write-metadata \
    --app "$APP_PATH" \
    --output "$METADATA_PATH" \
    --architecture "$RELEASE_ARCHITECTURE"
  "$PYTHON_BIN" "$RELEASE_FEED_HELPER" validate-artifact \
    --metadata "$METADATA_PATH" \
    --dmg "$DMG_PATH" \
    --architecture "$RELEASE_ARCHITECTURE"

  log "Release artifact is complete"
  printf 'App: %s\nDMG: %s\nMetadata: %s\n' "$APP_PATH" "$DMG_PATH" "$METADATA_PATH"
}

find_artifact_pair() {
  local directory="$1"
  local nullglob_was_set=0
  local dmg_files metadata_files
  shopt -q nullglob && nullglob_was_set=1
  shopt -s nullglob
  dmg_files=("$directory"/*.dmg)
  metadata_files=("$directory"/*.metadata.json)
  if [[ "$nullglob_was_set" == "0" ]]; then
    shopt -u nullglob
  fi

  if [[ "${#dmg_files[@]}" -ne 1 || "${#metadata_files[@]}" -ne 1 ]]; then
    die "Expected one DMG and one metadata file in $directory; found ${#dmg_files[@]} DMG(s) and ${#metadata_files[@]} metadata file(s)."
  fi
  FOUND_DMG="${dmg_files[0]}"
  FOUND_METADATA="${metadata_files[0]}"
}

validate_artifact_pair() {
  local dmg_path="$1"
  local metadata_path="$2"
  "$PYTHON_BIN" "$RELEASE_FEED_HELPER" validate-artifact \
    --metadata "$metadata_path" \
    --dmg "$dmg_path" \
    --architecture "ARM64"
  "$VERIFY_DMG_SCRIPT" "$dmg_path"
}

release_tag() {
  local value="${TAG_NAME:-${GITHUB_REF_NAME:-${EASYTIER_RELEASE_TAG:-}}}"
  [[ -n "$value" ]] || die "TAG_NAME, GITHUB_REF_NAME, or EASYTIER_RELEASE_TAG is required."
  printf '%s\n' "$value"
}

validate_published_order() {
  local metadata_path="$1"
  local tag="$2"
  local current_feed="${EASYTIER_CURRENT_FEED_PATH:-}"
  if [[ -z "$current_feed" ]]; then
    current_feed="$TEMP_ROOT/current-update.json"
    local cache_bust="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$(date +%s)"
    log "Checking the currently deployed build ordering"
    if ! curl -fsSL -H 'Cache-Control: no-cache' \
      "$UPDATE_BASE_URL/update.json?ordering=$cache_bust" \
      -o "$current_feed"; then
      if [[ "${EASYTIER_ALLOW_MISSING_CURRENT_FEED:-0}" == "1" ]]; then
        log "No current update feed was found; initial-feed override is enabled"
        return
      fi
      die "Could not load the existing update feed for monotonic build validation."
    fi
  fi
  "$PYTHON_BIN" "$RELEASE_FEED_HELPER" validate-order \
    --metadata "$metadata_path" \
    --current-feed "$current_feed" \
    --tag "$tag"
}

prepare_canonical_release_asset() {
  local local_dmg="$1"
  local metadata_path="$2"
  local tag="$3"
  local asset_names="$TEMP_ROOT/existing-dmg-assets.txt"
  local remote_dir="$TEMP_ROOT/existing-release-assets"
  local asset_count=0
  local asset_name=""

  CANONICAL_DMG="$local_dmg"
  RELEASE_EXISTS=0
  REMOTE_ASSET_EXISTS=0

  if gh release view "$tag" --repo "$REPOSITORY" \
    --json assets \
    --jq '.assets[].name | select(endswith(".dmg"))' > "$asset_names" 2>/dev/null; then
    RELEASE_EXISTS=1
    asset_count="$(awk 'NF { count += 1 } END { print count + 0 }' "$asset_names")"
    if [[ "$asset_count" -gt 1 ]]; then
      die "Existing release $tag contains more than one DMG; refusing an ambiguous rerun."
    fi
    if [[ "$asset_count" == "1" ]]; then
      asset_name="$(awk 'NF { print; exit }' "$asset_names")"
      mkdir -p "$remote_dir"
      log "Reusing the immutable DMG already published for $tag: $asset_name"
      gh release download "$tag" \
        --repo "$REPOSITORY" \
        --pattern "$asset_name" \
        --dir "$remote_dir"
      CANONICAL_DMG="$remote_dir/$asset_name"
      validate_artifact_pair "$CANONICAL_DMG" "$metadata_path"
      REMOTE_ASSET_EXISTS=1
    fi
  fi
}

prepare_sparkle_private_key() {
  local key_contents="${SPARKLE_EDDSA_PRIVATE_KEY:-}"
  local key_file="${EASYTIER_SPARKLE_PRIVATE_KEY_FILE:-}"

  if [[ -n "$key_contents" && -n "$key_file" ]]; then
    die "Choose either SPARKLE_EDDSA_PRIVATE_KEY or EASYTIER_SPARKLE_PRIVATE_KEY_FILE, not both."
  fi
  if [[ -n "$key_file" ]]; then
    [[ -s "$key_file" ]] || die "Sparkle private key file is unavailable: $key_file"
    SPARKLE_PRIVATE_KEY_FILE="$key_file"
  elif [[ -n "$key_contents" ]]; then
    SPARKLE_PRIVATE_KEY_FILE="$TEMP_ROOT/sparkle-private-key"
    umask 077
    printf '%s' "$key_contents" > "$SPARKLE_PRIVATE_KEY_FILE"
  else
    die "Set SPARKLE_EDDSA_PRIVATE_KEY or EASYTIER_SPARKLE_PRIVATE_KEY_FILE."
  fi
}

ensure_swift_6() {
  local swift_version swift_major candidate
  swift_version="$(swift --version)"
  swift_major="$(printf '%s\n' "$swift_version" | sed -n 's/.*Swift version \([0-9][0-9]*\).*/\1/p' | head -n 1)"
  if [[ -n "$swift_major" && "$swift_major" -ge 6 ]]; then
    printf '%s\n' "$swift_version"
    return
  fi

  for candidate in /Applications/Xcode_16*.app /Applications/Xcode.app; do
    if [[ -d "$candidate/Contents/Developer" ]]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      swift_version="$(swift --version)"
      swift_major="$(printf '%s\n' "$swift_version" | sed -n 's/.*Swift version \([0-9][0-9]*\).*/\1/p' | head -n 1)"
      if [[ -n "$swift_major" && "$swift_major" -ge 6 ]]; then
        printf '%s\n' "$swift_version"
        return
      fi
    fi
  done
  die "Swift 6 or newer is required to resolve the pinned Sparkle tools."
}

resolve_sparkle_tools() {
  local configured="${EASYTIER_SPARKLE_TOOLS_DIR:-}"
  local scratch_path="${EASYTIER_SPARKLE_SCRATCH_PATH:-$ROOT_DIR/.build/sparkle-tools}"
  if [[ -n "$configured" ]]; then
    SPARKLE_TOOLS_DIR="$configured"
  else
    ensure_swift_6
    swift package \
      --package-path "$ROOT_DIR" \
      --scratch-path "$scratch_path" \
      resolve
    SPARKLE_TOOLS_DIR="$scratch_path/artifacts/sparkle/Sparkle/bin"
  fi

  [[ -x "$SPARKLE_TOOLS_DIR/generate_appcast" ]] \
    || die "Pinned Sparkle generate_appcast tool was not resolved in $SPARKLE_TOOLS_DIR."
  [[ -x "$SPARKLE_TOOLS_DIR/sign_update" ]] \
    || die "Pinned Sparkle sign_update tool was not resolved in $SPARKLE_TOOLS_DIR."
}

generate_and_validate_feeds() {
  local dmg_path="$1"
  local metadata_path="$2"
  local tag="$3"
  local notes_path="$4"
  local appcast_input="$TEMP_ROOT/appcast-input"
  local appcast_path="$PAGES_DIR/appcast.xml"
  local legacy_path="$PAGES_DIR/update.json"
  local notes_name="$(basename "${dmg_path%.dmg}.md")"
  local generate_output signature

  rm -rf "$PAGES_DIR" "$appcast_input"
  mkdir -p "$PAGES_DIR" "$appcast_input"
  cp "$dmg_path" "$appcast_input/$(basename "$dmg_path")"
  cp "$notes_path" "$appcast_input/$notes_name"

  resolve_sparkle_tools
  prepare_sparkle_private_key
  log "Generating the signed Sparkle appcast"
  if ! generate_output="$(
    "$SPARKLE_TOOLS_DIR/generate_appcast" \
      --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
      --download-url-prefix "https://github.com/$REPOSITORY/releases/download/$tag/" \
      --embed-release-notes \
      --maximum-versions 1 \
      -o "$appcast_path" \
      "$appcast_input" 2>&1
  )"; then
    printf '%s\n' "$generate_output" >&2
    die "Sparkle appcast generation failed."
  fi
  printf '%s\n' "$generate_output"
  if [[ "$generate_output" == *"does not match"* ]]; then
    die "Sparkle private key does not match SUPublicEDKey in the packaged app."
  fi

  "$PYTHON_BIN" "$RELEASE_FEED_HELPER" legacy-feed \
    --metadata "$metadata_path" \
    --dmg "$dmg_path" \
    --tag "$tag" \
    --repository "$REPOSITORY" \
    --minimum-system-version "$MINIMUM_SYSTEM_VERSION" \
    --output "$legacy_path"

  signature="$(
    "$PYTHON_BIN" "$RELEASE_FEED_HELPER" validate-appcast \
      --appcast "$appcast_path" \
      --metadata "$metadata_path" \
      --dmg "$dmg_path" \
      --tag "$tag" \
      --repository "$REPOSITORY" \
      --minimum-system-version "$MINIMUM_SYSTEM_VERSION" \
      --architecture "ARM64"
  )"
  "$SPARKLE_TOOLS_DIR/sign_update" \
    --verify \
    --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
    "$dmg_path" \
    "$signature"
  "$SPARKLE_TOOLS_DIR/sign_update" \
    --verify \
    --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
    "$appcast_path"
}

publish_github_release() {
  local dmg_path="$1"
  local tag="$2"
  local notes_path="$3"

  if [[ "$RELEASE_EXISTS" == "0" ]]; then
    log "Creating GitHub Release $tag"
    gh release create "$tag" \
      --repo "$REPOSITORY" \
      --title "$tag" \
      --notes-file "$notes_path"
    RELEASE_EXISTS=1
  else
    gh release edit "$tag" --repo "$REPOSITORY" --notes-file "$notes_path"
  fi

  if [[ "$REMOTE_ASSET_EXISTS" == "0" ]]; then
    log "Uploading immutable release asset $(basename "$dmg_path")"
    gh release upload "$tag" "$dmg_path" --repo "$REPOSITORY"
  else
    log "Existing release asset was verified and left unchanged"
  fi
}

publish_release() {
  configure_paths
  require_command curl
  require_command gh
  require_command swift
  require_command "$PYTHON_BIN"
  require_executable "$RELEASE_FEED_HELPER"
  require_executable "$VERIFY_DMG_SCRIPT"
  ensure_temp_root

  local tag notes_path
  tag="$(release_tag)"
  find_artifact_pair "$ARTIFACTS_DIR"
  validate_artifact_pair "$FOUND_DMG" "$FOUND_METADATA"
  validate_published_order "$FOUND_METADATA" "$tag"

  notes_path="$ARTIFACTS_DIR/RELEASE_NOTES.md"
  "$PYTHON_BIN" "$RELEASE_FEED_HELPER" release-notes \
    --changelog "$ROOT_DIR/CHANGELOG.md" \
    --tag "$tag" \
    --output "$notes_path"

  prepare_canonical_release_asset "$FOUND_DMG" "$FOUND_METADATA" "$tag"
  generate_and_validate_feeds "$CANONICAL_DMG" "$FOUND_METADATA" "$tag" "$notes_path"
  publish_github_release "$CANONICAL_DMG" "$tag" "$notes_path"
  log "GitHub Release and signed feed payloads are ready"
  printf 'Release asset: %s\nPages directory: %s\n' "$CANONICAL_DMG" "$PAGES_DIR"
}

verify_deployed_feeds() {
  require_command cmp
  require_command curl
  ensure_temp_root
  [[ -s "$PAGES_DIR/appcast.xml" && -s "$PAGES_DIR/update.json" ]] \
    || die "Expected generated feeds in $PAGES_DIR."

  local attempts="${EASYTIER_DEPLOY_VERIFY_ATTEMPTS:-12}"
  local delay="${EASYTIER_DEPLOY_VERIFY_DELAY_SECONDS:-5}"
  local deployed_appcast="$TEMP_ROOT/deployed-appcast.xml"
  local deployed_legacy="$TEMP_ROOT/deployed-update.json"
  local attempt cache_bust
  [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || die "EASYTIER_DEPLOY_VERIFY_ATTEMPTS must be positive."
  [[ "$delay" =~ ^[0-9]+$ ]] || die "EASYTIER_DEPLOY_VERIFY_DELAY_SECONDS must be non-negative."

  attempt=1
  while [[ "$attempt" -le "$attempts" ]]; do
    cache_bust="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$attempt"
    if curl -fsSL -H 'Cache-Control: no-cache' \
         "$UPDATE_BASE_URL/appcast.xml?deploy=$cache_bust" \
         -o "$deployed_appcast" && \
       curl -fsSL -H 'Cache-Control: no-cache' \
         "$UPDATE_BASE_URL/update.json?deploy=$cache_bust" \
         -o "$deployed_legacy" && \
       cmp "$PAGES_DIR/appcast.xml" "$deployed_appcast" && \
       cmp "$PAGES_DIR/update.json" "$deployed_legacy"; then
      log "GitHub Pages is serving the newly signed update feeds"
      return
    fi
    if [[ "$attempt" -lt "$attempts" && "$delay" -gt 0 ]]; then
      sleep "$delay"
    fi
    attempt=$((attempt + 1))
  done
  die "GitHub Pages did not serve the expected update feeds after $attempts attempt(s)."
}

usage() {
  cat <<'EOF'
Usage: scripts/release.sh <command>

Commands:
  artifact               Build, sign, notarize, staple, and verify the final DMG.
  publish                Verify one artifact, generate signed feeds, and publish/reuse a GitHub Release asset.
  verify-deployed-feeds  Compare deployed GitHub Pages feeds byte-for-byte with the generated files.

Local notarization uses:
  EASYTIER_NOTARY_KEYCHAIN_PROFILE=easytier-notary
  EASYTIER_NOTARY_KEYCHAIN=/path/to/signing.keychain-db  # optional

CI notarization uses:
  APPLE_NOTARY_KEY, APPLE_NOTARY_KEY_ID, APPLE_NOTARY_ISSUER_ID
EOF
}

main() {
  local command="${1:-}"
  case "$command" in
    artifact)
      build_artifact
      ;;
    publish)
      publish_release
      ;;
    verify-deployed-feeds)
      verify_deployed_feeds
      ;;
    help|-h|--help|"")
      usage
      ;;
    *)
      usage >&2
      die "Unknown release command: $command"
      ;;
  esac
}

main "$@"
