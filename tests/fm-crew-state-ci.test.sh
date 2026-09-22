#!/usr/bin/env bash
# CI-monitoring state reconciliation tests for bin/fm-crew-state.sh.
#
# A run parked at the ci step (or a top-level ci status) must reconcile against
# the crew's own status log and the ci step's log tail: a green-but-still-
# monitoring run reads done, a fresh re-arm stays working, and a ci poll that
# keeps failing wedges only on repeated real errors rather than transient ones.
# Split from fm-crew-state.test.sh to stay under the test-size ceiling.

# TMP_ROOT and the FM_FAKE_* variables are read by the sourced
# fm-crew-state-lib.sh harness (new_case and the fake binaries); shellcheck
# cannot see those reads across the source boundary.
# shellcheck disable=SC2034
set -u

# shellcheck source=tests/fm-crew-state-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-crew-state-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-crew-state-ci)
fm_git_identity fmtest fmtest@example.invalid
test_ci_ready_done_log_beats_monitoring_run() {
  reset_fakes
  local d; d=$(new_case ci-ready)
  make_repo_on_branch "$d/wt" fm/feat-ci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci.meta" "window=fm:fm-feat-ci" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-ci.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ci)"
  local out; out=$(run_crew_state "$d" feat-ci)
  assert_contains "$out" "state: done" "ci-ready status log -> done"
  assert_contains "$out" "source: status-log" "ci-ready state comes from the status log"
  assert_contains "$out" "checks green" "ci-ready detail preserves the report"
  assert_not_contains "$out" "state: working" "ci-ready is not hidden by monitoring run"
  pass "ci-ready status log beats monitoring run"
}

# Regression for the PR #252 incident: the crew's own status log never got a
# "done: ... checks green" line (log_reports_ci_ready above does not apply),
# but the ci step's log tail shows CI is actually green and only waiting on
# merge/close. fm-crew-state must surface this as done, not "validating
# (running)", so a green PR is never silently absorbed as still-in-progress.
test_ci_monitoring_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-green)
  make_repo_on_branch "$d/wt" fm/feat-cigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cigreen.meta" "window=fm:fm-feat-cigreen" "worktree=$d/wt" "kind=ship"
  # No status-log line at all: the crew never reported its own checks-green line.
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cigreen)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
CI checks running, waiting for results...
all CI checks passed - still monitoring until merged or closed
EOF
)
  local out; out=$(run_crew_state "$d" feat-cigreen)
  assert_contains "$out" "state: done" "green ci-monitor run -> done"
  assert_contains "$out" "source: run-step" "green ci-monitor -> run-step source"
  assert_contains "$out" "checks green" "green ci-monitor detail mentions checks green"
  assert_not_contains "$out" "state: working" "green ci-monitor must not read as still validating"
  pass "ci-monitoring run with checks already green surfaces done"
}

test_top_level_ci_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case top-level-ci-green)
  make_repo_on_branch "$d/wt" fm/feat-topcigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topcigreen.meta" "window=fm:fm-feat-topcigreen" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_top_level_ci fm/feat-topcigreen)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topcigreen)
  assert_contains "$out" "state: done" "top-level ci with green log -> done"
  assert_contains "$out" "source: run-step" "top-level ci green -> run-step source"
  assert_contains "$out" "checks green" "top-level ci green detail mentions checks green"
  assert_not_contains "$out" "state: working" "top-level ci green must not stay working"
  pass "top-level ci status uses ci log green marker"
}

test_ci_monitoring_no_checks_terminal_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-nochecks)
  make_repo_on_branch "$d/wt" fm/feat-cinochecks
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecks.meta" "window=fm:fm-feat-cinochecks" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecks)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cinochecks)
  assert_contains "$out" "state: done" "terminal no-checks ci-monitor run -> done"
  assert_contains "$out" "checks green" "terminal no-checks ci-monitor detail mentions checks green"
  pass "terminal no-checks ci-monitor marker surfaces done"
}

test_ci_monitoring_green_then_rearm_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-rearm)
  make_repo_on_branch "$d/wt" fm/feat-cirearm
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirearm.meta" "window=fm:fm-feat-cirearm" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirearm)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirearm)
  assert_contains "$out" "state: working" "base-advance rearm marker -> working"
  assert_not_contains "$out" "state: done" "base-advance rearm marker must not read as done"
  assert_not_contains "$out" "checks green" "base-advance rearm marker must not read as checks green"
  pass "base-advance rearm after green stays working"
}

