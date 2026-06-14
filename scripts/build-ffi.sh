#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EASYTIER_DIR="$ROOT_DIR/Vendor/EasyTier"
OUT_DIR="$ROOT_DIR/Vendor/Frameworks"
HEADER_DIR="$OUT_DIR/include"
STATIC_DIR="$OUT_DIR/static"
CORE_TAG="${EASYTIER_CORE_TAG:-v2.6.4}"
RUST_RELEASE_OPT_LEVEL="${EASYTIER_RUST_OPT_LEVEL:-z}"
RUST_RELEASE_LTO="${EASYTIER_RUST_LTO:-fat}"
RUST_RELEASE_CODEGEN_UNITS="${EASYTIER_RUST_CODEGEN_UNITS:-1}"
RUST_RELEASE_PANIC="${EASYTIER_RUST_PANIC:-abort}"
RUST_RELEASE_STRIP="${EASYTIER_RUST_STRIP:-none}"
STRIP_STATIC_LIBS="${EASYTIER_STRIP_STATIC_LIBS:-1}"

configure_rust_release_profile() {
  # Keep the vendored EasyTier checkout clean while forcing the FFI/core build
  # through the smallest portable release profile. Override OPT_LEVEL=3 for
  # throughput-focused builds. Final archives are stripped explicitly below so
  # host-side proc-macro dylibs stay intact during cross compilation.
  export CARGO_INCREMENTAL=0
  export CARGO_PROFILE_RELEASE_DEBUG=0
  export CARGO_PROFILE_RELEASE_OPT_LEVEL="$RUST_RELEASE_OPT_LEVEL"
  export CARGO_PROFILE_RELEASE_LTO="$RUST_RELEASE_LTO"
  export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="$RUST_RELEASE_CODEGEN_UNITS"
  export CARGO_PROFILE_RELEASE_PANIC="$RUST_RELEASE_PANIC"
  export CARGO_PROFILE_RELEASE_STRIP="$RUST_RELEASE_STRIP"

  echo "Rust FFI release profile: opt-level=$RUST_RELEASE_OPT_LEVEL lto=$RUST_RELEASE_LTO codegen-units=$RUST_RELEASE_CODEGEN_UNITS panic=$RUST_RELEASE_PANIC cargo-strip=$RUST_RELEASE_STRIP archive-strip=$STRIP_STATIC_LIBS incremental=0"
}

strip_static_library() {
  local path="$1"
  if [[ "$STRIP_STATIC_LIBS" != "1" ]]; then
    return
  fi
  xcrun strip -S -x "$path"
  xcrun ranlib "$path"
}

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

cd "$ROOT_DIR"
export MACOSX_DEPLOYMENT_TARGET=14.0
ensure_easytier_core_tag
configure_rust_release_profile

mkdir -p "$OUT_DIR" "$HEADER_DIR" "$STATIC_DIR"

cat > "$HEADER_DIR/EasyTierFFI.h" <<'HEADER'
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct KeyValuePair {
  const char *key;
  const char *value;
} KeyValuePair;

int32_t parse_config(const char *cfg_str);
int32_t run_network_instance(const char *cfg_str);
int32_t retain_network_instance(const char **inst_names, uintptr_t length);
int32_t collect_network_infos(KeyValuePair *infos, uintptr_t max_length);
void get_error_msg(const char **out);
void free_string(const char *s);
HEADER

build_target() {
  local target="$1"
  rustup target add "$target" >/dev/null
  cargo rustc --manifest-path "$EASYTIER_DIR/Cargo.toml" \
    -p easytier-ffi \
    --release \
    --target "$target" \
    --lib \
    --crate-type staticlib
}

build_target aarch64-apple-darwin
build_target x86_64-apple-darwin

ARM_STATIC="$EASYTIER_DIR/target/aarch64-apple-darwin/release/libeasytier_ffi.a"
X64_STATIC="$EASYTIER_DIR/target/x86_64-apple-darwin/release/libeasytier_ffi.a"
UNIVERSAL_STATIC="$STATIC_DIR/libeasytier_ffi.a"

strip_static_library "$ARM_STATIC"
strip_static_library "$X64_STATIC"
lipo -create "$ARM_STATIC" "$X64_STATIC" -output "$UNIVERSAL_STATIC"

rm -rf "$OUT_DIR/EasyTierFFI.xcframework"
xcodebuild -create-xcframework \
  -library "$UNIVERSAL_STATIC" \
  -headers "$HEADER_DIR" \
  -output "$OUT_DIR/EasyTierFFI.xcframework"

cp "$HEADER_DIR/EasyTierFFI.h" "$ROOT_DIR/Sources/CEasyTierFFI/include/EasyTierFFI.h"

echo "Created static $OUT_DIR/EasyTierFFI.xcframework"
