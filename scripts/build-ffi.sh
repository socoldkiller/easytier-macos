#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EASYTIER_DIR="$ROOT_DIR/Vendor/EasyTier"
GUI_FFI_DIR="$ROOT_DIR/Rust/EasyTierGuiFFI"
OUT_DIR="$ROOT_DIR/Vendor/Frameworks"
HEADER_DIR="$OUT_DIR/include"
STATIC_DIR="$OUT_DIR/static"
CORE_TAG="${EASYTIER_CORE_TAG:-v2.6.4}"
FFI_CACHE_DIR="${EASYTIER_FFI_CACHE_DIR:-$HOME/Library/Caches/easytier-swift/ffi}"
FFI_CACHE_VERSION="4"
USE_FFI_CACHE="${EASYTIER_USE_FFI_CACHE:-1}"
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

sha256_files() {
  cat "$@" | shasum -a 256 | awk '{ print $1 }'
}

ffi_cache_key() {
  local core_rev cargo_lock_hash gui_ffi_hash script_hash rustc_hash profile_hash
  core_rev="$(git -C "$EASYTIER_DIR" rev-parse HEAD)"
  cargo_lock_hash="$(sha256_files "$EASYTIER_DIR/Cargo.lock")"
  gui_ffi_hash="$(sha256_files "$GUI_FFI_DIR/Cargo.toml" "$GUI_FFI_DIR/Cargo.lock" "$GUI_FFI_DIR/src/lib.rs")"
  script_hash="$(sha256_files "$ROOT_DIR/scripts/build-ffi.sh")"
  rustc_hash="$(rustc -vV | shasum -a 256 | awk '{ print $1 }')"
  profile_hash="$(printf '%s\n' \
    "cache=$FFI_CACHE_VERSION" \
    "core=$core_rev" \
    "cargo-lock=$cargo_lock_hash" \
    "gui-ffi=$gui_ffi_hash" \
    "script=$script_hash" \
    "rustc=$rustc_hash" \
    "deployment=$MACOSX_DEPLOYMENT_TARGET" \
    "opt=$RUST_RELEASE_OPT_LEVEL" \
    "lto=$RUST_RELEASE_LTO" \
    "codegen-units=$RUST_RELEASE_CODEGEN_UNITS" \
    "panic=$RUST_RELEASE_PANIC" \
    "cargo-strip=$RUST_RELEASE_STRIP" \
    "archive-strip=$STRIP_STATIC_LIBS" \
    "targets=aarch64-apple-darwin,x86_64-apple-darwin" \
    | shasum -a 256 | awk '{ print $1 }')"
  printf 'core-%s-%s' "$core_rev" "$profile_hash"
}

restore_cached_ffi() {
  local cache_path="$1"
  if [[ "$USE_FFI_CACHE" != "1" ]]; then
    return 1
  fi
  if [[ ! -f "$cache_path/static/libeasytier_ffi.a" || ! -d "$cache_path/EasyTierFFI.xcframework" ]]; then
    return 1
  fi

  rm -rf "$OUT_DIR"
  mkdir -p "$(dirname "$OUT_DIR")"
  ditto "$cache_path" "$OUT_DIR"
  mkdir -p "$ROOT_DIR/Sources/CEasyTierFFI/include"
  cp "$HEADER_DIR/EasyTierFFI.h" "$ROOT_DIR/Sources/CEasyTierFFI/include/EasyTierFFI.h"
  echo "Restored EasyTier FFI from cache: $cache_path"
}

save_cached_ffi() {
  local cache_path="$1"
  if [[ "$USE_FFI_CACHE" != "1" ]]; then
    return
  fi

  local tmp_path
  mkdir -p "$FFI_CACHE_DIR"
  tmp_path="$cache_path.tmp.$$"
  rm -rf "$tmp_path"
  ditto "$OUT_DIR" "$tmp_path"
  rm -rf "$cache_path"
  mv "$tmp_path" "$cache_path"
  echo "Saved EasyTier FFI cache: $cache_path"
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

CACHE_KEY="$(ffi_cache_key)"
CACHE_PATH="$FFI_CACHE_DIR/$CACHE_KEY"
if restore_cached_ffi "$CACHE_PATH"; then
  exit 0
fi
echo "EasyTier FFI cache miss: $CACHE_PATH"

mkdir -p "$OUT_DIR" "$HEADER_DIR" "$STATIC_DIR"

cat > "$HEADER_DIR/EasyTierFFI.h" <<'HEADER'
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct KeyValuePair {
  const char *key;
  const char *value;
} KeyValuePair;

int32_t parse_config(const char *cfg_str, const char **out_error);
int32_t run_network_instance(const char *cfg_str, const char **out_error);
int32_t retain_network_instance(const char **inst_names, uintptr_t length, const char **out_error);
int32_t stop_network_instance(const char **inst_names, uintptr_t length, const char **out_error);
int32_t collect_network_infos(KeyValuePair *infos, uintptr_t max_length, const char **out_error);
void free_string(const char *s);
int32_t connect_rpc_client(const char *client_id, const char *url, const char **out_error);
int32_t disconnect_rpc_client(const char *client_id, const char **out_error);
int32_t call_json_rpc(
  const char *client_id,
  const char *service_name,
  const char *method_name,
  const char *domain,
  const char *payload_json,
  const char **out_json,
  const char **out_error
);
int32_t configure_rpc_portal(
  int32_t enabled,
  const char *listen_addr,
  const char **whitelist,
  uintptr_t whitelist_count,
  const char **out_error
);
HEADER

build_target() {
  local target="$1"
  rustup target add "$target" >/dev/null
  cargo rustc --manifest-path "$GUI_FFI_DIR/Cargo.toml" \
    --release \
    --target "$target" \
    --lib \
    --crate-type staticlib
}

build_target aarch64-apple-darwin
build_target x86_64-apple-darwin

ARM_STATIC="$GUI_FFI_DIR/target/aarch64-apple-darwin/release/libeasytier_ffi.a"
X64_STATIC="$GUI_FFI_DIR/target/x86_64-apple-darwin/release/libeasytier_ffi.a"
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
save_cached_ffi "$CACHE_PATH"

echo "Created static $OUT_DIR/EasyTierFFI.xcframework"
