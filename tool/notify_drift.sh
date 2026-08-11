#!/usr/bin/env bash
#
# Sends a notification when the nightly DAP drift check flags a regression.
# Reads the JSON report written by `tool/check_drift.py --report`.
#
# Notification channels (both optional, independently enabled):
#   * Slack: posts to the webhook in SLACK_WEBHOOK_URL (skipped when unset).
#   * repository_dispatch: fires a `dap-load-drift` event to GITHUB_REPOSITORY
#     when DISPATCH=1 (a consuming workflow can e.g. open an issue).
#
# Env:
#   DRIFT_REPORT       path to the report JSON (default: drift-report.json)
#   SLACK_WEBHOOK_URL  Slack incoming-webhook URL (optional)
#   DISPATCH           "1" to fire a repository_dispatch (optional)
#   GITHUB_TOKEN       token for the dispatch API (provided by Actions)
#   GITHUB_REPOSITORY  owner/repo for the dispatch API (provided by Actions)
#   RUN_URL            link to the failing Actions run
#   HISTORY_URL        link to .ci/dap-load-history.csv
#
# Always exits 0: the drift flag itself is the failure signal (the check step
# exits 1); a notification hiccup must not add noise on top of it.

set -euo pipefail

REPORT="${DRIFT_REPORT:-drift-report.json}"
RUN_URL="${RUN_URL:-<run url>}"
HISTORY_URL="${HISTORY_URL:-<history url>}"

if [ ! -f "$REPORT" ]; then
  echo "notify_drift: no report at $REPORT; nothing to do."
  exit 0
fi

FLAGGED="$(python3 -c "import json; print('1' if json.load(open('$REPORT')).get('flagged') else '0')")"
if [ "$FLAGGED" != "1" ]; then
  echo "notify_drift: no drift flagged; nothing to do."
  exit 0
fi

echo "notify_drift: drift flagged; sending notifications."
DATE="$(date -u +%Y-%m-%d)"

# --- Slack -------------------------------------------------------------------
if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  PAYLOAD="$(python3 - "$REPORT" "$DATE" "$RUN_URL" "$HISTORY_URL" <<'PYEOF'
import json
import sys

report = json.load(open(sys.argv[1]))
date, run_url, history_url = sys.argv[2], sys.argv[3], sys.argv[4]
lines = [
    ":warning: DAP load-test drift flagged (nightly " + date + ")",
    "",
    "Median handshake ratio >= " + str(report["threshold"]) +
    " over " + str(report["window"]) + " run(s):",
]
lines.extend(report["summary"].splitlines())
lines.extend(["", "Run: " + run_url, "History: " + history_url])
sys.stdout.write(json.dumps({"text": "\n".join(lines)}))
PYEOF
)"
  echo "notify_drift: posting to Slack..."
  curl -fsS -X POST -H 'Content-Type: application/json' -d "$PAYLOAD" \
    "$SLACK_WEBHOOK_URL" || echo "notify_drift: Slack post failed (non-fatal)"
else
  echo "notify_drift: SLACK_WEBHOOK_URL not set; skipping Slack."
fi

# --- repository_dispatch -----------------------------------------------------
if [ "${DISPATCH:-0}" = "1" ]; then
  PAYLOAD="$(python3 - "$REPORT" "$DATE" "$RUN_URL" "$HISTORY_URL" <<'PYEOF'
import json
import sys

report = json.load(open(sys.argv[1]))
date, run_url, history_url = sys.argv[2], sys.argv[3], sys.argv[4]
payload = {
    "event_type": "dap-load-drift",
    "client_payload": {
        "date": date,
        "threshold": report["threshold"],
        "window": report["window"],
        "offenders": report["offenders"],
        "summary": report["summary"],
        "run_url": run_url,
        "history_url": history_url,
    },
}
sys.stdout.write(json.dumps(payload))
PYEOF
)"
  echo "notify_drift: firing repository_dispatch dap-load-drift..."
  curl -fsS -X POST \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY:-}/dispatches" \
    -d "$PAYLOAD" || echo "notify_drift: dispatch failed (non-fatal)"
else
  echo "notify_drift: DISPATCH != 1; skipping repository_dispatch."
fi

echo "notify_drift: done."
