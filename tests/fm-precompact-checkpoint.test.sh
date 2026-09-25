#!/usr/bin/env bash
# Colocated test for the PreCompact checkpoint writer.
# Exercises the script through its public interface (the bin/ executable).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN="$ROOT/bin/fm-precompact-checkpoint.sh"

TEST_STATE="$(fm_test_tmproot precompact-checkpoint)"
export FM_STATE_OVERRIDE="$TEST_STATE"
export FM_HOME="$TEST_STATE"

test_checkpoint_writes_json() {
  "$BIN" || fail "checkpoint script must exit 0"
  out=$(ls "$TEST_STATE"/precompact-checkpoint-*.json 2>/dev/null | head -1)
  [ -f "$out" ] || fail "checkpoint file not written"
  jq . "$out" >/dev/null 2>&1 || fail "checkpoint is not valid JSON"
  pass "checkpoint written and valid JSON"
}

test_checkpoint_contains_keys() {
  out=$(ls "$TEST_STATE"/precompact-checkpoint-*.json 2>/dev/null | head -1)
  jq -e '.timestamp and .wake_queue and .open_decisions and .tasks_in_flight' "$out" >/dev/null || fail "required keys missing"
  pass "checkpoint contains required top-level keys"
}

test_never_blocks() {
  # Must exit 0 even with no state
  rm -f "$TEST_STATE"/*.json
  "$BIN" || fail "must exit 0 with empty state"
  pass "exits 0 with empty state"
}

test_checkpoint_extracts_seeded_state() {
  rm -f "$TEST_STATE"/*.json "$TEST_STATE"/*.status "$TEST_STATE"/*.meta

  printf '1700000000\t42\tsignal\tsome-key\tsome-payload\n' > "$TEST_STATE/.wake-queue"
  printf 'state=needs-decision reason=example\n' > "$TEST_STATE/abc.status"
  : > "$TEST_STATE/task-123.meta"

  "$BIN" || fail "checkpoint script must exit 0"
  out=$(ls "$TEST_STATE"/precompact-checkpoint-*.json 2>/dev/null | head -1)
  [ -f "$out" ] || fail "checkpoint file not written"

  jq -e '.wake_queue == [{"seq":42,"ts":"1700000000","kind":"signal"}]' "$out" >/dev/null \
    || fail "wake_queue row not extracted with correct ts/kind mapping: $(cat "$out")"
  jq -e '.open_decisions | length == 1 and (.[0] | contains("needs-decision"))' "$out" >/dev/null \
    || fail "open_decisions did not capture the seeded status line: $(cat "$out")"
  jq -e '.tasks_in_flight == ["task-123"]' "$out" >/dev/null \
    || fail "tasks_in_flight did not capture the seeded meta file: $(cat "$out")"

  rm -f "$TEST_STATE/.wake-queue" "$TEST_STATE/abc.status" "$TEST_STATE/task-123.meta"
  pass "checkpoint extracts seeded wake queue, decisions, and in-flight tasks"
}

test_checkpoint_writes_json
test_checkpoint_contains_keys
test_never_blocks
test_checkpoint_extracts_seeded_state
