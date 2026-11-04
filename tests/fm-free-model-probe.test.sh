#!/usr/bin/env bash
# tests/fm-free-model-probe.test.sh - unit tests for bin/fm-free-model-probe.sh.
#
# Uses a fake `opencode` on PATH and a temp log file (overridable via
# FM_OPENCODE_LOG) to cover the ok, capped, stale-entry, timeout, and failure
# paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-free-model-probe.sh"
TMP_ROOT=$(fm_test_tmproot fm-free-model-probe-tests)
FAKE_BIN="$TMP_ROOT/fakebin"
LOG_FILE="$TMP_ROOT/opencode.log"
HOME_DIR="$TMP_ROOT/home"
PROBE_MARKER="$TMP_ROOT/probe-ran"
mkdir -p "$FAKE_BIN" "$HOME_DIR"

export HOME="$HOME_DIR"
export FM_OPENCODE_LOG="$LOG_FILE"
export PROBE_MARKER

run_probe() {
  PATH="$FAKE_BIN:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    "$SCRIPT" "${1:-glm-5.3-flash-free}" "${2:-5}"
}

reset_logs() {
  : > "$LOG_FILE"
}

# --- help and usage refusals -------------------------------------------------

cat > "$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
: > "$PROBE_MARKER"
exec sleep 10
SH
chmod +x "$FAKE_BIN/opencode"

rm -f "$PROBE_MARKER"
out=$(PATH="$FAKE_BIN:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" "$SCRIPT" --help)
rc=$?
[ "$rc" -eq 0 ] || fail "--help: expected exit 0, got $rc"
assert_contains "$out" "Usage: fm-free-model-probe.sh" "--help: should print usage"
assert_contains "$out" "FM_OPENCODE_LOG" "--help: should name the log override"
assert_contains "$out" "exits 2" "--help: should document the usage exit"
[ ! -e "$PROBE_MARKER" ] || fail "--help: help handling launched a probe"
pass "fm-free-model-probe: --help prints usage without probing"

expect_usage_refusal() {  # <label> [args...]
  local label=$1
  shift
  rm -f "$PROBE_MARKER"
  PATH="$FAKE_BIN:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    "$SCRIPT" "$@" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "$label: expected exit 2, got $rc"
  [ ! -e "$PROBE_MARKER" ] || fail "$label: a probe ran"
  pass "fm-free-model-probe: $label refuses with exit 2 without probing"
}

expect_usage_refusal "an unknown option" --bogus
expect_usage_refusal "a missing model"
expect_usage_refusal "an empty model" ""
expect_usage_refusal "a whitespace-only model" "   "
expect_usage_refusal "an empty provider" "/glm-5.3-flash-free"
expect_usage_refusal "an empty model component" "opencode/"
expect_usage_refusal "a whitespace-only provider" "   /glm-5.3-flash-free"
expect_usage_refusal "too many arguments" glm-5.3-flash-free 5 extra
expect_usage_refusal "a zero timeout" glm-5.3-flash-free 0
expect_usage_refusal "a non-numeric timeout" glm-5.3-flash-free soon

# --- ok case -----------------------------------------------------------------

# Fake opencode that prints the reply on stdout and an OK-bearing diagnostic on
# stderr, so only the exact stdout reply decides ok.
cat > "$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
printf 'OK\n'
printf 'HTTP/1.1 200 OK\n' >&2
exit 0
SH
chmod +x "$FAKE_BIN/opencode"

out=$(run_probe glm-5.3-flash-free)
rc=$?
[ "$out" = "ok" ] || fail "ok case: expected 'ok', got '$out'"
[ "$rc" -eq 0 ] || fail "ok case: expected exit 0, got $rc"
pass "fm-free-model-probe: ok case returns 'ok' with exit 0"

# --- non-exact reply ---------------------------------------------------------

# A substring match on stdout or an OK in stderr must not count as ok.
cat > "$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
printf 'NOT OK\n'
printf '200 OK\n' >&2
exit 0
SH
chmod +x "$FAKE_BIN/opencode"

reset_logs
err_file="$TMP_ROOT/non-exact-stderr"
out=$(run_probe glm-5.3-flash-free 2>"$err_file")
rc=$?
[ "$out" != "ok" ] || fail "non-exact reply: 'NOT OK' must not count as ok"
assert_contains "$out" "unknown" "non-exact reply: output should start with 'unknown'"
assert_contains "$(cat "$err_file")" "NOT OK" "non-exact reply: should forward non-OK stdout to stderr"
assert_contains "$(cat "$err_file")" "200 OK" "non-exact reply: should still forward vendor stderr"
[ "$rc" -eq 1 ] || fail "non-exact reply: expected exit 1, got $rc"
pass "fm-free-model-probe: an OK substring in either stream is not an ok reply"

# --- probe cwd ---------------------------------------------------------------

