#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCESS_NAME="${EASYTIER_UI_PROCESS_NAME:-EasyTierMac}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${EASYTIER_WAKE_REPRO_OUT_DIR:-/tmp/easytier-wake-repro-$RUN_ID}"

MODE="suspend"
SUSPEND_SECONDS="45"
UI_SECONDS="60"
UI_INTERVAL="0.05"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/repro-wake-lag.sh [options]

Builds a fast, external wake-lag repro around the already-running EasyTier GUI.
It does not modify or relaunch the app.

Modes:
  --mode suspend      Pause only EasyTierMac with SIGSTOP, then resume with SIGCONT.
                      Fast and fully scriptable; approximates app suspension.
  --mode lock-screen  Lock the current macOS session, wait, then run UI stress after
                      you manually unlock. Closest to the reported lock-screen bug.
  --mode real-sleep   Try to schedule a near wake and put macOS to sleep.
                      Closer to the real bug; may require manual wake or privileges.

Options:
  --suspend-seconds N Seconds to suspend/sleep before resuming. Default: 45
  --ui-seconds N      Seconds of post-resume UI tab switching. Default: 60
  --ui-interval N     Delay between tab clicks. Default: 0.05
  -h, --help          Show this help.

Examples:
  scripts/repro-wake-lag.sh
  scripts/repro-wake-lag.sh --mode suspend --suspend-seconds 60
  scripts/repro-wake-lag.sh --mode lock-screen --suspend-seconds 60
  scripts/repro-wake-lag.sh --mode real-sleep --suspend-seconds 90

Interpretation:
  1. Run scripts/stress-ui-tabs.sh 60 0.05 as baseline.
  2. Run this script in suspend mode.
  3. If suspend mode is worse than baseline, the bug is likely resume/backlog related.
  4. Run lock-screen mode for the user-reported scenario.
  5. If only lock-screen/real-sleep mode is worse, the trigger is likely macOS
     session wake, window server, network, or helper state rather than tab switching alone.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --suspend-seconds)
      SUSPEND_SECONDS="${2:-}"
      shift 2
      ;;
    --ui-seconds)
      UI_SECONDS="${2:-}"
      shift 2
      ;;
    --ui-interval)
      UI_INTERVAL="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ "$MODE" == "suspend" || "$MODE" == "lock-screen" || "$MODE" == "real-sleep" ]] || fail "--mode must be suspend, lock-screen, or real-sleep."
[[ -x "$ROOT_DIR/scripts/stress-ui-tabs.sh" ]] || fail "missing executable scripts/stress-ui-tabs.sh"
command -v pgrep >/dev/null || fail "pgrep is required."

PID="$(pgrep -x "$PROCESS_NAME" | head -n 1 || true)"
if [[ -z "$PID" ]]; then
  PID="$(pgrep -f "/${PROCESS_NAME}$|/${PROCESS_NAME} " | head -n 1 || true)"
fi
[[ -n "$PID" ]] || fail "$PROCESS_NAME is not running. Start EasyTier GUI first."

mkdir -p "$OUT_DIR"

echo "EasyTier wake-lag repro"
echo "  mode:      $MODE"
echo "  pid:       $PID"
echo "  suspend:   ${SUSPEND_SECONDS}s"
echo "  ui:        ${UI_SECONDS}s @ ${UI_INTERVAL}s"
echo "  output:    $OUT_DIR"

ps -o pid,ppid,pcpu,pmem,rss,etime,state,command -p "$PID" >"$OUT_DIR/ps-before-resume.txt" 2>/dev/null || true

is_screen_locked() {
  ioreg -r -d 1 -k CGSSessionScreenIsLocked 2>/dev/null | grep -q '"CGSSessionScreenIsLocked" = Yes'
}

wait_for_unlock() {
  local wait_limit="${EASYTIER_LOCK_WAIT_SECONDS:-600}"
  local waited=0

  while is_screen_locked; do
    if (( waited == 0 )); then
      echo "Screen is locked. Unlock this Mac; the script will continue automatically."
    fi
    if (( waited >= wait_limit )); then
      fail "screen stayed locked for ${wait_limit}s; unlock and rerun the script."
    fi
    sleep 2
    waited=$((waited + 2))
  done
}

if [[ "$MODE" == "suspend" ]]; then
  echo
  echo "Suspending $PROCESS_NAME with SIGSTOP..."
  kill -STOP "$PID"
  sleep "$SUSPEND_SECONDS"
  echo "Resuming $PROCESS_NAME with SIGCONT..."
  kill -CONT "$PID"
elif [[ "$MODE" == "lock-screen" ]]; then
  echo
  echo "Locking the current macOS session with Control-Command-Q."
  echo "Wait at least ${SUSPEND_SECONDS}s, then unlock manually. The script will continue after unlock."
  osascript -e 'tell application "System Events" to keystroke "q" using {control down, command down}'
  sleep "$SUSPEND_SECONDS"
  wait_for_unlock
else
  command -v pmset >/dev/null || fail "pmset is required for --mode real-sleep."
  WAKE_TIME="$(date -v+"${SUSPEND_SECONDS}"S "+%m/%d/%y %H:%M:%S")"

  echo
  echo "Attempting to schedule wake at $WAKE_TIME, then sleep now."
  echo "If macOS does not wake automatically, wake it manually after about ${SUSPEND_SECONDS}s."
  pmset schedule wakeorpoweron "$WAKE_TIME" >"$OUT_DIR/pmset-schedule.txt" 2>"$OUT_DIR/pmset-schedule-error.txt" || true
  pmset sleepnow
fi

echo
echo "Post-resume settle..."
sleep 3
ps -o pid,ppid,pcpu,pmem,rss,etime,state,command -p "$PID" >"$OUT_DIR/ps-after-resume.txt" 2>/dev/null || true

echo
echo "Running post-resume UI stress..."
EASYTIER_UI_STRESS_OUT_DIR="$OUT_DIR/ui-stress" "$ROOT_DIR/scripts/stress-ui-tabs.sh" "$UI_SECONDS" "$UI_INTERVAL"

echo
echo "Resume CPU/RSS before:"
cat "$OUT_DIR/ps-before-resume.txt" || true
echo
echo "Resume CPU/RSS after:"
cat "$OUT_DIR/ps-after-resume.txt" || true
echo
echo "Wake repro output: $OUT_DIR"
