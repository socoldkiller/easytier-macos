#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EASYTIER_DIR="$ROOT_DIR/Vendor/EasyTier"
GUI_FFI_DIR="$ROOT_DIR/Rust/EasyTierGuiFFI"
OUT_DIR="$ROOT_DIR/Vendor/Frameworks"
STATIC_DIR="$OUT_DIR/static"
CORE_STATIC_LIBRARY="$STATIC_DIR/libeasytier_core_ffi.a"
GATEWAY_STATIC_LIBRARY="$STATIC_DIR/libgateway_ffi.a"
CORE_TRACKED_HEADER="$ROOT_DIR/Sources/CEasyTierCoreFFI/include/EasyTierCoreFFI.h"
GATEWAY_TRACKED_HEADER="$ROOT_DIR/Sources/CGatewayFFI/include/GatewayFFI.h"
FFI_CACHE_DIR="${EASYTIER_FFI_CACHE_DIR:-$HOME/Library/Caches/easytier-macos/ffi}"
FFI_CACHE_VERSION="7"
USE_FFI_CACHE="${EASYTIER_USE_FFI_CACHE:-1}"
RUST_RELEASE_OPT_LEVEL="${EASYTIER_RUST_OPT_LEVEL:-z}"
RUST_RELEASE_LTO="${EASYTIER_RUST_LTO:-fat}"
RUST_RELEASE_CODEGEN_UNITS="${EASYTIER_RUST_CODEGEN_UNITS:-1}"
RUST_RELEASE_PANIC="${EASYTIER_RUST_PANIC:-abort}"
RUST_RELEASE_STRIP="${EASYTIER_RUST_STRIP:-none}"
STRIP_STATIC_LIBS="${EASYTIER_STRIP_STATIC_LIBS:-1}"
EXPECTED_CORE_REVISION="${EASYTIER_CORE_REVISION:-}"

# Xcode launched from Finder does not inherit Cargo or Homebrew shell paths.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

case "$(uname -m)" in
  arm64)
    TARGET_TRIPLE="aarch64-apple-darwin"
    ;;
  x86_64)
    TARGET_TRIPLE="x86_64-apple-darwin"
    ;;
  *)
    echo "Unsupported macOS architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

configure_rust_release_profile() {
  export CARGO_INCREMENTAL=0
  export CARGO_PROFILE_RELEASE_DEBUG=0
  export CARGO_PROFILE_RELEASE_OPT_LEVEL="$RUST_RELEASE_OPT_LEVEL"
  export CARGO_PROFILE_RELEASE_LTO="$RUST_RELEASE_LTO"
  export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="$RUST_RELEASE_CODEGEN_UNITS"
  export CARGO_PROFILE_RELEASE_PANIC="$RUST_RELEASE_PANIC"
  export CARGO_PROFILE_RELEASE_STRIP="$RUST_RELEASE_STRIP"

  echo "Rust FFI release profile: target=$TARGET_TRIPLE opt-level=$RUST_RELEASE_OPT_LEVEL lto=$RUST_RELEASE_LTO codegen-units=$RUST_RELEASE_CODEGEN_UNITS panic=$RUST_RELEASE_PANIC cargo-strip=$RUST_RELEASE_STRIP archive-strip=$STRIP_STATIC_LIBS incremental=0"
}

verify_core_gitlink() {
  if [[ ! -f "$EASYTIER_DIR/Cargo.toml" ]]; then
    echo "Vendor/EasyTier is not initialized; run: git submodule update --init --recursive" >&2
    exit 1
  fi

  local expected_rev current_rev
  current_rev="$(git -C "$EASYTIER_DIR" rev-parse HEAD)"
  if [[ -n "$EXPECTED_CORE_REVISION" ]]; then
    [[ "$EXPECTED_CORE_REVISION" =~ ^[0-9a-f]{40}$ ]] || {
      echo "EASYTIER_CORE_REVISION must be a full lowercase Git SHA: $EXPECTED_CORE_REVISION" >&2
      exit 1
    }
    expected_rev="$EXPECTED_CORE_REVISION"
  else
    expected_rev="$(git ls-files --stage -- Vendor/EasyTier | awk '$1 == 160000 { print $2 }')"
  fi
  if [[ -z "$expected_rev" || "$current_rev" != "$expected_rev" ]]; then
    echo "Vendor/EasyTier does not match the expected revision $expected_rev; current revision is $current_rev." >&2
    exit 1
  fi
  if [[ -n "$(git -C "$EASYTIER_DIR" status --short --untracked-files=no)" ]]; then
    echo "Vendor/EasyTier has tracked changes; refusing to cache a non-reproducible FFI build." >&2
    exit 1
  fi

  echo "EasyTier Core: $(git -C "$EASYTIER_DIR" describe --tags --always)"
}

