#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EASYTIER_DIR="$ROOT_DIR/Vendor/EasyTier"
cd "$ROOT_DIR"

if ! command -v swift >/dev/null 2>&1; then
  echo "swift is required" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required" >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo is required for EasyTier FFI builds" >&2
  exit 1
fi

if ! command -v rustc >/dev/null 2>&1; then
  echo "rustc is required for EasyTier FFI builds" >&2
  exit 1
fi

if ! command -v protoc >/dev/null 2>&1; then
  echo "protoc is required for EasyTier FFI builds; install protobuf first." >&2
  exit 1
fi

if [[ ! -f "$EASYTIER_DIR/Cargo.toml" ]]; then
  echo "Vendor/EasyTier is not initialized; run: git submodule update --init --recursive" >&2
  exit 1
fi

EXPECTED_CORE_REV="${EASYTIER_CORE_REVISION:-}"
if [[ -n "$EXPECTED_CORE_REV" ]]; then
  if [[ ! "$EXPECTED_CORE_REV" =~ ^[0-9a-f]{40}$ ]]; then
    echo "EASYTIER_CORE_REVISION must be a full lowercase Git SHA: $EXPECTED_CORE_REV" >&2
    exit 1
  fi
else
  EXPECTED_CORE_REV="$(git ls-files --stage -- Vendor/EasyTier | awk '$1 == 160000 { print $2 }')"
fi

CURRENT_CORE_REV="$(git -C "$EASYTIER_DIR" rev-parse HEAD)"
if [[ -z "$EXPECTED_CORE_REV" || "$CURRENT_CORE_REV" != "$EXPECTED_CORE_REV" ]]; then
  echo "Vendor/EasyTier does not match the expected revision $EXPECTED_CORE_REV; current revision is $CURRENT_CORE_REV." >&2
  exit 1
fi

echo "Swift: $(swift --version | head -n 1)"
echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"
echo "Rust: $(rustc --version); $(cargo --version)"
echo "protoc: $(protoc --version)"
echo "EasyTier Core: $(git -C "$EASYTIER_DIR" describe --tags --always --dirty)"
echo "Bootstrap complete."