test_ci_monitoring_no_checks_yet_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-nochecks-yet)
  make_repo_on_branch "$d/wt" fm/feat-cinochecksyet
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecksyet.meta" "window=fm:fm-feat-cinochecksyet" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecksyet)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
no CI checks reported - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
no CI checks reported yet, waiting for checks to register...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cinochecksyet)
  assert_contains "$out" "state: working" "pending no-checks marker -> working"
  assert_not_contains "$out" "state: done" "pending no-checks marker must not read as done"
  assert_not_contains "$out" "checks green" "pending no-checks marker must not read as checks green"
  pass "pending no-checks ci-monitor marker stays working"
}

test_ci_monitoring_repeated_poll_failure_surfaces_wedge() {
  reset_fakes
  local d; d=$(new_case ci-wedge)
  make_repo_on_branch "$d/wt" fm/feat-ciwedge
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ciwedge.meta" "window=fm:fm-feat-ciwedge" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ciwedge)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
CI checks running, waiting for results...
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
EOF
)
  local out; out=$(run_crew_state "$d" feat-ciwedge)
  assert_contains "$out" "state: failed" "repeated identical poll failures -> failed"
  assert_contains "$out" "CI polling wedge" "wedge detail names the wedge"
  pass "repeated identical CI poll failures surface a wedge"
}

# Transient early poll failures followed by normal pending-checks polling are
# forward progress, not a wedge: the run must keep reading as working.
test_ci_monitoring_transient_errors_then_pending_not_wedged() {
  reset_fakes
  local d; d=$(new_case ci-transient)
  make_repo_on_branch "$d/wt" fm/feat-citransient
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-citransient.meta" "window=fm:fm-feat-citransient" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-citransient)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
no CI checks reported yet, waiting for checks to register...
no CI checks reported yet, waiting for checks to register...
EOF
)
  local out; out=$(run_crew_state "$d" feat-citransient)
  assert_contains "$out" "state: working" "transient errors then pending polling -> working"
  assert_not_contains "$out" "state: failed" "healthy pending run must not be reported failed"
  assert_not_contains "$out" "CI polling wedge" "healthy pending run must not be called a wedge"
  pass "transient poll errors followed by pending checks are not a wedge"
}

# A per-poll heartbeat emitted alongside every failing poll is not progress:
# interleaved (and trailing) heartbeat lines must not mask a real wedge.
test_ci_monitoring_interleaved_heartbeat_still_wedged() {
  reset_fakes
  local d; d=$(new_case ci-wedge-heartbeat)
  make_repo_on_branch "$d/wt" fm/feat-ciwedgehb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ciwedgehb.meta" "window=fm:fm-feat-ciwedgehb" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ciwedgehb)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
CI checks running, waiting for results...
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
CI checks running, waiting for results...
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
CI checks running, waiting for results...
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
CI checks running, waiting for results...
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
CI checks running, waiting for results...
EOF
)
  local out; out=$(run_crew_state "$d" feat-ciwedgehb)
  assert_contains "$out" "state: failed" "heartbeat interleaved with repeated failures -> failed"
  assert_contains "$out" "CI polling wedge" "trailing heartbeat must not mask the wedge"
  pass "per-poll heartbeats interleaved with repeated failures still wedge"
}

# A prefix that repeats early but is followed by real progress must not be
# reported as wedged just because some other error prefix trails the log.
test_ci_monitoring_repeated_errors_then_green_not_wedged() {
  reset_fakes
  local d; d=$(new_case ci-wedge-then-green)
  make_repo_on_branch "$d/wt" fm/feat-ciwedgegreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ciwedgegreen.meta" "window=fm:fm-feat-ciwedgegreen" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ciwedgegreen)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1
all CI checks passed - still monitoring until merged or closed
log: --verbose "gh pr view 36" exit status 1
EOF
)
  local out; out=$(run_crew_state "$d" feat-ciwedgegreen)
  assert_not_contains "$out" "CI polling wedge" "progress after the repeated prefix clears the wedge"
  assert_not_contains "$out" "state: failed" "green run must not be reported failed"
  pass "repeated errors followed by green progress are not a wedge"
}

