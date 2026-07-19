SHELL := /bin/bash

.DEFAULT_GOAL := help

ROOT_DIR := $(CURDIR)
ARTIFACTS_DIR ?= $(ROOT_DIR)/.build/artifacts
APP_PRODUCTS_DIR ?= $(ROOT_DIR)/.build/AppProducts
SWIFT_BUILD_DIR ?= $(APP_PRODUCTS_DIR)/SwiftBuild
APP_PATH ?= $(ARTIFACTS_DIR)/EasyTier.app
INSTALL_APP_PATH ?= /Applications/EasyTier.app
RELEASE_ARCH ?= ARM64
DMG_PATH ?= $(ARTIFACTS_DIR)/EasyTier-macOS-$(RELEASE_ARCH).dmg
FFI_CACHE_DIR ?= $(HOME)/Library/Caches/easytier-macos/ffi
RUST_TOOLS_DIR ?= $(APP_PRODUCTS_DIR)/RustTools
PYTHON_BIN ?= python3
CODESIGN_IDENTITY ?=
CODESIGN_KEYCHAIN ?= $(firstword $(wildcard $(HOME)/Library/Keychains/easytier-signing.keychain-db))
PROVISIONING_PROFILE ?= $(HOME)/Library/Developer/Xcode/UserData/Provisioning Profiles/56f9d3f7-c23c-4946-a0e9-f226d27458e7.provisionprofile
SPARKLE_PUBLIC_ED_KEY ?=
NOTARY_PROFILE ?= easytier-notary
NOTARY_KEYCHAIN ?= $(CODESIGN_KEYCHAIN)
RELEASE_TAG ?=
APP_VERSION ?=
BUILD_NUMBER ?=

# Rust FFI/core optimization knobs. Defaults favor the smallest release app.
RUST_OPT_LEVEL ?= z
RUST_LTO ?= fat
RUST_CODEGEN_UNITS ?= 1

.PHONY: help bootstrap rust-toolchain-shims ffi test-swift test-rust test-packaging test-xcode-project test test-keychain-integration smoke clean clean-cache \
	require-codesign-identity \
	app-debug app-release-signed \
	debug-install dmg release-dmg verify-app install-helper

help:
	@printf '%s\n' 'EasyTier macOS build targets:'
	@printf '%s\n' ''
	@printf '%-24s %s\n' 'make bootstrap' 'Check local Swift/Xcode/Rust/protoc setup.'
	@printf '%-24s %s\n' 'make ffi' 'Build the isolated EasyTier Core and Gateway FFI archives.'
	@printf '%-24s %s\n' 'make test-swift' 'Run Swift package tests.'
	@printf '%-24s %s\n' 'make test-rust' 'Run Rust FFI tests.'
	@printf '%-24s %s\n' 'make test-packaging' 'Run credential-free release pipeline tests.'
	@printf '%-24s %s\n' 'make test-xcode-project' 'Resolve and validate the native Xcode project.'
	@printf '%-24s %s\n' 'make test' 'Run all automated tests.'
	@printf '%-24s %s\n' 'make test-keychain-integration' 'Run the signed Data Protection Keychain integration harness.'
	@printf '%-24s %s\n' 'make smoke' 'Run tests and package a Developer ID app with the required profile/Sparkle key.'
	@printf '%s\n' ''
	@printf '%-24s %s\n' 'make app-debug' 'Archive a Developer ID signed debug .app with Xcode.'
	@printf '%-24s %s\n' 'make debug-install' 'Build, install, and open the signed Xcode Debug app.'
	@printf '%-24s %s\n' 'make app-release-signed' 'Archive a Developer ID signed release .app with Xcode.'
	@printf '%s\n' ''
	@printf '%-24s %s\n' 'make dmg' 'Build the final signed, notarized, stapled, and verified release DMG.'
	@printf '%-24s %s\n' 'make verify-app' 'Run bundle/signature/linkage verification on APP_PATH.'
	@printf '%-24s %s\n' 'make install-helper' 'Package, install/check privileged helper, then open the app.'
	@printf '%-24s %s\n' 'make clean' 'Remove project build artifacts.'
	@printf '%-24s %s\n' 'make clean-cache' 'Also remove Swift/Rust and FFI caches.'
	@printf '%s\n' ''
	@printf '%s\n' 'Useful overrides:'
	@printf '%s\n' '  APP_PATH=/path/EasyTier.app DMG_PATH=/path/EasyTier.dmg'
	@printf '%s\n' '  CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)"'
	@printf '%s\n' '  CODESIGN_KEYCHAIN=/path/to/signing.keychain-db'
	@printf '%s\n' '  PROVISIONING_PROFILE=/path/to/EasyTier.provisionprofile'
	@printf '%s\n' '  SPARKLE_PUBLIC_ED_KEY="base64 SUPublicEDKey from Sparkle generate_keys"'
	@printf '%s\n' '  NOTARY_PROFILE=easytier-notary NOTARY_KEYCHAIN=/path/to/signing.keychain-db'
	@printf '%s\n' '  RELEASE_TAG=v1.4.0, or APP_VERSION=1.4.0 BUILD_NUMBER=YYYYMMDDhhmmss'
	@printf '%s\n' '  RUST_OPT_LEVEL=3 for throughput-focused Rust builds; default is z for size.'

