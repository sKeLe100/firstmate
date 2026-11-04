#!/usr/bin/env bash
# Behavior tests for bin/fm-test-run-stop.sh. Real process trees stand in for a
# hung no-mistakes test run: each fixture run directory holds a
# bin/fm-test-run.sh that sleeps, started in its own session so that its process
# group is the one the script must stop. A fake no-mistakes answers the run
# selection, and a fake ssh runs the PC02 walk against a fake PC02 home, so no
# real host is contacted.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The stop walks /proc and the fixtures need setsid, so the cases run only where
# Linux /proc exists. Elsewhere the skip is printed, never silent.
if [ ! -d /proc/self ] || ! command -v setsid >/dev/null 2>&1; then
  printf 'ok - skipped: needs Linux /proc and setsid\n'
  exit 0
fi

SCRIPT="$ROOT/bin/fm-test-run-stop.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-run-stop)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
ERRF="$TMP_ROOT/stderr"
FIXTURE_PIDS=()
LAST_PID=

# shellcheck disable=SC2329 # Reached from the EXIT cleanup trap.
reap_fixtures() {
  local pid
  for pid in ${FIXTURE_PIDS[@]+"${FIXTURE_PIDS[@]}"}; do
    kill -KILL -- "-$pid" 2>/dev/null || true
  done
}
trap 'reap_fixtures; fm_test_cleanup' EXIT

# 0 while pid $1 exists and is not a zombie.
proc_live() {
  local s
  [ -r "/proc/$1/status" ] || return 1
  s=$(sed -n 's/^State:[[:space:]]*//p' "/proc/$1/status" 2>/dev/null)
  case "$s" in
    ''|Z*) return 1 ;;
  esac
  return 0
}

# detach <command...>: starts the command in the background from a subshell that
# exits at once, so the command is reparented and this shell never reports its
# termination. Sets LAST_PID to the command's pid, and records it for cleanup.
PIDFILE_SEQ=0
detach() {
  local pidfile="$TMP_ROOT/pid.$PIDFILE_SEQ"
  PIDFILE_SEQ=$((PIDFILE_SEQ + 1))
  ( "$@" >/dev/null 2>&1 & echo "$!" > "$pidfile" )
  LAST_PID=$(cat "$pidfile")
  FIXTURE_PIDS+=("$LAST_PID")
}

# wait_cmdline <pid> <needle>: waits until the process's command line shows <needle>.
wait_cmdline() {
  local i
  for ((i = 0; i < 100; i++)); do
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q -- "$2" && return 0
    sleep 0.05
  done
  return 1
}

# start_run <run-dir> <body>: writes <run-dir>/bin/fm-test-run.sh with <body>
# and starts it from <run-dir> in its own session. Sets LAST_PID, which is the
# pid and the process group of the fixture.
start_run() {
  local dir=$1 body=$2
  mkdir -p "$dir/bin"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$dir/bin/fm-test-run.sh"
  # shellcheck disable=SC2016 # The single quotes pass $1 to the launched shell.
  detach setsid bash -c 'cd "$1" && exec bash "$1/bin/fm-test-run.sh"' _ "$dir"
  wait_cmdline "$LAST_PID" 'fm-test-run.sh' || fail "fixture in $dir did not start"
}

# Answers only `no-mistakes axi` with the overview named by FM_TEST_NM_OVERVIEW.
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = axi ]; then
  cat "$FM_TEST_NM_OVERVIEW"
  exit 0
fi
exit 1
SH
chmod +x "$FAKEBIN/no-mistakes"

# Runs the piped program on the fake PC02 home, recording the call.
cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_SSH_LOG"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
shift
HOME="$FM_TEST_PC02_HOME" exec "$@"
SH
chmod +x "$FAKEBIN/ssh"

