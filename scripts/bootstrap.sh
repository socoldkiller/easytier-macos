#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EASYTIER_DIR="$ROOT_DIR/Vendor/EasyTier"
CORE_TAG="${EASYTIER_CORE_TAG:-v2.6.4}"
cd "$ROOT_DIR"

ensure_easytier_core_tag() {
  if [[ -f "$EASYTIER_DIR/Cargo.toml" ]]; then
    echo "Vendor/EasyTier already present."
  else
    git submodule update --init Vendor/EasyTier
  fi

  local current_tag
  current_tag="$(git -C "$EASYTIER_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"

  if [[ "$current_tag" != "$CORE_TAG" ]]; then
    if [[ -n "$(git -C "$EASYTIER_DIR" status --short --untracked-files=no 2>/dev/null || true)" ]]; then
      echo "Vendor/EasyTier has local tracked changes; refusing to switch Core tag." >&2
      exit 1
    fi
    if ! git -C "$EASYTIER_DIR" rev-parse -q --verify "refs/tags/$CORE_TAG" >/dev/null; then
      git -C "$EASYTIER_DIR" fetch --force --depth 1 origin "refs/tags/$CORE_TAG:refs/tags/$CORE_TAG"
    fi
    git -C "$EASYTIER_DIR" checkout --detach "$CORE_TAG"
  fi

  echo "EasyTier Core: $(git -C "$EASYTIER_DIR" describe --tags --always --dirty)"
}

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

ensure_easytier_core_tag

mkdir -p Vendor/Frameworks

echo "Swift: $(swift --version | head -n 1)"
echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"
echo "Rust: $(cargo --version)"
echo "Bootstrap complete."