strip_static_library() {
  local path="$1"
  if [[ "$STRIP_STATIC_LIBS" != "1" ]]; then
    return
  fi
  xcrun strip -S -x "$path"
  xcrun ranlib "$path"
}

archive_has_symbol() {
  local path="$1"
  local symbol="$2"
  grep -E "[[:space:]]T _$symbol$" < <(nm -gU "$path" 2>/dev/null || true) >/dev/null
}

verify_archive_symbols() {
  local symbol
  local core_symbols=(
    parse_config
    run_network_instance
    retain_network_instance
    stop_network_instance
    collect_network_infos
    connect_rpc_client
    call_json_rpc
    configure_rpc_portal
  )
  local gateway_symbols=(
    gateway_start
    gateway_apply_config
    gateway_stop
    gateway_status
    gateway_request_renewal
  )

  for symbol in "${core_symbols[@]}"; do
    archive_has_symbol "$CORE_STATIC_LIBRARY" "$symbol" || {
      echo "EasyTier Core FFI archive is missing symbol: $symbol" >&2
      return 1
    }
    ! archive_has_symbol "$GATEWAY_STATIC_LIBRARY" "$symbol" || {
      echo "Gateway FFI archive unexpectedly contains EasyTier Core symbol: $symbol" >&2
      return 1
    }
  done
  for symbol in "${gateway_symbols[@]}"; do
    archive_has_symbol "$GATEWAY_STATIC_LIBRARY" "$symbol" || {
      echo "Gateway FFI archive is missing symbol: $symbol" >&2
      return 1
    }
    ! archive_has_symbol "$CORE_STATIC_LIBRARY" "$symbol" || {
      echo "EasyTier Core FFI archive unexpectedly contains Gateway symbol: $symbol" >&2
      return 1
    }
  done
}

sha256_files() {
  cat "$@" | shasum -a 256 | awk '{ print $1 }'
}

hash_gui_ffi_sources() {
  {
    printf '%s\0' 'Cargo.toml'
    cat "$GUI_FFI_DIR/Cargo.toml"
    printf '%s\0' 'Cargo.lock'
    cat "$GUI_FFI_DIR/Cargo.lock"
    find "$GUI_FFI_DIR/src" -type f -name '*.rs' -print \
      | LC_ALL=C sort \
      | while IFS= read -r source_file; do
          printf '%s\0' "${source_file#"$GUI_FFI_DIR/"}"
          cat "$source_file"
        done
  } | shasum -a 256 | awk '{ print $1 }'
}

verify_rust_build_tools() {
  local tool
  for tool in cargo rustc cmake xcrun; do
    command -v "$tool" >/dev/null 2>&1 || {
      echo "Required Rust FFI build tool is missing: $tool" >&2
      exit 1
    }
  done
  xcrun --sdk macosx --find clang >/dev/null 2>&1 || {
    echo "Xcode Clang is unavailable; install or select Xcode Command Line Tools." >&2
    exit 1
  }
}

ffi_cache_key() {
  local core_rev cargo_lock_hash gui_ffi_hash header_hash script_hash rustc_hash profile_hash
  core_rev="$(git -C "$EASYTIER_DIR" rev-parse HEAD)"
  cargo_lock_hash="$(sha256_files "$EASYTIER_DIR/Cargo.lock")"
  gui_ffi_hash="$(hash_gui_ffi_sources)"
  header_hash="$(sha256_files "$CORE_TRACKED_HEADER" "$GATEWAY_TRACKED_HEADER")"
  script_hash="$(sha256_files "$ROOT_DIR/scripts/build-ffi.sh")"
  rustc_hash="$(rustc -vV | shasum -a 256 | awk '{ print $1 }')"
  profile_hash="$(printf '%s\n' \
    "cache=$FFI_CACHE_VERSION" \
    "core=$core_rev" \
    "cargo-lock=$cargo_lock_hash" \
    "gui-ffi=$gui_ffi_hash" \
    "header=$header_hash" \
    "script=$script_hash" \
    "rustc=$rustc_hash" \
    "deployment=$MACOSX_DEPLOYMENT_TARGET" \
    "target=$TARGET_TRIPLE" \
    "opt=$RUST_RELEASE_OPT_LEVEL" \
    "lto=$RUST_RELEASE_LTO" \
    "codegen-units=$RUST_RELEASE_CODEGEN_UNITS" \
    "panic=$RUST_RELEASE_PANIC" \
    "cargo-strip=$RUST_RELEASE_STRIP" \
    "archive-strip=$STRIP_STATIC_LIBS" \
    | shasum -a 256 | awk '{ print $1 }')"
  printf 'core-%s-%s' "$core_rev" "$profile_hash"
}

