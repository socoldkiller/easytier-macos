#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command_name="${1:-}"

case "$command_name" in
  artifact)
    exec "$ROOT_DIR/scripts/release-artifact.sh" "$@"
    ;;
  publish|verify-deployed-feeds|prune-nightlies)
    exec "$ROOT_DIR/scripts/release-publish.sh" "$@"
    ;;
  *)
    cat >&2 <<'EOF'
Usage: scripts/release.sh <command>

Commands:
  artifact               Build, notarize, staple, and verify the release DMG.
  publish                Publish a prepared DMG and update feeds.
  verify-deployed-feeds  Verify the deployed Pages feed payloads.
  prune-nightlies        Remove expired Nightly releases and tags.
EOF
    exit 64
    ;;
esac
