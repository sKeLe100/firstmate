#!/usr/bin/env bash
# Portable behavior tests for the PC02 side of the personal-use switch:
# bin/fm-pc02-personal-use-runners.sh must stop every discovered
# `actions.runner.*` user unit while the flag file exists and start them again
# when it is gone. A fake `systemctl` keeps the cases off any real user manager
# and lets them prove discovery, not a hardcoded runner list.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pc02-personal-use-runners.sh"
TMP_ROOT=$(fm_test_tmproot fm-pc02-personal-use)
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"
fakebin=$(fm_fakebin "$TMP_ROOT/fake")
export PATH="$fakebin:$PATH"
export FM_TEST_SYSTEMCTL_LOG="$TMP_ROOT/systemctl.log"
export FM_TEST_UNIT_LIST="$TMP_ROOT/unit-list"
export FM_TEST_STATE_DIR="$TMP_ROOT/state"
FLAG_REL=".fm-pc02-personal-use"
export FM_TEST_FLAG="$HOME/$FLAG_REL"

cat > "$fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_SYSTEMCTL_LOG"
[ "${1:-}" = --user ] && shift
cmd=${1:-}
[ "$#" -gt 0 ] && shift
case "$cmd" in
  list-unit-files)
    [ -f "$FM_TEST_UNIT_LIST" ] || exit 1
    cat "$FM_TEST_UNIT_LIST"
    ;;
  is-active)
    [ "${1:-}" = --quiet ] && shift
    unit=${1:-}
    state=$(cat "$FM_TEST_STATE_DIR/$unit" 2>/dev/null) || state=inactive
    [ "$state" = active ]
    ;;
  start | stop)
    unit=${1:-}
    case "$unit" in
      *fail-$cmd*) exit 1 ;;
    esac
    if [ "$cmd" = start ]; then
      printf 'active\n' > "$FM_TEST_STATE_DIR/$unit"
    else
      printf 'inactive\n' > "$FM_TEST_STATE_DIR/$unit"
    fi
    # FM_TEST_FLIP_ON=<start|stop>: flip the flag once, the first time that
    # command runs, to model a desktop-toggle flip that lands mid-pass.
    if [ "${FM_TEST_FLIP_ON:-}" = "$cmd" ] && [ ! -e "$FM_TEST_STATE_DIR/flipped" ]; then
      : > "$FM_TEST_STATE_DIR/flipped"
      if [ -f "$FM_TEST_FLAG" ]; then
        rm -f "$FM_TEST_FLAG"
      else
        : > "$FM_TEST_FLAG"
      fi
    fi
    ;;
  daemon-reload | enable | restart)
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$fakebin/systemctl"

