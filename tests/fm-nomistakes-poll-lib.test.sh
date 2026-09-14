#!/usr/bin/env bash
# Behavior tests for bin/fm-nomistakes-poll-lib.sh: exercises `classify`
# against the three real 2026-09-08 wrong-exit-condition shapes (a top-level
# `status: running` blob whose active step is actually gated, a genuinely
# active step, and a terminal outcome) plus the other-branch shape `axi
# status` emits when the current branch has no run, using field shapes
# captured from live `no-mistakes axi status` calls. Also exercises `wait`'s
# bounded poll loop against a fake `no-mistakes` binary, including a hung
# status call and an other-branch-only answer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-nomistakes-poll-lib.sh"

classify() { printf '%s\n' "$1" | "$SCRIPT" classify; }

# --- 0. another branch's run: `axi status` emits `other_branch_run:` (and no
# `run:` block) when the CURRENT branch has no run at all. Its gate/outcome
# is not ours; classify must say so rather than report a false gate/outcome.
# Captured verbatim from a live `no-mistakes axi status` on a branch with no
# run while another branch's run was active.
OTHER_BRANCH_TOON='current_branch: fm/nomistakes-poll-helper-gap
other_branch_run:
  id: "01M2FVPY44K6ZZYZS708MTVGBA"
  branch: fm/backlog-routing-registry
  status: running
  head: 262c78eb
  head_sha: 262c78ebfbb00d9dcd311f6bdb21a92e13594547
  findings: "2 auto-fix, 1 info"
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,24
    rebase,completed,1,626
    review,awaiting_approval,2,83704
    test,pending,0,0'
OUT=$(classify "$OTHER_BRANCH_TOON")
[ "$OUT" = no-run ] || fail "other branch run: expected 'no-run', got '$OUT'"
pass "0. another branch's gated run classifies as no-run, never as our gate"

# --- 1. genuinely active step: no gate, no outcome, current-branch run: ----
# Same field shape as the live capture above, under the `run:` key `axi
# status` uses for the current branch's own run.
RUNNING_TOON='run:
  id: "01M2FVPY44K6ZZYZS708MTVGBA"
  branch: fm/nomistakes-poll-helper-gap
  status: running
  head: 262c78eb
  head_sha: 262c78ebfbb00d9dcd311f6bdb21a92e13594547
  findings: "2 auto-fix, 1 info"
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,24
    rebase,completed,1,626
    review,completed,2,83704
    test,running,0,0
    document,pending,0,0
    lint,pending,0,0
    push,pending,0,0
    pr,pending,0,0
    ci,pending,0,0
  active_steps[1]{step,status,active_for,round_active_for,last_activity,agent_pid,round}:
    test,running,17m38s,17m38s,"1s ago: claude producing output","728174",starting'
OUT=$(classify "$RUNNING_TOON")
[ "$OUT" = running ] || fail "active step: expected 'running', got '$OUT'"
pass "1. genuinely active step classifies as running"

# --- 2. terminal outcome: status completed + outcome: passed
TERMINAL_TOON='run:
  id: "01M2DMSZTRX137R2B26F9E99BW"
  branch: fm/nomistakes-poll-helper-gap
  status: completed
  head: 9226bdaa
  head_sha: 9226bdaa0e5b9314007541830304c3d652ca106c
  pr: "https://github.com/sKeLe100/firstmate/pull/103"
  findings: 1 awaiting
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,23
    rebase,completed,0,949
    review,completed,0,94436
    test,completed,1,148782
    document,completed,0,59159
    lint,completed,0,747
    push,completed,0,2550
    pr,completed,0,24371
    ci,completed,0,1558539
outcome: passed'
OUT=$(classify "$TERMINAL_TOON")
[ "$OUT" = "outcome:passed" ] || fail "terminal outcome: expected 'outcome:passed', got '$OUT'"
pass "2. terminal outcome:passed classifies as outcome:passed"

# --- 3. the exact incident shape: top-level status still 'running' while a
# step is gated (awaiting_approval). This is the bug data/learnings.md
# records: three crewmates' loops treated top-level status:running as "keep
# waiting" and spun forever, or treated it as "still active" too early and
# exited before responding to the gate.
GATED_TOON='run:
  id: "01EXAMPLE"
  branch: fm/example
  status: running
  head: abc1234
  findings: "2 blocking"
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,20
    rebase,completed,0,500
    review,awaiting_approval,2,60000
    test,pending,0,0'
OUT=$(classify "$GATED_TOON")
[ "$OUT" = gate ] || fail "gated step: expected 'gate' despite top-level status:running, got '$OUT'"
pass "3. step gated at awaiting_approval classifies as gate even though top-level status is running"

# --- 4. fix_review step gate --------------------------------------------
FIX_REVIEW_TOON='run:
  id: "01EXAMPLE2"
  branch: fm/example
  status: running
  head: abc1234
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,20
    review,fix_review,1,9000'
OUT=$(classify "$FIX_REVIEW_TOON")
[ "$OUT" = gate ] || fail "fix_review step: expected 'gate', got '$OUT'"
pass "4. step gated at fix_review classifies as gate"

# --- 5. top-level status itself is awaiting_approval ----------------------
TOP_GATE_TOON='run:
  id: "01EXAMPLE3"
  branch: fm/example
  status: awaiting_approval
  head: abc1234'
OUT=$(classify "$TOP_GATE_TOON")
[ "$OUT" = gate ] || fail "top-level awaiting_approval: expected 'gate', got '$OUT'"
pass "5. top-level status:awaiting_approval classifies as gate"

# --- 6. awaiting_agent line signals a gate regardless of status wording ---
AWAITING_AGENT_TOON='run:
  id: "01EXAMPLE4"
  branch: fm/example
  status: running
  awaiting_agent: claude
  head: abc1234'
