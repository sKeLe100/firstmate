#!/usr/bin/env bash
# tests/fm-free-model-probe.test.sh - unit tests for bin/fm-free-model-probe.sh.
#
# Uses a fake `opencode` on PATH and a temp log directory (overridable via
# FM_FREE_PROBE_LOG_DIR) to cover the ok, capped, and timeout-unknown paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-free-model-probe.sh"
TMP_ROOT=$(fm_test_tmproot fm-free-model-probe-tests)
FAKE_BIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKE_BIN"

# Override log dir so the script writes/reads from our temp tree.
export FM_FREE_PROBE_LOG_DIR="$TMP_ROOT/opencode-logs"
mkdir -p "$FM_FREE_PROBE_LOG_DIR"

# Also export via the script's own var name so it resolves.
export OPENCODE_LOG_DIR="$FM_FREE_PROBE_LOG_DIR"

run_probe() {
  # Run with the fake opencode on PATH and our log dir. Default timeout 5s for fast tests.
  PATH="$FAKE_BIN:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" OPENCODE_LOG_DIR="$FM_FREE_PROBE_LOG_DIR" "$SCRIPT" "${1:-glm-5.3-flash-free}" "${2:-5}"
}

# --- ok case ------------------------------------------------------------------

# Fake opencode that exits 0 and prints OK.
cat > "$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
printf 'OK\n'
exit 0
SH
chmod +x "$FAKE_BIN/opencode"

out=$(run_probe glm-5.3-flash-free)
rc=$?
[ "$out" = "ok" ] || fail "ok case: expected 'ok', got '$out'"
[ "$rc" -eq 0 ] || fail "ok case: expected exit 0, got $rc"
pass "fm-free-model-probe: ok case returns 'ok' with exit 0"

# --- capped case (log entry present) ------------------------------------------

# Fake opencode that times out (simulating silent retry before cap).
cat > "$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
exec sleep 300
SH
chmod +x "$FAKE_BIN/opencode"

# Write a log entry for the model with "Free usage limit reached".
cat > "$FM_FREE_PROBE_LOG_DIR/$(date +%Y%m%d).log" <<'LOG'
{"timestamp":"2026-11-04T10:00:00Z","level":"ERROR","providerID":"opencode","modelID":"glm-5.3-flash-free","error":"AI_APICallError: Free usage limit reached. Please retry after 30s."}
LOG

out=$(run_probe glm-5.3-flash-free)
rc=$?
assert_contains "$out" "capped" "capped case: output should start with 'capped'"
[ "$rc" -eq 3 ] || fail "capped case: expected exit 3, got $rc"
assert_contains "$out" "retry after 30s" "capped case: should include retry time from log"
pass "fm-free-model-probe: capped case returns 'capped <retry>' with exit 3 when log entry present"

# --- capped case (log entry present, no retry time) ----------------------------

cat > "$FM_FREE_PROBE_LOG_DIR/$(date +%Y%m%d).log" <<'LOG'
{"timestamp":"2026-11-04T10:00:00Z","level":"ERROR","providerID":"opencode","modelID":"glm-5.3-flash-free","error":"AI_APICallError: Free usage limit reached."}
LOG

out=$(run_probe glm-5.3-flash-free)
rc=$?
assert_contains "$out" "capped" "capped no-retry: output should start with 'capped'"
[ "$rc" -eq 3 ] || fail "capped no-retry: expected exit 3, got $rc"
assert_contains "$out" "unknown retry" "capped no-retry: should include 'unknown retry' when no retry time"
pass "fm-free-model-probe: capped case returns 'capped unknown retry' with exit 3 when no retry time in log"

# --- timeout-unknown case (no matching log entry) -----------------------------

# Write a log for a different model, so the capped check finds nothing.
cat > "$FM_FREE_PROBE_LOG_DIR/$(date +%Y%m%d).log" <<'LOG'
{"timestamp":"2026-11-04T10:00:00Z","level":"ERROR","providerID":"opencode","modelID":"other-model","error":"AI_APICallError: Free usage limit reached."}
LOG

out=$(run_probe glm-5.3-flash-free)
rc=$?
assert_contains "$out" "unknown" "timeout case: output should start with 'unknown'"
assert_contains "$out" "timed out" "timeout case: should mention timeout"
[ "$rc" -eq 1 ] || fail "timeout case: expected exit 1, got $rc"
pass "fm-free-model-probe: timeout without matching log returns 'unknown probe timed out' with exit 1"

# --- unknown case (non-timeout failure) ---------------------------------------

cat > "$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
echo "some error output" >&2
exit 42
SH
chmod +x "$FAKE_BIN/opencode"

# Remove log dir contents so capped check finds nothing.
rm -f "$FM_FREE_PROBE_LOG_DIR"/*

out=$(run_probe glm-5.3-flash-free)
rc=$?
assert_contains "$out" "unknown" "non-timeout failure: output should start with 'unknown'"
assert_contains "$out" "exit code 42" "non-timeout failure: should mention the exit code"
[ "$rc" -eq 1 ] || fail "non-timeout failure: expected exit 1, got $rc"
pass "fm-free-model-probe: non-timeout failure returns 'unknown probe exit code' with exit 1"

# --- log dir absent case ------------------------------------------------------

cat > "$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
exec sleep 300
SH
chmod +x "$FAKE_BIN/opencode"

# Set to a path that definitely does not exist.
out=$(PATH="$FAKE_BIN:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" OPENCODE_LOG_DIR="/tmp/nonexistent-log-dir-$(date +%s)" "$SCRIPT" glm-5.3-flash-free 5)
rc=$?
assert_contains "$out" "unknown" "no log dir: output should start with 'unknown'"
[ "$rc" -eq 1 ] || fail "no log dir: expected exit 1, got $rc"
pass "fm-free-model-probe: absent log dir treats timeout as unknown"

echo "# fm-free-model-probe.test.sh: all assertions passed"
