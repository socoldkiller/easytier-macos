SHELL := /bin/bash

.DEFAULT_GOAL := help

ROOT_DIR := $(CURDIR)
ARTIFACTS_DIR ?= $(ROOT_DIR)/.build/artifacts
APP_PRODUCTS_DIR ?= $(ROOT_DIR)/.build/AppProducts
SWIFT_BUILD_DIR ?= $(APP_PRODUCTS_DIR)/SwiftBuild
APP_PATH ?= $(ARTIFACTS_DIR)/EasyTier.app
INSTALL_APP_PATH ?= /Applications/EasyTier.app
ARCH := $(shell uname -m)
DMG_PATH ?= $(ARTIFACTS_DIR)/EasyTier-macOS-$(ARCH).dmg
FFI_CACHE_DIR ?= $(HOME)/Library/Caches/easytier-macos/ffi
CODESIGN_IDENTITY ?=

# Rust FFI/core optimization knobs. Defaults favor the smallest release app.
RUST_OPT_LEVEL ?= z
RUST_LTO ?= fat
RUST_CODEGEN_UNITS ?= 1

.PHONY: help bootstrap ffi test-swift test-rust test smoke clean clean-cache \
	require-codesign-identity \
	app-debug app-release-adhoc app-release-signed \
	dmg dmg-adhoc dmg-signed dmg-from-app verify-app install-helper

help:
	@printf '%s\n' 'EasyTier macOS build targets:'
	@printf '%s\n' ''
	@printf '%-24s %s\n' 'make bootstrap' 'Check local Swift/Xcode/Rust/protoc setup.'
	@printf '%-24s %s\n' 'make ffi' 'Build the optimized Rust FFI static library for this Mac.'
	@printf '%-24s %s\n' 'make test-swift' 'Run Swift package tests.'
	@printf '%-24s %s\n' 'make test-rust' 'Run Rust FFI tests.'
	@printf '%-24s %s\n' 'make test' 'Run all automated tests.'
	@printf '%-24s %s\n' 'make smoke' 'Run tests and package an ad-hoc release app.'
	@printf '%s\n' ''
	@printf '%-24s %s\n' 'make app-debug' 'Build an ad-hoc debug .app for local development.'
	@printf '%-24s %s\n' 'make app-release-adhoc' 'Build an ad-hoc release .app; helper installation is unavailable.'
	@printf '%-24s %s\n' 'make app-release-signed' 'Build a Developer ID signed release .app. Requires CODESIGN_IDENTITY=...'
	@printf '%s\n' ''
	@printf '%-24s %s\n' 'make dmg' 'Build the default ad-hoc DMG.'
	@printf '%-24s %s\n' 'make dmg-adhoc' 'Build an ad-hoc DMG; helper installation is unavailable.'
	@printf '%-24s %s\n' 'make dmg-signed' 'Build optimized Developer ID release DMG. Requires CODESIGN_IDENTITY=...'
	@printf '%-24s %s\n' 'make dmg-from-app' 'Package existing APP_PATH into DMG_PATH.'
	@printf '%-24s %s\n' 'make verify-app' 'Run bundle/signature/linkage verification on APP_PATH.'
	@printf '%-24s %s\n' 'make install-helper' 'Package, install/check privileged helper, then open the app.'
	@printf '%-24s %s\n' 'make clean' 'Remove project build artifacts.'
	@printf '%-24s %s\n' 'make clean-cache' 'Also remove Swift/Rust and FFI caches.'
	@printf '%s\n' ''
	@printf '%s\n' 'Useful overrides:'
	@printf '%s\n' '  APP_PATH=/path/EasyTier.app DMG_PATH=/path/EasyTier.dmg'
	@printf '%s\n' '  CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)"'
	@printf '%s\n' '  RUST_OPT_LEVEL=3 for throughput-focused Rust builds; default is z for size.'

bootstrap:
	./scripts/bootstrap.sh

ffi:
	EASYTIER_FFI_CACHE_DIR="$(FFI_CACHE_DIR)" \
	EASYTIER_RUST_OPT_LEVEL="$(RUST_OPT_LEVEL)" \
	EASYTIER_RUST_LTO="$(RUST_LTO)" \
	EASYTIER_RUST_CODEGEN_UNITS="$(RUST_CODEGEN_UNITS)" \
	./scripts/build-ffi.sh

