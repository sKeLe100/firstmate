#!/usr/bin/env bash
# Behavior tests for bin/fm-worker-memory-guard.sh: the per-worker memory scope
# prefix, the runaway-worker stop, and the brief install check. Real helper, a
# fixture /proc and /proc/meminfo, a fake systemd-run and a fake fm-control.sh
# that records the verb it was given.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-worker-memory-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-memory-guard)
PAGE=4096

new_home() {  # <name>: prints the home dir
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' "$home"
}

guard() {  # <home> <args...>: run the helper under an explicit fixture home
  local home=$1; shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROC_ROOT_OVERRIDE="${PROC_FIXTURE:-/nonexistent}" FM_MEMINFO_OVERRIDE="${MEMINFO_FIXTURE:-/nonexistent}" \
    "$GUARD" "$@"
}

# fake systemd-run: reports memory.max for the probe like a working user manager.
fake_systemd() {  # <dir> <mode: ok|nocontroller|fail>
  local dir=$1 mode=$2
  mkdir -p "$dir"
  cat > "$dir/systemd-run" <<SH
#!/usr/bin/env bash
mode=$mode
max=
for a in "\$@"; do case "\$a" in MemoryMax=*M) max=\${a#MemoryMax=}; max=\${max%M} ;; esac; done
[ "\$mode" != fail ] || exit 1
if [ "\$mode" = ok ]; then echo \$(( max * 1048576 )); else echo max; fi
SH
  chmod +x "$dir/systemd-run"
}

test_limits_defaults_and_config() {
  local home out status
  home=$(new_home limits)
  out=$(guard "$home" limits)
  assert_contains "$out" "rss-stop=4096" "default per-worker stop limit"
  assert_contains "$out" "scope-high=5120" "default MemoryHigh"
  assert_contains "$out" "scope-max=6144" "default MemoryMax"
  printf 'rss-stop=2048\nscope-max=8192\n# comment\n\n' > "$home/config/worker-memory-guard"
  out=$(guard "$home" limits)
  assert_contains "$out" "rss-stop=2048" "config overrides the stop limit"
  assert_contains "$out" "scope-max=8192" "config overrides MemoryMax"
  printf 'rss-stop=lots\n' > "$home/config/worker-memory-guard"
  out=$(guard "$home" limits 2>&1); status=$?
  expect_code 2 "$status" "a malformed value is rejected loudly: $out"
  printf 'scope-high=9000\nscope-max=100\n' > "$home/config/worker-memory-guard"
  out=$(guard "$home" limits 2>&1); status=$?
  expect_code 2 "$status" "scope-max below scope-high is rejected: $out"
  printf 'bogus=1\n' > "$home/config/worker-memory-guard"
  out=$(guard "$home" limits 2>&1); status=$?
  expect_code 2 "$status" "an unknown key is rejected: $out"
  pass "fm-worker-memory-guard.sh: limits defaults, overrides, and loud rejection"
}
test_limits_defaults_and_config

