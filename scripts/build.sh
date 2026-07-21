#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTEXT_SCRIPT="$ROOT_DIR/scripts/build_context.py"

usage() {
  cat <<'EOF'
Usage: scripts/build.sh <command> [arguments]

Commands:
  context ...                 Resolve build metadata with build_context.py.
  app debug|release           Build and export a signed App with Xcode.
  debug-install               Build, install, register helpers, and open Debug App.
  package                     Build the signed, notarized, verified release DMG.
  publish                     Publish a prepared release artifact and update feeds.
  verify app|dmg <path>       Verify an App bundle or release DMG.
  install-helper              Package and validate the privileged helpers.
  verify-deployed-feeds       Verify the deployed Sparkle/update feed state.
  prune-nightlies             Remove expired Nightly releases.
EOF
}

inherit_public_environment() {
  export EASYTIER_ARTIFACTS_DIR="${EASYTIER_ARTIFACTS_DIR:-${ARTIFACTS_DIR:-$ROOT_DIR/.build/artifacts}}"
  export EASYTIER_APP_PRODUCTS_DIR="${EASYTIER_APP_PRODUCTS_DIR:-${APP_PRODUCTS_DIR:-$ROOT_DIR/.build/AppProducts}}"
  export EASYTIER_SWIFT_BUILD_DIR="${EASYTIER_SWIFT_BUILD_DIR:-${SWIFT_BUILD_DIR:-$EASYTIER_APP_PRODUCTS_DIR/SwiftBuild}}"
  export EASYTIER_EXPORT_APP_DIR="${EASYTIER_EXPORT_APP_DIR:-${APP_PATH:-$EASYTIER_ARTIFACTS_DIR/EasyTier.app}}"
  export EASYTIER_INSTALL_APP_PATH="${EASYTIER_INSTALL_APP_PATH:-${INSTALL_APP_PATH:-/Applications/EasyTier.app}}"
  export EASYTIER_DMG_PATH="${EASYTIER_DMG_PATH:-${DMG_PATH:-$EASYTIER_ARTIFACTS_DIR/EasyTier-macOS-ARM64.dmg}}"
  export EASYTIER_CODESIGN_IDENTITY="${EASYTIER_CODESIGN_IDENTITY:-${CODESIGN_IDENTITY:-}}"
  export EASYTIER_CODESIGN_KEYCHAIN="${EASYTIER_CODESIGN_KEYCHAIN:-${CODESIGN_KEYCHAIN:-}}"
  export EASYTIER_PROVISIONING_PROFILE="${EASYTIER_PROVISIONING_PROFILE:-${PROVISIONING_PROFILE:-}}"
  export EASYTIER_SPARKLE_PUBLIC_ED_KEY="${EASYTIER_SPARKLE_PUBLIC_ED_KEY:-${SPARKLE_PUBLIC_ED_KEY:-}}"
  if [[ -n "${EASYTIER_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    export EASYTIER_NOTARY_KEYCHAIN_PROFILE
  elif [[ -z "${APPLE_NOTARY_KEY:-}" && -z "${EASYTIER_NOTARY_KEY_FILE:-}" ]]; then
    export EASYTIER_NOTARY_KEYCHAIN_PROFILE="${NOTARY_PROFILE:-easytier-notary}"
  fi
  export EASYTIER_NOTARY_KEYCHAIN="${EASYTIER_NOTARY_KEYCHAIN:-${NOTARY_KEYCHAIN:-$EASYTIER_CODESIGN_KEYCHAIN}}"
  export EASYTIER_RELEASE_TAG="${EASYTIER_RELEASE_TAG:-${RELEASE_TAG:-}}"
  export EASYTIER_APP_VERSION="${EASYTIER_APP_VERSION:-${APP_VERSION:-}}"
  export EASYTIER_BUILD_NUMBER="${EASYTIER_BUILD_NUMBER:-${BUILD_NUMBER:-}}"
}

resolve_local_context() {
  local mode="$1"
  shift
  local env_file
  env_file="$(mktemp "${TMPDIR:-/tmp}/easytier-build-context.XXXXXX")"
  trap 'rm -f "$env_file"' RETURN
  "$CONTEXT_SCRIPT" local --mode "$mode" --env-file "$env_file" "$@" >/dev/null
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^EASYTIER_[A-Z0-9_]+$ ]] || {
      printf 'Unexpected build context key: %s\n' "$key" >&2
      return 1
    }
    export "$key=$value"
  done < "$env_file"
  rm -f "$env_file"
  trap - RETURN
}

inherit_public_environment

command_name="${1:-}"
[[ -n "$command_name" ]] || {
  usage >&2
  exit 64
}
shift

case "$command_name" in
  context)
    exec "$CONTEXT_SCRIPT" "$@"
    ;;
  app)
    configuration="${1:-}"
    [[ "$configuration" == "debug" || "$configuration" == "release" ]] || {
      printf 'Usage: scripts/build.sh app debug|release\n' >&2
      exit 64
    }
    resolve_local_context "$configuration"
    export EASYTIER_BUILD_CONFIGURATION="$configuration"
    mkdir -p "$(dirname "$EASYTIER_EXPORT_APP_DIR")"
    exec "$ROOT_DIR/scripts/archive-app.sh"
    ;;
  debug-install)
    resolve_local_context debug
    exec "$ROOT_DIR/scripts/build-debug-app.sh"
    ;;
  package)
    if [[ -z "${EASYTIER_GUI_REVISION:-}" || -z "${EASYTIER_CORE_REVISION:-}" ]]; then
      resolve_local_context release --require-release-version
    fi
    exec "$ROOT_DIR/scripts/release-artifact.sh" artifact
    ;;
  publish)
    exec "$ROOT_DIR/scripts/release-publish.sh" publish
    ;;
  verify)
    kind="${1:-}"
    artifact_path="${2:-}"
    case "$kind" in
      app)
        [[ -n "$artifact_path" ]] || { printf 'Missing App path.\n' >&2; exit 64; }
        exec "$ROOT_DIR/scripts/verify-app.sh" "$artifact_path"
        ;;
      dmg)
        [[ -n "$artifact_path" ]] || { printf 'Missing DMG path.\n' >&2; exit 64; }
        exec "$ROOT_DIR/scripts/verify-release-dmg.sh" "$artifact_path"
        ;;
      *)
        printf 'Usage: scripts/build.sh verify app|dmg <path>\n' >&2
        exit 64
        ;;
    esac
    ;;
  install-helper)
    export EASYTIER_EXPORT_APP_DIR="$EASYTIER_INSTALL_APP_PATH"
    exec "$ROOT_DIR/scripts/dev-install-helper.sh"
    ;;
  verify-deployed-feeds)
    exec "$ROOT_DIR/scripts/release-publish.sh" verify-deployed-feeds
    ;;
  prune-nightlies)
    exec "$ROOT_DIR/scripts/release-publish.sh" prune-nightlies
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    printf 'Unknown build command: %s\n' "$command_name" >&2
    usage >&2
    exit 64
    ;;
esac
