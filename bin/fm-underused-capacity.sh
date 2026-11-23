#!/usr/bin/env bash
# fm-underused-capacity.sh - report spend lanes that have quota headroom while
# dispatchable work waits.
#
# Why: the heartbeat review already refills idle capacity from
# bin/fm-queue-snapshot.sh, but nothing compared the per-account quota windows
# with the standing order to keep an account's workers filled. A fleet could sit
# nearly idle beside an eligible queue while one account's five-hour window held
# headroom, and only the captain noticed. This script is that comparison made
# deterministic and read-only.
#
# It reads three existing owners and adds no fleet-state reader of its own:
#   - bin/fm-resource-snapshot.sh --json for each spend lane's quota windows
#     (the five-hour window and the weekly window), each reading's state, and
#     the live workers already on that lane.
#   - bin/fm-queue-snapshot.sh's `dispatchable:` count for the work waiting.
#   - bin/fm-capacity.sh's first `capacity:` line for the pool's free slots.
#     `config/lane-capacity` is the cap owner; no target means the pool is
#     uncapped, which counts as free slots.
#
# A lane is reported only when ALL of these hold:
#   1. its five-hour window (window `five_hour`, else the `rolling` window
#      opencode-go publishes) has a fresh reading at or above the threshold;
#   2. its weekly window (window `seven_day`, `weekly`, or `window:<h>h` with
#      at least 168 hours) is not behind pace - a missing weekly window is not
#      treated as behind;
#   3. the pool has a free slot (or no configured cap);
#   4. the queue has at least one dispatchable item.
#
# One line per qualifying lane:
#   idle capacity: <lane> <pct>%, <n> free slots, <m> dispatchable, live=<k>
# `<n>` is `uncapped` when no lane cap is configured. `<k>` is the lane's
# current live worker count from the same snapshot.
# Exit 0 with no output when nothing is idle, as well as when idle capacity is
# found. Exit 1 when a required source cannot be read (so "nothing idle" is
# never claimed from a broken read), and 2 on a usage error or a malformed
# threshold.
#
# This script only reports; it never dispatches, spawns, steers, writes under
# state/, data/, config/, or projects/, and never refreshes quota credentials.
#
# Usage:
#   fm-underused-capacity.sh [--threshold <pct>]
#                            [--resource-json <file>]
#                            [--queue-output <file>]
#                            [--capacity-line <text>]
#   -h, --help               this header
#
# --threshold is a whole percentage 0-100 (default 50). Precedence: flag, then
# FM_UNDERUSED_FIVE_HOUR_MIN, then config/underused-capacity-threshold, then 50.
# The config file holds one integer and optional surrounding whitespace, the
# config/lane-capacity idiom; a malformed file is a usage error, never a silent
# default.
#
# Fixture seams, for tests and deterministic replay:
#   FM_UNDERUSED_RESOURCE_FIXTURE  file holding the fm-resource-snapshot --json model
#   FM_UNDERUSED_QUEUE_FIXTURE     file holding fm-queue-snapshot output
#   FM_UNDERUSED_CAPACITY_FIXTURE  file holding fm-capacity.sh output
#   FM_UNDERUSED_FIVE_HOUR_MIN     threshold override (see above)
# The matching flags win over the environment.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

DEFAULT_THRESHOLD=50

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die_usage() {
  echo "fm-underused-capacity: $*" >&2
  exit 2
}

THRESHOLD=""
RESOURCE_JSON=""
QUEUE_OUTPUT=""
CAPACITY_LINE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --threshold)
      [ "$#" -ge 2 ] || die_usage '--threshold needs a value'
      THRESHOLD=$2
      shift
      ;;
    --resource-json)
      [ "$#" -ge 2 ] || die_usage '--resource-json needs a file'
      RESOURCE_JSON=$2
      shift
      ;;
    --queue-output)
      [ "$#" -ge 2 ] || die_usage '--queue-output needs a file'
      QUEUE_OUTPUT=$2
      shift
      ;;
    --capacity-line)
      [ "$#" -ge 2 ] || die_usage '--capacity-line needs text'
      CAPACITY_LINE=$2
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done

if [ -z "$THRESHOLD" ]; then
  THRESHOLD=${FM_UNDERUSED_FIVE_HOUR_MIN:-}
fi
if [ -z "$THRESHOLD" ] && [ -f "$CONFIG/underused-capacity-threshold" ]; then
  THRESHOLD=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$CONFIG/underused-capacity-threshold" 2>/dev/null)
  case "$THRESHOLD" in
    ''|*[!0-9]*) die_usage "config/underused-capacity-threshold must hold one integer 0-100" ;;
  esac
fi
[ -n "$THRESHOLD" ] || THRESHOLD=$DEFAULT_THRESHOLD
case "$THRESHOLD" in
  ''|*[!0-9]*) die_usage "--threshold must be a whole number 0-100, got: $THRESHOLD" ;;
esac
if [ "$THRESHOLD" -gt 100 ]; then
  die_usage "--threshold must be 0-100, got: $THRESHOLD"
fi

command -v jq >/dev/null 2>&1 || {
  echo 'fm-underused-capacity: jq not found on PATH' >&2
  exit 1
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-underused-capacity.XXXXXX") || {
  echo 'fm-underused-capacity: cannot create temp directory' >&2
  exit 1
}
# shellcheck disable=SC2329 # invoked through the EXIT trap below
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -z "$RESOURCE_JSON" ]; then
  RESOURCE_JSON=${FM_UNDERUSED_RESOURCE_FIXTURE:-}