bootstrap:
	./scripts/bootstrap.sh

rust-toolchain-shims:
	mkdir -p "$(RUST_TOOLS_DIR)"
	ln -sf "$$(xcrun --sdk macosx --find ar)" "$(RUST_TOOLS_DIR)/llvm-ar"

ffi: rust-toolchain-shims
	PATH="$(RUST_TOOLS_DIR):$$PATH" \
	EASYTIER_FFI_CACHE_DIR="$(FFI_CACHE_DIR)" \
	EASYTIER_RUST_OPT_LEVEL="$(RUST_OPT_LEVEL)" \
	EASYTIER_RUST_LTO="$(RUST_LTO)" \
	EASYTIER_RUST_CODEGEN_UNITS="$(RUST_CODEGEN_UNITS)" \
	./scripts/build-ffi.sh

test-swift:
	swift test --scratch-path "$(SWIFT_BUILD_DIR)" --configuration release

test-rust: rust-toolchain-shims
	PATH="$(RUST_TOOLS_DIR):$$PATH" \
		./scripts/test-rust.sh

test-packaging:
	$(PYTHON_BIN) -m unittest discover -s Tests/PackagingTests -p 'test_*.py' -v
	bash Tests/PackagingTests/release-pipeline-tests.sh

test-xcode-project:
	xcodebuild -project EasyTier.xcodeproj -list \
		-clonedSourcePackagesDirPath "$(SWIFT_BUILD_DIR)" \
		-disableAutomaticPackageResolution \
		-onlyUsePackageVersionsFromResolvedFile

test: test-swift test-rust test-packaging test-xcode-project

test-keychain-integration: require-codesign-identity
	EASYTIER_CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
	EASYTIER_CODESIGN_KEYCHAIN="$(CODESIGN_KEYCHAIN)" \
	EASYTIER_PROVISIONING_PROFILE="$(PROVISIONING_PROFILE)" \
	EASYTIER_SWIFT_BUILD_DIR="$(SWIFT_BUILD_DIR)" \
	./scripts/test-keychain-integration.sh

smoke: test test-keychain-integration app-release-signed

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
	@case "$(CODESIGN_IDENTITY)" in \
		'Developer ID Application:'*) ;; \
		*) \
			echo 'CODESIGN_IDENTITY must be a Developer ID Application identity, for example:' >&2; \
			echo '  make dmg CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)"' >&2; \
			exit 1; \
			;; \
	esac

app-debug: require-codesign-identity
	mkdir -p "$(ARTIFACTS_DIR)"
	EASYTIER_BUILD_CONFIGURATION=debug \
	EASYTIER_APP_PRODUCTS_DIR="$(APP_PRODUCTS_DIR)" \
	EASYTIER_SWIFT_BUILD_DIR="$(SWIFT_BUILD_DIR)" \
	EASYTIER_CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
	EASYTIER_CODESIGN_KEYCHAIN="$(CODESIGN_KEYCHAIN)" \
	EASYTIER_PROVISIONING_PROFILE="$(PROVISIONING_PROFILE)" \
	EASYTIER_SPARKLE_PUBLIC_ED_KEY="$(SPARKLE_PUBLIC_ED_KEY)" \
	EASYTIER_APP_VERSION="$(APP_VERSION)" \
	EASYTIER_BUILD_NUMBER="$(BUILD_NUMBER)" \
	EASYTIER_EXPORT_APP_DIR="$(APP_PATH)" \
	./scripts/archive-app.sh

app-release-signed: require-codesign-identity
	mkdir -p "$(ARTIFACTS_DIR)"
	EASYTIER_BUILD_CONFIGURATION=release \
	EASYTIER_APP_PRODUCTS_DIR="$(APP_PRODUCTS_DIR)" \
	EASYTIER_SWIFT_BUILD_DIR="$(SWIFT_BUILD_DIR)" \
	EASYTIER_CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
	EASYTIER_CODESIGN_KEYCHAIN="$(CODESIGN_KEYCHAIN)" \
	EASYTIER_PROVISIONING_PROFILE="$(PROVISIONING_PROFILE)" \
	EASYTIER_SPARKLE_PUBLIC_ED_KEY="$(SPARKLE_PUBLIC_ED_KEY)" \
	EASYTIER_APP_VERSION="$(APP_VERSION)" \
	EASYTIER_BUILD_NUMBER="$(BUILD_NUMBER)" \
	EASYTIER_EXPORT_APP_DIR="$(APP_PATH)" \
	./scripts/archive-app.sh

