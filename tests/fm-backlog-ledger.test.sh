#!/usr/bin/env bash
# tests/fm-backlog-ledger.test.sh - tests for the append-only backlog
# transition ledger (bin/fm-backlog-ledger-lib.sh) and the summary reader
# (bin/fm-ledger-summary.sh).
#
# Tests are pure: they use a temporary data directory and never touch the
# real backlog or tasks-axi.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- test: sanitize_field strips tabs and newlines -------------------------

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backlog-ledger-lib.sh"

sanitized=$(fm_backlog_ledger_sanitize_field $'hello\tworld\nfoo\rbar')
[ "$sanitized" = 'hello world foo bar' ] \
  || fail "sanitize_field should strip tabs/newlines, got: '$sanitized'"
pass "fm_backlog_ledger_sanitize_field strips tabs and newlines"

# --- test: sanitize_field preserves other characters ------------------------

sanitized=$(fm_backlog_ledger_sanitize_field 'hello, world! @#$%')
[ "$sanitized" = 'hello, world! @#$%' ] \
  || fail "sanitize_field should preserve other chars, got: '$sanitized'"
pass "fm_backlog_ledger_sanitize_field preserves non-control characters"

# --- test: sanitize_field handles empty input -------------------------------

sanitized=$(fm_backlog_ledger_sanitize_field '')
[ "$sanitized" = '' ] \
  || fail "sanitize_field should handle empty input, got: '$sanitized'"
pass "fm_backlog_ledger_sanitize_field handles empty input"

# --- test: validate rejects invalid event names -----------------------------

TEST_ROOT=$(fm_test_tmproot ledger-event)
DATA="$TEST_ROOT/data"
mkdir -p "$DATA"
FM_BACKLOG_LEDGER_FILE="$DATA/backlog-ledger.tsv"

# Invalid event should return 1 without creating/writing
fm_backlog_ledger_append invalid "$DATA" "test-task"
rc=$?
[ "$rc" -eq 1 ] \
  || fail "invalid event should return 1, got: $rc"
[ ! -f "$FM_BACKLOG_LEDGER_FILE" ] \
  || fail "invalid event should not write to ledger"
pass "fm_backlog_ledger_append rejects invalid event names"

# --- test: append with known kind/repo uses the direct path -----------------

TEST_ROOT=$(fm_test_tmproot ledger-append)
DATA="$TEST_ROOT/data"
mkdir -p "$DATA"
FM_BACKLOG_LEDGER_FILE="$DATA/backlog-ledger.tsv"

fm_backlog_ledger_append_kind_repo added "$DATA" "test-task-1" "ship" "firstmate"
rc=$?
[ "$rc" -eq 0 ] || fail "append returned $rc"
[ -f "$FM_BACKLOG_LEDGER_FILE" ] || fail "ledger file not created"

lines=$(wc -l < "$FM_BACKLOG_LEDGER_FILE" | tr -d ' ')
[ "$lines" -eq 1 ] || fail "expected 1 line, got $lines"

# Check the line format: <epoch>\tadded\ttest-task-1\tship\tfirstmate
line=$(head -1 "$FM_BACKLOG_LEDGER_FILE")
epoch=$(printf '%s\n' "$line" | cut -f1)
event=$(printf '%s\n' "$line" | cut -f2)
task_id=$(printf '%s\n' "$line" | cut -f3)
kind=$(printf '%s\n' "$line" | cut -f4)
repo=$(printf '%s\n' "$line" | cut -f5)

[ "$event" = "added" ] || fail "event should be 'added', got: '$event'"
[ "$task_id" = "test-task-1" ] || fail "task_id should be 'test-task-1', got: '$task_id'"
[ "$kind" = "ship" ] || fail "kind should be 'ship', got: '$kind'"
[ "$repo" = "firstmate" ] || fail "repo should be 'firstmate', got: '$repo'"
[ "$epoch" -gt 0 ] || fail "epoch should be a positive integer, got: '$epoch'"
pass "fm_backlog_ledger_append_kind_repo writes correct TSV format"

