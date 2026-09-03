#!/usr/bin/env bash
# fm-autonomous-thresholds.sh - evaluate the autonomous dispatch nudge
# thresholds for the /autonomous skill.
#
# Reads a JSON array of decision rows from stdin (or from --input <file>)
# and prints whether the bundle-size or time threshold fires.
#
# Each decision row carries:
#   id, key, verb, summary, owner, declared_priority
#   created_at  (optional, epoch seconds; rows without it are excluded
#                from the age computation, so they never fire the time
#                threshold)
#
# Exit codes:
#   0 - nudge needed (one or both thresholds met), prints one line:
#       nudge: <threshold_name>  (bundle-size, time, or both)
#   1 - no nudge needed
#   2 - usage error or invalid input
#
# Usage: fm-autonomous-thresholds.sh [--input <file>]
#
# Input is a JSON array.  Output is a single line to stdout or "none".
#
# Bundle-size threshold: >= 5 chat-rulable decisions.
# Time threshold: oldest pending decision >= 48h old.
# Both thresholds are per the captain's 2026-09-01 ruling (Q3).
#
# Chat-rulable = every open captain hold (verb == "captain-hold").
# fm-bearings-snapshot.sh's decisions_open carries no structured
# blocked-on category, and free-text heuristics over the summary both
# over- and under-match, silently dropping genuine open questions. Per
# AGENTS.md section 10's decision-is-simply-a-held-task model, every
# captain hold counts rather than being filtered by prose.
#
# The same chat-rulable subset feeds both thresholds: the bundle-size
# count and the oldest-row age used by the time threshold.

set -u

INPUT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --input)
      [ $# -ge 2 ] || { echo "fm-autonomous-thresholds.sh: --input requires a value" >&2; exit 2; }
      INPUT_FILE="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: fm-autonomous-thresholds.sh [--input <file>]" >&2
      exit 0
      ;;
    *)
      echo "fm-autonomous-thresholds.sh: unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# Read input: from file or stdin
if [ -n "$INPUT_FILE" ]; then
  INPUT=$(cat "$INPUT_FILE") || { echo "fm-autonomous-thresholds.sh: cannot read input file: $INPUT_FILE" >&2; exit 2; }
else
  INPUT=$(cat)
fi

# Validate: must be a JSON array
echo "$INPUT" | jq -e 'type == "array"' >/dev/null 2>&1 || { echo "fm-autonomous-thresholds.sh: input must be a JSON array" >&2; exit 2; }

# Select the chat-rulable subset once; both thresholds read from it.
CHAT_RULABLE_ROWS=$(echo "$INPUT" | jq -c '
  [ .[] | select(.verb == "captain-hold") ]
')

CHAT_RULABLE=$(echo "$CHAT_RULABLE_ROWS" | jq 'length')

# Time threshold: oldest chat-rulable decision >= 48h old.
# Rows without created_at are excluded from the age computation.
OLDEST_AGE_SECONDS=$(echo "$CHAT_RULABLE_ROWS" | jq '
  [ .[] | .created_at // null ]
  | map(select(. != null))
  | if length == 0 then null
    else
      ([ .[] | now - . ] | max | floor)
    end
')

# Compare against thresholds
BUNDLE_THRESHOLD=5
TIME_THRESHOLD=172800  # 48 hours in seconds

THRESHOLDS_MET=""

if [ "$CHAT_RULABLE" -ge "$BUNDLE_THRESHOLD" ]; then
  THRESHOLDS_MET="bundle-size"
fi

if [ "$OLDEST_AGE_SECONDS" != "null" ] && [ "$(echo "$OLDEST_AGE_SECONDS" | jq 'floor')" -ge "$TIME_THRESHOLD" ]; then
  if [ -n "$THRESHOLDS_MET" ]; then
    THRESHOLDS_MET="both"
  else
    THRESHOLDS_MET="time"
  fi
fi

if [ -n "$THRESHOLDS_MET" ]; then
  echo "nudge: $THRESHOLDS_MET"
  exit 0
else
  echo "none"
  exit 1
fi