# world <case>: one task (task-a) whose run is RUN-A-<case>, plus an unrelated
# run of another branch in the same no-mistakes home. Exports the environment
# the script reads and sets CASE_DIR, RUNA (task run directory) and RUNC (the
# unrelated run's directory).
world() {
  local c=$1
  CASE_DIR="$TMP_ROOT/$c"
  RUNA="$CASE_DIR/nm/worktrees/hash-$c/RUN-A-$c"
  RUNC="$CASE_DIR/nm/worktrees/hash-$c/RUN-C-$c"
  mkdir -p "$CASE_DIR/home/state" "$CASE_DIR/wt-a" "$RUNA" "$RUNC" "$CASE_DIR/pc02-home"
  printf 'branch=fm/task-a\nworktree=%s\n' "$CASE_DIR/wt-a" > "$CASE_DIR/home/state/task-a.meta"
  printf 'count: 2 of 2 total\nruns[2]{id,branch,status,head,pr}:\n  "RUN-A-%s",fm/task-a,running,abc1234,""\n  "RUN-C-%s",fm/other,running,abc1234,""\n' "$c" "$c" > "$CASE_DIR/overview"
  export FM_HOME="$CASE_DIR/home"
  export NM_HOME="$CASE_DIR/nm"
  export FM_TEST_NM_OVERVIEW="$CASE_DIR/overview"
  export FM_TEST_PC02_HOME="$CASE_DIR/pc02-home"
  export FM_TEST_SSH_LOG="$CASE_DIR/ssh.log"
  export FM_TEST_RUN_STOP_GRACE_SECS=2
  export FM_PC02_OFFLOAD_HOST=pc02
  export FM_PC02_OFFLOAD_REMOTE_BASE=.fm-pc02-test-offload
  export PATH="$FAKEBIN:$PATH"
}

# run_stop <args...>: sets OUT, ERR and RC.
run_stop() {
  OUT=$(bash "$SCRIPT" "$@" 2>"$ERRF")
  RC=$?
  ERR=$(cat "$ERRF")
}

test_refuses_bad_invocations() {
  world usage
  run_stop
  expect_code 2 "$RC" "no task id"
  run_stop task-a --host pc09
  expect_code 2 "$RC" "unknown host"
  run_stop no-such-task --host pc01
  expect_code 2 "$RC" "unknown task"
  assert_contains "$ERR" "no task record" "unknown task names the missing record"
  pass "refuses bad invocations with exit 2"
}

test_absent_run_reports_none() {
  world absent
  printf 'count: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  "RUN-C-absent",fm/other,running,abc1234,""\n' > "$CASE_DIR/overview"
  run_stop task-a --host pc01
  expect_code 0 "$RC" "no run for the branch"
  assert_equals "none" "$OUT" "no run prints none"
  pass "a branch with no run reports none"
}

test_ambiguous_run_selection_refuses() {
  world ambiguous
  start_run "$RUNA" 'sleep 300'
  local victim=$LAST_PID
  printf 'count: 2 of 2 total\nruns[2]{id,branch,status,head,pr}:\n  "RUN-A-ambiguous",fm/task-a,running,abc1234,""\n  "RUN-D-ambiguous",fm/task-a,running,abc1234,""\n' > "$CASE_DIR/overview"
  run_stop task-a --host pc01
  expect_code 2 "$RC" "two live runs for one branch"
  assert_contains "$ERR" "not unambiguous" "refusal names the ambiguous selection"
  proc_live "$victim" || fail "ambiguous selection must not stop anything"
  pass "an ambiguous run selection refuses and stops nothing"
}

test_stops_the_matched_group_and_spares_other_runs() {
  world matched
  start_run "$RUNA" 'sleep 300'
  local victim=$LAST_PID
  start_run "$RUNC" 'sleep 300'
  local other=$LAST_PID
  run_stop task-a --host pc01
  expect_code 0 "$RC" "stop of the task's run"
  assert_equals "pc01 group=$victim stopped=2 signal=TERM" "$OUT" "one line for the stopped group"
  proc_live "$victim" && fail "the task's run survived its stop"
  proc_live "$other" || fail "a run of another branch in another worktree was stopped"
  [ ! -e "$FM_TEST_SSH_LOG" ] || fail "--host pc01 must not contact PC02"
  pass "stops the task's run group and spares another worktree's run"
}

test_dry_run_changes_nothing() {
  world dryrun
  start_run "$RUNA" 'sleep 300'
  local victim=$LAST_PID
  run_stop task-a --host pc01 --dry-run
  expect_code 0 "$RC" "dry-run"
  assert_equals "dry-run pc01 group=$victim would-stop=2" "$OUT" "dry-run names the group"
  proc_live "$victim" || fail "dry-run stopped a process"
  pass "--dry-run lists the group and stops nothing"
}

