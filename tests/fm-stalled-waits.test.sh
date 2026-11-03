#!/usr/bin/env bash
# tests/fm-stalled-waits.test.sh - behavior tests for the STALLED WAITS section
# and the PROCESS CENSUS line bin/fm-wake-drain.sh prints on every drain. The
# section is wiring around fm-classify-lib.sh's stalled_wait_line verdict, which
# judges one bin/fm-crew-state.sh line per ship. These tests run the real drain
# over crafted status logs and a stub crew-state whose per-task verdicts are
# canned, then assert on the printed output. Each flag has its non-flag
# counterpart (fresh gate, open needs-decision, external pause, fresh go-wait,
# untimed wait, captain wait, live run over a stale declared wait).
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-stalled-waits-tests)
NOW=$(date +%s)

# A stub crew-state: prints the canned verdict for the task id it is asked about,
# or a no-verdict line, so each test fixes exactly what the authoritative read says.
write_crew_state_stub() {  # <case-dir>
  cat > "$1/fakebin/crew-state" <<'SH'
#!/usr/bin/env bash
set -u
f="$FM_STUB_CANNED/${1:-}"
if [ -f "$f" ]; then
  cat "$f"
else
  printf 'state: unknown · source: none · no canned verdict\n'
fi
SH
  chmod +x "$1/fakebin/crew-state"
}

# A task with a recorded kind, its status log, and its canned crew-state verdict.
add_task() {  # <case-dir> <task> <kind> <canned-verdict> <status-line>...
  local dir=$1 task=$2 kind=$3 verdict=$4 line
  shift 4
  printf 'kind=%s\n' "$kind" > "$dir/state/$task.meta"
  mkdir -p "$dir/canned"
  printf '%s\n' "$verdict" > "$dir/canned/$task"
  : > "$dir/state/$task.status"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$dir/state/$task.status"
  done
}

# Run the real drain over the case, with the stub standing in for crew-state and
# a fake /proc/loadavg whose load5 is the second argument. Prints the output path.
run_drain_case() {  # <case-dir> <load5>
  local dir=$1 load=$2 out="$1/drain.out"
  printf '0.10 %s 0.10 1/100 1234\n' "$load" > "$dir/loadavg"
  FM_STUB_CANNED="$dir/canned" \
    FM_CREW_STATE_BIN="$dir/fakebin/crew-state" \
    FM_LOADAVG_FILE="$dir/loadavg" \
    FM_STATE_OVERRIDE="$dir/state" \
    "$DRAIN" > "$out" 2>"$dir/drain.err" || fail "drain failed: $(cat "$dir/drain.err")"
  printf '%s' "$out"
}

test_gate_awaiting_agent_past_an_hour_is_flagged() {
  local dir out
  dir=$(make_case gate-stall)
  write_crew_state_stub "$dir"
  add_task "$dir" gate-stall ship \
    'state: parked · source: run-step · parked at test: 1 finding(s) · gate awaiting agent for 1h05m0s · run: 01RUN' \
    "working [at=$((NOW - 4000))]: validating"

  out=$(run_drain_case "$dir" 0.50)

  grep -F 'STALLED WAITS' "$out" >/dev/null || fail "a gate parked 1h05m on the crewmate printed no STALLED WAITS section: $(cat "$out")"
  grep -F 'gate-stall: parked at test: 1 finding(s) has waited 1h05m on the crewmate with no needs-decision open' "$out" >/dev/null \
    || fail "the stalled gate line did not name the task, gate, age, and missing decision: $(cat "$out")"
  pass "a no-mistakes gate awaiting the crewmate past an hour with no needs-decision open is flagged with its age"
}

test_fresh_gate_is_not_flagged() {
  local dir out
  dir=$(make_case gate-fresh)
  write_crew_state_stub "$dir"
  add_task "$dir" gate-fresh ship \
    'state: parked · source: run-step · parked at test: 1 finding(s) · gate awaiting agent for 10m0s · run: 01RUN' \
    "working [at=$((NOW - 600))]: validating"

  out=$(run_drain_case "$dir" 0.50)

  if grep -F 'STALLED WAITS' "$out" >/dev/null || grep -F 'gate-fresh:' "$out" >/dev/null; then
    fail "a gate parked only 10m was flagged as stalled: $(cat "$out")"
  fi
  pass "a fresh gate parked 10m is not flagged"
}