test_scope_prefix_proves_the_scope() {
  local home out status bin
  home=$(new_home scope)
  bin="$TMP_ROOT/scope/bin"
  fake_systemd "$bin" ok
  out=$(FM_SYSTEMD_RUN="$bin/systemd-run" guard "$home" scope-prefix "task.one" "s1.2"); status=$?
  expect_code 0 "$status" "a working user scope yields a prefix: $out"
  assert_contains "$out" "--user --scope" "the prefix is a user scope"
  assert_contains "$out" "MemoryHigh=5120M" "MemoryHigh in the prefix"
  assert_contains "$out" "MemoryMax=6144M" "MemoryMax in the prefix"
  assert_contains "$out" "MemorySwapMax=0" "swap is capped so the ceiling kills instead of swapping"
  assert_contains "$out" "--unit=fm-worker-task.one-s1.2" "the scope is named for the task and generation"

  fake_systemd "$bin" nocontroller
  out=$(FM_SYSTEMD_RUN="$bin/systemd-run" guard "$home" scope-prefix t g 2>&1); status=$?
  expect_code 3 "$status" "a scope whose memory.max is not enforced is unavailable: $out"
  assert_contains "$out" "memory controller not delegated" "the reason is stated"

  fake_systemd "$bin" fail
  out=$(FM_SYSTEMD_RUN="$bin/systemd-run" guard "$home" scope-prefix t g 2>&1); status=$?
  expect_code 3 "$status" "no user manager is unavailable: $out"
  assert_contains "$out" "scope unavailable" "the fallback is named, never silent"

  out=$(FM_SYSTEMD_RUN="$bin/absent" guard "$home" scope-prefix t g 2>&1); status=$?
  expect_code 3 "$status" "a missing systemd-run is unavailable: $out"
  assert_contains "$out" "systemd-run not found" "the missing binary is named"

  printf 'scope=off\n' > "$home/config/worker-memory-guard"
  out=$(FM_SYSTEMD_RUN="$bin/systemd-run" guard "$home" scope-prefix t g 2>&1); status=$?
  expect_code 4 "$status" "scope=off is reported distinctly: $out"
  pass "fm-worker-memory-guard.sh: scope-prefix proves enforcement and names every fallback"
}
test_scope_prefix_proves_the_scope

# Fixture /proc: one process per entry, cwd symlinked into a worktree.
add_proc() {  # <pid> <ppid> <rss-mib> <cwd>
  local d="$PROC_FIXTURE/$1" i fields=
  mkdir -p "$d"
  for i in $(seq 3 21); do fields="$fields 0"; done
  printf '%s (agent) S %s%s %s\n' "$1" "$2" "$fields" "$(( $3 * 1048576 / PAGE ))" > "$d/stat"
  ln -sfn "$4" "$d/cwd"
}

write_meta() {  # <home> <id> <kind> <worktree> <gen>
  cat > "$1/state/$2.meta" <<META
window=firstmate:fm-$2
endpoint_task_id=$2
worktree=$4
harness=claude
kind=$3
backend=tmux
spawn_gen=$5
META
}

fake_control() {  # <dir> <exit-code>
  mkdir -p "$1"
  cat > "$1/fm-control.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$1/calls"
exit $2
SH
  chmod +x "$1/fm-control.sh"
}

setup_check() {  # <name>: sets HOME_DIR PROC_FIXTURE MEMINFO_FIXTURE CONTROL
  HOME_DIR=$(new_home "$1")
  PROC_FIXTURE="$TMP_ROOT/$1/proc"
  MEMINFO_FIXTURE="$TMP_ROOT/$1/meminfo"
  CONTROL="$TMP_ROOT/$1/ctl"
  mkdir -p "$PROC_FIXTURE" "$TMP_ROOT/$1/wt-a" "$TMP_ROOT/$1/wt-b"
  printf 'MemTotal: 22000000 kB\nMemAvailable: 16000000 kB\n' > "$MEMINFO_FIXTURE"
  fake_control "$CONTROL" 0
}

run_check() { FM_WORKER_MEMORY_GUARD_CONTROL_BIN="$CONTROL/fm-control.sh" guard "$HOME_DIR" check 2>&1; }

