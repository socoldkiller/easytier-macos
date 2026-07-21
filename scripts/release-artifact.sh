#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/release-common.sh"

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

  local default_dmg_name="EasyTier-macOS-$RELEASE_ARCHITECTURE.dmg"
  if [[ "$RELEASE_CHANNEL" == "nightly" ]]; then
    local nightly_date
    [[ "${EASYTIER_BUILD_NUMBER:-}" =~ ^[0-9]{14}$ ]] \
      || die "Nightly artifacts require a 14-digit EASYTIER_BUILD_NUMBER before path configuration."
    default_dmg_name="EasyTier-macOS-$RELEASE_ARCHITECTURE-nightly-${EASYTIER_BUILD_NUMBER}.dmg"
  fi
  APP_PATH="${EASYTIER_EXPORT_APP_DIR:-$ARTIFACTS_DIR/EasyTier.app}"
  DMG_PATH="${EASYTIER_DMG_PATH:-$ARTIFACTS_DIR/$default_dmg_name}"
  METADATA_PATH="${EASYTIER_ARTIFACT_METADATA_PATH:-${DMG_PATH%.dmg}.metadata.json}"
}

configure_release_version() {
  local release_tag="${EASYTIER_RELEASE_TAG:-}"
  local exact_tag=""
  local head_commit=""
  local tag_commit=""
  local tag_commit_epoch=""

  configure_release_channel
  if [[ "$RELEASE_CHANNEL" == "nightly" ]]; then
    [[ "${EASYTIER_APP_VERSION:-}" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] \
      || die "Nightly artifacts require a numeric EASYTIER_APP_VERSION."
    [[ "${EASYTIER_BUILD_NUMBER:-}" =~ ^[0-9]{14}$ ]] \
      || die "Nightly artifacts require a 14-digit EASYTIER_BUILD_NUMBER."
    [[ "${EASYTIER_BUILD_TIME:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
      || die "Nightly artifacts require EASYTIER_BUILD_TIME in UTC ISO-8601 format."
    [[ "${EASYTIER_GUI_REVISION:-}" =~ ^[0-9a-f]{40}$ ]] \
      || die "Nightly artifacts require a full EASYTIER_GUI_REVISION."
    [[ "${EASYTIER_CORE_REVISION:-}" =~ ^[0-9a-f]{40}$ ]] \
      || die "Nightly artifacts require a full EASYTIER_CORE_REVISION."
    return
  fi

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
  local error_path="$TEMP_ROOT/${label}-notary-error.log"
  local max_attempts="${EASYTIER_NOTARY_MAX_ATTEMPTS:-3}"
  local retry_delay="${EASYTIER_NOTARY_RETRY_DELAY_SECONDS:-15}"
  local attempt=1
  local status=0

  [[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] \
    || die "EASYTIER_NOTARY_MAX_ATTEMPTS must be a positive integer."
  [[ "$retry_delay" =~ ^[0-9]+$ ]] \
    || die "EASYTIER_NOTARY_RETRY_DELAY_SECONDS must be a non-negative integer."

  while (( attempt <= max_attempts )); do
    log "Submitting $label for Apple notarization (attempt $attempt/$max_attempts)"
    if xcrun notarytool submit "$path" \
      "${NOTARY_ARGS[@]}" \
      --wait \
      --output-format json > "$result_path" 2> "$error_path"; then
      break
    else
      status=$?
    fi

    cat "$error_path" >&2
    if (( attempt == max_attempts )) \
      || ! grep -Eqi \
        'abortedUpload|connection reset|network connection was lost|timed? out|timeout|temporarily unavailable' \
        "$error_path"; then
      return "$status"
    fi

    log "Apple notarization upload was interrupted; retrying $label after ${retry_delay}s"
    if (( retry_delay > 0 )); then
      sleep "$retry_delay"
    fi
    attempt=$((attempt + 1))
  done

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
  require_executable "$VERIFY_APP_SCRIPT"
  require_executable "$VERIFY_DMG_SCRIPT"
  [[ "${EASYTIER_CODESIGN_IDENTITY:-}" == "Developer ID Application:"* ]] \
    || die "EASYTIER_CODESIGN_IDENTITY must name a Developer ID Application identity."
  [[ "${EASYTIER_SPARKLE_PUBLIC_ED_KEY:-}" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    || die "EASYTIER_SPARKLE_PUBLIC_ED_KEY must contain the production Sparkle Ed25519 public key."
}

build_artifact() {
  configure_release_version
  configure_paths
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
  "$VERIFY_APP_SCRIPT" "$APP_PATH" notarized

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


usage() {
  cat >&2 <<'EOF'
Usage: scripts/release-artifact.sh artifact
EOF
}

main() {
  [[ "${1:-}" == "artifact" ]] || {
    usage
    exit 64
  }
  build_artifact
}

main "$@"