# --- test: multiple appends accumulate --------------------------------------

fm_backlog_ledger_append_kind_repo started "$DATA" "test-task-1" "ship" "firstmate"
fm_backlog_ledger_append_kind_repo "done" "$DATA" "test-task-1" "ship" "firstmate"
fm_backlog_ledger_append_kind_repo added "$DATA" "test-task-2" "scout" "other-repo"

lines=$(wc -l < "$FM_BACKLOG_LEDGER_FILE" | tr -d ' ')
[ "$lines" -eq 4 ] || fail "expected 4 lines, got $lines"
pass "fm_backlog_ledger_append_kind_repo accumulates multiple entries"

# --- test: full add+drain cycle round-trips ---------------------------------

TEST_ROOT=$(fm_test_tmproot ledger-cycle)
DATA="$TEST_ROOT/data"
mkdir -p "$DATA"
FM_BACKLOG_LEDGER_FILE="$DATA/backlog-ledger.tsv"

# Simulate a full lifecycle: added → started → done → closed
fm_backlog_ledger_append_kind_repo added "$DATA" "cycle-task" "ship" "firstmate"
fm_backlog_ledger_append_kind_repo started "$DATA" "cycle-task" "ship" "firstmate"
fm_backlog_ledger_append_kind_repo "done" "$DATA" "cycle-task" "ship" "firstmate"
fm_backlog_ledger_append_kind_repo closed "$DATA" "cycle-task" "ship" "firstmate"

# Verify all four events are present
event_count=$(awk -F'\t' '$2 == "added"' "$FM_BACKLOG_LEDGER_FILE" | wc -l | tr -d ' ')
[ "$event_count" -eq 1 ] || fail "expected 1 'added', got $event_count"

event_count=$(awk -F'\t' '$2 == "started"' "$FM_BACKLOG_LEDGER_FILE" | wc -l | tr -d ' ')
[ "$event_count" -eq 1 ] || fail "expected 1 'started', got $event_count"

event_count=$(awk -F'\t' '$2 == "done"' "$FM_BACKLOG_LEDGER_FILE" | wc -l | tr -d ' ')
[ "$event_count" -eq 1 ] || fail "expected 1 'done', got $event_count"

event_count=$(awk -F'\t' '$2 == "closed"' "$FM_BACKLOG_LEDGER_FILE" | wc -l | tr -d ' ')
[ "$event_count" -eq 1 ] || fail "expected 1 'closed', got $event_count"

# Verify epoch ordering (each event should have a later or equal epoch)
prev_epoch=0
while IFS=$'\t' read -r epoch _rest; do
  [ "$epoch" -ge "$prev_epoch" ] || fail "epochs not in order: $prev_epoch > $epoch"
  prev_epoch=$epoch
done < "$FM_BACKLOG_LEDGER_FILE"
pass "full add→started→done→closed cycle preserves epoch ordering"

# --- test: multiple tasks with different kinds ------------------------------

TEST_ROOT=$(fm_test_tmproot ledger-multi)
DATA="$TEST_ROOT/data"
mkdir -p "$DATA"
FM_BACKLOG_LEDGER_FILE="$DATA/backlog-ledger.tsv"

fm_backlog_ledger_append_kind_repo added "$DATA" "task-a" "ship" "firstmate"
fm_backlog_ledger_append_kind_repo added "$DATA" "task-b" "scout" "other-repo"
fm_backlog_ledger_append_kind_repo added "$DATA" "task-c" "captain" "pc02"
fm_backlog_ledger_append_kind_repo started "$DATA" "task-a" "ship" "firstmate"
fm_backlog_ledger_append_kind_repo started "$DATA" "task-b" "scout" "other-repo"
fm_backlog_ledger_append_kind_repo "done" "$DATA" "task-a" "ship" "firstmate"