test_escalates_to_kill_when_term_is_ignored() {
  world kill
  start_run "$RUNA" 'trap "" TERM; sleep 300'
  local victim=$LAST_PID
  run_stop task-a --host pc01
  expect_code 0 "$RC" "stop of a TERM-ignoring run"
  assert_equals "pc01 group=$victim stopped=2 signal=KILL" "$OUT" "KILL is reported after the grace"
  proc_live "$victim" && fail "KILL did not end the run"
  pass "KILLs a group that ignores TERM after the grace"
}

test_stops_orphans_of_the_run_group() {
  world orphan
  start_run "$RUNA" "( sleep 300 & echo \$! > '$RUNA/orphan.pid' ); sleep 300"
  local victim=$LAST_PID i
  for ((i = 0; i < 100; i++)); do
    [ -s "$RUNA/orphan.pid" ] && break
    sleep 0.05
  done
  local orphan
  orphan=$(cat "$RUNA/orphan.pid")
  proc_live "$orphan" || fail "fixture orphan did not start"
  run_stop task-a --host pc01
  expect_code 0 "$RC" "stop with an orphan in the group"
  assert_contains "$OUT" "pc01 group=$victim " "the group is reported"
  proc_live "$orphan" && fail "an orphan in the run's own group survived"
  pass "stops same-group orphans of the run"
}

test_spares_the_daemon_in_its_own_group() {
  world daemon
  local daemon_script="$CASE_DIR/fake-daemon.sh" daemon child i
  cat > "$daemon_script" <<'SH'
#!/usr/bin/env bash
# Stand-in for the no-mistakes daemon: a session leader with the test run as its child.
( cd "$FM_TEST_RUN_DIR" && exec setsid bash "$FM_TEST_RUN_DIR/bin/fm-test-run.sh" ) &
echo "$!" > "$FM_TEST_CHILD_PID"
sleep 300
SH
  mkdir -p "$RUNA/bin"
  printf '#!/usr/bin/env bash\nsleep 300\n' > "$RUNA/bin/fm-test-run.sh"
  # shellcheck disable=SC2016 # The single quotes pass $0 to the daemon shell.
  detach env FM_TEST_RUN_DIR="$RUNA" FM_TEST_CHILD_PID="$CASE_DIR/child.pid" \
    setsid bash -c 'exec -a "no-mistakes daemon run" bash "$0"' "$daemon_script"
  daemon=$LAST_PID
  wait_cmdline "$daemon" 'no-mistakes daemon run' || fail "fixture daemon did not start"
  for ((i = 0; i < 100; i++)); do
    [ -s "$CASE_DIR/child.pid" ] && break
    sleep 0.05
  done
  child=$(cat "$CASE_DIR/child.pid")
  proc_live "$child" || fail "fixture daemon did not start its test run"
  run_stop task-a --host pc01
  expect_code 0 "$RC" "stop beside a daemon"
  assert_contains "$OUT" "pc01 group=$child " "the test run's own group is stopped"
  proc_live "$child" && fail "the test run survived its stop"
  proc_live "$daemon" || fail "the no-mistakes daemon was stopped"
  pass "stops the test run and spares the daemon in its own group"
}

test_refuses_a_group_that_holds_the_daemon() {
  world shared
  local daemon_script="$CASE_DIR/fake-daemon.sh" daemon child i
  cat > "$daemon_script" <<'SH'
#!/usr/bin/env bash
# Stand-in for the no-mistakes daemon whose test run shares its group.
( cd "$FM_TEST_RUN_DIR" && exec bash "$FM_TEST_RUN_DIR/bin/fm-test-run.sh" ) &
echo "$!" > "$FM_TEST_CHILD_PID"
sleep 300
SH
  mkdir -p "$RUNA/bin"
  printf '#!/usr/bin/env bash\nsleep 300\n' > "$RUNA/bin/fm-test-run.sh"
  # shellcheck disable=SC2016 # The single quotes pass $0 to the daemon shell.
  detach env FM_TEST_RUN_DIR="$RUNA" FM_TEST_CHILD_PID="$CASE_DIR/child.pid" \
    setsid bash -c 'exec -a "no-mistakes daemon run" bash "$0"' "$daemon_script"
  daemon=$LAST_PID
  wait_cmdline "$daemon" 'no-mistakes daemon run' || fail "fixture daemon did not start"
  for ((i = 0; i < 100; i++)); do
    [ -s "$CASE_DIR/child.pid" ] && break
    sleep 0.05
  done
  child=$(cat "$CASE_DIR/child.pid")
  proc_live "$child" || fail "fixture daemon did not start its test run"
  run_stop task-a --host pc01
  expect_code 1 "$RC" "a group holding the daemon is refused"
  assert_equals "none" "$OUT" "nothing is reported as stopped"
  assert_contains "$ERR" "refused pc01 group $daemon" "refusal names the daemon's group"
  proc_live "$child" || fail "a refused group's test run was stopped"
  proc_live "$daemon" || fail "the no-mistakes daemon was stopped"
  pass "refuses a group that shares the no-mistakes daemon and stops nothing in it"
}