restore_cached_ffi() {
  local cache_path="$1"
  if [[ "$USE_FFI_CACHE" != "1" \
    || ! -f "$cache_path/libeasytier_core_ffi.a" \
    || ! -f "$cache_path/libgateway_ffi.a" ]]; then
    return 1
  fi

  mkdir -p "$STATIC_DIR"
  cp "$cache_path/libeasytier_core_ffi.a" "$CORE_STATIC_LIBRARY"
  cp "$cache_path/libgateway_ffi.a" "$GATEWAY_STATIC_LIBRARY"
  verify_archive_symbols || return 1
  echo "Restored isolated EasyTier Core and Gateway FFI archives from cache: $cache_path"
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
  mkdir -p "$tmp_path"
  cp "$CORE_STATIC_LIBRARY" "$tmp_path/libeasytier_core_ffi.a"
  cp "$GATEWAY_STATIC_LIBRARY" "$tmp_path/libgateway_ffi.a"
  rm -rf "$cache_path"
  mv "$tmp_path" "$cache_path"
  echo "Saved EasyTier FFI cache: $cache_path"
}

cd "$ROOT_DIR"
export MACOSX_DEPLOYMENT_TARGET=15.0
for tracked_header in "$CORE_TRACKED_HEADER" "$GATEWAY_TRACKED_HEADER"; do
  [[ -f "$tracked_header" ]] || {
    echo "Tracked FFI header not found: $tracked_header" >&2
    exit 1
  }
done
verify_core_gitlink
verify_rust_build_tools
configure_rust_release_profile

CACHE_KEY="$(ffi_cache_key)"
CACHE_PATH="$FFI_CACHE_DIR/$CACHE_KEY"
if restore_cached_ffi "$CACHE_PATH"; then
  exit 0
fi
echo "EasyTier FFI cache miss: $CACHE_PATH"

cargo build \
  --manifest-path "$GUI_FFI_DIR/Cargo.toml" \
  --release \
  --target "$TARGET_TRIPLE" \
  --target-dir "$GUI_FFI_DIR/target/core" \
  --no-default-features \
  --features core \
  --lib

cargo build \
  --manifest-path "$GUI_FFI_DIR/Cargo.toml" \
  --release \
  --target "$TARGET_TRIPLE" \
  --target-dir "$GUI_FFI_DIR/target/gateway" \
  --no-default-features \
  --features gateway \
  --lib

BUILT_CORE_STATIC="$GUI_FFI_DIR/target/core/$TARGET_TRIPLE/release/libeasytier_ffi.a"
BUILT_GATEWAY_STATIC="$GUI_FFI_DIR/target/gateway/$TARGET_TRIPLE/release/libeasytier_ffi.a"
[[ -f "$BUILT_CORE_STATIC" ]] || {
  echo "EasyTier Core Rust FFI archive not found after build: $BUILT_CORE_STATIC" >&2
  exit 1
}
[[ -f "$BUILT_GATEWAY_STATIC" ]] || {
  echo "Gateway Rust FFI archive not found after build: $BUILT_GATEWAY_STATIC" >&2
  exit 1
}

mkdir -p "$STATIC_DIR"
cp "$BUILT_CORE_STATIC" "$CORE_STATIC_LIBRARY"
cp "$BUILT_GATEWAY_STATIC" "$GATEWAY_STATIC_LIBRARY"
strip_static_library "$CORE_STATIC_LIBRARY"
strip_static_library "$GATEWAY_STATIC_LIBRARY"
verify_archive_symbols
save_cached_ffi "$CACHE_PATH"

echo "Created $CORE_STATIC_LIBRARY for $TARGET_TRIPLE"
echo "Created $GATEWAY_STATIC_LIBRARY for $TARGET_TRIPLE"