test_gate_with_an_open_needs_decision_is_not_flagged() {
  local dir out
  dir=$(make_case gate-answered)
  write_crew_state_stub "$dir"
  add_task "$dir" gate-answered ship \
    'state: parked · source: run-step · parked at test: 1 finding(s) · gate awaiting agent for 2h00m0s · run: 01RUN' \
    'needs-decision [key=nm-01RUN-test]: ask-user findings=test-1 file=/tmp/nm-01RUN-findings.txt'

  out=$(run_drain_case "$dir" 0.50)

  if grep -F 'gate-answered: parked at test' "$out" >/dev/null; then
    fail "a gate with an open needs-decision was flagged as silent: $(cat "$out")"
  fi
  grep -F 'OPEN DECISIONS' "$out" >/dev/null \
    || fail "the open needs-decision did not reach OPEN DECISIONS, so the gate would be silent: $(cat "$out")"
  pass "a gate parked past an hour with an open needs-decision is left to OPEN DECISIONS, not flagged"
}

test_declared_go_wait_past_an_hour_is_flagged() {
  local dir out
  dir=$(make_case go-wait)
  write_crew_state_stub "$dir"
  add_task "$dir" go-wait ship \
    'state: paused · source: status-log · paused: ready for test slot' \
    "paused [at=$((NOW - 7200))]: ready for test slot; waiting for firstmate go before no-mistakes"

  out=$(run_drain_case "$dir" 0.50)

  grep -F 'go-wait: paused 2h00m waiting on firstmate: ready for test slot; waiting for firstmate go before no-mistakes' "$out" >/dev/null \
    || fail "an idle go-wait pause past an hour was not flagged with its age and wait: $(cat "$out")"
  pass "a declared paused go-wait idle past an hour is flagged with its age and what it waits on"
}

test_external_pause_is_not_flagged() {
  local dir out
  dir=$(make_case external-pause)
  write_crew_state_stub "$dir"
  add_task "$dir" external-pause ship \
    'state: paused · source: status-log · paused: held for Claude quota' \
    "paused [at=$((NOW - 7200))]: held for Claude quota; resumes on firstmate steer"

  out=$(run_drain_case "$dir" 0.50)

  if grep -F 'external-pause:' "$out" >/dev/null; then
    fail "a quota-held pause was flagged as a firstmate wait: $(cat "$out")"
  fi
  pass "a pause held for an external delay is not flagged even when it names a firstmate steer"
}

test_fresh_go_wait_is_not_flagged() {
  local dir out
  dir=$(make_case go-fresh)
  write_crew_state_stub "$dir"
  add_task "$dir" go-fresh ship \
    'state: paused · source: status-log · paused: ready for test slot' \
    "paused [at=$((NOW - 300))]: ready for test slot; waiting for firstmate go before no-mistakes"

  out=$(run_drain_case "$dir" 0.50)

  if grep -F 'go-fresh:' "$out" >/dev/null; then
    fail "a go-wait declared five minutes ago was flagged: $(cat "$out")"
  fi
  pass "a go-wait declared five minutes ago is not flagged"
}

test_go_wait_without_a_time_is_not_flagged() {
  local dir out
  dir=$(make_case go-untimed)
  write_crew_state_stub "$dir"
  add_task "$dir" go-untimed ship \
    'state: paused · source: status-log · paused: waiting for firstmate go' \
    'paused: waiting for firstmate go'

  out=$(run_drain_case "$dir" 0.50)

  if grep -F 'go-untimed:' "$out" >/dev/null; then
    fail "a go-wait with no [at=] time was flagged; its age is unknown: $(cat "$out")"
  fi
  pass "a go-wait with no recorded time is unknown and is not flagged"
}

test_captain_wait_is_not_flagged() {
  local dir out
  dir=$(make_case captain-wait)
  write_crew_state_stub "$dir"
  add_task "$dir" captain-wait ship \
    'state: paused · source: status-log · paused: waiting for the captain' \
    "paused [at=$((NOW - 7200))]: waiting for the captain decision on the API shape"

  out=$(run_drain_case "$dir" 0.50)

  if grep -F 'captain-wait:' "$out" >/dev/null; then
    fail "a captain-held wait was flagged as a firstmate wait: $(cat "$out")"
  fi
  pass "a wait on the captain is not a firstmate go and is not flagged"
}

