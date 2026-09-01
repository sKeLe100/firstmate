#!/usr/bin/env bash
# bin/fm-retry-pressure.sh - report a task's retry-loop pressure from durable
# records, as a data-only sibling of bin/fm-context-usage.sh.
#
# Why: the context-threshold mechanism senses context SIZE only. The
# session-retry-failsafe-design scout (data/session-retry-failsafe-design/
# report.md, 2026-09-01) showed a repetition-driven failure mode it cannot
# catch: repeated relaunches, review-gate rounds, and fix no-ops that each pay
# a full cold context reload before the size band ever fires. This helper
# counts that repetition so supervision can act proactively; it reads and
# reports only, and never relaunches, holds, or steers anything itself.
#
# Usage: fm-retry-pressure.sh <task-id>
#   Reads, under FM_HOME (default: current directory), honoring the same
#   FM_STATE_OVERRIDE and FM_DATA_OVERRIDE directory overrides its writers use:
#   - data/llm-usage/firstmate.jsonl delegation events for this task_id since
#     its last landed/completed outcome event (relaunch count),
#   - state/<task-id>.status keyed retry-loop reports, when the status file
#     exists: the `[key=retry-loop]` decision counts only while the shared fold
#     in bin/fm-classify-lib.sh still reads it open, under either opening verb
#     that fold recognizes (`blocked` or `needs-decision`), so a later resolving
#     or captain-held line closes it exactly as it does for every other reader
#     of the status protocol.
#
#   A redispatch filed under a NEW task id is intentionally not counted toward
#   this task's relaunch ceiling; that chain's evidence lives in the telemetry's
#   from_task_id field (docs/llm-usage-telemetry.md), not here.
#
# Output is one data-only line; callers act on the band, not the raw counts:
#   relaunches=<N> retry_loop_reported=<0|1> \
#     relaunch_ceiling=<K> round_ceiling=<R> retry_band=<ok|loop|halt> task=<id>
#
# The round ceiling is the worker's own self-check ceiling from standing rule 9
# of bin/fm-brief.sh, reported here so callers read one source for it; this
# helper does not count rounds itself, because the protocol has workers emit a
# single keyed line at the threshold rather than per-round progress lines.
#
# Bands:
#   ok   - counts below every ceiling; nothing to do.
#   loop - the worker reported a `[key=retry-loop]` decision itself and it is
#          still open (`blocked` or `needs-decision`); the next restart must
#          change a variable (approach, runtime, or authority), not just
#          relaunch.
#   halt - relaunch count at/past the relaunch ceiling with no landed outcome;
#          stop relaunching and hold the task for the captain.
#
# Ceilings come from optional config/retry-thresholds under FM_HOME, the
# sibling of config/context-thresholds documented in docs/configuration.md
# "Retry-loop thresholds": at most one `relaunch=<K>` line and one `rounds=<R>`
# line, each a positive base-10 integer. Absent file or key means the built-in
# defaults relaunch=3 and rounds=4. A malformed file is rejected loudly rather
# than silently replaced by defaults.
#
# Missing telemetry or a missing status file is zero evidence, not an error:
# the counts it would feed are reported as 0 so a fresh home reads ok.
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

[ $# -eq 1 ] || { echo "usage: fm-retry-pressure.sh <task-id>" >&2; exit 1; }
task="$1"
home="${FM_HOME:-$PWD}"
state_dir="${FM_STATE_OVERRIDE:-$home/state}"
data_dir="${FM_DATA_OVERRIDE:-$home/data}"

relaunch_ceiling=3
round_ceiling=4
cfg="$home/config/retry-thresholds"
if [ -e "$cfg" ]; then
  [ -f "$cfg" ] || { echo "fm-retry-pressure: $cfg is not a regular file" >&2; exit 1; }
  [ -r "$cfg" ] || { echo "fm-retry-pressure: unreadable $cfg" >&2; exit 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) ;;
      relaunch=*)
        v="${line#relaunch=}"
        case "$v" in ''|*[!0-9]*|0*[0-9]) echo "fm-retry-pressure: malformed relaunch= in $cfg" >&2; exit 1;; esac
        [ "$v" -ge 1 ] || { echo "fm-retry-pressure: relaunch= must be >= 1 in $cfg" >&2; exit 1; }
        relaunch_ceiling="$v" ;;
      rounds=*)
        v="${line#rounds=}"
        case "$v" in ''|*[!0-9]*|0*[0-9]) echo "fm-retry-pressure: malformed rounds= in $cfg" >&2; exit 1;; esac
        [ "$v" -ge 1 ] || { echo "fm-retry-pressure: rounds= must be >= 1 in $cfg" >&2; exit 1; }
        round_ceiling="$v" ;;
      *) echo "fm-retry-pressure: unrecognized line in $cfg: $line" >&2; exit 1 ;;
    esac
  done < "$cfg"
fi

# Relaunches since the last landed outcome, from the delegation telemetry.
relaunches=0
telemetry="$data_dir/llm-usage/firstmate.jsonl"
if [ -r "$telemetry" ]; then
  relaunches=$(TASK="$task" python3 - "$telemetry" <<'PY'
import json, os, sys
task = os.environ["TASK"]
count = 0
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except ValueError:
        continue
    if not isinstance(row, dict):
        continue
    if row.get("task_id") != task:
        continue
    if row.get("event_type") == "outcome" and row.get("result") in ("landed", "completed"):
        count = 0
    elif row.get("event_type") == "delegation" and row.get("trigger") == "relaunch":
        count += 1
print(count)
PY
  )
fi

# Worker-reported loops, decided by the shared status-key fold in
# bin/fm-classify-lib.sh so this helper cannot disagree with every other reader.
retry_loop_reported=0
status_file="$state_dir/$task.status"
case "$(status_key_closing_verb "$status_file" retry-loop)" in
  blocked|needs-decision) retry_loop_reported=1 ;;
esac

band=ok
if [ "$retry_loop_reported" -eq 1 ]; then
  band=loop
fi
if [ "$relaunches" -ge "$relaunch_ceiling" ]; then
  band=halt
fi

printf 'relaunches=%s retry_loop_reported=%s relaunch_ceiling=%s round_ceiling=%s retry_band=%s task=%s\n' \
  "$relaunches" "$retry_loop_reported" "$relaunch_ceiling" "$round_ceiling" "$band" "$task"
