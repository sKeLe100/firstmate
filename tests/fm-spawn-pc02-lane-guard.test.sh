#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's pc02-single-lane-guard: a spawn onto any
# pc02-llamaswap/* model refuses while another task's meta holds one whose
# endpoint is not positively dead or missing (PC02 serves one model at a time;
# data/pc02-followthrough-gap-assessment/report.md). Fake tmux controls the
# liveness read: FM_FAKE_WINDOWS is what `tmux list-windows` prints, and
# FM_FAKE_LIST_WINDOWS_ERR forces the inventory read to fail (unreadable ->
# unknown liveness, which must keep the lane occupied).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pc02-lane-guard)

make_case() {
  local name=$1 case_dir home proj wt fakebin id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *pane_current_command*) printf '%s\n' "${FM_FAKE_PANE_CMD:-firstmate}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ -n "${FM_FAKE_LIST_WINDOWS_ERR:-}" ]; then
      echo "fake inventory failure" >&2
      exit 1
    fi
    printf '%s' "${FM_FAKE_WINDOWS:-}"
    exit 0
    ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case_record() {
  # shellcheck disable=SC2034  # CASE_DIR kept for parity with the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

write_other_meta() {  # <home> <task> <model>
  cat > "$1/state/$2.meta" <<EOF
window=firstmate:fm-$2
endpoint_task_id=$2
harness=opencode
kind=ship
model=$3
EOF
}

run_pc02_spawn() {
  local home=$1 wt=$2 fakebin=$3 id=$4 proj=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' PATH="$fakebin:$PATH" \
    "$@" "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off \
    --model pc02-llamaswap/qwen3.6-35b-a3b-dispatch 2>&1
}

test_relaunch_refuses_while_task_set_locked() {
  local rec id out status lockdir holder_pid
  id=pc02-guard-z5
  rec=$(make_case relaunchlock "$id")
  read_case_record "$rec"

  out=$(run_pc02_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" env)
  status=$?
  expect_code 0 "$status" "the initial pc02 spawn should succeed: $out"

  # A relaunch is normally exempt from the task-set lock, but a pc02 relaunch
  # must take it so its lane read cannot race a concurrent fresh spawn.
  lockdir="$HOME_DIR/state/.task-set.lock"
  mkdir -p "$lockdir"
  /bin/sleep 30 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" > "$lockdir/pid"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' PATH="$FAKEBIN_DIR:$PATH" \
    FM_FAKE_WINDOWS="fm-$id
" FM_FAKE_PANE_CMD=zsh "$SPAWN" "$id" --relaunch \
    --model pc02-llamaswap/qwen3.6-35b-a3b-dispatch 2>&1)
  status=$?
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  expect_code 1 "$status" "a pc02 relaunch must refuse while the task set is locked: $out"
  assert_contains "$out" "task set is locked" "relaunch refusal did not name the task-set lock: $out"

  rm -rf "$lockdir"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' PATH="$FAKEBIN_DIR:$PATH" \
    FM_FAKE_WINDOWS="fm-$id
" FM_FAKE_PANE_CMD=zsh "$SPAWN" "$id" --relaunch \
    --model pc02-llamaswap/qwen3.6-35b-a3b-dispatch 2>&1)
  status=$?
  expect_code 0 "$status" "an unlocked pc02 relaunch should still proceed: $out"
  [ ! -d "$lockdir" ] || fail "the pc02 relaunch must release the task-set lock after publication"
  pass "a pc02 relaunch takes the task-set lock so its lane read cannot race a fresh spawn"
}

test_refuses_while_other_pc02_lane_unknown_liveness() {
  local rec id out status
  id=pc02-guard-z1
  rec=$(make_case unknown "$id")
  read_case_record "$rec"
  write_other_meta "$HOME_DIR" other-pc02-task pc02-llamaswap/qwen3.8-27b-dispatch

  out=$(run_pc02_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    env FM_FAKE_LIST_WINDOWS_ERR=1)
  status=$?
  expect_code 1 "$status" "spawn should refuse while the other PC02 lane's liveness is unknown"
  assert_contains "$out" "PC02 lane occupied" "refusal did not name the occupied lane"
  assert_contains "$out" "other-pc02-task" "refusal did not name the occupying task"
  [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "refused spawn must not write $id.meta"
  pass "unknown liveness keeps the PC02 lane occupied and names the occupying task"
}

test_refuses_while_other_pc02_lane_alive_window_listed() {
  local rec id out status
  id=pc02-guard-z2
  rec=$(make_case listed "$id")
  read_case_record "$rec"
  write_other_meta "$HOME_DIR" other-pc02-task pc02-llamaswap/qwen3.6-35b-a3b-dispatch

  out=$(run_pc02_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    env FM_FAKE_WINDOWS='fm-other-pc02-task
')
  status=$?
  expect_code 1 "$status" "spawn should refuse while the other PC02 window is still present"
  assert_contains "$out" "PC02 lane occupied" "refusal did not name the occupied lane"
  pass "a listed PC02 window keeps the lane occupied"
}

test_proceeds_when_other_pc02_lane_positively_missing() {
  local rec id out status
  id=pc02-guard-z3
  rec=$(make_case missing "$id")
  read_case_record "$rec"
  write_other_meta "$HOME_DIR" other-pc02-task pc02-llamaswap/qwen3.6-35b-a3b-dispatch

  out=$(run_pc02_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" env)
  status=$?
  expect_code 0 "$status" "spawn should proceed when the other PC02 endpoint is positively missing: $out"
  assert_grep "model=pc02-llamaswap/qwen3.6-35b-a3b-dispatch" "$HOME_DIR/state/$id.meta" "meta missing pc02 model"
  pass "a positively missing PC02 endpoint frees the lane"
}

test_ignores_non_pc02_metas() {
  local rec id out status
  id=pc02-guard-z4
  rec=$(make_case nonpc02 "$id")
  read_case_record "$rec"
  write_other_meta "$HOME_DIR" cloud-task claude-sonnet-5

  out=$(run_pc02_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    env FM_FAKE_LIST_WINDOWS_ERR=1)
  status=$?
  expect_code 0 "$status" "a non-PC02 meta must not occupy the PC02 lane: $out"
  pass "non-PC02 metas never occupy the lane"
}

test_relaunch_refuses_while_task_set_locked
test_refuses_while_other_pc02_lane_unknown_liveness
test_refuses_while_other_pc02_lane_alive_window_listed
test_proceeds_when_other_pc02_lane_positively_missing
test_ignores_non_pc02_metas

echo "# all fm-spawn-pc02-lane-guard tests passed"