# Verify per-task counts
added_a=$(awk -F'\t' '$3 == "task-a" && $2 == "added"' "$FM_BACKLOG_LEDGER_FILE" | wc -l | tr -d ' ')
added_b=$(awk -F'\t' '$3 == "task-b" && $2 == "added"' "$FM_BACKLOG_LEDGER_FILE" | wc -l | tr -d ' ')
started_a=$(awk -F'\t' '$3 == "task-a" && $2 == "started"' "$FM_BACKLOG_LEDGER_FILE" | wc -l | tr -d ' ')
done_a=$(awk -F'\t' '$3 == "task-a" && $2 == "done"' "$FM_BACKLOG_LEDGER_FILE" | wc -l | tr -d ' ')
[ "$added_a" -eq 1 ] || fail "task-a should have 1 added event"
[ "$added_b" -eq 1 ] || fail "task-b should have 1 added event"
[ "$started_a" -eq 1 ] || fail "task-a should have 1 started event"
[ "$done_a" -eq 1 ] || fail "task-a should have 1 done event"
pass "ledger correctly tracks multiple tasks with different kinds"

# --- test: lock serializes concurrent appends -------------------------------

TEST_ROOT=$(fm_test_tmproot ledger-lock)
DATA="$TEST_ROOT/data"
mkdir -p "$DATA"
FM_BACKLOG_LEDGER_FILE="$DATA/backlog-ledger.tsv"

# Run multiple appends in background to test lock contention
for i in $(seq 1 10); do
  ( fm_backlog_ledger_append_kind_repo added "$DATA" "lock-task-$i" "ship" "firstmate" ) &
done
wait

lines=$(wc -l < "$FM_BACKLOG_LEDGER_FILE" | tr -d ' ')
[ "$lines" -eq 10 ] || fail "expected 10 lines from concurrent appends, got $lines"
pass "ledger lock serializes concurrent appends correctly"

# --- test: ledger preserves kind/repo with special characters ---------------

TEST_ROOT=$(fm_test_tmproot ledger-special)
DATA="$TEST_ROOT/data"
mkdir -p "$DATA"
FM_BACKLOG_LEDGER_FILE="$DATA/backlog-ledger.tsv"

fm_backlog_ledger_append_kind_repo added "$DATA" "special-task" "ship-with-dashes" "firstmate-repo"
line=$(head -1 "$FM_BACKLOG_LEDGER_FILE")
repo=$(printf '%s\n' "$line" | cut -f5)
[ "$repo" = "firstmate-repo" ] || fail "repo with dash should be preserved, got: '$repo'"
pass "ledger preserves hyphens in kind and repo fields"

# --- test: summary script reports all-zeros for empty ledger ----------------

TEST_ROOT=$(fm_test_tmproot ledger-summary-empty)
DATA="$TEST_ROOT/data"
mkdir -p "$DATA"

output=$(FM_BACKLOG_LEDGER_OVERRIDE="$DATA/backlog-ledger.tsv" "$ROOT/bin/fm-ledger-summary.sh" 2>/dev/null)
expected='added: 0
started: 0
done: 0
closed: 0
total: 0'
[ "$output" = "$expected" ] || fail "summary of empty ledger should be all-zeros: got '$output'"
pass "summary script reports all-zeros for empty ledger"

# --- test: summary script reports correct counts for populated ledger ---------

TEST_ROOT=$(fm_test_tmproot ledger-summary-populated)
DATA="$TEST_ROOT/data"
mkdir -p "$DATA"
LEDGER="$DATA/backlog-ledger.tsv"

# Write known entries directly
printf '1000\tadded\ttask-1\tship\tfirstmate\n' >> "$LEDGER"
printf '1001\tadded\ttask-2\tscout\tother\n' >> "$LEDGER"
printf '1002\tstarted\ttask-1\tship\tfirstmate\n' >> "$LEDGER"
printf '1003\tdone\ttask-1\tship\tfirstmate\n' >> "$LEDGER"