CWD_FILE="$TMP_ROOT/probe-cwd"
cat > "$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
pwd > "$PROBE_CWD_FILE"
printf 'OK\n'
exit 0
SH
chmod +x "$FAKE_BIN/opencode"

reset_logs
export PROBE_CWD_FILE="$CWD_FILE"
out=$(run_probe glm-5.3-flash-free)
rc=$?
unset PROBE_CWD_FILE
[ "$out" = "ok" ] || fail "probe cwd: expected 'ok', got '$out'"
[ "$rc" -eq 0 ] || fail "probe cwd: expected exit 0, got $rc"
probe_cwd=$(cat "$CWD_FILE")
[ "$probe_cwd" != "$PWD" ] || fail "probe cwd: opencode ran in the caller's directory"
[ "$probe_cwd" != "$ROOT" ] || fail "probe cwd: opencode ran in the repo root"
pass "fm-free-model-probe: runs opencode from a temporary directory"

# --- capped case (log entry present) ------------------------------------------

# Fake opencode that logs a real opencode logfmt cap line during the probe,
# then retries silently.
cat > "$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
printf 'timestamp=%s level=ERROR run=probe message="stream error" providerID=opencode modelID=glm-5.3-flash-free session.id=ses_probe small=false agent=build mode=primary error.error="AI_APICallError: Free usage limit reached. Please retry after 30s."\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$FM_OPENCODE_LOG"
exec sleep 300
SH
chmod +x "$FAKE_BIN/opencode"

reset_logs
out=$(run_probe glm-5.3-flash-free)
rc=$?
assert_contains "$out" "capped" "capped case: output should start with 'capped'"
[ "$rc" -eq 3 ] || fail "capped case: expected exit 3, got $rc"
assert_contains "$out" "retry after 30s" "capped case: should include retry time from log"
pass "fm-free-model-probe: capped case returns 'capped <retry>' with exit 3 when log entry present"

# --- capped case (log entry present, no retry time) ----------------------------

cat > "$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
printf 'timestamp=%s level=ERROR run=probe message="stream error" providerID=opencode modelID=glm-5.3-flash-free session.id=ses_probe small=false agent=build mode=primary error.error="AI_APICallError: Free usage limit reached."\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$FM_OPENCODE_LOG"
exec sleep 300
SH
chmod +x "$FAKE_BIN/opencode"

reset_logs
out=$(run_probe glm-5.3-flash-free)
rc=$?
assert_contains "$out" "capped" "capped no-retry: output should start with 'capped'"
[ "$rc" -eq 3 ] || fail "capped no-retry: expected exit 3, got $rc"
assert_contains "$out" "unknown retry" "capped no-retry: should include 'unknown retry' when no retry time"
pass "fm-free-model-probe: capped case returns 'capped unknown retry' with exit 3 when no retry time in log"

# --- provider-qualified model id ---------------------------------------------

cat > "$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
printf 'timestamp=%s level=ERROR run=probe message="stream error" providerID=opencode modelID=glm-5.3-flash-free session.id=ses_probe small=false agent=build mode=primary error.error="AI_APICallError: Free usage limit reached."\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$FM_OPENCODE_LOG"
exec sleep 300
SH
chmod +x "$FAKE_BIN/opencode"

reset_logs
out=$(run_probe opencode/glm-5.3-flash-free)
rc=$?
assert_contains "$out" "capped" "provider-qualified: output should start with 'capped'"
[ "$rc" -eq 3 ] || fail "provider-qualified: expected exit 3, got $rc"
pass "fm-free-model-probe: a provider-qualified model id matches its providerID and modelID log pair"

cat > "$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
printf 'timestamp=%s level=ERROR run=probe message="stream error" providerID=other-provider modelID=glm-5.3-flash-free session.id=ses_probe small=false agent=build mode=primary error.error="AI_APICallError: Free usage limit reached."\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$FM_OPENCODE_LOG"
exec sleep 300
SH
chmod +x "$FAKE_BIN/opencode"

reset_logs
out=$(run_probe opencode/glm-5.3-flash-free)
rc=$?
assert_contains "$out" "unknown" "provider mismatch: output should start with 'unknown'"
assert_contains "$out" "timed out" "provider mismatch: should report the timeout"
[ "$rc" -eq 1 ] || fail "provider mismatch: expected exit 1, got $rc"
pass "fm-free-model-probe: a qualified model id does not match another provider's same bare model"

# --- stale capped entry ------------------------------------------------------

# A cap entry written before the probe started must not classify this probe.
cat > "$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
exec sleep 300
SH
chmod +x "$FAKE_BIN/opencode"

reset_logs
cat > "$FM_OPENCODE_LOG" <<'LOG'
timestamp=1970-01-01T00:00:00Z level=ERROR run=old message="stream error" providerID=opencode modelID=glm-5.3-flash-free session.id=ses_old small=false agent=build mode=primary error.error="AI_APICallError: Free usage limit reached. Please retry after 30s."
LOG

