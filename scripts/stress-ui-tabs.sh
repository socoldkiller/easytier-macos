#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DURATION_SECONDS="${1:-60}"
INTERVAL_SECONDS="${2:-0.08}"
SAMPLE_SECONDS="${EASYTIER_UI_STRESS_SAMPLE_SECONDS:-8}"
PROCESS_NAME="${EASYTIER_UI_PROCESS_NAME:-EasyTierMac}"
APP_NAME="${EASYTIER_UI_APP_NAME:-EasyTier}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${EASYTIER_UI_STRESS_OUT_DIR:-/tmp/easytier-ui-stress-$RUN_ID}"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/stress-ui-tabs.sh [duration_seconds] [interval_seconds]

Drives the already-running EasyTier GUI by repeatedly clicking the workspace
tabs (Status, Traffic, Config, Peers, Logs). This is an external repro harness:
it does not modify or relaunch the app.

Examples:
  scripts/stress-ui-tabs.sh
  scripts/stress-ui-tabs.sh 60 0.05

Environment:
  EASYTIER_UI_APP_NAME=EasyTier
  EASYTIER_UI_PROCESS_NAME=EasyTierMac
  EASYTIER_UI_STRESS_SAMPLE_SECONDS=8
  EASYTIER_UI_STRESS_OUT_DIR=/tmp/easytier-ui-stress

macOS may require Accessibility permission for the terminal running this script.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

fail() {
  echo "error: $*" >&2
  exit 1
}

command -v osascript >/dev/null || fail "osascript is required on macOS."
command -v pgrep >/dev/null || fail "pgrep is required."

PID="$(pgrep -x "$PROCESS_NAME" | head -n 1 || true)"
if [[ -z "$PID" ]]; then
  PID="$(pgrep -f "/${PROCESS_NAME}$|/${PROCESS_NAME} " | head -n 1 || true)"
fi
[[ -n "$PID" ]] || fail "$PROCESS_NAME is not running. Start EasyTier GUI first, then rerun this script."

mkdir -p "$OUT_DIR"

PS_BEFORE="$OUT_DIR/ps-before.txt"
PS_AFTER="$OUT_DIR/ps-after.txt"
UI_LOG="$OUT_DIR/ui-driver.log"
SAMPLE_FILE="$OUT_DIR/sample.txt"
SAMPLE_ERROR="$OUT_DIR/sample-error.txt"

echo "EasyTier UI stress run"
echo "  pid:      $PID"
echo "  duration: ${DURATION_SECONDS}s"
echo "  interval: ${INTERVAL_SECONDS}s"
echo "  output:   $OUT_DIR"

ps -o pid,ppid,pcpu,pmem,rss,etime,state,command -p "$PID" >"$PS_BEFORE" 2>/dev/null || true

if command -v sample >/dev/null; then
  (
    sleep 2
    sample "$PID" "$SAMPLE_SECONDS" -file "$SAMPLE_FILE" >/dev/null 2>"$SAMPLE_ERROR" || true
  ) &
  SAMPLE_PID="$!"
else
  SAMPLE_PID=""
  echo "sample command not found." >"$SAMPLE_ERROR"
fi

set +e
osascript - "$APP_NAME" "$PROCESS_NAME" "$DURATION_SECONDS" "$INTERVAL_SECONDS" >"$UI_LOG" 2>&1 <<'APPLESCRIPT'
on parseReal(valueText, fallbackValue)
    try
        return valueText as real
    on error
        return fallbackValue
    end try
end parseReal

on findProcess(processName)
    tell application "System Events"
        if exists process processName then
            return process processName
        end if

        repeat with proc in processes
            set procName to name of proc as text
            if procName contains "EasyTier" then
                return proc
            end if
        end repeat
    end tell

    error "EasyTier process is not visible to System Events."
end findProcess

on findWorkspaceRadioGroup(targetProcess)
    tell application "System Events"
        tell targetProcess
            try
                repeat with toolbarGroup in groups of toolbar 1 of window 1
                    repeat with childElement in UI elements of toolbarGroup
                        try
                            if role of childElement is "AXRadioGroup" then
                                set childDescription to description of childElement as text
                                if childDescription contains "Workspace" and (count of radio buttons of childElement) is 5 then
                                    return childElement
                                end if
                            end if
                        end try
                    end repeat
                end repeat
            end try
        end tell
    end tell

    return missing value
end findWorkspaceRadioGroup

on clickWorkspaceTab(targetProcess, tabIndex)
    set workspaceRadioGroup to my findWorkspaceRadioGroup(targetProcess)
    if workspaceRadioGroup is missing value then return false

    tell application "System Events"
        try
            click radio button tabIndex of workspaceRadioGroup
            return true
        end try
        try
            click UI element tabIndex of workspaceRadioGroup
            return true
        end try
    end tell

    return false
end clickWorkspaceTab

on run argv
    set appName to item 1 of argv as text
    set processName to item 2 of argv as text
    set durationSeconds to my parseReal(item 3 of argv, 60)
    set intervalSeconds to my parseReal(item 4 of argv, 0.08)
    set tabTitles to {"Status", "Traffic", "Config", "Peers", "Logs"}

    try
        tell application appName to activate
    on error
        tell application processName to activate
    end try

    delay 0.4

    set endTime to (current date) + durationSeconds
    set clickCount to 0
    set missCount to 0
    set startedAt to current date

    repeat while (current date) < endTime
        set targetProcess to my findProcess(processName)
        repeat with tabIndex from 1 to count of tabTitles
            if (current date) >= endTime then exit repeat
            set clicked to my clickWorkspaceTab(targetProcess, tabIndex)
            if clicked then
                set clickCount to clickCount + 1
            else
                set missCount to missCount + 1
            end if
            delay intervalSeconds
        end repeat
    end repeat

    set elapsedSeconds to (current date) - startedAt
    log "clicked=" & clickCount & " missed=" & missCount & " elapsed_seconds=" & elapsedSeconds

    if clickCount = 0 then
        error "No workspace tabs were clicked. Grant Accessibility permission to this terminal, make the EasyTier window visible, then retry."
    end if
end run
APPLESCRIPT
OSASCRIPT_STATUS="$?"
set -e

if [[ -n "${SAMPLE_PID:-}" ]]; then
  wait "$SAMPLE_PID" || true
fi

ps -o pid,ppid,pcpu,pmem,rss,etime,state,command -p "$PID" >"$PS_AFTER" 2>/dev/null || true

echo
echo "Result files:"
echo "  ui log:       $UI_LOG"
echo "  ps before:    $PS_BEFORE"
echo "  ps after:     $PS_AFTER"
if [[ -s "$SAMPLE_FILE" ]]; then
  echo "  sample:       $SAMPLE_FILE"
else
  echo "  sample:       not captured; see $SAMPLE_ERROR"
fi

if [[ "$OSASCRIPT_STATUS" -ne 0 ]]; then
  echo >&2
  echo "UI driver failed. First lines from $UI_LOG:" >&2
  sed -n '1,80p' "$UI_LOG" >&2 || true
  echo >&2
  echo "If this is an Accessibility error, grant permission to Terminal/iTerm/Codex host in:" >&2
  echo "System Settings > Privacy & Security > Accessibility" >&2
  exit "$OSASCRIPT_STATUS"
fi

echo
echo "UI driver summary:"
sed -n '1,40p' "$UI_LOG" || true

echo
echo "CPU/RSS before:"
cat "$PS_BEFORE" || true
echo
echo "CPU/RSS after:"
cat "$PS_AFTER" || true