output=$(FM_BACKLOG_LEDGER_OVERRIDE="$LEDGER" "$ROOT/bin/fm-ledger-summary.sh" 2>/dev/null)
expected='added: 2
started: 1
done: 1
closed: 0
total: 4'
[ "$output" = "$expected" ] || fail "summary should report correct counts: got '$output'"
pass "summary script reports correct counts for populated ledger"

# --- test: summary --since filters correctly --------------------------------

TEST_ROOT=$(fm_test_tmproot ledger-summary-since)
DATA="$TEST_ROOT/data"
mkdir -p "$DATA"
LEDGER="$DATA/backlog-ledger.tsv"

printf '1000\tadded\ttask-1\tship\tfirstmate\n' >> "$LEDGER"
printf '2000\tstarted\ttask-1\tship\tfirstmate\n' >> "$LEDGER"
printf '3000\tdone\ttask-1\tship\tfirstmate\n' >> "$LEDGER"

output=$(FM_BACKLOG_LEDGER_OVERRIDE="$LEDGER" "$ROOT/bin/fm-ledger-summary.sh" --since 2000 2>/dev/null)
expected='added: 0
started: 1
done: 1
closed: 0
total: 2'
[ "$output" = "$expected" ] || fail "summary --since should filter correctly: got '$output'"
pass "summary --since filters events correctly"

# --- test: summary --until filters correctly --------------------------------

output=$(FM_BACKLOG_LEDGER_OVERRIDE="$LEDGER" "$ROOT/bin/fm-ledger-summary.sh" --until 2001 2>/dev/null)
expected='added: 1
started: 1
done: 0
closed: 0
total: 2'
[ "$output" = "$expected" ] || fail "summary --until should filter correctly: got '$output'"
pass "summary --until filters events correctly"

# --- test: summary --since and --until combined -----------------------------

output=$(FM_BACKLOG_LEDGER_OVERRIDE="$LEDGER" "$ROOT/bin/fm-ledger-summary.sh" --since 1001 --until 3001 2>/dev/null)
expected='added: 0
started: 1
done: 1
closed: 0
total: 2'
[ "$output" = "$expected" ] || fail "summary --since/--until combined should filter correctly: got '$output'"
pass "summary --since and --until combine correctly"

# --- test: summary rejects invalid --since ----------------------------------

output=$("$ROOT/bin/fm-ledger-summary.sh" --since abc 2>&1)
rc=$?
[ "$rc" -eq 2 ] || fail "invalid --since should exit 2, got $rc"
pass "summary rejects non-integer --since value"

# --- test: summary handles missing ledger file ------------------------------

TEST_ROOT=$(fm_test_tmproot ledger-summary-missing)
DATA="$TEST_ROOT/data"
mkdir -p "$DATA"
LEDGER="$DATA/backlog-ledger.tsv"
# Deliberately don't create the ledger file

output=$(FM_BACKLOG_LEDGER_OVERRIDE="$LEDGER" "$ROOT/bin/fm-ledger-summary.sh" 2>/dev/null)
expected='added: 0
started: 0
done: 0
closed: 0
total: 0'
[ "$output" = "$expected" ] || fail "summary for missing ledger should be all-zeros: got '$output'"
pass "summary handles missing ledger file gracefully"

# --- test: ledger preserves tabs in kind/repo but not in field structure -----

TEST_ROOT=$(fm_test_tmproot ledger-tabs)
DATA="$TEST_ROOT/data"
mkdir -p "$DATA"
FM_BACKLOG_LEDGER_FILE="$DATA/backlog-ledger.tsv"

