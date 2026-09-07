#!/usr/bin/env bash
# Behavior tests for bin/fm-autonomous-pc02-lane.sh: the /autonomous skill's
# step 3 dispatch-availability check for the PC02 lane, separate
# from and independent of the generic Claude dispatch-cap check. Mirrors
# fm-spawn.sh's pc02_lane_guard scan-and-liveness read (see
# tests/fm-spawn-pc02-lane-guard.test.sh for that guard's own coverage).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-autonomous-pc02-lane.sh"
TMP_ROOT=$(fm_test_tmproot fm-autonomous-pc02-lane)

make_home() {  # <name> -> prints "<home>|<fakebin>"
  local name=$1 home fakebin
  home="$TMP_ROOT/$name/home"
  fakebin=$(fm_fakebin "$TMP_ROOT/$name/fake")
  mkdir -p "$home/state"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)
    if [ -n "${FM_FAKE_LIST_WINDOWS_ERR:-}" ]; then
      echo "fake inventory failure" >&2
      exit 1
    fi
    printf '%s' "${FM_FAKE_WINDOWS:-}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s|%s\n' "$home" "$fakebin"
}

write_meta() {  # <home> <task> <model> [harness] [remote_host]
  local home=$1 task=$2 model=$3 harness=${4:-opencode} remote_host=${5:-}
  {
    printf 'window=firstmate:fm-%s\n' "$task"
    printf 'endpoint_task_id=%s\n' "$task"
    printf 'harness=%s\n' "$harness"
    printf 'kind=ship\n'
    printf 'model=%s\n' "$model"
    [ -n "$remote_host" ] && printf 'remote_host=%s\n' "$remote_host"
  } > "$home/state/$task.meta"
}

run_lane_check() {  # <home> <fakebin> [extra env...]
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" TMUX="fake,1,0" "$@" "$SCRIPT" 2>&1
}

test_free_when_no_pc02_meta_exists() {
  local rec home fakebin out status
  rec=$(make_home nopc02)
  IFS='|' read -r home fakebin <<< "$rec"
  write_meta "$home" cloud-task claude-sonnet-5 claude

  out=$(run_lane_check "$home" "$fakebin")
  status=$?
  expect_code 0 "$status" "no PC02 meta should read as free: $out"
  assert_contains "$out" "free" "expected 'free', got: $out"
  pass "PC02 lane reads free when no task holds a pc02-llamaswap meta"
}

test_occupied_when_pc02_lane_alive() {
  local rec home fakebin out status
  rec=$(make_home alive)
  IFS='|' read -r home fakebin <<< "$rec"
  write_meta "$home" pc02-holder pc02-llamaswap/qwen3.6-35b-a3b-dispatch

  out=$(run_lane_check "$home" "$fakebin" env FM_FAKE_WINDOWS="fm-pc02-holder
")
  status=$?
  expect_code 1 "$status" "a live PC02 task must report the lane occupied: $out"
  assert_contains "$out" "occupied: pc02-holder" "occupied output did not name the holding task: $out"
  pass "a live PC02 task reports the lane occupied, independent of any Claude dispatch-cap reading"
}

test_occupied_when_pc02_liveness_unknown() {
  local rec home fakebin out status
  rec=$(make_home unknown)
  IFS='|' read -r home fakebin <<< "$rec"
  write_meta "$home" pc02-holder pc02-llamaswap/qwen3.6-35b-a3b-dispatch

  out=$(run_lane_check "$home" "$fakebin" env FM_FAKE_LIST_WINDOWS_ERR=1)
  status=$?
  expect_code 1 "$status" "unknown liveness must fail closed as occupied: $out"
  assert_contains "$out" "occupied: pc02-holder" "unknown-liveness case did not report occupied: $out"
  pass "ambiguous PC02 liveness fails closed as occupied"
}

test_free_when_pc02_lane_positively_dead() {
  local rec home fakebin out status
  rec=$(make_home dead)
  IFS='|' read -r home fakebin <<< "$rec"
  write_meta "$home" pc02-holder pc02-llamaswap/qwen3.6-35b-a3b-dispatch

  out=$(run_lane_check "$home" "$fakebin" env FM_FAKE_WINDOWS="")
  status=$?
  expect_code 0 "$status" "a positively dead PC02 endpoint should free the lane: $out"
  assert_contains "$out" "free" "expected 'free' once the holder's window is gone: $out"
  pass "the PC02 lane frees once its holder's endpoint is positively dead"
}

test_remote_pc02_meta_keeps_lane_occupied() {
  local rec home fakebin out status
  rec=$(make_home remote)
  IFS='|' read -r home fakebin <<< "$rec"
  write_meta "$home" remote-pc02-task pc02-llamaswap/qwen3.6-35b-a3b-dispatch opencode secondmate-host

  out=$(run_lane_check "$home" "$fakebin" env FM_FAKE_WINDOWS="")
  status=$?
  expect_code 1 "$status" "a remote PC02 lane must stay occupied regardless of local liveness: $out"
  assert_contains "$out" "occupied: remote-pc02-task" "remote occupied output missing task name: $out"
  pass "a remote secondmate's PC02 lane always reads as occupied"
}

test_non_opencode_harness_still_holds_pc02_lane() {
  local rec home fakebin out status
  rec=$(make_home otherharness)
  IFS='|' read -r home fakebin <<< "$rec"
  write_meta "$home" pc02-holder pc02-llamaswap/qwen3.6-35b-a3b-dispatch codex

  out=$(run_lane_check "$home" "$fakebin" env FM_FAKE_WINDOWS="fm-pc02-holder
")
  status=$?
  expect_code 1 "$status" "a pc02-llamaswap model must hold the lane regardless of harness: $out"
  assert_contains "$out" "occupied: pc02-holder" "non-opencode holder was not reported occupied: $out"
  pass "a live pc02-llamaswap task holds the lane under any harness"
}

test_stray_argument_is_a_usage_error() {
  local rec home fakebin out status
  rec=$(make_home usage)
  IFS='|' read -r home fakebin <<< "$rec"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" TMUX="fake,1,0" "$SCRIPT" --bogus 2>&1)
  status=$?
  expect_code 2 "$status" "a stray argument must exit 2: $out"
  assert_contains "$out" "unknown argument" "usage error did not explain the bad argument: $out"
  pass "a stray argument is rejected as a usage error"
}

test_missing_state_dir_refuses_instead_of_reading_free() {
  local rec home fakebin out status
  rec=$(make_home nostate)
  IFS='|' read -r home fakebin <<< "$rec"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state-gone" \
    PATH="$fakebin:$PATH" TMUX="fake,1,0" "$SCRIPT" 2>&1)
  status=$?
  expect_code 2 "$status" "a missing state directory must refuse, not read free: $out"
  assert_contains "$out" "state directory is unavailable" "missing state dir lacked a concrete diagnostic: $out"
  pass "a missing state directory refuses instead of silently reading free"
}

test_free_when_no_pc02_meta_exists
test_missing_state_dir_refuses_instead_of_reading_free
test_non_opencode_harness_still_holds_pc02_lane
test_stray_argument_is_a_usage_error
test_occupied_when_pc02_lane_alive
test_occupied_when_pc02_liveness_unknown
test_free_when_pc02_lane_positively_dead
test_remote_pc02_meta_keeps_lane_occupied

echo "# all fm-autonomous-pc02-lane tests passed"