test_stops_the_pc02_offload_run_root() {
  world pc02
  local ck other_ck base root other
  base="$CASE_DIR/pc02-home/.fm-pc02-test-offload"
  ck=$(printf '%s' "$(cd "$RUNA" && pwd)" | cksum | cut -d' ' -f1)
  other_ck=$(printf '%s' "$CASE_DIR/some-other-run" | cksum | cut -d' ' -f1)
  root="$base/run-$ck-4242"
  start_run "$root/worktree" 'sleep 300'
  local victim=$LAST_PID
  printf '%s\n' "$victim" > "$root/pgid"
  other="$base/run-$other_ck-4243"
  start_run "$other/worktree" 'sleep 300'
  local unrelated=$LAST_PID
  printf '%s\n' "$unrelated" > "$other/pgid"
  run_stop task-a --host pc02 --dry-run
  expect_code 0 "$RC" "PC02 dry-run"
  assert_contains "$OUT" "dry-run pc02 group=$victim would-stop=2" "PC02 dry-run names the offload group"
  proc_live "$victim" || fail "PC02 dry-run stopped a process"
  run_stop task-a --host pc02
  expect_code 0 "$RC" "PC02 stop"
  assert_contains "$OUT" "pc02 group=$victim stopped=2 signal=TERM" "PC02 stop names the offload group"
  proc_live "$victim" && fail "the PC02 offload run survived its stop"
  proc_live "$unrelated" || fail "a PC02 run root of another run directory was stopped"
  assert_grep "bash -s" "$CASE_DIR/ssh.log" "PC02 was reached over the one bounded ssh call"
  pass "stops the PC02 offload run root it owns and spares the others"
}

test_stops_a_run_led_by_a_shell_wrapper() {
  world wrapped
  mkdir -p "$RUNA/bin"
  printf '#!/usr/bin/env bash\nsleep 300\n' > "$RUNA/bin/fm-test-run.sh"
  # The shell leads the group and stays as the run's parent, as the no-mistakes
  # test step launches it: the wrapper is a member of the run, not an outsider.
  # shellcheck disable=SC2016 # The single quotes pass $1 to the launched shell.
  detach setsid sh -c 'cd "$1" && bash "$1/bin/fm-test-run.sh" ; echo finished' _ "$RUNA"
  local victim=$LAST_PID
  wait_cmdline "$victim" 'fm-test-run.sh' || fail "shell-wrapped fixture did not start"
  run_stop task-a --host pc01
  expect_code 0 "$RC" "stop of a shell-wrapped run"
  assert_contains "$OUT" "pc01 group=$victim stopped=3 " "the wrapper, the run and its child form the group"
  proc_live "$victim" && fail "the shell-wrapped run survived its stop"
  pass "stops a run whose shell wrapper leads the group"
}

test_reports_none_when_nothing_runs() {
  world quiet
  run_stop task-a --host pc01
  expect_code 0 "$RC" "no run processes"
  assert_equals "none" "$OUT" "nothing to stop prints none"
  pass "prints none when no run process exists"
}

test_refuses_bad_invocations
test_absent_run_reports_none
test_ambiguous_run_selection_refuses
test_stops_the_matched_group_and_spares_other_runs
test_dry_run_changes_nothing
test_escalates_to_kill_when_term_is_ignored
test_stops_orphans_of_the_run_group
test_spares_the_daemon_in_its_own_group
test_refuses_a_group_that_holds_the_daemon
test_stops_the_pc02_offload_run_root
test_stops_a_run_led_by_a_shell_wrapper
test_reports_none_when_nothing_runs

echo "# all fm-test-run-stop tests passed"