debug-install:
	@build_number="$$(date -u +%Y%m%d%H%M%S)"; \
	build_time="$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	gui_commit="$$(git -C "$(ROOT_DIR)" rev-parse HEAD 2>/dev/null || printf unknown)"; \
	core_commit="$$(git -C "$(ROOT_DIR)/Vendor/EasyTier" rev-parse HEAD 2>/dev/null || printf unknown)"; \
	core_tag="$$(git -C "$(ROOT_DIR)/Vendor/EasyTier" describe --tags --always 2>/dev/null || printf unknown)"; \
	gateway_version="$$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$(ROOT_DIR)/Rust/EasyTierGuiFFI/Cargo.toml" | head -n 1)"; \
	if test -n "$$(git -C "$(ROOT_DIR)" status --short --untracked-files=no --ignore-submodules=all 2>/dev/null)"; then gui_commit="$$gui_commit-dirty"; fi; \
	if test -n "$$(git -C "$(ROOT_DIR)/Vendor/EasyTier" status --short --untracked-files=no 2>/dev/null)"; then core_commit="$$core_commit-dirty"; core_tag="$$core_tag-dirty"; fi; \
	printf 'Building local Debug app: build=%s time=%s GUI/Gateway=%s Gateway=%s Core=%s (%s)\n' "$$build_number" "$$build_time" "$$gui_commit" "$$gateway_version" "$$core_tag" "$$core_commit"; \
	xcodebuild -project EasyTier.xcodeproj \
		-scheme EasyTierMac \
		-configuration Debug \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath "$(APP_PRODUCTS_DIR)/DebugDerivedData" \
		"CURRENT_PROJECT_VERSION=$$build_number" \
		"EASYTIER_BUILD_TIME=$$build_time" \
		"EASYTIER_GUI_COMMIT=$$gui_commit" \
		"GATEWAY_BUILD_TIME=$$build_time" \
		"GATEWAY_COMMIT=$$gui_commit" \
		"GATEWAY_VERSION=$$gateway_version" \
		"EASYTIER_CORE_TAG=$$core_tag" \
		"EASYTIER_CORE_COMMIT=$$core_commit" \
		build
	EASYTIER_INSTALL_APP_PATH="$(INSTALL_APP_PATH)" \
	EASYTIER_OPEN_APP=1 \
	./scripts/install-xcode-debug-app.sh \
		"$(APP_PRODUCTS_DIR)/DebugDerivedData/Build/Products/Debug/EasyTier.app"

dmg: release-dmg

release-dmg: require-codesign-identity
	EASYTIER_ARTIFACTS_DIR="$(ARTIFACTS_DIR)" \
	EASYTIER_APP_PRODUCTS_DIR="$(APP_PRODUCTS_DIR)" \
	EASYTIER_SWIFT_BUILD_DIR="$(SWIFT_BUILD_DIR)" \
	EASYTIER_CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
	EASYTIER_CODESIGN_KEYCHAIN="$(CODESIGN_KEYCHAIN)" \
	EASYTIER_PROVISIONING_PROFILE="$(PROVISIONING_PROFILE)" \
	EASYTIER_SPARKLE_PUBLIC_ED_KEY="$(SPARKLE_PUBLIC_ED_KEY)" \
	EASYTIER_NOTARY_KEYCHAIN_PROFILE="$(NOTARY_PROFILE)" \
	EASYTIER_NOTARY_KEYCHAIN="$(NOTARY_KEYCHAIN)" \
	EASYTIER_RELEASE_TAG="$(RELEASE_TAG)" \
	EASYTIER_APP_VERSION="$(APP_VERSION)" \
	EASYTIER_BUILD_NUMBER="$(BUILD_NUMBER)" \
	EASYTIER_EXPORT_APP_DIR="$(APP_PATH)" \
	EASYTIER_DMG_PATH="$(DMG_PATH)" \
	./scripts/release.sh artifact

verify-app:
	./scripts/verify-app.sh "$(APP_PATH)"

install-helper: require-codesign-identity
	EASYTIER_APP_PRODUCTS_DIR="$(APP_PRODUCTS_DIR)" \
	EASYTIER_SWIFT_BUILD_DIR="$(SWIFT_BUILD_DIR)" \
	EASYTIER_CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
	EASYTIER_CODESIGN_KEYCHAIN="$(CODESIGN_KEYCHAIN)" \
	EASYTIER_PROVISIONING_PROFILE="$(PROVISIONING_PROFILE)" \
	EASYTIER_SPARKLE_PUBLIC_ED_KEY="$(SPARKLE_PUBLIC_ED_KEY)" \
	EASYTIER_EXPORT_APP_DIR="$(INSTALL_APP_PATH)" \
	EASYTIER_OPEN_APP=1 \
	./scripts/dev-install-helper.sh