test-swift:
	swift test --scratch-path "$(SWIFT_BUILD_DIR)" --configuration release

test-rust:
	cargo test --manifest-path Rust/EasyTierGuiFFI/Cargo.toml

test: test-swift test-rust

smoke: test app-release-adhoc

clean:
	rm -rf \
		"$(ARTIFACTS_DIR)" \
		"$(APP_PRODUCTS_DIR)" \
		"$(ROOT_DIR)/Vendor/Frameworks/static"

clean-cache: clean
	rm -rf \
		"$(ROOT_DIR)/.build" \
		"$(ROOT_DIR)/Rust/EasyTierGuiFFI/target" \
		"$(FFI_CACHE_DIR)"

require-codesign-identity:
	@if [[ -z "$(CODESIGN_IDENTITY)" ]]; then \
		echo 'CODESIGN_IDENTITY is required, for example:' >&2; \
		echo '  make dmg-signed CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)"' >&2; \
		exit 1; \
	fi

app-debug: ffi
	mkdir -p "$(ARTIFACTS_DIR)"
	EASYTIER_BUILD_CONFIGURATION=debug \
	EASYTIER_APP_PRODUCTS_DIR="$(APP_PRODUCTS_DIR)" \
	EASYTIER_SWIFT_BUILD_DIR="$(SWIFT_BUILD_DIR)" \
	EASYTIER_AUTO_CODESIGN_IDENTITY=0 \
	EASYTIER_ALLOW_UNINSTALLABLE_HELPER=1 \
	EASYTIER_EXPORT_APP_DIR="$(APP_PATH)" \
	./scripts/package-app.sh

app-release-adhoc: ffi
	mkdir -p "$(ARTIFACTS_DIR)"
	EASYTIER_BUILD_CONFIGURATION=release \
	EASYTIER_APP_PRODUCTS_DIR="$(APP_PRODUCTS_DIR)" \
	EASYTIER_SWIFT_BUILD_DIR="$(SWIFT_BUILD_DIR)" \
	EASYTIER_AUTO_CODESIGN_IDENTITY=0 \
	EASYTIER_ALLOW_UNINSTALLABLE_HELPER=1 \
	EASYTIER_EXPORT_APP_DIR="$(APP_PATH)" \
	./scripts/package-app.sh

app-release-signed: require-codesign-identity ffi
	mkdir -p "$(ARTIFACTS_DIR)"
	EASYTIER_BUILD_CONFIGURATION=release \
	EASYTIER_APP_PRODUCTS_DIR="$(APP_PRODUCTS_DIR)" \
	EASYTIER_SWIFT_BUILD_DIR="$(SWIFT_BUILD_DIR)" \
	EASYTIER_REQUIRE_DISTRIBUTION_SIGNING=1 \
	EASYTIER_CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
	EASYTIER_EXPORT_APP_DIR="$(APP_PATH)" \
	./scripts/package-app.sh

dmg: dmg-adhoc

dmg-adhoc: app-release-adhoc
	./scripts/create-dmg.sh "$(APP_PATH)" "$(DMG_PATH)"

dmg-signed: app-release-signed
	./scripts/create-dmg.sh "$(APP_PATH)" "$(DMG_PATH)"

dmg-from-app:
	./scripts/create-dmg.sh "$(APP_PATH)" "$(DMG_PATH)"

verify-app:
	./scripts/verify-app.sh "$(APP_PATH)"

install-helper: ffi
	EASYTIER_APP_PRODUCTS_DIR="$(APP_PRODUCTS_DIR)" \
	EASYTIER_SWIFT_BUILD_DIR="$(SWIFT_BUILD_DIR)" \
	EASYTIER_ALLOW_UNINSTALLABLE_HELPER=0 \
	EASYTIER_EXPORT_APP_DIR="$(INSTALL_APP_PATH)" \
	EASYTIER_OPEN_APP=1 \
	./scripts/dev-install-helper.sh
