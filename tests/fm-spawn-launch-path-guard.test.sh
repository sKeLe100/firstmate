#!/usr/bin/env bash
# tests/fm-spawn-launch-path-guard.test.sh - a launch must not depend on the
# PATH a long-lived pane shell happened to be born with.
#
# A relaunch reuses the task's pane. When that pane's shell predates the
# directory holding the harness binary, the launch used to die instantly with a
# bare `env: <bin>: No such file or directory` in scrollback while no agent ever
# ran. These tests drive a real fm-control.sh relaunch, capture the staged
# launch file the pane actually receives, and execute it against a deliberately
# stale pane PATH, so the login-shell retry and the durable launch-failure
# record are observed as behavior rather than by reading bin/fm-spawn.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-launch-path-guard)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# The stub records the staged launch file verbatim so the test can execute the
# exact command the pane received, in the environment under test.
make_tmux_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          if [ -f "$staged" ]; then
            cp "$staged" "$D/staged"
            payload=$(cat "$staged")
          fi
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*) printf 'codex' > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

# link_tools <dir>: a PATH holding the ordinary tooling a launch needs but no
# harness, so a test PATH can be minimal and hermetic.
link_tools() {
  local dir=$1 tool
  mkdir -p "$dir"
  for tool in bash sh tail date printenv env sed grep awk cut tr sort head mktemp chmod cat mkdir rm dirname sleep jq basename mv git ln; do
    [ -e "$dir/$tool" ] && continue
    command -v "$tool" >/dev/null 2>&1 && ln -s "$(command -v "$tool")" "$dir/$tool"
  done
}

make_case() {  # <name> <id> -> echoes the case dir
  local name=$1 id=$2 dir="$TMP_ROOT/$1-$RANDOM"
  local home proj wt
  home="$dir/home"
  proj="$dir/proj"
  wt="$dir/wt"
  mkdir -p "$home/state" "$home/data/$id" "$home/config" "$home/projects" "$dir/fake"
  touch "$home/state/.last-watcher-beat"
  make_tmux_stub "$dir"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the launch PATH guard for $id.

## Firstmate spec
Replace the agent without depending on the pane's inherited PATH.
EOF
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'codex' > "$dir/fake/command"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=$dir/tasktmp"
    echo "model=gpt-5"
    echo "effort=medium"
  } > "$home/state/$id.meta"

  link_tools "$dir/tools"
  cat > "$dir/fake-login-shell" <<'SH'
#!/bin/sh
[ -z "${FM_TEST_LOGIN_SHELL_CALLED:-}" ] || : > "$FM_TEST_LOGIN_SHELL_CALLED"
printf '%s\n' "${FM_TEST_LOGIN_PATH:-}"
SH
  chmod +x "$dir/fake-login-shell"
  mkdir -p "$dir/loginbin"
  cat > "$dir/loginbin/codex" <<'SH'
#!/bin/sh
[ -z "${FM_TEST_GUARD_MARKER:-}" ] || printf 'started\n' > "$FM_TEST_GUARD_MARKER"
SH
  chmod +x "$dir/loginbin/codex"
  printf '%s\n' "$dir"
}

# relaunch_case <case-dir> <id>: drive the real relaunch that stages the launch.
relaunch_case() {
  local dir=$1 id=$2 out
  mkdir -p "$dir/user-home"
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.3 \
    "$CONTROL" "$id" relaunch --note 'replacement continues the same task' 2>&1)
  local rc=$?
  expect_code 0 "$rc" "the relaunch should stage its replacement launch: $out"$'\n'"$out"
  [ -s "$dir/fake/staged" ] || fail "the pane received no staged launch file"
}

# run_staged <case-dir> <login-path> <marker>: execute the staged launch as the
# pane would, under a stale PATH that does not hold the harness.
run_staged() {
  local dir=$1 login_path=$2 marker=$3
  env -i HOME="$dir/user-home" PATH="$dir/tools" \
    SHELL="$dir/fake-login-shell" FM_TEST_LOGIN_PATH="$login_path" \
    FM_TEST_GUARD_MARKER="$marker" TERM=xterm \
    /bin/bash "$dir/fake/staged"
}

test_launch_retries_with_the_login_shell_path() {
  local dir marker out
  dir=$(make_case login-restore rlg1)
  marker="$dir/harness-ran"
  relaunch_case "$dir" rlg1
  out=$(run_staged "$dir" "$dir/loginbin:$dir/tools:$PATH" "$marker" 2>&1)
  local rc=$?
  expect_code 0 "$rc" "the launch should recover through the login-shell PATH: $out"$'\n'"$out"
  [ -f "$marker" ] || fail "the harness never ran after the login-shell PATH retry"
  [ ! -e "$dir/home/state/rlg1.launch-failure" ] \
    || fail "a recovered launch must not leave a launch-failure record"
  pass "fm-spawn launch guard: a stale pane PATH is retried through the login shell and the agent starts"
}
test_launch_retries_with_the_login_shell_path

test_unresolvable_binary_records_a_specific_launch_failure() {
  local dir marker out rc
  dir=$(make_case login-missing rlg2)
  marker="$dir/harness-ran"
  relaunch_case "$dir" rlg2
  out=$(run_staged "$dir" "$dir/tools" "$marker" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a launch whose harness never resolves must fail"
  [ ! -e "$marker" ] || fail "the harness ran even though its binary does not resolve"
  assert_contains "$out" "harness binary codex does not resolve on PATH" \
    "the failure should name the harness binary it could not resolve"
  local record="$dir/home/state/rlg2.launch-failure"
  [ -r "$record" ] || fail "the launch should leave a durable launch-failure record"
  grep -qx 'task=rlg2' "$record" || fail "the record should name the task"
  grep -qx 'harness=codex' "$record" || fail "the record should name the harness"
  grep -qx 'binary=codex' "$record" || fail "the record should name the unresolved binary"
  grep -q '^reason=.*agent never started' "$record" \
    || fail "the record should say the agent never started"
  pass "fm-spawn launch guard: an unresolvable harness fails loudly and records a specific launch failure"
}
test_unresolvable_binary_records_a_specific_launch_failure

test_resolved_binary_needs_no_login_shell() {
  local dir marker out rc
  dir=$(make_case login-unused rlg3)
  marker="$dir/harness-ran"
  relaunch_case "$dir" rlg3
  # A PATH that already resolves the harness, with a SHELL that could not run:
  # the guard must not consult it at all.
  out=$(env -i HOME="$dir/user-home" PATH="$dir/loginbin:$dir/tools" \
    SHELL="$dir/fake-login-shell" FM_TEST_LOGIN_PATH="$dir/tools" \
    FM_TEST_LOGIN_SHELL_CALLED="$dir/login-shell-called" \
    FM_TEST_GUARD_MARKER="$marker" TERM=xterm \
    /bin/bash "$dir/fake/staged" 2>&1)
  rc=$?
  expect_code 0 "$rc" "a resolvable harness needs no login shell: $out"$'\n'"$out"
  [ -f "$marker" ] || fail "the harness did not run when its binary already resolves"
  [ ! -e "$dir/login-shell-called" ] \
    || fail "the guard consulted a login shell even though the harness already resolved"
  [ ! -e "$dir/home/state/rlg3.launch-failure" ] \
    || fail "a successful launch must not leave a launch-failure record"
  pass "fm-spawn launch guard: a harness already on the pane PATH launches without a login-shell probe"
}
test_resolved_binary_needs_no_login_shell