test_live_run_overrides_a_stale_declared_go_wait() {
  local dir out
  dir=$(make_case live-over-stale)
  write_crew_state_stub "$dir"
  add_task "$dir" live-over-stale ship \
    'state: working · source: run-step · validating (running) · run: 01RUN' \
    "paused [at=$((NOW - 7200))]: waiting for firstmate go before no-mistakes"

  out=$(run_drain_case "$dir" 0.50)

  if grep -F 'live-over-stale:' "$out" >/dev/null; then
    fail "a stale declared go-wait outvoted a live run: $(cat "$out")"
  fi
  pass "the authoritative state wins: a live run does not read as a stalled go-wait"
}

test_scouts_are_not_judged() {
  local dir out
  dir=$(make_case scout-gate)
  write_crew_state_stub "$dir"
  add_task "$dir" scout-gate scout \
    'state: parked · source: run-step · parked at test: 1 finding(s) · gate awaiting agent for 3h00m0s · run: 01RUN' \
    "working [at=$((NOW - 9000))]: scouting"

  out=$(run_drain_case "$dir" 0.50)

  if grep -F 'scout-gate:' "$out" >/dev/null; then
    fail "a scout was judged as a ship stall: $(cat "$out")"
  fi
  pass "only ships are judged; a scout is never flagged"
}

test_unparseable_read_never_fails_the_drain() {
  local dir out
  dir=$(make_case unreadable)
  write_crew_state_stub "$dir"
  add_task "$dir" unreadable ship 'not a state line at all' \
    "paused [at=$((NOW - 7200))]: waiting for firstmate go"

  out=$(run_drain_case "$dir" 0.50)

  if grep -F 'unreadable:' "$out" >/dev/null; then
    fail "an unreadable verdict was judged: $(cat "$out")"
  fi
  pass "an unreadable state read prints nothing for that ship and leaves the drain healthy"
}

test_census_names_the_busy_task_above_load_eight() {
  local dir out wt pid
  dir=$(make_case census-busy)
  write_crew_state_stub "$dir"
  add_task "$dir" census-busy ship 'state: working · source: pane · busy' "working [at=$NOW]: busy"
  mkdir -p "$dir/wt"
  wt=$(cd "$dir/wt" && pwd -P)
  printf 'kind=ship\nworktree=%s\n' "$wt" > "$dir/state/census-busy.meta"
  ( cd "$wt" && exec sh -c 'while :; do :; done' ) &
  pid=$!

  out=$(run_drain_case "$dir" 9.50)
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null || true

  grep -F 'PROCESS CENSUS (load5 9.50 above 8 on this host; top CPU by task worktree):' "$out" >/dev/null \
    || fail "load5 9.50 above 8 printed no process census line: $(cat "$out")"
  grep -F 'PROCESS CENSUS' "$out" | grep -F 'census-busy' >/dev/null \
    || fail "the census did not group the busy process under its task worktree: $(cat "$out")"
  pass "above load5 8 the census groups the top CPU consumers under the task worktree they run in"
}

test_census_stays_quiet_at_or_below_load_eight() {
  local dir out
  dir=$(make_case census-quiet)
  write_crew_state_stub "$dir"
  add_task "$dir" census-quiet ship 'state: working · source: pane · busy' "working [at=$NOW]: busy"

  out=$(run_drain_case "$dir" 7.00)

  if grep -F 'PROCESS CENSUS' "$out" >/dev/null; then
    fail "a census line printed at load5 7.00: $(cat "$out")"
  fi
  pass "at or below load5 8 no process census line prints"
}

test_gate_awaiting_agent_past_an_hour_is_flagged
test_fresh_gate_is_not_flagged
test_gate_with_an_open_needs_decision_is_not_flagged
test_declared_go_wait_past_an_hour_is_flagged
test_external_pause_is_not_flagged
test_fresh_go_wait_is_not_flagged
test_go_wait_without_a_time_is_not_flagged
test_captain_wait_is_not_flagged
test_live_run_overrides_a_stale_declared_go_wait
test_scouts_are_not_judged
test_unparseable_read_never_fails_the_drain
test_census_names_the_busy_task_above_load_eight
test_census_stays_quiet_at_or_below_load_eight
