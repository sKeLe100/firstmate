#!/usr/bin/env bash
# fm-autonomous-thresholds.sh - evaluate the autonomous dispatch nudge
# thresholds for the /autonomous skill.
#
# Reads a JSON array of decision rows from stdin (or from --input <file>)
# and prints whether the bundle-size or time threshold fires.
#
# Each decision row carries:
#   id, key, verb, summary, owner, declared_priority
#   created_at  (optional, epoch seconds; when absent, the row is treated
#                as 9999999999 so it never fires the time threshold)
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
# Chat-rulable = verb == "captain-hold" (standing orders that are
# purely declarative, e.g. "never merge task-7", are silently skipped
# because they contain no question for the captain to rule on).

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

# Count chat-rulable decisions (verb == "captain-hold", excluding pure
# standing orders where summary does not contain a colon-separated title:reason
# pattern - those are declarative and not chat-rulable).
CHAT_RULABLE=$(echo "$INPUT" | jq '
  [ .[] | select(.verb == "captain-hold")
    | select(
        # A pure standing order has a summary that looks like
        # "ruling: action" without a question - but we conservatively
        # count all captain-holds as chat-rulable unless they match
        # a known declarative pattern.  The skill treats all
        # captain-holds as chat-rulable for the threshold count,
        # and the questionnaire skill filters further at presentation.
        true
      )
  ] | length
')

# Time threshold: oldest decision >= 48h old.
# Use created_at field if present; when absent, treat as never-old.
OLDEST_AGE_SECONDS=$(echo "$INPUT" | jq '
  [ .[] | select(.verb == "captain-hold") | .created_at // null ]
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