fi
if [ -z "$RESOURCE_JSON" ]; then
  RESOURCE_JSON=$TMP/resource.json
  if ! "$SCRIPT_DIR/fm-resource-snapshot.sh" --json > "$RESOURCE_JSON" 2> "$TMP/resource.err"; then
    echo "fm-underused-capacity: resource snapshot failed: $(cat "$TMP/resource.err")" >&2
    exit 1
  fi
fi
if ! jq -e '(.quota | type == "array") and (.workers | type == "array")' "$RESOURCE_JSON" >/dev/null 2>&1; then
  echo "fm-underused-capacity: resource snapshot is not a readable snapshot: $RESOURCE_JSON" >&2
  exit 1
fi

if [ -z "$QUEUE_OUTPUT" ]; then
  QUEUE_OUTPUT=${FM_UNDERUSED_QUEUE_FIXTURE:-}
fi
if [ -z "$QUEUE_OUTPUT" ]; then
  QUEUE_OUTPUT=$TMP/queue.txt
  if ! "$SCRIPT_DIR/fm-queue-snapshot.sh" > "$QUEUE_OUTPUT" 2> "$TMP/queue.err"; then
    echo "fm-underused-capacity: queue snapshot failed: $(cat "$TMP/queue.err")" >&2
    exit 1
  fi
fi
dispatchable=$(awk -F': ' '$1 == "dispatchable" { v = $2 } END { print v }' "$QUEUE_OUTPUT" 2>/dev/null)
case "$dispatchable" in
  ''|*[!0-9]*)
    echo "fm-underused-capacity: queue snapshot printed no dispatchable count: $QUEUE_OUTPUT" >&2
    exit 1
    ;;
esac
[ "$dispatchable" -gt 0 ] || exit 0

if [ -z "$CAPACITY_LINE" ]; then
  if [ -n "${FM_UNDERUSED_CAPACITY_FIXTURE:-}" ]; then
    CAPACITY_LINE=$(grep -m1 '^capacity:' "$FM_UNDERUSED_CAPACITY_FIXTURE" 2>/dev/null) || CAPACITY_LINE=
  else
    if ! "$SCRIPT_DIR/fm-capacity.sh" > "$TMP/capacity.txt" 2> "$TMP/capacity.err"; then
      echo "fm-underused-capacity: capacity read failed: $(cat "$TMP/capacity.err")" >&2
      exit 1
    fi
    CAPACITY_LINE=$(grep -m1 '^capacity:' "$TMP/capacity.txt" 2>/dev/null) || CAPACITY_LINE=
  fi
fi
case "$CAPACITY_LINE" in
  capacity:*) ;;
  *)
    echo 'fm-underused-capacity: no capacity: line to read free slots from' >&2
    exit 1
    ;;
esac

free_lanes=$(printf '%s\n' "$CAPACITY_LINE" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^free_lanes=/) { sub(/^free_lanes=/, "", $i); print $i; exit } }')
capacity_reason=$(printf '%s\n' "$CAPACITY_LINE" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^reason=/) { sub(/^reason=/, "", $i); print $i; exit } }')
case "$free_lanes" in
  0) exit 0 ;;
  ''|*[!0-9]*)
    if [ "$capacity_reason" = no-target ]; then
      free_lanes=uncapped
    else
      echo "fm-underused-capacity: capacity read has no free slots verdict (free_lanes=${free_lanes:-?} reason=${capacity_reason:-?})" >&2
      exit 1
    fi
    ;;
esac

jq -r --argjson threshold "$THRESHOLD" '
  def rank($lane):
    if $lane == "claude#1" then 0
    elif $lane == "claude#2" then 1
    elif $lane == "opencode-go" then 2
    elif $lane == "codex" then 3
    else 4 end;
  def weekly_window:
    if .window == "seven_day" or .window == "weekly" then true
    elif ((.window // "") | test("^window:[0-9]+h$")) then
      ((.window | capture("^window:(?<h>[0-9]+)h$").h | tonumber) >= 168)
    else false end;
  def short_window:
    .window == "five_hour" or .window == "rolling";
  . as $root
  | [ $root.quota[] | select(.state == "fresh") ] as $fresh
  | [ $fresh[].lane ] | unique
  | map(. as $lane
      | ([ $fresh[] | select(.lane == $lane and short_window)
           | select((.pct_remaining // "") | tostring | test("^[0-9]+(\\.[0-9]+)?$"))
         ] | first) as $short
      | ([ $fresh[] | select(.lane == $lane and weekly_window) ] | first) as $week
      | select($short != null)
      | ($short.pct_remaining | tonumber) as $pct
      | select($pct >= $threshold)
      | select($week == null or ((($week.pace // "-") | ascii_downcase) | contains("behind") | not))
      | ([ $root.workers[] | select(.spend_lane == $lane)
           | select(((.stage // "") == "done" or (.stage // "") == "failed") | not)
         ] | length) as $live
      | [$lane, ($pct | tostring), ($live | tostring)])
  | sort_by(rank(.[0]), .[0])
  | .[]
  | @tsv
' "$RESOURCE_JSON" > "$TMP/lanes.tsv" 2> "$TMP/lanes.err" || {
  echo "fm-underused-capacity: could not evaluate quota windows: $(cat "$TMP/lanes.err")" >&2
  exit 1
}
while IFS=$'\t' read -r lane pct live; do
  [ -n "$lane" ] || continue
  printf 'idle capacity: %s %s%%, %s free slots, %s dispatchable, live=%s\n' \
    "$lane" "$pct" "$free_lanes" "$dispatchable" "$live"
done < "$TMP/lanes.tsv"

exit 0
