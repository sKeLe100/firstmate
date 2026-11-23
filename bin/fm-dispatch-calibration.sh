#!/usr/bin/env bash
# bin/fm-dispatch-calibration.sh - read-only replay of firstmate's recorded
# dispatch decisions against the outcomes already in this home's LLM usage
# telemetry archive (docs/llm-usage-telemetry.md).
#
# Why: dispatch decisions were not recorded, so no router or rule engine could
# be re-scored from firstmate's own history (data/dispatch-router-options/
# report.md, 2026-11-22). This helper joins each `dispatch` record's optional
# `decision_record` (its confidence and the inputs it was made on) to the
# archive's own outcome signals, then reports how well confidence predicts the
# real result. It reads and prints only; it never writes, edits, or dispatches.
#
# Usage: fm-dispatch-calibration.sh [--archive <path>] [--json]
#   Reads <data-dir>/llm-usage/firstmate.jsonl, where <data-dir> is
#   FM_DATA_OVERRIDE when set, else <FM_HOME>/data (FM_HOME defaults to the
#   current directory), matching the archive's own writers. --archive points at
#   a specific file, which is also how tests drive a fixture.
#
# Outcome join (first match wins, per dispatched task):
#   1. an `outcome` event: result=landed is a success, result=abandoned a failure
#   2. a later `dispatch` whose from_task_id names this task: a redelegation, failure
#   3. a `delegation` event with had_issue=true for this task: a retry, failure
#   A task with none of these is unresolved and is excluded from the score.
#
# Output:
#   One summary line with the decision count, resolved and unresolved counts,
#   and the Brier score (mean of (confidence/100 - actual)^2, lower is better;
#   n/a when nothing is resolved), then a reliability table by 10-point
#   confidence band: n, mean confidence, observed success rate, and the
#   calibration gap in percentage points (positive means overconfident).
#   --json prints one JSON object instead.
#
# Absent decisions, unresolved outcomes, or an empty archive are reported as
# such rather than failing; only a missing or unreadable archive path is an
# error.
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,/^set -euo pipefail/{ /^set -euo pipefail/d; p; }' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

home="${FM_HOME:-$PWD}"
data_dir="${FM_DATA_OVERRIDE:-$home/data}"
archive="$data_dir/llm-usage/firstmate.jsonl"
json=0
while [ "$#" -gt 0 ]; do
  case "$1" in
  --archive)
    [ "$#" -ge 2 ] || { echo "fm-dispatch-calibration: --archive needs a path" >&2; exit 1; }
    archive=$2
    shift 2
    ;;
  --archive=*)
    archive=${1#--archive=}
    shift
    ;;
  --json)
    json=1
    shift
    ;;
  *)
    echo "fm-dispatch-calibration: unknown argument: $1" >&2
    exit 1
    ;;
  esac
done

command -v jq >/dev/null 2>&1 || {
  echo "fm-dispatch-calibration: jq is required" >&2
  exit 1
}
[ -n "$archive" ] || { echo "fm-dispatch-calibration: empty archive path" >&2; exit 1; }
[ -f "$archive" ] || { echo "fm-dispatch-calibration: archive not found: $archive" >&2; exit 1; }
[ -r "$archive" ] || { echo "fm-dispatch-calibration: archive is unreadable: $archive" >&2; exit 1; }

result=$(jq -s '
  def decision:
    .decision_record as $r
    | if ($r | type) == "string" then (try ($r | fromjson) catch null)
      elif ($r | type) == "object" then $r
      else null end;
  def band($c): if $c >= 90 then 90 else (($c / 10 | floor) * 10) end;
  def band_label($b): if $b >= 90 then "90-100" else "\($b)-\($b + 9)" end;
  . as $all
  | (reduce ($all[] | select(.event_type == "outcome" and (.task_id | type) == "string")) as $o
      ({}; .[$o.task_id] = $o.result)) as $outcomes
  | ([ $all[]
       | select(.event_type == "dispatch" and (.from_task_id | type) == "string" and (.from_task_id | length) > 0)
       | .from_task_id ] | unique) as $redelegated
  | ([ $all[]
       | select(.event_type == "delegation" and .had_issue == "true" and (.task_id | type) == "string")
       | .task_id ] | unique) as $issue_tasks
  | [ $all[]
      | select(.event_type == "dispatch")
      | (decision) as $d
      | select($d != null and ($d | type) == "object" and ($d.confidence | type) == "number")
      | .task_id as $tid
      | (if $outcomes[$tid] == "landed" then 1
         elif $outcomes[$tid] == "abandoned" then 0
         elif ($redelegated | index($tid)) != null then 0
         elif ($issue_tasks | index($tid)) != null then 0
         else null end) as $actual
      | { task_id: $tid, ts: .ts, confidence: $d.confidence, band: band($d.confidence), actual: $actual }
    ] as $rows
  | ($rows | map(select(.actual != null))) as $resolved
  | [ range(0; 100; 10) as $b
      | ($resolved | map(select(.band == $b))) as $g
      | select(($g | length) > 0)
      | (($g | map(.confidence) | add) / ($g | length)) as $mean
      | (($g | map(.actual) | add) / ($g | length) * 100) as $observed
      | { band: band_label($b), n: ($g | length), mean_confidence: $mean,
          observed: $observed, gap: ($mean - $observed) }
    ] as $bands
  | { decisions: ($rows | length),
      resolved: ($resolved | length),
      unresolved: (($rows | length) - ($resolved | length)),
      brier: (if ($resolved | length) > 0
              then (($resolved | map(((.confidence / 100) - .actual) as $e | $e * $e) | add) / ($resolved | length))
              else null end),
      bands: $bands }
' "$archive") || {
  echo "fm-dispatch-calibration: failed to read archive: $archive" >&2
  exit 1
}

if [ "$json" -eq 1 ]; then
  printf '%s\n' "$result"
  exit 0
fi

printf 'fm-dispatch-calibration: %s\n' "$archive"
printf '%s\n' "$result" | jq -r '
  "decisions=\(.decisions) resolved=\(.resolved) unresolved=\(.unresolved) brier=\(if .brier == null then "n/a" else ((.brier * 10000 | round) / 10000 | tostring) end)",
  (if (.bands | length) == 0 then
     "no resolved decision records yet"
   else
     ("band\tn\tmean_conf\tobserved\tgap_pp",
      (.bands[] | "\(.band)\t\(.n)\t\(((.mean_confidence * 100 | round) / 100))\t\(((.observed * 100 | round) / 100))\t\(((.gap * 100 | round) / 100))"))
   end)
'
