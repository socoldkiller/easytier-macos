#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_PATH="$ROOT_DIR/Rust/EasyTierGuiFFI/Cargo.toml"
LOCKFILE_PATH="$ROOT_DIR/Rust/EasyTierGuiFFI/Cargo.lock"

"$ROOT_DIR/scripts/with-preserved-file.sh" "$LOCKFILE_PATH" \
  cargo test --manifest-path "$MANIFEST_PATH"
