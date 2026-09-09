#!/usr/bin/env bash
# fm-routing-ledger-metrics.sh - reconciles data/routing-ledger.tsv (written
# only by bin/fm-backlog-routing.sh's set/escalate/gc commands) into the
# rebalance metrics the durable refill design's step 8 needs (report
# "Migration order" > "Rebalance daily"):
# opened, closed, reopened, gross/day, net/day, median cycle time.
#
# Scope note: this reconciles ROUTING lifecycle events only - a row entering
# the pc02/medium/senior registry ("classified"), moving up a tier
# ("escalated"), or leaving the registry on close ("closed"). It is not the
# full backlog inflow/drain ledger the report's separate
# `queue-inflow-drain-ledger` backlog item covers; that item's ledger, once
# it exists, is a different data source with a different meaning ("opened"
# there means "entered the backlog", not "entered PC02 routing").
#
# PC02 idle percentage is reported only when an occupancy-samples file is
# supplied (--occupancy <file>, lines of "<epoch> free|occupied"): this
# script has no other durable record of lane occupancy over time and
# reports "pc02_idle_pct: unavailable" rather than fabricate one, matching
# this codebase's fail-closed-on-unmeasurable convention (see
# bin/fm-queue-snapshot.sh's own "unknown" availability verdicts).
#
# Usage: fm-routing-ledger-metrics.sh [--since <epoch>] [--occupancy <file>]
#
# Output (stable field order, one "key: value" line each):
#   opened: <n>          count of ids that entered the registry (an id's
#                        FIRST classified event; re-writing an open row to
#                        correct its purpose/risk never counts again)
#   closed: <n>          count of "closed" events
#   reopened: <n>        count of "classified" events for an id that was
#                        already closed earlier in the ledger (re-entered
#                        the registry after leaving it)
#   escalated: <n>       count of "escalated" events, for visibility only
#   gross_per_day: <f>   closed / observed-window-days (2 decimal places),
#                        or "unavailable" when the window holds no events
#   net_per_day: <f>     (closed - opened) / observed-window-days, or
#                        "unavailable" when the window holds no events
#   median_cycle_time_seconds: <n or "unavailable">
#     median of (closed_epoch - first_classified_epoch) over ids that have
#     both a classified and a later closed event; "unavailable" when no id
#     has both.
#   pc02_idle_pct: <n or "unavailable">
#     percentage of samples in --occupancy reading "free"; "unavailable"
#     without --occupancy.
#
# Reads the whole ledger unless --since <epoch> is given, in which case only
# lines at or after that epoch are reconciled (the observed window for the
# per-day rates is then "now - since" seconds; without --since, the window
# is "now - earliest ledger line").
#
# Exit codes: 0 on success (including an absent/empty ledger, reported as
# all-zero counts and "unavailable" rates), 2 on a usage error - including a
# non-integer --since or an --occupancy path that does not exist, which are
# refused with a diagnostic rather than silently reported as "unavailable".
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
LEDGER="${FM_ROUTING_LEDGER_OVERRIDE:-$FM_HOME/data/routing-ledger.tsv}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

SINCE=""
OCCUPANCY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since)
      SINCE="${2:?--since needs a value}"
      case "$SINCE" in
        ''|*[!0-9]*)
          echo "fm-routing-ledger-metrics: --since needs an epoch-seconds integer, got: $SINCE" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    --occupancy)
      OCCUPANCY="${2:?--occupancy needs a value}"
      if [ ! -f "$OCCUPANCY" ]; then
        echo "fm-routing-ledger-metrics: --occupancy file does not exist: $OCCUPANCY" >&2
        exit 2
      fi
      shift 2
      ;;
    *)
      echo "fm-routing-ledger-metrics: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

FM_METRICS_LEDGER="$LEDGER" \
FM_METRICS_SINCE="$SINCE" \
FM_METRICS_OCCUPANCY="$OCCUPANCY" \
python3 <<'PY'
import os
import statistics
import time

ledger = os.environ["FM_METRICS_LEDGER"]
since = os.environ.get("FM_METRICS_SINCE") or ""
occupancy = os.environ.get("FM_METRICS_OCCUPANCY") or ""

since_epoch = int(since) if since else None

events = []
if os.path.isfile(ledger):
    with open(ledger, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            epoch_s, event, item_id = parts[0], parts[1], parts[2]
            try:
                epoch = int(epoch_s)
            except ValueError:
                continue
            if since_epoch is not None and epoch < since_epoch:
                continue
            events.append((epoch, event, item_id))

events.sort(key=lambda e: e[0])

closed = 0
reopened = 0
escalated = 0
ever_closed = set()
first_classified = {}
cycle_times = []

for epoch, event, item_id in events:
    if event == "classified":
        if item_id in ever_closed:
            reopened += 1
        if item_id not in first_classified:
            first_classified[item_id] = epoch
    elif event == "escalated":
        escalated += 1
    elif event == "closed":
        closed += 1
        if item_id in first_classified:
            cycle_times.append(epoch - first_classified[item_id])
        ever_closed.add(item_id)

now = int(time.time())
if events:
    window_start = since_epoch if since_epoch is not None else events[0][0]
else:
    window_start = since_epoch if since_epoch is not None else now
window_seconds = max(now - window_start, 1)
window_days = window_seconds / 86400.0

opened = len(first_classified)
if events:
    gross_per_day = f"{closed / window_days:.2f}"
    net_per_day = f"{(closed - opened) / window_days:.2f}"
else:
    gross_per_day = "unavailable"
    net_per_day = "unavailable"

median_cycle = "unavailable"
if cycle_times:
    median_cycle = int(statistics.median(cycle_times))

pc02_idle_pct = "unavailable"
if occupancy:
    total = 0
    free = 0
    with open(occupancy, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            fields = line.split()
            if len(fields) < 2:
                continue
            state = fields[1]
            total += 1
            if state == "free":
                free += 1
    if total:
        pc02_idle_pct = round((free / total) * 100, 1)

print(f"opened: {opened}")
print(f"closed: {closed}")
print(f"reopened: {reopened}")
print(f"escalated: {escalated}")
print(f"gross_per_day: {gross_per_day}")
print(f"net_per_day: {net_per_day}")
print(f"median_cycle_time_seconds: {median_cycle}")
print(f"pc02_idle_pct: {pc02_idle_pct}")
PY
