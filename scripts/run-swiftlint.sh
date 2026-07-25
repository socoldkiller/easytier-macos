#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE_TEMPLATE="$ROOT_DIR/.swiftlint-baseline.json"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easytier-swiftlint.XXXXXX")"
RUNTIME_BASELINE="$TEMP_DIR/baseline.json"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

EASYTIER_LINT_ROOT="$ROOT_DIR" \
EASYTIER_LINT_BASELINE_TEMPLATE="$BASELINE_TEMPLATE" \
EASYTIER_LINT_RUNTIME_BASELINE="$RUNTIME_BASELINE" \
"${PYTHON_BIN:-python3}" <<'PY'
import json
import os
from pathlib import Path

placeholder = "file:///__EASYTIER_REPOSITORY_ROOT__"
template = json.loads(
    Path(os.environ["EASYTIER_LINT_BASELINE_TEMPLATE"]).read_text(encoding="utf-8")
)
root_uri = Path(os.environ["EASYTIER_LINT_ROOT"]).resolve().as_uri()
replacement_count = 0
for entry in template:
    location = entry["violation"]["location"]
    file_uri = location["file"]
    if file_uri.startswith(placeholder):
        location["file"] = root_uri + file_uri.removeprefix(placeholder)
        replacement_count += 1

if replacement_count == 0:
    raise SystemExit("SwiftLint baseline does not contain the repository root placeholder.")

Path(os.environ["EASYTIER_LINT_RUNTIME_BASELINE"]).write_text(
    json.dumps(template, separators=(",", ":")),
    encoding="utf-8",
)
PY

swiftlint lint \
  --strict \
  --config "$ROOT_DIR/.swiftlint.yml" \
  --baseline "$RUNTIME_BASELINE" \
  --working-directory "$ROOT_DIR" \
  "$@"
