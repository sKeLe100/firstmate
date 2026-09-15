#!/usr/bin/env bash
# fm-ledger-summary.sh - reports backlog transition counts from
# data/backlog-ledger.tsv, optionally filtered by time window.
#
# Usage:
#   fm-ledger-summary.sh [--since <epoch>] [--until <epoch>]
#
# Options:
#   --since <epoch>  only count events at or after this unix epoch
#   --until <epoch>  only count events before this unix epoch
#   When neither is given, reports all ledger entries.
#
# Output (one "key: value" line each, event order is added/started/done/closed):
#   added: <n>
#   started: <n>
#   done: <n>
#   closed: <n>
#   total: <n>
#
# Exit codes: 0 on success (including an absent/empty ledger, reported as
# all-zero counts), 2 on a usage error (non-integer epoch).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
LEDGER="${FM_BACKLOG_LEDGER_OVERRIDE:-$FM_HOME/data/backlog-ledger.tsv}"

SINCE=""
UNTIL=""

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --since)
      SINCE="${2:?--since needs a value}"
      case "$SINCE" in
        ''|*[!0-9]*)
          echo "fm-ledger-summary: --since needs an epoch-seconds integer, got: $SINCE" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    --until)
      UNTIL="${2:?--until needs a value}"
      case "$UNTIL" in
        ''|*[!0-9]*)
          echo "fm-ledger-summary: --until needs an epoch-seconds integer, got: $UNTIL" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    *)
      echo "fm-ledger-summary: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

output=$(awk -F'\t' -v since="$SINCE" -v until="$UNTIL" '
BEGIN {
  added = 0; started = 0; done_ = 0; closed = 0
}
{
  if (NF < 3) next
  epoch = $1 + 0
  event = $2
  if (since != "" && epoch < since) next
  if (until != "" && epoch >= until) next
  if (event == "added") added++
  else if (event == "started") started++
  else if (event == "done") done_++
  else if (event == "closed") closed++
}
END {
  total = added + started + done_ + closed
  print "added: " added
  print "started: " started
  print "done: " done_
  print "closed: " closed
  print "total: " total
}
' "$LEDGER" 2>/dev/null)

# If the ledger doesn't exist or awk failed, output all-zeros.
if [ -z "$output" ]; then
  printf 'added: 0\nstarted: 0\ndone: 0\nclosed: 0\ntotal: 0\n'
else
  printf '%s\n' "$output"
fi
exit 0