OUT=$(classify "$AWAITING_AGENT_TOON")
[ "$OUT" = gate ] || fail "awaiting_agent line: expected 'gate', got '$OUT'"
pass "6. awaiting_agent line classifies as gate"

# --- 7. no run / no output at all: falls through to running (safe default,
# meaning "nothing to act on yet, poll again"), never a false gate/outcome ---
OUT=$(classify "")
[ "$OUT" = running ] || fail "empty input: expected 'running', got '$OUT'"
pass "7. empty status output classifies as running, not a false gate or outcome"

# --- 8. failed/cancelled terminal status without an explicit outcome line -
FAILED_TOON='run:
  id: "01EXAMPLE5"
  branch: fm/example
  status: failed
  head: abc1234'
OUT=$(classify "$FAILED_TOON")
[ "$OUT" = "outcome:failed" ] || fail "failed status: expected 'outcome:failed', got '$OUT'"
pass "8. top-level status:failed classifies as outcome:failed"

# --- 9. --help exits 0 with usage text -------------------------------------
OUT=$("$SCRIPT" --help)
RC=$?
expect_code 0 "$RC" "help exit code"
assert_contains "$OUT" "Usage:" "help: expected usage text"
pass "9. --help exits 0 with usage text"

# --- 10. wait: bounded poll loop against a fake no-mistakes, transitions
# from running -> gate across two polls, and returns well inside a short
# --max window (proving it never spins past its own bound).
TMP_ROOT=$(fm_test_tmproot fm-nomistakes-poll-lib)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
STATE_FILE="$TMP_ROOT/state"
printf '0\n' > "$STATE_FILE"
cat > "$FAKEBIN/no-mistakes" <<EOF
#!/usr/bin/env bash
state_file="$STATE_FILE"
n=\$(cat "\$state_file")
n=\$((n + 1))
printf '%s\n' "\$n" > "\$state_file"
if [ "\$n" -lt 2 ]; then
  printf '%s\n' "$RUNNING_TOON"
else
  printf '%s\n' "$GATED_TOON"
fi
EOF
chmod +x "$FAKEBIN/no-mistakes"
OUT=$(PATH="$FAKEBIN:$PATH" "$SCRIPT" wait --dir "$TMP_ROOT" --interval 1 --max 30 2>"$TMP_ROOT/err")
RC=$?
expect_code 0 "$RC" "wait: expected gate exit code"
assert_contains "$OUT" "01EXAMPLE" "wait: expected the gated run's TOON on stdout"
assert_grep "FM_NMPOLL_RESULT=gate" "$TMP_ROOT/err" "wait: expected FM_NMPOLL_RESULT=gate on stderr"
pass "10. wait polls through a running step and stops at the gate"

# --- 11. wait: returns 'running' (exit 2) once --max elapses with no gate
# or outcome yet, instead of spinning past its own bound ---
cat > "$FAKEBIN/no-mistakes" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$RUNNING_TOON"
EOF
chmod +x "$FAKEBIN/no-mistakes"
OUT=$(PATH="$FAKEBIN:$PATH" "$SCRIPT" wait --dir "$TMP_ROOT" --interval 1 --max 2 2>"$TMP_ROOT/err2")
RC=$?
expect_code 2 "$RC" "wait: expected still-running exit code once --max elapses"
assert_grep "FM_NMPOLL_RESULT=running" "$TMP_ROOT/err2" "wait: expected FM_NMPOLL_RESULT=running on timeout"
pass "11. wait returns running (exit 2) once --max elapses without a gate or outcome"

# --- 12. wait: refuses (exit 3, no FM_NMPOLL_RESULT=gate) when axi status
# only reports another branch's run, instead of acting on that run's gate ---
cat > "$FAKEBIN/no-mistakes" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$OTHER_BRANCH_TOON"
EOF
chmod +x "$FAKEBIN/no-mistakes"
OUT=$(PATH="$FAKEBIN:$PATH" "$SCRIPT" wait --dir "$TMP_ROOT" --interval 1 --max 5 2>"$TMP_ROOT/err3")
RC=$?
expect_code 3 "$RC" "wait: expected refusal exit code for other-branch-only status"
[ -z "$OUT" ] || fail "wait: other-branch run must not be printed as a result, got: $OUT"
assert_grep "FM_NMPOLL_RESULT=no-run" "$TMP_ROOT/err3" "wait: expected FM_NMPOLL_RESULT=no-run on stderr"
assert_grep "no run for the current branch" "$TMP_ROOT/err3" "wait: expected a diagnostic naming the missing current-branch run"
pass "12. wait refuses with exit 3 when only another branch's run is reported"

# --- 13. wait: a hung `axi status` is bounded and reported, never waited on
# past the helper's own status timeout ---
cat > "$FAKEBIN/no-mistakes" <<'EOF'
#!/usr/bin/env bash
sleep 60
EOF
chmod +x "$FAKEBIN/no-mistakes"
START=$SECONDS
OUT=$(PATH="$FAKEBIN:$PATH" FM_NMPOLL_STATUS_TIMEOUT_OVERRIDE=2 "$SCRIPT" wait --dir "$TMP_ROOT" --interval 1 --max 30 2>"$TMP_ROOT/err4")
RC=$?
ELAPSED=$((SECONDS - START))
expect_code 3 "$RC" "wait: expected error exit code for a hung status call"
[ "$ELAPSED" -lt 20 ] || fail "wait: hung status call was not bounded (took ${ELAPSED}s)"
assert_grep "timed out" "$TMP_ROOT/err4" "wait: expected a timeout diagnostic"
pass "13. wait bounds a hung axi status call and exits 3 with a diagnostic"

echo "ok: fm-nomistakes-poll-lib.test.sh"