test_runaway_worker_is_stopped_once() {
  local out calls
  setup_check runaway
  write_meta "$HOME_DIR" big scout "$TMP_ROOT/runaway/wt-a" g1
  write_meta "$HOME_DIR" small ship "$TMP_ROOT/runaway/wt-b" g1
  add_proc 100 1 3000 "$TMP_ROOT/runaway/wt-a"
  add_proc 101 100 2500 "$TMP_ROOT/runaway/wt-a/node_modules/x"
  add_proc 200 1 800 "$TMP_ROOT/runaway/wt-b"
  out=$(run_check)
  calls=$(cat "$CONTROL/calls" 2>/dev/null)
  assert_equals "big exit" "$calls" "only the worker whose tree is over 4096 MiB is stopped, through the exit verb: $out"
  assert_contains "$(cat "$HOME_DIR/state/big.status")" "[key=memory-guard]" "a durable status event is written"
  assert_contains "$(cat "$HOME_DIR/state/big.status")" "blocked" "the event is actionable"
  assert_absent "$HOME_DIR/state/small.status" "an in-bounds worker gets no event"
  run_check >/dev/null
  assert_equals "big exit" "$(cat "$CONTROL/calls")" "the same launch generation is stopped once"
  write_meta "$HOME_DIR" big scout "$TMP_ROOT/runaway/wt-a" g2
  run_check >/dev/null
  assert_equals "2" "$(wc -l < "$CONTROL/calls" | tr -d ' ')" "a relaunched generation is measured afresh"
  pass "fm-worker-memory-guard.sh: a runaway process tree is stopped once per launch, in-bounds workers untouched"
}
test_runaway_worker_is_stopped_once

test_low_host_stops_only_the_largest_worker() {
  local out
  setup_check lowhost
  printf 'rss-stop=99999\n' > "$HOME_DIR/config/worker-memory-guard"
  printf 'MemTotal: 22000000 kB\nMemAvailable: 2097152 kB\n' > "$MEMINFO_FIXTURE"
  write_meta "$HOME_DIR" big scout "$TMP_ROOT/lowhost/wt-a" g1
  write_meta "$HOME_DIR" mid ship "$TMP_ROOT/lowhost/wt-b" g1
  add_proc 100 1 2500 "$TMP_ROOT/lowhost/wt-a"
  add_proc 200 1 1500 "$TMP_ROOT/lowhost/wt-b"
  out=$(run_check)
  assert_equals "big exit" "$(cat "$CONTROL/calls")" "a host under its floor stops the single largest worker: $out"
  assert_contains "$(cat "$HOME_DIR/state/big.status")" "host memory low" "the event names the host reading"
  out=$(run_check)
  assert_equals "big exit
mid exit" "$(cat "$CONTROL/calls")" "the next pass stops the next worker only while the host stays low: $out"
  pass "fm-worker-memory-guard.sh: a low host stops one worker per pass, largest first"
}
test_low_host_stops_only_the_largest_worker

test_small_workers_and_secondmates_survive_a_low_host() {
  setup_check lowsmall
  printf 'MemTotal: 22000000 kB\nMemAvailable: 2097152 kB\n' > "$MEMINFO_FIXTURE"
  write_meta "$HOME_DIR" tiny scout "$TMP_ROOT/lowsmall/wt-a" g1
  write_meta "$HOME_DIR" mate secondmate "$TMP_ROOT/lowsmall/wt-b" g1
  add_proc 100 1 300 "$TMP_ROOT/lowsmall/wt-a"
  add_proc 200 1 9000 "$TMP_ROOT/lowsmall/wt-b"
  run_check >/dev/null
  assert_absent "$CONTROL/calls" "a worker under host-stop-min and a secondmate are never stopped"
  pass "fm-worker-memory-guard.sh: tiny workers and secondmates are never stopped"
}
test_small_workers_and_secondmates_survive_a_low_host

test_failed_stop_is_reported_and_retried() {
  local out
  setup_check failstop
  fake_control "$CONTROL" 1
  write_meta "$HOME_DIR" big scout "$TMP_ROOT/failstop/wt-a" g1
  add_proc 100 1 5000 "$TMP_ROOT/failstop/wt-a"
  out=$(run_check)
  assert_contains "$out" "FAILED" "a failed stop is reported plainly: $out"
  assert_contains "$(cat "$HOME_DIR/state/big.status")" "could not stop" "the failure is a durable event"
  run_check >/dev/null
  assert_equals "1" "$(wc -l < "$CONTROL/calls" | tr -d ' ')" "the retry waits out its interval"
  touch -d '10 minutes ago' "$HOME_DIR/state/.memory-guard-stopped-big"
  run_check >/dev/null
  assert_equals "2" "$(wc -l < "$CONTROL/calls" | tr -d ' ')" "the stop is retried after the interval"
  assert_equals "1" "$(wc -l < "$HOME_DIR/state/big.status" | tr -d ' ')" "a repeated failure does not spam events"
  pass "fm-worker-memory-guard.sh: a failed stop is reported once and retried"
}
test_failed_stop_is_reported_and_retried

