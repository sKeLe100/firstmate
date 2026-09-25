#!/usr/bin/env bash
# PreCompact hook: write a non-blocking compaction checkpoint under state/.
# Records open wake queue rows (list only, never ack), open decisions, and in-flight tasks.
# Always exits 0; bounded runtime; never blocks or fails compaction.
set -u

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE" 2>/dev/null || echo "fm-precompact-checkpoint: failed to create state dir $STATE" >&2

TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$STATE/precompact-checkpoint-$TS.json"

# Open wake queue rows: read .wake-queue directly, never ack or mutate
WAKE_QUEUE="$STATE/.wake-queue"
WAKE_ROWS="[]"
if [ -f "$WAKE_QUEUE" ]; then
  WAKE_ROWS="$(awk -F'\t' 'NF>=5 { printf "{\"seq\":%s,\"ts\":\"%s\",\"kind\":\"%s\"}\n",$2,$1,$3 }' "$WAKE_QUEUE" | jq -s . 2>/dev/null)"
  if [ -z "$WAKE_ROWS" ] || [ "$WAKE_ROWS" = "null" ]; then
    echo "fm-precompact-checkpoint: failed to parse $WAKE_QUEUE, falling back to []" >&2
    WAKE_ROWS="[]"
  fi
fi

# Open decisions: bounded read of needs-decision lines from status files (never ack)
DECISIONS="$(find "$STATE" -maxdepth 1 -name '*.status' -exec grep -l 'needs-decision' {} + 2>/dev/null | head -20 | while read -r f; do
  grep 'needs-decision' "$f" 2>/dev/null | tail -3
done | jq -R . | jq -s . 2>/dev/null)"
if [ -z "$DECISIONS" ] || [ "$DECISIONS" = "null" ]; then
  echo "fm-precompact-checkpoint: failed to collect open decisions, falling back to []" >&2
  DECISIONS="[]"
fi

# Tasks in flight: every state/<id>.meta
IN_FLIGHT="$(find "$STATE" -maxdepth 1 -name '*.meta' -printf '%f\n' 2>/dev/null | sed 's/\.meta$//' | jq -R . | jq -s . 2>/dev/null)"
if [ -z "$IN_FLIGHT" ] || [ "$IN_FLIGHT" = "null" ]; then
  echo "fm-precompact-checkpoint: failed to collect tasks in flight, falling back to []" >&2
  IN_FLIGHT="[]"
fi

jq -n \
  --arg ts "$TS" \
  --argjson wake "$WAKE_ROWS" \
  --argjson decisions "$DECISIONS" \
  --argjson inflight "$IN_FLIGHT" \
  '{timestamp:$ts, wake_queue:$wake, open_decisions:$decisions, tasks_in_flight:$inflight}' \
  > "$OUT" 2>/dev/null || { echo "fm-precompact-checkpoint: jq failed, writing empty checkpoint to $OUT" >&2; echo '{}' > "$OUT"; }

exit 0
