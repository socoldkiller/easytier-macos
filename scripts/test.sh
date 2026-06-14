#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift test
swift build --product EasyTierPrivilegedHelper

APP_PATH="$(EASYTIER_ALLOW_UNINSTALLABLE_HELPER=1 EASYTIER_EXPORT_APP_DIR=/tmp/EasyTier.app ./scripts/package-app.sh | tail -n 1)"
EASYTIER_VERIFY_INSTALLABLE_HELPER=0 ./scripts/verify-app.sh "$APP_PATH"