out=$(run_probe glm-5.3-flash-free)
rc=$?
assert_contains "$out" "unknown" "stale cap: output should start with 'unknown'"
assert_contains "$out" "timed out" "stale cap: should report the timeout"
[ "$rc" -eq 1 ] || fail "stale cap: expected exit 1, got $rc"
pass "fm-free-model-probe: a capped entry from before the probe does not classify it as capped"

# --- fresh capped entry for another model ------------------------------------

cat > "$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
printf 'timestamp=%s level=ERROR run=probe message="stream error" providerID=opencode modelID=other-model session.id=ses_probe small=false agent=build mode=primary error.error="AI_APICallError: Free usage limit reached."\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$FM_OPENCODE_LOG"
exec sleep 300
SH
chmod +x "$FAKE_BIN/opencode"

reset_logs
out=$(run_probe glm-5.3-flash-free)
rc=$?
assert_contains "$out" "unknown" "other model: output should start with 'unknown'"
assert_contains "$out" "timed out" "other model: should report the timeout"
[ "$rc" -eq 1 ] || fail "other model: expected exit 1, got $rc"
pass "fm-free-model-probe: a fresh cap for another model does not classify this probe as capped"

# --- timeout-unknown case (no matching log entry) -----------------------------

cat > "$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
exec sleep 300
SH
chmod +x "$FAKE_BIN/opencode"

reset_logs
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

reset_logs
err_file="$TMP_ROOT/non-timeout-stderr"
out=$(run_probe glm-5.3-flash-free 2>"$err_file")
rc=$?
assert_contains "$out" "unknown" "non-timeout failure: output should start with 'unknown'"
assert_contains "$out" "exit code 42" "non-timeout failure: should mention the exit code"
assert_contains "$(cat "$err_file")" "some error output" "non-timeout failure: should pass vendor stderr through"
[ "$rc" -eq 1 ] || fail "non-timeout failure: expected exit 1, got $rc"
pass "fm-free-model-probe: non-timeout failure returns 'unknown probe exit code' with exit 1"

# --- unknown case (signal-range exit status) ---------------------------------

# Exit 130 is a signal death, not the bound firing, so it must name the status.
cat > "$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
exit 130
SH
chmod +x "$FAKE_BIN/opencode"

reset_logs
out=$(run_probe glm-5.3-flash-free)
rc=$?
assert_contains "$out" "exit code 130" "signal exit: should report the exit code"
assert_not_contains "$out" "timed out" "signal exit: a status above 124 is not a timeout"
[ "$rc" -eq 1 ] || fail "signal exit: expected exit 1, got $rc"
pass "fm-free-model-probe: a signal-range exit status is reported as that status, not a timeout"

# --- log file absent case -----------------------------------------------------

cat > "$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
exec sleep 300
SH
chmod +x "$FAKE_BIN/opencode"

missing_log="$TMP_ROOT/nonexistent-$(date +%s).log"
err_file="$TMP_ROOT/absent-log-stderr"
out=$(PATH="$FAKE_BIN:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" FM_OPENCODE_LOG="$missing_log" "$SCRIPT" glm-5.3-flash-free 5 2>"$err_file")
rc=$?
assert_contains "$out" "unknown" "no log file: output should start with 'unknown'"
assert_contains "$(cat "$err_file")" "cannot read OpenCode log" "no log file: should name the unreadable log"
assert_contains "$(cat "$err_file")" "$missing_log" "no log file: should name the unreadable log path"
[ "$rc" -eq 1 ] || fail "no log file: expected exit 1, got $rc"
pass "fm-free-model-probe: absent log file treats timeout as unknown"

# --- HOME unset without an override ------------------------------------------

cat > "$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
exec sleep 300
SH
chmod +x "$FAKE_BIN/opencode"

out_file="$TMP_ROOT/no-home-stdout"
err_file="$TMP_ROOT/no-home-stderr"
(
  unset HOME FM_OPENCODE_LOG
  PATH="$FAKE_BIN:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    "$SCRIPT" glm-5.3-flash-free 1 >"$out_file" 2>"$err_file"
)
rc=$?
[ "$rc" -eq 1 ] || fail "no HOME: expected exit 1, got $rc"
assert_contains "$(cat "$out_file")" "unknown" "no HOME: should still print a verdict"
assert_not_contains "$(cat "$err_file")" "unbound variable" "no HOME: should not abort on an unset HOME"
assert_contains "$(cat "$err_file")" "cannot read OpenCode log" "no HOME: should name the unreadable log"
assert_contains "$(cat "$err_file")" "/.local/share/opencode/log/opencode.log" "no HOME: should name the unreadable log path"
pass "fm-free-model-probe: an unset HOME still produces a verdict"

echo "# fm-free-model-probe.test.sh: all assertions passed"
