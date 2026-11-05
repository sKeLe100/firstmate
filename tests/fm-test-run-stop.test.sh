#!/usr/bin/env bash
# Behavior tests for bin/fm-test-run-stop.sh. Real process trees stand in for a
# hung no-mistakes test run: a fixture run directory holds a
# bin/fm-test-run.sh that sleeps. A fake no-mistakes answers the run selection
# and each run's status, and a fake ssh runs the PC02 walk against a fake PC02
# home, so no real host is contacted.
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
OFFLOAD="$ROOT/bin/fm-pc02-test-offload.sh"
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

# Process group of pid $1.
proc_pgid() {
  local line rest
  local -a f
  IFS= read -r line < "/proc/$1/stat" 2>/dev/null || return 1
  rest=${line##*) }
  read -r -a f <<< "$rest" || return 1
  printf '%s\n' "${f[2]}"
}

# wait_file <path>: waits until <path> exists and is not empty.
wait_file() {
  local i
  for ((i = 0; i < 100; i++)); do
    [ -s "$1" ] && return 0
    sleep 0.05
  done
  return 1
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

# write_run_script <run-dir> <body>: writes <run-dir>/bin/fm-test-run.sh with <body>.
write_run_script() {
  mkdir -p "$1/bin"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$1/bin/fm-test-run.sh"
}

# start_run <run-dir> <body>: writes the script and starts it from <run-dir> in
# its own session, so its pid is also its process group. Sets LAST_PID.
start_run() {
  local dir=$1
  write_run_script "$dir" "$2"
  # shellcheck disable=SC2016 # The single quotes pass $1 to the launched shell.
  detach setsid bash -c 'cd "$1" && exec bash "$1/bin/fm-test-run.sh"' _ "$dir"
  wait_cmdline "$LAST_PID" 'fm-test-run.sh' || fail "fixture in $dir did not start"
}

# Answers the run overview and each run's status from the fixture case files.
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = axi ]; then
  cat "$FM_TEST_NM_OVERVIEW"
  exit 0
fi
if [ "$#" -eq 4 ] && [ "$1" = axi ] && [ "$2" = status ] && [ "$3" = --run ]; then
  status_file="$FM_TEST_NM_STATUS_DIR/$4"
  [ -r "$status_file" ] || exit 1
  printf 'id: "%s"\nstatus: %s\noutcome:\n' "$4" "$(cat "$status_file")"
  exit 0
fi
exit 1
SH
chmod +x "$FAKEBIN/no-mistakes"

# Runs the piped program on the fake PC02 home, recording the call. A failing
# host is a nonzero ssh exit, as an unreachable PC02 is.
cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_SSH_LOG"
if [ "${FM_TEST_SSH_FAIL:-0}" = 1 ]; then
  echo "ssh: connect to host pc02 port 22: Connection refused" >&2
  exit 255
fi
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

# pc02_prefix <local-run-root> <remote-base>: the offload owner's run-root
# prefix for that local root.
pc02_prefix() {
  FM_PC02_OFFLOAD_REMOTE_BASE=$2 bash "$OFFLOAD" --remote-run-prefix "$1"
}

# world <case>: one task (task-a) whose run is RUN-A-<case>, plus an unrelated
# run of another branch in the same no-mistakes home. Exports the environment
# the script reads and sets CASE_DIR, RUNA (task run directory) and RUNC (the
# unrelated run's directory).
world() {
  local c=$1
  CASE_DIR="$TMP_ROOT/$c"
  RUNA="$CASE_DIR/nm/worktrees/hash-$c/RUN-A-$c"
  RUNC="$CASE_DIR/nm/worktrees/hash-$c/RUN-C-$c"
  mkdir -p "$CASE_DIR/home/state" "$CASE_DIR/wt-a" "$RUNA" "$RUNC" \
    "$CASE_DIR/pc02-home" "$CASE_DIR/status"
  printf 'branch=fm/task-a\nworktree=%s\n' "$CASE_DIR/wt-a" > "$CASE_DIR/home/state/task-a.meta"
  printf 'count: 2 of 2 total\nruns[2]{id,branch,status,head,pr}:\n  "RUN-A-%s",fm/task-a,running,abc1234,""\n  "RUN-C-%s",fm/other,running,abc1234,""\n' "$c" "$c" > "$CASE_DIR/overview"
  printf 'running\n' > "$CASE_DIR/status/RUN-A-$c"
  printf 'running\n' > "$CASE_DIR/status/RUN-C-$c"
  export FM_HOME="$CASE_DIR/home"
  export NM_HOME="$CASE_DIR/nm"
  export FM_TEST_NM_OVERVIEW="$CASE_DIR/overview"
  export FM_TEST_NM_STATUS_DIR="$CASE_DIR/status"
  export FM_TEST_PC02_HOME="$CASE_DIR/pc02-home"
  export FM_TEST_SSH_LOG="$CASE_DIR/ssh.log"
  export FM_TEST_SSH_FAIL=0
  export FM_TEST_RUN_STOP_GRACE_SECS=2
  export FM_PC02_OFFLOAD_HOST=pc02
  export FM_PC02_OFFLOAD_REMOTE_BASE=.fm-pc02-test-offload
  export PATH="$FAKEBIN:$PATH"
}

# first_line <text>: the first line of <text>.
first_line() {
  printf '%s\n' "$1" | head -n 1
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
  run_stop task-a --help
  expect_code 0 "$RC" "--help"
  assert_contains "$OUT" "Ending the whole run stays" "--help prints the two abort paths"
  assert_contains "$OUT" "no-mistakes axi abort" "--help names the owned whole-run abort"
  assert_contains "$OUT" "mode=group|pid" "--help prints the output contract"
  pass "refuses bad invocations with exit 2 and prints the header for --help"
}

test_refuses_when_no_run_is_active() {
  world noactive
  start_run "$RUNA" 'sleep 300'
  local victim=$LAST_PID
  printf 'completed\n' > "$FM_TEST_NM_STATUS_DIR/RUN-A-noactive"
  run_stop task-a --host pc01
  expect_code 2 "$RC" "a terminal run is not active"
  assert_contains "$ERR" "no active" "the refusal names the missing active run"
  proc_live "$victim" || fail "a refusal stopped the run's processes"

  world norun
  printf 'count: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  "RUN-C-norun",fm/other,running,abc1234,""\n' > "$CASE_DIR/overview"
  run_stop task-a --host pc01
  expect_code 2 "$RC" "no run for the branch"
  assert_contains "$ERR" "no active" "the refusal covers a branch with no run at all"
  pass "refuses with exit 2 when no run is active"
}

test_refuses_two_active_runs() {
  world ambiguous
  start_run "$RUNA" 'sleep 300'
  local victim=$LAST_PID
  mkdir -p "$CASE_DIR/nm/worktrees/hash-ambiguous/RUN-D-ambiguous"
  printf 'count: 3 of 3 total\nruns[3]{id,branch,status,head,pr}:\n  "RUN-E-ambiguous",fm/task-a,completed,abc1234,""\n  "RUN-A-ambiguous",fm/task-a,running,abc1234,""\n  "RUN-D-ambiguous",fm/task-a,running,abc1234,""\n' > "$CASE_DIR/overview"
  printf 'completed\n' > "$FM_TEST_NM_STATUS_DIR/RUN-E-ambiguous"
  printf 'running\n' > "$FM_TEST_NM_STATUS_DIR/RUN-D-ambiguous"
  run_stop task-a --host pc01
  expect_code 2 "$RC" "two active runs for one branch"
  assert_contains "$ERR" "active no-mistakes runs" "the refusal names the ambiguity"
  proc_live "$victim" || fail "an ambiguous selection must not stop anything"
  pass "refuses an ambiguous active run selection and stops nothing"
}

test_stops_the_real_launch_shape() {
  world real
  local agent daemon leader sshpid
  mkdir -p "$RUNA/bin" "$RUNA/tmp"
  cat > "$RUNA/bin/fm-test-run.sh" <<'SH'
#!/usr/bin/env bash
here=$(cd "$(dirname "$0")/.." && pwd)
setsid bash -c 'cd "$1" && exec -a ssh sleep 300' _ "$here/tmp" &
echo "$!" > "$here/tmp/ssh.pid"
sleep 300
SH
  cat > "$CASE_DIR/daemon.sh" <<'SH'
#!/usr/bin/env bash
setsid sh -c '{ printf 1000 > /proc/self/oom_score_adj; } 2>/dev/null; cd "$1" && exec bash "$1/bin/fm-test-run.sh" --changed' _ "$FM_TEST_RUN_DIR" &
echo "$!" > "$FM_TEST_CHILD_PID"
sleep 300
SH
  cat > "$CASE_DIR/agent.sh" <<'SH'
#!/usr/bin/env bash
( exec -a "no-mistakes daemon run" bash "$1" ) &
echo "$!" > "$2"
sleep 300
SH
  # shellcheck disable=SC2016 # The single quotes pass the paths as arguments.
  detach env FM_TEST_RUN_DIR="$RUNA" FM_TEST_CHILD_PID="$CASE_DIR/leader.pid" \
    setsid bash -c 'exec -a "claude --print test-agent" bash "$1" "$2" "$3"' _ \
    "$CASE_DIR/agent.sh" "$CASE_DIR/daemon.sh" "$CASE_DIR/daemon.pid"
  agent=$LAST_PID
  wait_cmdline "$agent" 'test-agent' || fail "fixture test agent did not start"
  wait_file "$CASE_DIR/daemon.pid" || fail "fixture agent did not start the daemon"
  daemon=$(cat "$CASE_DIR/daemon.pid")
  wait_file "$CASE_DIR/leader.pid" || fail "fixture daemon did not start the run leader"
  leader=$(cat "$CASE_DIR/leader.pid")
  wait_cmdline "$leader" 'fm-test-run.sh' || fail "fixture leader did not start the test run"
  wait_file "$RUNA/tmp/ssh.pid" || fail "fixture run did not start its fake ssh"
  sshpid=$(cat "$RUNA/tmp/ssh.pid")
  FIXTURE_PIDS+=("$leader" "$sshpid")
  proc_live "$daemon" || fail "fixture daemon is not live"
  proc_live "$agent" || fail "fixture test agent is not live"
  assert_equals "$leader" "$(proc_pgid "$leader")" "the leader leads its own process group"
  assert_not_equals "$leader" "$(proc_pgid "$sshpid")" "the hung descendant has a different process group"

  run_stop task-a --host pc01
  expect_code 0 "$RC" "stop of the 2026-11-04 launch shape"
  assert_contains "$OUT" "pc01 group=$leader stopped=2 signal=TERM mode=group" "the run leader's group is stopped"
  assert_contains "$OUT" "pc01 group=$sshpid stopped=1 signal=TERM mode=group" "the hung descendant in another group is stopped"
  proc_live "$leader" && fail "the run leader survived"
  proc_live "$sshpid" && fail "a hung descendant in another process group survived"
  proc_live "$daemon" || fail "the no-mistakes daemon was stopped"
  proc_live "$agent" || fail "the LLM test agent was stopped"
  assert_contains "$OUT" "run RUN-A-real status=running" "the run's own status follows the stop lines"
  pass "stops the real launch shape's tree, including a descendant in another group"
}

test_stops_outsider_group_members_by_pid() {
  world shared
  local daemon agent child
  write_run_script "$RUNA" 'sleep 300'
  cat > "$CASE_DIR/daemon.sh" <<'SH'
#!/usr/bin/env bash
cd "$FM_TEST_RUN_DIR" || exit 1
( exec -a "claude --print test-agent" sleep 300 ) &
echo "$!" > "$FM_TEST_AGENT_PID"
bash "$FM_TEST_RUN_DIR/bin/fm-test-run.sh" &
echo "$!" > "$FM_TEST_CHILD_PID"
sleep 300
SH
  # shellcheck disable=SC2016 # The single quotes pass $0 to the daemon shell.
  detach env FM_TEST_RUN_DIR="$RUNA" FM_TEST_AGENT_PID="$CASE_DIR/agent.pid" \
    FM_TEST_CHILD_PID="$CASE_DIR/run.pid" \
    setsid bash -c 'exec -a "no-mistakes daemon run" bash "$0"' "$CASE_DIR/daemon.sh"
  daemon=$LAST_PID
  wait_file "$CASE_DIR/run.pid" || fail "fixture daemon did not start the run"
  child=$(cat "$CASE_DIR/run.pid")
  wait_file "$CASE_DIR/agent.pid" || fail "fixture daemon did not start the test agent"
  agent=$(cat "$CASE_DIR/agent.pid")
  FIXTURE_PIDS+=("$child" "$agent")
  wait_cmdline "$child" 'fm-test-run.sh' || fail "fixture run did not start"
  assert_equals "$daemon" "$(proc_pgid "$child")" "the run shares the daemon's process group"
  assert_equals "$daemon" "$(proc_pgid "$agent")" "the test agent shares the daemon's process group"

  run_stop task-a --host pc01
  expect_code 0 "$RC" "stop of a run sharing the daemon's group"
  assert_contains "$OUT" "pc01 group=$daemon stopped=2 signal=TERM mode=pid" "only the run members are signalled"
  proc_live "$child" && fail "the run survived"
  proc_live "$daemon" || fail "the no-mistakes daemon was stopped"
  proc_live "$agent" || fail "the LLM test agent was stopped"
  pass "stops run members by pid in a group that also holds the daemon and the test agent"
}

test_stops_the_older_active_run_not_the_newest_row() {
  world older
  start_run "$RUNA" 'sleep 300'
  local victim=$LAST_PID newer="$CASE_DIR/nm/worktrees/hash-older/RUN-N-older"
  mkdir -p "$newer"
  printf 'count: 2 of 2 total\nruns[2]{id,branch,status,head,pr}:\n  "RUN-N-older",fm/task-a,completed,abc1234,""\n  "RUN-A-older",fm/task-a,running,abc1234,""\n' > "$CASE_DIR/overview"
  printf 'completed\n' > "$FM_TEST_NM_STATUS_DIR/RUN-N-older"
  run_stop task-a --host pc01
  expect_code 0 "$RC" "the older live run is the active one"
  assert_contains "$OUT" "pc01 group=$victim " "the older active run's group is stopped"
  proc_live "$victim" && fail "the older active run survived"
  assert_contains "$OUT" "run RUN-A-older status=running" "the active run's own status is reported"
  pass "acts on the older live run, not the newest terminal row"
}

test_stops_the_matched_group_and_spares_other_runs() {
  world matched
  start_run "$RUNA" 'sleep 300'
  local victim=$LAST_PID
  start_run "$RUNC" 'sleep 300'
  local other=$LAST_PID
  run_stop task-a --host pc01
  expect_code 0 "$RC" "stop of the task's run"
  assert_equals "pc01 group=$victim stopped=2 signal=TERM mode=group" "$(first_line "$OUT")" "one line for the stopped group"
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
  assert_equals "dry-run pc01 group=$victim would-stop=2 mode=group" "$OUT" "dry-run names the group"
  proc_live "$victim" || fail "dry-run stopped a process"
  pass "--dry-run lists the group and stops nothing"
}

test_escalates_to_kill_when_term_is_ignored() {
  world kill
  start_run "$RUNA" 'trap "" TERM; sleep 300'
  local victim=$LAST_PID
  run_stop task-a --host pc01
  expect_code 0 "$RC" "stop of a TERM-ignoring run"
  assert_equals "pc01 group=$victim stopped=2 signal=KILL mode=group" "$(first_line "$OUT")" "KILL is reported after the grace"
  proc_live "$victim" && fail "KILL did not end the run"
  pass "KILLs a group that ignores TERM after the grace"
}

test_stops_orphans_of_the_run_group() {
  world orphan
  start_run "$RUNA" "( sleep 300 & echo \$! > '$RUNA/orphan.pid' ); sleep 300"
  local victim=$LAST_PID orphan
  wait_file "$RUNA/orphan.pid" || fail "fixture orphan did not start"
  orphan=$(cat "$RUNA/orphan.pid")
  FIXTURE_PIDS+=("$orphan")
  proc_live "$orphan" || fail "fixture orphan is not live"
  assert_equals "$victim" "$(proc_pgid "$orphan")" "the orphan stayed in the run's group"
  run_stop task-a --host pc01
  expect_code 0 "$RC" "stop with an orphan in the group"
  assert_equals "pc01 group=$victim stopped=3 signal=TERM mode=group" "$(first_line "$OUT")" "the run's own group is stopped whole"
  proc_live "$orphan" && fail "an orphan in the run's own group survived"
  pass "stops same-group orphans of the run"
}

test_stops_a_run_led_by_a_shell_wrapper() {
  world wrapped
  write_run_script "$RUNA" 'sleep 300'
  # The shell leads the group and stays as the run's parent, as the no-mistakes
  # test step launches it: the wrapper is a member of the run, not an outsider.
  # shellcheck disable=SC2016 # The single quotes pass $1 to the launched shell.
  detach setsid sh -c 'cd "$1" && bash "$1/bin/fm-test-run.sh" ; echo finished' _ "$RUNA"
  local victim=$LAST_PID
  wait_cmdline "$victim" 'fm-test-run.sh' || fail "shell-wrapped fixture did not start"
  run_stop task-a --host pc01
  expect_code 0 "$RC" "stop of a shell-wrapped run"
  assert_equals "pc01 group=$victim stopped=3 signal=TERM mode=group" "$(first_line "$OUT")" "the wrapper, the run and its child form the group"
  proc_live "$victim" && fail "the shell-wrapped run survived its stop"
  pass "stops a run whose shell wrapper leads the group"
}

test_reports_none_when_nothing_runs() {
  world quiet
  run_stop task-a --host pc01
  expect_code 0 "$RC" "no run processes"
  assert_contains "$OUT" "none" "nothing to stop prints none"
  assert_contains "$OUT" "run RUN-A-quiet status=running" "the run's status is still reported"
  pass "prints none when no run process exists"
}

test_stops_the_pc02_offload_run_root() {
  world pc02
  local base_rel=roots-here prefix expected root victim other_root other marker
  export FM_PC02_OFFLOAD_REMOTE_BASE=$base_rel
  prefix=$(pc02_prefix "$RUNA" "$base_rel")
  expected="$base_rel/run-$(printf '%s' "$(cd "$RUNA" && pwd)" | cksum | cut -d' ' -f1)-"
  assert_equals "$expected" "$prefix" "the offload owner names the run root by the documented contract"
  root="$CASE_DIR/pc02-home/${prefix}4242"
  start_run "$root/worktree" 'sleep 300'
  victim=$LAST_PID
  printf '%s\n' "$victim" > "$root/pgid"
  marker="$root/keep.txt"
  : > "$marker"
  : > "$RUNA/keep.txt"
  other_root="$CASE_DIR/pc02-home/$base_rel/run-$(printf '%s' "$CASE_DIR/some-other-run" | cksum | cut -d' ' -f1)-4243"
  start_run "$other_root/worktree" 'sleep 300'
  other=$LAST_PID
  printf '%s\n' "$other" > "$other_root/pgid"
  run_stop task-a --host pc02 --dry-run
  expect_code 0 "$RC" "PC02 dry-run"
  assert_contains "$OUT" "dry-run pc02 group=$victim would-stop=2 mode=group" "PC02 dry-run names the offload group"
  proc_live "$victim" || fail "PC02 dry-run stopped a process"
  run_stop task-a --host pc02
  expect_code 0 "$RC" "PC02 stop"
  assert_contains "$OUT" "pc02 group=$victim stopped=2 signal=TERM mode=group" "PC02 stop names the offload group"
  assert_contains "$OUT" "run RUN-A-pc02 status=running" "the run's status follows the stop lines"
  proc_live "$victim" && fail "the PC02 offload run survived its stop"
  proc_live "$other" || fail "a PC02 run root of another run directory was stopped"
  assert_grep "bash -s" "$CASE_DIR/ssh.log" "PC02 was reached over the one bounded ssh call"
  [ -e "$marker" ] || fail "the stop removed a file from the PC02 run root"
  [ -e "$RUNA/keep.txt" ] || fail "the stop removed a file from the local run directory"
  pass "stops the PC02 offload run root the owner names, spares the others, and removes nothing"
}

test_pc02_probe_failure_is_reported() {
  world probe
  start_run "$RUNA" 'sleep 300'
  local victim=$LAST_PID
  export FM_TEST_SSH_FAIL=1
  run_stop task-a --host pc02
  export FM_TEST_SSH_FAIL=0
  expect_code 1 "$RC" "a failing PC02 check"
  assert_contains "$OUT" "pc02 unknown" "an unconfirmed PC02 says so on stdout"
  assert_contains "$ERR" "PC02 check exited 255" "the failure is diagnosed on stderr"
  proc_live "$victim" || fail "--host pc02 must not stop PC01 processes"
  pass "reports an unconfirmed PC02 instead of a clean none"
}

test_pc02_reports_none_without_a_claim() {
  world pc02quiet
  run_stop task-a --host pc02
  expect_code 0 "$RC" "PC02 with no root and no claim"
  assert_equals "none" "$(first_line "$OUT")" "no root and no claim prints none"
  assert_contains "$OUT" "run RUN-A-pc02quiet status=running" "the run's status is still reported"
  pass "prints none only when PC02 has no root and no claim"
}

test_pc02_claim_without_root_reports_unknown() {
  world claim
  local client
  # shellcheck disable=SC2016 # The single quotes pass $1 to the launched shell.
  detach setsid bash -c 'cd "$1" && exec -a "$1/bin/fm-pc02-test-offload.sh" sleep 300' _ "$RUNA"
  client=$LAST_PID
  wait_cmdline "$client" 'fm-pc02-test-offload.sh' || fail "fixture offload client did not start"
  run_stop task-a --host pc02
  expect_code 1 "$RC" "a PC02 claim with no run root"
  assert_contains "$OUT" "pc02 unknown" "a claim with no root prints pc02 unknown"
  proc_live "$client" || fail "--host pc02 must not stop the PC01 offload client"
  pass "reports an unconfirmed PC02 when an offload client claims the run"
}

test_default_invocation_checks_both_hosts() {
  world twohost
  local victim pc02_victim prefix root
  start_run "$RUNA" 'sleep 300'
  victim=$LAST_PID
  prefix=$(pc02_prefix "$RUNA" .fm-pc02-test-offload)
  root="$CASE_DIR/pc02-home/${prefix}777"
  start_run "$root/worktree" 'sleep 300'
  pc02_victim=$LAST_PID
  printf '%s\n' "$pc02_victim" > "$root/pgid"
  run_stop task-a
  expect_code 0 "$RC" "default two-host invocation"
  assert_contains "$OUT" "pc01 group=$victim " "the default invocation stops PC01"
  assert_contains "$OUT" "pc02 group=$pc02_victim " "the default invocation stops PC02"
  proc_live "$victim" && fail "PC01 survived the default invocation"
  proc_live "$pc02_victim" && fail "PC02 survived the default invocation"
  assert_equals "run RUN-A-twohost status=running" "$(printf '%s\n' "$OUT" | tail -n 1)" "the run status is the last line"
  pass "the default invocation checks and stops both hosts"
}

test_default_invocation_with_a_claim_stops_the_pc02_root_first() {
  world claimfirst
  local client victim pc02_victim prefix root
  start_run "$RUNA" 'sleep 300'
  victim=$LAST_PID
  # A PC01 offload client of the run directory: the PC01 pass would kill it, and
  # its exit trap would then remove the PC02 mirror before a later walk.
  # shellcheck disable=SC2016 # The single quotes pass $1 to the launched shell.
  detach setsid bash -c 'cd "$1" && exec -a "$1/bin/fm-pc02-test-offload.sh" sleep 300' _ "$RUNA"
  client=$LAST_PID
  wait_cmdline "$client" 'fm-pc02-test-offload.sh' || fail "fixture offload client did not start"
  prefix=$(pc02_prefix "$RUNA" .fm-pc02-test-offload)
  root="$CASE_DIR/pc02-home/${prefix}777"
  start_run "$root/worktree" 'sleep 300'
  pc02_victim=$LAST_PID
  printf '%s\n' "$pc02_victim" > "$root/pgid"
  run_stop task-a
  expect_code 0 "$RC" "a claimed default run stops both hosts"
  assert_contains "$OUT" "pc02 group=$pc02_victim " "the PC02 root is stopped while its mirror still exists"
  assert_not_contains "$OUT" "pc02 unknown" "a claim with a live root is not unknown"
  proc_live "$pc02_victim" && fail "PC02 survived the claimed stop"
  proc_live "$victim" && fail "PC01 survived the claimed stop"
  proc_live "$client" && fail "the PC01 offload client survived the claimed stop"
  pass "stops the PC02 root before the PC01 pass removes its mirror"
}

test_refuses_bad_invocations
test_refuses_when_no_run_is_active
test_refuses_two_active_runs
test_stops_the_real_launch_shape
test_stops_outsider_group_members_by_pid
test_stops_the_older_active_run_not_the_newest_row
test_stops_the_matched_group_and_spares_other_runs
test_dry_run_changes_nothing
test_escalates_to_kill_when_term_is_ignored
test_stops_orphans_of_the_run_group
test_stops_a_run_led_by_a_shell_wrapper
test_reports_none_when_nothing_runs
test_stops_the_pc02_offload_run_root
test_pc02_probe_failure_is_reported
test_pc02_reports_none_without_a_claim
test_pc02_claim_without_root_reports_unknown
test_default_invocation_checks_both_hosts
test_default_invocation_with_a_claim_stops_the_pc02_root_first

echo "# all fm-test-run-stop tests passed"
