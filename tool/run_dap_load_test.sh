#!/usr/bin/env bash
#
# Runs the DAP test suite while burning CPU in the background so that
# debugpy / js-debug cold starts are exercised under contention — the exact
# condition that produced the historical "Debug adapter stopped" flake.
# A failure here means a handshake timeout that would also bite real users on
# slow machines, so treat it as a release blocker.
#
# The tests emit one `HANDSHAKE <adapter> totalMs=.. timeoutMs=..` line per
# cold start; this script reports the observed margin so the CI log shows how
# close each adapter came to the timeout under this load level.
#
# Usage:
#   tool/run_dap_load_test.sh [workers]
#
# Env overrides:
#   WORKERS               number of CPU-burning isolates (default: cores - 1, capped by STRESS_CAP)
#   STRESS_CAP            max default workers on big machines (default: 4)
#   DAP_TIMEOUT           per-test timeout passed to `flutter test` (default: 5m)
#   FLUTTER_EXTRA         extra arguments for `flutter test`
#   HANDSHAKE_WARN_RATIO  warn when a handshake uses >= this fraction of the
#                         service timeout (default: 0.5)
#   HANDSHAKE_FAIL_RATIO  when set, exit non-zero if a handshake uses >= this
#                         fraction of the timeout even though the test passed
#                         (default: unset = never fail on margin alone)
#   MARGIN_CSV            when set, append one CSV row per adapter
#                         (timestamp,os,workers,adapter,totalMs,ratio)
#   MARGIN_OS             value for the `os` column (default: unknown)
#
# Exit code is 0 only if every DAP test passes under load (plus any
# HANDSHAKE_FAIL_RATIO margin check).

set -euo pipefail
cd "$(dirname "$0")/.."

WORKERS="${WORKERS:-}"
DAP_TIMEOUT="${DAP_TIMEOUT:-5m}"
STRESS_CAP="${STRESS_CAP:-4}"
WARN_RATIO="${HANDSHAKE_WARN_RATIO:-0.5}"
FAIL_RATIO="${HANDSHAKE_FAIL_RATIO:-}"

SENTINEL="$(mktemp -t cpu_stress.XXXXXXXX)"
# Git Bash's /tmp is an MSYS view; pass Dart a path it can resolve on Windows.
if command -v cygpath >/dev/null 2>&1; then
  SENTINEL="$(cygpath -w "$SENTINEL")"
fi
rm -f "$SENTINEL"
LOG_FILE="$(mktemp -t dap_load_log.XXXXXXXX)"
cleanup() {
  rm -f "$SENTINEL" "$LOG_FILE"
  kill "${STRESS_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT

if [ -z "$WORKERS" ]; then
  if command -v nproc >/dev/null 2>&1; then
    CORES="$(nproc)"
  else
    CORES="$(python -c 'import os; print(os.cpu_count() or 4)' 2>/dev/null || echo 4)"
  fi
  DEFAULT_WORKERS=$(( CORES > 1 ? CORES - 1 : 1 ))
  if [ "$DEFAULT_WORKERS" -gt "$STRESS_CAP" ]; then
    DEFAULT_WORKERS="$STRESS_CAP"
  fi
  WORKERS="$DEFAULT_WORKERS"
fi

echo "==> CPU stress: $WORKERS worker(s) while DAP tests run (timeout $DAP_TIMEOUT each)."
dart run tool/cpu_stress.dart "$WORKERS" --sentinel "$SENTINEL" >/dev/null 2>&1 &
STRESS_PID=$!

# Let the workers spin up so the tests start under full contention.
sleep 3

echo "==> Running: flutter test test/debug_adapter_service_test.dart --timeout $DAP_TIMEOUT --reporter expanded ${FLUTTER_EXTRA:-}"
set +e
# shellcheck disable=SC2086
flutter test test/debug_adapter_service_test.dart \
  --timeout "$DAP_TIMEOUT" --reporter expanded ${FLUTTER_EXTRA:-} 2>&1 | tee "$LOG_FILE"
RESULT=$?
set -e

# Cooperative shutdown: the stressor exits once the sentinel appears. Give it a
# few seconds, then hard-kill as a fallback (harmless if already gone).
touch "$SENTINEL"
for _ in 1 2 3 4 5; do
  if ! kill -0 "$STRESS_PID" 2>/dev/null; then
    break
  fi
  sleep 1
done
kill "$STRESS_PID" 2>/dev/null || true
rm -f "$SENTINEL"

# --- Handshake margin report ------------------------------------------------
# Parse lines like: HANDSHAKE python initializedMs=.. launchMs=.. totalMs=.. timeoutMs=..
echo "==> Handshake timing under load (cold-start margin vs the 30s service timeout):"
WORST_RATIO="0"
MARGIN_CSV="${MARGIN_CSV:-}"
MARGIN_OS="${MARGIN_OS:-unknown}"
CSV_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
while IFS= read -r line; do
  adapter="$(echo "$line" | awk '{print $2}')"
  total="$(echo "$line" | sed -n 's/.*totalMs=\([0-9]*\).*/\1/p')"
  timeout="$(echo "$line" | sed -n 's/.*timeoutMs=\([0-9]*\).*/\1/p')"
  if [ -z "$total" ] || [ -z "$timeout" ] || [ "$timeout" -eq 0 ]; then
    continue
  fi
  ratio=$(awk -v t="$total" -v m="$timeout" 'BEGIN { printf "%.2f", t / m }')
  seconds=$(awk -v t="$total" 'BEGIN { printf "%.1f", t / 1000 }')
  echo "  $adapter: ${seconds}s of ${timeout}ms timeout (${ratio} of budget)"
  if [ -n "$MARGIN_CSV" ]; then
    echo "$CSV_TS,$MARGIN_OS,$WORKERS,$adapter,$total,$ratio" >> "$MARGIN_CSV"
  fi
  if awk -v r="$ratio" -v w="$WORST_RATIO" 'BEGIN { exit !(r > w) }'; then
    WORST_RATIO="$ratio"
  fi
done < <(grep -E '^HANDSHAKE ' "$LOG_FILE" || true)

if [ "$RESULT" -ne 0 ]; then
  echo "==> DAP tests under load: FAIL (startup-timeout flake reproduced?)"
  exit "$RESULT"
fi

if awk -v r="$WORST_RATIO" -v w="$WARN_RATIO" 'BEGIN { exit !(r >= w) }'; then
  echo "==> WARNING: worst handshake used ${WORST_RATIO} of the timeout budget under this load."
  echo "    If this repeats, raise the default DAP timeout (DebugAdapterService) or lower WORKERS."
fi

if [ -n "$FAIL_RATIO" ] && awk -v r="$WORST_RATIO" -v f="$FAIL_RATIO" 'BEGIN { exit !(r >= f) }'; then
  echo "==> FAIL: handshake margin under the HANDSHAKE_FAIL_RATIO=$FAIL_RATIO threshold (worst ${WORST_RATIO})."
  exit 1
fi

echo "==> DAP tests under load: PASS"
exit 0
