#!/usr/bin/env python3
"""Flags drift in the DAP load-test margin history (`.ci/dap-load-history.csv`).

For each (os, adapter) group, computes the median `ratio` over the most recent
DRIFT_WINDOW rows (rows are appended chronologically). If any median is >=
DRIFT_RATIO, prints the offenders and exits 1 so the nightly run is flagged
before the trend crosses the merge-gating threshold.

Usage:
  python3 tool/check_drift.py [history.csv] [--report report.json]

With --report, writes a JSON summary (flagged, threshold, window, offenders,
summary text) that tool/notify_drift.sh uses to build notifications.

Env overrides:
  DRIFT_WINDOW  number of most-recent rows per (os, adapter) (default: 7)
  DRIFT_RATIO   median ratio threshold that flags drift (default: 0.35)
"""

import csv
import json
import os
import statistics
import sys


def main() -> int:
    args = sys.argv[1:]
    path = ".ci/dap-load-history.csv"
    report_path: str | None = None
    if args and not args[0].startswith("--"):
        path = args[0]
        args = args[1:]
    index = 0
    while index < len(args):
        if args[index] == "--report" and index + 1 < len(args):
            report_path = args[index + 1]
            index += 2
        else:
            index += 1

    window = int(os.environ.get("DRIFT_WINDOW", "7"))
    threshold = float(os.environ.get("DRIFT_RATIO", "0.35"))

    groups: dict[tuple[str, str], list[float]] = {}
    with open(path, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            try:
                ratio = float(row["ratio"])
            except (KeyError, ValueError):
                continue
            groups.setdefault((row["os"], row["adapter"]), []).append(ratio)

    if not groups:
        print("DRIFT: no margin rows found; nothing to check.")
        if report_path:
            _write_report(report_path, flagged=False, threshold=threshold,
                          window=window, offenders=[])
        return 0

    print(
        f"==> Drift check (window {window} run(s), median ratio threshold {threshold}):"
    )
    offenders: list[tuple[str, str, float, int]] = []
    for (os_name, adapter), ratios in sorted(groups.items()):
        sample = ratios[-window:]
        median = statistics.median(sample)
        flag = "DRIFT" if median >= threshold else "ok"
        print(
            f"  {os_name:<16} {adapter:<10} "
            f"median({len(sample)} run(s))={median:.2f} {flag}"
        )
        if median >= threshold:
            offenders.append((os_name, adapter, median, len(sample)))

    if report_path:
        _write_report(report_path, flagged=bool(offenders),
                      threshold=threshold, window=window, offenders=offenders)

    if offenders:
        detail = ", ".join(
            f"{os_name}/{adapter}={median:.2f} over {count} run(s)"
            for os_name, adapter, median, count in offenders
        )
        print(
            f"DRIFT: median handshake ratio above {threshold} - {detail}. "
            "Investigate before the merge gate (HANDSHAKE_FAIL_RATIO) starts "
            "blocking PRs."
        )
        return 1

    print("DRIFT: OK")
    return 0


def _write_report(
    report_path: str,
    *,
    flagged: bool,
    threshold: float,
    window: int,
    offenders: list[tuple[str, str, float, int]],
) -> None:
    summary = "\n".join(
        f"{os_name}/{adapter}={median:.2f} (over {count} run(s))"
        for os_name, adapter, median, count in offenders
    )
    report = {
        "flagged": flagged,
        "threshold": threshold,
        "window": window,
        "offenders": [
            {"os": os_name, "adapter": adapter, "median": median,
             "runs": count}
            for os_name, adapter, median, count in offenders
        ],
        "summary": summary,
    }
    with open(report_path, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2)


if __name__ == "__main__":
    sys.exit(main())
