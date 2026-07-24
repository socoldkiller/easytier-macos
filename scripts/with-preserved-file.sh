#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 2 ]]; then
  printf 'Usage: %s <file> <command> [arguments...]\n' "$0" >&2
  exit 64
fi

PRESERVED_FILE="$1"
shift

[[ -f "$PRESERVED_FILE" ]] || {
  printf 'File to preserve does not exist: %s\n' "$PRESERVED_FILE" >&2
  exit 1
}

BACKUP_FILE="$(mktemp "${TMPDIR:-/tmp}/easytier-preserved-file.XXXXXX")"

cleanup() {
  cp -p "$BACKUP_FILE" "$PRESERVED_FILE"
  rm -f "$BACKUP_FILE"
}
trap cleanup EXIT

cp -p "$PRESERVED_FILE" "$BACKUP_FILE"
"$@"
