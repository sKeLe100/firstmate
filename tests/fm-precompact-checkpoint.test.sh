#!/usr/bin/env bash
# Colocated test for the PreCompact checkpoint writer.
# Exercises the script through its public interface (the bin/ executable).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$ROOT/bin/fm-precompact-checkpoint.sh"

oneTimeSetUp() {
  TEST_STATE="$(mktemp -d "$ROOT/state.test.XXXXXX")"
  export FM_STATE_OVERRIDE="$TEST_STATE"
  export FM_HOME="$TEST_STATE"
}

oneTimeTearDown() {
  rm -rf "$TEST_STATE"
}

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

. shunit2