# Kind and repo should have tabs stripped
fm_backlog_ledger_append_kind_repo added "$DATA" "tab-task" $'ship\twith\ttabs' "repo\twith\ttabs"
line=$(head -1 "$FM_BACKLOG_LEDGER_FILE")
# Count fields - should have exactly 5 fields (4 tabs)
tab_count=$(printf '%s' "$line" | tr -cd '\t' | wc -c | tr -d ' ')
[ "$tab_count" -eq 4 ] || fail "ledger line should have exactly 4 tabs (5 fields), got $tab_count"
pass "ledger strips tabs from kind/repo but preserves field structure"

# --- test: ledger epoch is monotonically non-decreasing within a process -----

TEST_ROOT=$(fm_test_tmproot ledger-epoch)
DATA="$TEST_ROOT/data"
mkdir -p "$DATA"
FM_BACKLOG_LEDGER_FILE="$DATA/backlog-ledger.tsv"

prev=0
for i in $(seq 1 5); do
  fm_backlog_ledger_append_kind_repo added "$DATA" "epoch-task-$i" "ship" "firstmate"
  epoch=$(tail -1 "$FM_BACKLOG_LEDGER_FILE" | cut -f1)
  [ "$epoch" -ge "$prev" ] || fail "epoch $epoch should be >= previous $prev"
  prev=$epoch
done
pass "ledger epochs are monotonically non-decreasing"

# --- test: ledger writes to data_dir, not source-time global ---------------

TEST_ROOT=$(fm_test_tmproot ledger-write-path)
DATA="$TEST_ROOT/data"
mkdir -p "$DATA"
# Set a different FM_BACKLOG_LEDGER_FILE (source-time default)
FM_BACKLOG_LEDGER_FILE="/tmp/wrong-path/backlog-ledger.tsv"

# Append using a different data_dir - should write to $DATA, not FM_BACKLOG_LEDGER_FILE
fm_backlog_ledger_append_kind_repo added "$DATA" "path-test-task" "ship" "firstmate"

# The ledger should be at $DATA/backlog-ledger.tsv, not at FM_BACKLOG_LEDGER_FILE
[ -f "$DATA/backlog-ledger.tsv" ] || fail "ledger should be in data_dir, not source-time global"
[ ! -f "/tmp/wrong-path/backlog-ledger.tsv" ] \
  || fail "should not write to source-time FM_BACKLOG_LEDGER_FILE path"
pass "ledger writes to passed data_dir, not source-time global"

# --- test: lock timeout returns error code 2 --------------------------------

TEST_ROOT=$(fm_test_tmproot ledger-lock-timeout)
DATA="$TEST_ROOT/data"
mkdir -p "$DATA"
# Create a persistent lock file to simulate contention
mkdir -p "$DATA/.backlog-ledger.lock"

# This should fail with exit code 2 after timeout
fm_backlog_ledger_append_kind_repo added "$DATA" "lock-timeout-task" "ship" "firstmate"
rc=$?
rmdir "$DATA/.backlog-ledger.lock" 2>/dev/null || true
[ "$rc" -eq 2 ] || fail "lock timeout should return exit code 2, got: $rc"
pass "lock timeout returns exit code 2 under contention"

# --- test: transition lib sources the ledger without a caller SCRIPT_DIR ---
# bin/fm-x-lib.sh sources bin/fm-backlog-transition-lib.sh under `set -u`
# without defining SCRIPT_DIR; the ledger source line must locate its sibling
# from its own path, or that sourcing aborts with an unbound-variable error.

out=$(bash -c 'set -u; unset SCRIPT_DIR; . "$1/bin/fm-tasks-axi-lib.sh"; \
  . "$1/bin/fm-backlog-transition-lib.sh"; \
  declare -F fm_backlog_ledger_append >/dev/null && echo loaded' _ "$ROOT" 2>&1)
[ "$out" = 'loaded' ] \
  || fail "transition lib should source the ledger lib without SCRIPT_DIR, got: $out"
pass "transition lib locates the ledger lib without a caller-owned SCRIPT_DIR"

# --- summary: all tests passed ----------------------------------------------

echo "# fm-backlog-ledger.test.sh: all assertions passed"
