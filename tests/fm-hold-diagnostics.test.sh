#!/usr/bin/env bash
# Contract tests for tests/fm-hold-diagnostics-lib.sh: a failing case and a
# timed-out barrier each preserve a diagnostic directory, a timed-out fixture
# child is terminated and reaped, and the wait reports exit 124.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DIAG_LIB="$ROOT/tests/fm-hold-diagnostics-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-hold-diag)

run_scenario() {  # <name> <body>; leaves $scenario_out, $scenario_rc, $scenario_diag
  local body=$2 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/fixture"
  cat > "$dir/scenario.sh" <<SH
#!/usr/bin/env bash
set -u
. "$DIAG_LIB"
TMP_ROOT="$dir/fixture"
DIAGNOSTIC_ROOT="$dir/diag"
CASE_TRACE="$dir/cases.tsv"
FM_TEST_LAST_COMMAND=initialization
FM_TEST_ACTIVE_CASE=initialization
mkdir -p "\$DIAGNOSTIC_ROOT"
: > "\$CASE_TRACE"
set -T
trap 'FM_TEST_LAST_COMMAND=\$BASH_COMMAND' DEBUG
trap 'fm_test_preserve_diagnostics \$?' EXIT
$body
SH
  scenario_out=$(bash "$dir/scenario.sh" 2>&1)
  scenario_rc=$?
  scenario_diag=$(find "$dir/diag" -maxdepth 1 -name 'failure-*' -type d 2>/dev/null | head -n1)
}

test_failing_case_preserves_diagnostics() {
  run_scenario failing-case 'bad_case() { false; exit 3; }
run_case bad_case'
  [ "$scenario_rc" -eq 3 ] || fail "a failing case must exit with its status, got $scenario_rc"
  [ -n "$scenario_diag" ] || fail "a failing case must preserve a diagnostic directory: $scenario_out"
  grep -q '^exit_status=3$' "$scenario_diag/diagnostic.txt" || fail "diagnostic must record the exit status"
  grep -q '^active_case=bad_case$' "$scenario_diag/diagnostic.txt" || fail "diagnostic must name the active case"
  grep -q $'^bad_case\tstart\t' "$scenario_diag/cases.tsv" || fail "case trace must record the failing case start"
  pass "a failing case preserves its diagnostic directory"
}

test_passing_case_preserves_nothing() {
  run_scenario passing-case 'ok_case() { return 0; }
run_case ok_case'
  [ "$scenario_rc" -eq 0 ] || fail "a passing case must exit 0, got $scenario_rc"
  [ -z "$scenario_diag" ] || fail "a passing run must not preserve a failure directory"
  pass "a passing case preserves no failure diagnostics"
}

test_timed_out_barrier_exits_124_and_reaps_the_child() {
  run_scenario timed-out-barrier 'hung_case() {
  sleep 30 &
  local pid=$!
  echo "$pid" > "$TMP_ROOT/pid"
  bounded_fixture_wait "$pid" "stuck fixture" 1
  local rc=$?
  kill -0 "$pid" 2>/dev/null && { echo "child still alive" >&2; return 99; }
  exit "$rc"
}
run_case hung_case'
  [ "$scenario_rc" -eq 124 ] || fail "a timed-out barrier must exit 124, got $scenario_rc: $scenario_out"
  [ -n "$scenario_diag" ] || fail "a timed-out barrier must preserve a diagnostic directory"
  grep -q '^exit_status=124$' "$scenario_diag/diagnostic.txt" || fail "diagnostic must record exit 124"
  grep -q '^active_case=hung_case$' "$scenario_diag/diagnostic.txt" || fail "diagnostic must name the hung case"
  case "$scenario_out" in *"timed out after 1s waiting for stuck fixture"*) ;; *) fail "timeout must name the awaited fixture: $scenario_out" ;; esac
  case "$scenario_out" in *"child still alive"*) fail "the timed-out child must be terminated" ;; esac
  pass "a timed-out barrier exits 124, preserves diagnostics, and reaps the child"
}

test_timed_out_child_does_not_hold_the_pipe_open() {
  local dir="$TMP_ROOT/pipe-hold" start end
  mkdir -p "$dir"
  start=$SECONDS
  bash -c '. "$1"; CASE_TRACE=/dev/null
    (sleep 30; true) & bounded_fixture_wait $! "pipe holder" 1' _ "$DIAG_LIB" 2>/dev/null | cat >/dev/null
  end=$SECONDS
  [ $((end - start)) -lt 20 ] || fail "a timed-out child kept the pipe open for $((end - start))s"
  pass "a timed-out fixture child does not keep the output pipe open"
}

test_failing_case_preserves_diagnostics
test_passing_case_preserves_nothing
test_timed_out_barrier_exits_124_and_reaps_the_child
test_timed_out_child_does_not_hold_the_pipe_open