test_guard_off_does_nothing() {
  setup_check guardoff
  printf 'guard=off\n' > "$HOME_DIR/config/worker-memory-guard"
  write_meta "$HOME_DIR" big scout "$TMP_ROOT/guardoff/wt-a" g1
  add_proc 100 1 9000 "$TMP_ROOT/guardoff/wt-a"
  run_check >/dev/null
  assert_absent "$CONTROL/calls" "guard=off stops nothing"
  pass "fm-worker-memory-guard.sh: guard=off disables the stop"
}
test_guard_off_does_nothing

write_brief() {  # <file> <task-line>
  printf '# Task\n## Captain'"'"'s intent\n%s\n\n# Setup\nNever install packages inside the worktree.\nnpm install is not for you.\n' "$2" > "$1"
}

test_brief_check() {
  local home out status brief
  home=$(new_home brief)
  brief="$TMP_ROOT/brief/brief.md"
  write_brief "$brief" "Run npm install in the working copy and then profile it."
  out=$(guard "$home" brief-check "$brief" 2>&1); status=$?
  expect_code 5 "$status" "an install inside the working copy is refused: $out"
  assert_contains "$out" "npm install in the working copy" "the offending line is shown"
  out=$(FM_ALLOW_WORKTREE_INSTALL=1 guard "$home" brief-check "$brief" 2>&1); status=$?
  expect_code 0 "$status" "the override downgrades the refusal: $out"
  assert_contains "$out" "FM_ALLOW_WORKTREE_INSTALL" "the override is disclosed"
  write_brief "$brief" "Run pnpm install and measure the tree."
  out=$(guard "$home" brief-check "$brief" 2>&1); status=$?
  expect_code 0 "$status" "a destination-less install only warns: $out"
  assert_contains "$out" "without a destination" "the warning is shown"
  write_brief "$brief" "Run npm install under ~/fm-scratch/job inside the repo clone there."
  out=$(guard "$home" brief-check "$brief" 2>&1); status=$?
  expect_code 0 "$status" "a scratch destination passes: $out"
  assert_equals "" "$out" "a scratch destination is silent"
  write_brief "$brief" "Never run npm install inside the working copy."
  out=$(guard "$home" brief-check "$brief" 2>&1); status=$?
  expect_code 0 "$status" "a negated line passes: $out"
  assert_equals "" "$out" "the scaffold's own prohibition and negated task lines are silent"
  pass "fm-worker-memory-guard.sh: brief-check refuses worktree installs and warns on bare ones"
}
test_brief_check

test_brief_scaffold_directs_scratch() {
  local home kind brief
  home=$(new_home scaffold)
  for kind in scout ship; do
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "scaf-$kind" proj --scout >/dev/null 2>&1 || fail "could not scaffold the $kind brief"
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "scaf-$kind" proj --mode direct-PR >/dev/null 2>&1 || fail "could not scaffold the $kind brief"
    fi
    brief="$home/data/scaf-$kind/brief.md"
    assert_present "$brief" "the $kind brief was scaffolded"
    assert_not_contains "$(cat "$brief")" "install, run, edit" "the $kind scaffold no longer invites installs in the worktree"
    assert_contains "$(cat "$brief")" "~/fm-scratch/scaf-$kind/" "the $kind scaffold names the scratch location"
  done
  pass "fm-brief.sh: scaffolds direct installs to ~/fm-scratch and no longer invite them in the worktree"
}
test_brief_scaffold_directs_scratch

printf '# all fm-worker-memory-guard tests passed\n'