SANDBOX="$TMP_ROOT/sandbox"
mkdir -p "$SANDBOX/mnt/c/Windows/System32/WindowsPowerShell/v1.0"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
chmod +x "$SANDBOX/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
export FM_TEST_SANDBOX="$SANDBOX"
cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
shift
cmd=${1//\/mnt\/c\//$FM_TEST_SANDBOX\/mnt\/c\/}
eval "$cmd"
SH
chmod +x "$fakebin/ssh"

set_units() {
  cat > "$FM_TEST_UNIT_LIST" <<'UNITS'
actions.runner.one.first.service enabled enabled
actions.runner.two.second.service enabled enabled
actions.runner.three.third.service enabled enabled
no-mistakes-daemon.service enabled enabled
UNITS
}

set_state() {  # <unit> <active|inactive>
  printf '%s\n' "$2" > "$FM_TEST_STATE_DIR/$1"
}

state_of() {
  cat "$FM_TEST_STATE_DIR/$1" 2>/dev/null || printf 'inactive\n'
}

reset_fixture() {
  : > "$FM_TEST_SYSTEMCTL_LOG"
  rm -rf "$FM_TEST_STATE_DIR"
  mkdir -p "$FM_TEST_STATE_DIR"
  set_units
  rm -f "$HOME/$FLAG_REL"
  unset FM_TEST_FLIP_ON
}

run_guard() {
  PATH="$fakebin:$PATH" \
    FM_PC02_OFFLOAD_PERSONAL_USE_FLAG="${1:-$FLAG_REL}" \
    "$SCRIPT" 2>&1
}

test_on_stops_every_active_runner() {
  local out status
  reset_fixture
  : > "$HOME/$FLAG_REL"
  set_state actions.runner.one.first.service active
  set_state actions.runner.two.second.service active
  set_state actions.runner.three.third.service inactive
  out=$(run_guard) || status=$?
  status=${status:-0}
  expect_code 0 "$status" "personal use on must converge cleanly: $out"
  assert_contains "$out" "personal use on" "a stop was not reported: $out"
  assert_contains "$(cat "$FM_TEST_SYSTEMCTL_LOG")" \
    "--user stop actions.runner.one.first.service" "first runner was not stopped"
  assert_contains "$(cat "$FM_TEST_SYSTEMCTL_LOG")" \
    "--user stop actions.runner.two.second.service" "second runner was not stopped"
  assert_not_contains "$(cat "$FM_TEST_SYSTEMCTL_LOG")" \
    "stop actions.runner.three.third.service" "an already-inactive runner was stopped again"
  [ "$(state_of actions.runner.one.first.service)" = inactive ] \
    || fail "first runner is still active after personal use turned on"
  [ "$(state_of actions.runner.two.second.service)" = inactive ] \
    || fail "second runner is still active after personal use turned on"
  pass "personal use on stops every active actions.runner.* unit"
}

test_off_starts_every_runner_including_a_third() {
  local out status log
  reset_fixture
  set_state actions.runner.one.first.service inactive
  set_state actions.runner.two.second.service inactive
  set_state actions.runner.three.third.service inactive
  out=$(run_guard) || status=$?
  status=${status:-0}
  expect_code 0 "$status" "personal use off must converge cleanly: $out"
  log=$(cat "$FM_TEST_SYSTEMCTL_LOG")
  assert_contains "$out" "personal use off" "a start was not reported: $out"
  for unit in actions.runner.one.first.service actions.runner.two.second.service \
    actions.runner.three.third.service; do
    assert_contains "$log" "--user start $unit" "the guard did not start $unit"
    [ "$(state_of "$unit")" = active ] || fail "$unit is not active after personal use turned off"
  done
  assert_not_contains "$log" "start no-mistakes-daemon.service" \
    "the guard started a non-runner unit"
  pass "personal use off starts every discovered runner, not a hardcoded pair"
}

test_already_active_runner_is_left_alone() {
  local out status log
  reset_fixture
  set_state actions.runner.one.first.service active
  set_state actions.runner.two.second.service inactive
  set_state actions.runner.three.third.service inactive
  out=$(run_guard) || status=$?
  status=${status:-0}
  expect_code 0 "$status" "an already-active runner must not fail the guard: $out"
  log=$(cat "$FM_TEST_SYSTEMCTL_LOG")
  assert_not_contains "$log" "start actions.runner.one.first.service" \
    "an already-active runner was started again"
  assert_contains "$log" "start actions.runner.two.second.service" \
    "an inactive runner was not started"
  pass "an already-active runner is left untouched when personal use turns off"
}

test_unlistable_units_fail_loudly() {
  local out status
  reset_fixture
  rm -f "$FM_TEST_UNIT_LIST"
  out=$(run_guard) || status=$?
  status=${status:-0}
  expect_code 1 "$status" "a failed unit listing must exit 1: $out"
  assert_contains "$out" "cannot list user units" "the listing failure was not named: $out"
  pass "a failed runner discovery refuses instead of reporting success"
}

test_stop_failure_is_reported_and_other_runners_continue() {
  local out status
  reset_fixture
  : > "$HOME/$FLAG_REL"
  printf 'actions.runner.fail-stop.service enabled enabled\n' >> "$FM_TEST_UNIT_LIST"
  set_state actions.runner.fail-stop.service active
  set_state actions.runner.one.first.service active
  out=$(run_guard) || status=$?
  status=${status:-0}
  expect_code 1 "$status" "a failed stop must exit 1: $out"
  assert_contains "$out" "failed to stop actions.runner.fail-stop.service" \
    "the failed unit was not named: $out"
  [ "$(state_of actions.runner.one.first.service)" = inactive ] \
    || fail "a failed stop prevented the other runners from stopping"
  pass "a runner that refuses to stop fails the guard and names the unit"
}

test_flag_removed_mid_stop_pass_converges_to_active() {
  local out status
  reset_fixture
  : > "$HOME/$FLAG_REL"
  set_state actions.runner.one.first.service active
  set_state actions.runner.two.second.service active
  export FM_TEST_FLIP_ON=stop
  out=$(run_guard) || status=$?
  unset FM_TEST_FLIP_ON
  status=${status:-0}
  expect_code 0 "$status" "a flip during a stop pass must still converge: $out"
  [ ! -e "$HOME/$FLAG_REL" ] || fail "the mid-pass flip did not remove the flag"
  assert_contains "$out" "converging again" "the re-converge pass was not reported: $out"
  [ "$(state_of actions.runner.one.first.service)" = active ] \
    || fail "first runner stayed stopped after the flag went off mid-pass"
  [ "$(state_of actions.runner.two.second.service)" = active ] \
    || fail "second runner stayed stopped after the flag went off mid-pass"
  pass "a flag removed mid-pass leaves every runner active, matching the final flag"
}

test_flag_created_mid_start_pass_converges_to_stopped() {
  local out status
  reset_fixture
  set_state actions.runner.one.first.service inactive
  set_state actions.runner.two.second.service inactive
  export FM_TEST_FLIP_ON=start
  out=$(run_guard) || status=$?
  unset FM_TEST_FLIP_ON
  status=${status:-0}
  expect_code 0 "$status" "a flip during a start pass must still converge: $out"
  [ -e "$HOME/$FLAG_REL" ] || fail "the mid-pass flip did not create the flag"
  assert_contains "$out" "converging again" "the re-converge pass was not reported: $out"
  [ "$(state_of actions.runner.one.first.service)" = inactive ] \
    || fail "first runner stayed running after the flag went on mid-pass"
  [ "$(state_of actions.runner.two.second.service)" = inactive ] \
    || fail "second runner stayed running after the flag went on mid-pass"
  pass "a flag created mid-pass leaves every runner stopped, matching the final flag"
}

run_install_toggle() {  # <flag>
  FM_PC02_OFFLOAD_PERSONAL_USE_FLAG="$1" "$ROOT/bin/fm-pc02-personal-use.sh" install-toggle 2>&1
}

test_install_toggle_deploys_path_unit_service_and_dropins() {
  local out status udir flag
  for flag in "$FLAG_REL"; do
    reset_fixture
    rm -rf "$HOME/.config" "$HOME/.local"
    status=0
    out=$(run_install_toggle "$flag") || status=$?
    expect_code 0 "$status" "install-toggle must succeed: $out"
    udir="$HOME/.config/systemd/user"
    local watch="%h/$flag"
    assert_contains "$(cat "$udir/fm-pc02-personal-use-runners.path")" "PathChanged=$watch" \
      "path unit must watch $watch"
    assert_contains "$(cat "$udir/fm-pc02-personal-use-runners.service")" \
      "Environment=\"FM_PC02_OFFLOAD_PERSONAL_USE_FLAG=$flag\"" "service must carry the flag"
    local u
    for u in actions.runner.one.first.service actions.runner.two.second.service actions.runner.three.third.service; do
      assert_contains "$(cat "$udir/$u.d/10-fm-pc02-personal-use.conf")" "ConditionPathExists=!$watch" \
        "$u must be gated on $watch"
    done
    [ ! -e "$udir/no-mistakes-daemon.service.d" ] || fail "non-runner unit got a drop-in"
    [ -x "$HOME/.local/bin/fm-pc02-personal-use-runners.sh" ] || fail "runner helper not installed executable"
    [ -f "$SANDBOX/mnt/c/pc02-llm-server/bin/fm-pc02-personal-use-toggle.vbs" ] || fail "desktop toggle not installed"
  done
  pass "install-toggle deploys path unit, service env, and a drop-in per runner for the relative flag"
}

test_on_stops_every_active_runner
test_off_starts_every_runner_including_a_third
test_already_active_runner_is_left_alone
test_unlistable_units_fail_loudly
test_stop_failure_is_reported_and_other_runners_continue
test_flag_removed_mid_stop_pass_converges_to_active
test_flag_created_mid_start_pass_converges_to_stopped
test_install_toggle_deploys_path_unit_service_and_dropins

echo "# all fm-pc02-personal-use tests passed"
