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

export ARTIFACTS_DIR APP_PRODUCTS_DIR SWIFT_BUILD_DIR APP_PATH INSTALL_APP_PATH DMG_PATH
export CODESIGN_IDENTITY CODESIGN_KEYCHAIN PROVISIONING_PROFILE SPARKLE_PUBLIC_ED_KEY
export NOTARY_PROFILE NOTARY_KEYCHAIN RELEASE_TAG APP_VERSION BUILD_NUMBER

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
	./scripts/build.sh app debug

app-release-signed: require-codesign-identity
	./scripts/build.sh app release

debug-install:
	EASYTIER_OPEN_APP=1 ./scripts/build.sh debug-install

dmg: release-dmg

release-dmg: require-codesign-identity
	./scripts/build.sh package

verify-app:
	./scripts/build.sh verify app "$(APP_PATH)"

install-helper: require-codesign-identity
	EASYTIER_OPEN_APP=1 ./scripts/build.sh install-helper