# Regression: log lines carrying a trailing carriage return (captured gh
# output) must still re-match their own prefix, so the progress marker after
# them is seen and a green run is not reported as terminally wedged.
test_ci_monitoring_crlf_errors_then_green_not_wedged() {
  reset_fakes
  local d; d=$(new_case ci-wedge-crlf)
  make_repo_on_branch "$d/wt" fm/feat-cicrlf
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cicrlf.meta" "window=fm:fm-feat-cicrlf" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cicrlf)"
  local err; err=$(printf 'log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1\r')
  FM_FAKE_CI_LOGS=$(printf '%s\n%s\n%s\n%s\n%s\nall CI checks passed - still monitoring until merged or closed\n' \
    "$err" "$err" "$err" "$err" "$err")
  local out; out=$(run_crew_state "$d" feat-cicrlf)
  assert_not_contains "$out" "CI polling wedge" "CRLF errors followed by green are not a wedge"
  assert_not_contains "$out" "state: failed" "green run with CRLF errors must not be reported failed"
  pass "carriage-return-terminated poll errors re-match their own prefix"
}

# Regression: a log mixing CR-terminated and plain copies of the SAME failing
# poll must group into one prefix, so the split does not hide a real wedge.
test_ci_monitoring_mixed_line_endings_still_wedged() {
  reset_fakes
  local d; d=$(new_case ci-wedge-mixed-eol)
  make_repo_on_branch "$d/wt" fm/feat-cimixedeol
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cimixedeol.meta" "window=fm:fm-feat-cimixedeol" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cimixedeol)"
  local plain cr
  plain='log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1'
  cr=$(printf '%s\r' "$plain")
  FM_FAKE_CI_LOGS=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$cr" "$plain" "$cr" "$plain" "$cr" "$plain")
  local out; out=$(run_crew_state "$d" feat-cimixedeol)
  assert_contains "$out" "state: failed" "mixed line endings must not split one wedged prefix"
  assert_contains "$out" "CI polling wedge" "mixed-line-ending wedge is still detected"
  pass "mixed CR and plain copies of one failing poll still wedge"
}

# Regression: an error prefix that itself begins with digits (e.g. an HTTP
# status) must survive the count parse and still be recognized as a wedge.
test_ci_monitoring_numeric_error_prefix_still_wedged() {
  reset_fakes
  local d; d=$(new_case ci-wedge-numeric)
  make_repo_on_branch "$d/wt" fm/feat-cinumeric
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinumeric.meta" "window=fm:fm-feat-cinumeric" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinumeric)"
  local err='warning: could not check CI: 404 Not Found (HTTP 404)'
  FM_FAKE_CI_LOGS=$(printf '%s\n%s\n%s\n%s\n%s\n' "$err" "$err" "$err" "$err" "$err")
  local out; out=$(run_crew_state "$d" feat-cinumeric)
  assert_contains "$out" "state: failed" "numeric-leading error prefix -> failed"
  assert_contains "$out" "404 Not Found (HTTP 404)" "numeric-leading prefix is reported intact"
  pass "an error prefix starting with digits is preserved and wedges"
}

# A repo with no CI workflows logs the green "no CI checks reported - still
# monitoring" marker every poll; flaky poll errors among those lines must not
# turn that green run into a wedge.
test_ci_monitoring_no_checks_green_marker_not_wedged() {
  reset_fakes
  local d; d=$(new_case ci-wedge-nochecks)
  make_repo_on_branch "$d/wt" fm/feat-cinochecks
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecks.meta" "window=fm:fm-feat-cinochecks" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecks)"
  local err green
  err='log: --verbose "gh api repos/o/r/commits/abc/check-runs" exit status 1'
  green='no CI checks reported - still monitoring until merged or closed'
  FM_FAKE_CI_LOGS=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$green" "$err" "$green" "$err" "$green" "$err" "$green" "$err" "$green" "$err" "$green")
  local out; out=$(run_crew_state "$d" feat-cinochecks)
  assert_not_contains "$out" "CI polling wedge" "the no-checks green marker is progress, not heartbeat noise"
  assert_not_contains "$out" "state: failed" "a green no-checks run must not be reported failed"
  pass "flaky poll errors around the no-checks green marker are not a wedge"
}

