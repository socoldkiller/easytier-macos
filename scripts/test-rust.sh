#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_PATH="$ROOT_DIR/Rust/EasyTierGuiFFI/Cargo.toml"
LOCKFILE_PATH="$ROOT_DIR/Rust/EasyTierGuiFFI/Cargo.lock"
LOCKFILE_BACKUP="$(mktemp "${TMPDIR:-/tmp}/easytier-cargo-lock.XXXXXX")"

cleanup() {
  cp "$LOCKFILE_BACKUP" "$LOCKFILE_PATH"
  rm -f "$LOCKFILE_BACKUP"
}
trap cleanup EXIT

cp "$LOCKFILE_PATH" "$LOCKFILE_BACKUP"
cargo test --manifest-path "$MANIFEST_PATH"
