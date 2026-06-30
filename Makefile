SHELL := /bin/bash

.DEFAULT_GOAL := help

ROOT_DIR := $(CURDIR)
ARTIFACTS_DIR ?= $(ROOT_DIR)/.build/artifacts
APP_PATH ?= $(ARTIFACTS_DIR)/EasyTier.app
INSTALL_APP_PATH ?= /Applications/EasyTier.app
ARCH := $(shell uname -m)
DMG_PATH ?= $(ARTIFACTS_DIR)/EasyTier-macOS-$(ARCH).dmg
LOCAL_CERT_PATH ?= $(ARTIFACTS_DIR)/EasyTierLocalCodeSigning.cer
LOCAL_INSTALL_NOTES_PATH ?= $(ARTIFACTS_DIR)/SELF_SIGNED_INSTALL.txt
CORE_TAG ?= v2.6.4
CODESIGN_IDENTITY ?=

# Rust FFI/core optimization knobs. Defaults favor the smallest release app.
RUST_OPT_LEVEL ?= z
RUST_LTO ?= fat
RUST_CODEGEN_UNITS ?= 1

.PHONY: help bootstrap ffi test clean-artifacts \
	require-codesign-identity \
	app-debug app-release-local app-release-adhoc app-release-signed \
	dmg-local dmg-adhoc dmg-signed dmg-from-app verify-app install-helper

help:
	@printf '%s\n' 'EasyTier macOS build targets:'
	@printf '%s\n' ''
	@printf '%-24s %s\n' 'make bootstrap' 'Check local Swift/Xcode/Rust/protoc setup.'
	@printf '%-24s %s\n' 'make ffi' 'Build optimized universal EasyTier Rust FFI static library.'
	@printf '%-24s %s\n' 'make test' 'Run Swift package tests.'
	@printf '%s\n' ''
	@printf '%-24s %s\n' 'make app-debug' 'Build a debug .app for local development.'
	@printf '%-24s %s\n' 'make app-release-local' 'Build a release .app signed with local/self-signed identity when needed.'
	@printf '%-24s %s\n' 'make app-release-adhoc' 'Build a release .app for symbol/bundle checks only; helper is not installable.'
	@printf '%-24s %s\n' 'make app-release-signed' 'Build a Developer ID signed release .app. Requires CODESIGN_IDENTITY=...'
	@printf '%s\n' ''
	@printf '%-24s %s\n' 'make dmg-local' 'Build optimized self-signed local release DMG.'
	@printf '%-24s %s\n' 'make dmg-adhoc' 'Build optimized ad-hoc verification DMG; helper is not installable.'
	@printf '%-24s %s\n' 'make dmg-signed' 'Build optimized Developer ID release DMG. Requires CODESIGN_IDENTITY=...'
	@printf '%-24s %s\n' 'make dmg-from-app' 'Package existing APP_PATH into DMG_PATH.'
	@printf '%-24s %s\n' 'make verify-app' 'Run bundle/signature/linkage verification on APP_PATH.'
	@printf '%-24s %s\n' 'make install-helper' 'Package, install/check privileged helper, then open the app.'
	@printf '%s\n' ''
	@printf '%s\n' 'Useful overrides:'
	@printf '%s\n' '  APP_PATH=/path/EasyTier.app DMG_PATH=/path/EasyTier.dmg CORE_TAG=vX.Y.Z'
	@printf '%s\n' '  CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)"'
	@printf '%s\n' '  RUST_OPT_LEVEL=3 for throughput-focused Rust builds; default is z for size.'

bootstrap:
	./scripts/bootstrap.sh

ffi:
	EASYTIER_CORE_TAG="$(CORE_TAG)" \
	EASYTIER_RUST_OPT_LEVEL="$(RUST_OPT_LEVEL)" \
	EASYTIER_RUST_LTO="$(RUST_LTO)" \
	EASYTIER_RUST_CODEGEN_UNITS="$(RUST_CODEGEN_UNITS)" \
	./scripts/build-ffi.sh

test:
	swift test --configuration release

clean-artifacts:
	rm -rf "$(ARTIFACTS_DIR)"

require-codesign-identity:
	@if [[ -z "$(CODESIGN_IDENTITY)" ]]; then \
		echo 'CODESIGN_IDENTITY is required, for example:' >&2; \
		echo '  make dmg-signed CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)"' >&2; \
		exit 1; \
	fi

app-debug: ffi
	mkdir -p "$(ARTIFACTS_DIR)"
	EASYTIER_BUILD_CONFIGURATION=debug \
	EASYTIER_EXPORT_APP_DIR="$(APP_PATH)" \
	./scripts/package-app.sh

app-release-local: ffi
	mkdir -p "$(ARTIFACTS_DIR)"
	EASYTIER_BUILD_CONFIGURATION=release \
	EASYTIER_EXPORT_APP_DIR="$(APP_PATH)" \
	EASYTIER_EXPORT_CODESIGN_CERT_PATH="$(LOCAL_CERT_PATH)" \
	./scripts/package-app.sh

app-release-adhoc: ffi
	mkdir -p "$(ARTIFACTS_DIR)"
	EASYTIER_BUILD_CONFIGURATION=release \
	EASYTIER_ALLOW_UNINSTALLABLE_HELPER=1 \
	EASYTIER_EXPORT_APP_DIR="$(APP_PATH)" \
	./scripts/package-app.sh

app-release-signed: require-codesign-identity ffi
	mkdir -p "$(ARTIFACTS_DIR)"
	EASYTIER_BUILD_CONFIGURATION=release \
	EASYTIER_REQUIRE_DISTRIBUTION_SIGNING=1 \
	EASYTIER_CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
	EASYTIER_EXPORT_APP_DIR="$(APP_PATH)" \
	./scripts/package-app.sh

$(LOCAL_INSTALL_NOTES_PATH):
	mkdir -p "$(ARTIFACTS_DIR)"
	printf '%s\n' \
		'EasyTier self-signed developer-mode build' \
		'' \
		'This DMG is not Developer ID signed or Apple notarized.' \
		'' \
		'To try the privileged helper on macOS:' \
		'1. Import and trust EasyTierLocalCodeSigning.cer for Code Signing.' \
		'2. Drag EasyTier.app to Applications.' \
		'3. Run xattr -cr /Applications/EasyTier.app if macOS copied quarantine attributes.' \
		'4. Open EasyTier.app, click Install Helper, and approve it in System Settings if prompted.' \
		'' \
		'Do not use this self-signed build as a production release.' \
		> "$(LOCAL_INSTALL_NOTES_PATH)"

dmg-local: app-release-local $(LOCAL_INSTALL_NOTES_PATH)
	EASYTIER_DMG_CODESIGN_CERT_PATH="$(LOCAL_CERT_PATH)" \
	EASYTIER_DMG_INSTALL_NOTES_PATH="$(LOCAL_INSTALL_NOTES_PATH)" \
	./scripts/create-dmg.sh "$(APP_PATH)" "$(DMG_PATH)"

dmg-adhoc: app-release-adhoc
	./scripts/create-dmg.sh "$(APP_PATH)" "$(DMG_PATH)"

dmg-signed: app-release-signed
	./scripts/create-dmg.sh "$(APP_PATH)" "$(DMG_PATH)"

dmg-from-app:
	./scripts/create-dmg.sh "$(APP_PATH)" "$(DMG_PATH)"

verify-app:
	./scripts/verify-app.sh "$(APP_PATH)"

install-helper:
	EASYTIER_EXPORT_APP_DIR="$(INSTALL_APP_PATH)" \
	EASYTIER_OPEN_APP=1 \
	./scripts/dev-install-helper.sh