test_ci_monitoring_still_waiting_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-waiting)
  make_repo_on_branch "$d/wt" fm/feat-ciwait
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ciwait.meta" "window=fm:fm-feat-ciwait" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ciwait)"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-ciwait)
  assert_contains "$out" "state: working" "ci step still red -> working"
  assert_not_contains "$out" "checks green" "no green marker present -> no checks-green detail"
  pass "ci-monitoring run with checks not yet green stays working"
}

# A later merge-conflict auto-fix round after an earlier green reading must
# not be masked: the MOST RECENT marker in the log tail wins.
test_ci_monitoring_green_then_new_issue_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-issue)
  make_repo_on_branch "$d/wt" fm/feat-cirelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirelapse.meta" "window=fm:fm-feat-cirelapse" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
issues detected: merge conflict - auto-fixing (attempt 2/10)...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirelapse)
  assert_contains "$out" "state: working" "a later relapse marker must win over an earlier green one"
  assert_not_contains "$out" "state: done" "relapsed ci run must not read as done"
  pass "a fresh issue after an earlier green reading is not masked"
}

test_ci_ready_done_log_relapse_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-ready-then-relapse)
  make_repo_on_branch "$d/wt" fm/feat-cireadyrelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cireadyrelapse.meta" "window=fm:fm-feat-cireadyrelapse" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cireadyrelapse.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cireadyrelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
CI checks running, waiting for results...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cireadyrelapse)
  assert_contains "$out" "state: working" "a stale ready status must not mask a later CI relapse"
  assert_contains "$out" "source: run-step" "relapsed ci run remains run-step sourced"
  assert_not_contains "$out" "state: done" "relapsed ci run with stale done log must not read as done"
  pass "stale checks-green status log does not mask CI relapse"
}

test_ci_fixing_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-fixing-after-green)
  make_repo_on_branch "$d/wt" fm/feat-cifixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cifixing.meta" "window=fm:fm-feat-cifixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cifixing.status"
  FM_FAKE_AXI_STATUS="$(run_ci_fixing fm/feat-cifixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cifixing)
  assert_contains "$out" "state: working" "ci fixing step must stay working"
  assert_contains "$out" "source: run-step" "ci fixing remains run-step sourced"
  assert_not_contains "$out" "state: done" "ci fixing must not read as checks-green done"
  pass "ci fixing is not overridden by an earlier green marker"
}

test_top_level_fixing_ci_running_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-ci-running)
  make_repo_on_branch "$d/wt" fm/feat-topfixingci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixingci.meta" "window=fm:fm-feat-topfixingci" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_fixing_ci_running fm/feat-topfixingci)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixingci)
  assert_contains "$out" "state: working" "top-level fixing with ci running must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing with ci running remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not use stale green marker"
  pass "top-level fixing is not overridden by a stale ci running row"
}

test_top_level_fixing_done_log_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-done-log)
  make_repo_on_branch "$d/wt" fm/feat-topfixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixing.meta" "window=fm:fm-feat-topfixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-topfixing.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-topfixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixing)
  assert_contains "$out" "state: working" "top-level fixing must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not read as stale checks-green done"
  pass "top-level fixing is not overridden by a stale done log"
}

test_ci_ready_done_log_beats_monitoring_run
test_ci_monitoring_checks_green_surfaces_done
test_top_level_ci_checks_green_surfaces_done
test_ci_monitoring_no_checks_terminal_surfaces_done
test_ci_monitoring_green_then_rearm_stays_working
test_ci_monitoring_no_checks_yet_stays_working
test_ci_monitoring_repeated_poll_failure_surfaces_wedge
test_ci_monitoring_transient_errors_then_pending_not_wedged
test_ci_monitoring_interleaved_heartbeat_still_wedged
test_ci_monitoring_repeated_errors_then_green_not_wedged
test_ci_monitoring_crlf_errors_then_green_not_wedged
test_ci_monitoring_mixed_line_endings_still_wedged
test_ci_monitoring_numeric_error_prefix_still_wedged
test_ci_monitoring_no_checks_green_marker_not_wedged
test_ci_monitoring_still_waiting_stays_working
test_ci_monitoring_green_then_new_issue_stays_working
test_ci_ready_done_log_relapse_stays_working
test_ci_fixing_after_green_stays_working
test_top_level_fixing_ci_running_after_green_stays_working
test_top_level_fixing_done_log_stays_working

echo "all fm-crew-state-ci tests passed"
