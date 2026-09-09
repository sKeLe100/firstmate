#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's codex lane guard: this home runs one live
# Codex agent at a time, so a second local harness=codex spawn is refused while
# another local codex task's endpoint is not positively dead. The lane is scoped
# to this home - a remote-routed codex meta runs on another host and never takes
# it. Fake tmux controls the liveness read: FM_FAKE_WINDOWS is what
# `tmux list-windows` prints, and FM_FAKE_LIST_WINDOWS_ERR forces the inventory
# read to fail (unreadable -> unknown liveness, which must keep the lane held).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-codex-lane-guard)

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
  fm_fake_codex_probe "$fakebin"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf '# Task\n## Captain'"'"'s intent\nbrief for %s\n\n## Firstmate spec\nExercise the spawn behavior under test.\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case_record() {
  # shellcheck disable=SC2034  # CASE_DIR kept for parity with the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<<"$1"
}

write_sibling_meta() {  # <home> <task> <harness> <kind>
  cat > "$1/state/$2.meta" <<EOF
window=firstmate:fm-$2
endpoint_task_id=$2
harness=$3
kind=$4
model=gpt-5
EOF
}

run_spawn() {  # <home> <wt> <fakebin> <id> <proj> <env-prefix...> -- <extra spawn args...>
  local home=$1 wt=$2 fakebin=$3 id=$4 proj=$5
  shift 5
  local -a envs=() extra=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --) shift; extra=("$@"); break ;;
      *) envs+=("$1"); shift ;;
    esac
  done
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' PATH="$fakebin:$PATH" \
    "${envs[@]}" "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off \
    "${extra[@]+"${extra[@]}"}" 2>&1
}

run_spawn_pairs() {  # <home> <wt> <fakebin> <spawn args...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
}

run_codex_spawn() {  # <home> <wt> <fakebin> <id> <proj> <env-prefix...>
  run_spawn "$@" -- --harness codex --model gpt-5 --effort high
}

# The batch refusal is a parent-side rule about half-spawned batches, so it is
# scoped to batches that actually have more than one pair; a single pair is one
# spawn and the lane guard owns it.
test_multi_pair_codex_batch_is_refused() {
  local rec id1 id2 out status
  id1=codexbatch-a-z8
  id2=codexbatch-b-z9
  rec=$(make_case multibatch "$id1" "$id2")
  read_case_record "$rec"

  out=$(run_spawn_pairs "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" \
    --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 1 "$status" "a multi-pair codex batch must be refused: $out"
  assert_contains "$out" "onto codex is refused" "refusal did not name the codex batch rule"
  [ ! -f "$HOME_DIR/state/$id1.meta" ] || fail "a refused batch must not spawn its first pair"
  [ ! -f "$HOME_DIR/state/$id2.meta" ] || fail "a refused batch must not spawn its second pair"
  pass "a multi-pair codex batch is refused before any pair spawns"
}

test_multi_pair_raw_codex_launch_batch_is_refused() {
  local rec id1 id2 out status
  id1=codexrawbatch-a-z11
  id2=codexrawbatch-b-z12
  rec=$(make_case multirawbatch "$id1" "$id2")
  read_case_record "$rec"

  out=$(run_spawn_pairs "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" \
    --harness 'codex --dangerously-bypass-approvals-and-sandbox' --model gpt-5 --effort high)
  status=$?
  expect_code 1 "$status" "a multi-pair batch on a raw codex launch must be refused: $out"
  assert_contains "$out" "onto codex is refused" "refusal did not name the codex batch rule"
  [ ! -f "$HOME_DIR/state/$id1.meta" ] || fail "a refused batch must not spawn its first pair"
  [ ! -f "$HOME_DIR/state/$id2.meta" ] || fail "a refused batch must not spawn its second pair"
  pass "a multi-pair batch whose --harness is a raw codex launch is refused before any pair spawns"
}

test_single_pair_codex_batch_still_spawns() {
  local rec id out status
  id=codexbatch-solo-z10
  rec=$(make_case solobatch "$id")
  read_case_record "$rec"

  out=$(run_spawn_pairs "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id=$PROJ_DIR" \
    --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "a single-pair codex batch is one spawn and must be allowed: $out"
  assert_contains "$out" "spawned $id harness=codex" "the single-pair codex batch did not spawn"
  pass "a single-pair codex batch still spawns"
}

test_live_local_codex_task_holds_the_lane() {
  local rec id out status
  id=codexlane-live-z1
  rec=$(make_case live "$id")
  read_case_record "$rec"
  write_sibling_meta "$HOME_DIR" other-codex-task codex ship

  out=$(run_codex_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    env FM_FAKE_WINDOWS='fm-other-codex-task
')
  status=$?
  expect_code 1 "$status" "a second codex spawn must be refused while another codex task is live: $out"
  assert_contains "$out" "Codex lane occupied in this home" "refusal did not name the occupied lane"
  assert_contains "$out" "$HOME_DIR/state" "refusal did not name the home the lane applies to"
  assert_contains "$out" "other-codex-task" "refusal did not name the occupying task"
  [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "refused spawn must not write $id.meta"
  pass "a live local codex task refuses a second codex spawn"
}

test_unknown_liveness_keeps_the_lane_occupied() {
  local rec id out status
  id=codexlane-unknown-z2
  rec=$(make_case unknown "$id")
  read_case_record "$rec"
  write_sibling_meta "$HOME_DIR" other-codex-task codex ship

  out=$(run_codex_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    env FM_FAKE_LIST_WINDOWS_ERR=1)
  status=$?
  expect_code 1 "$status" "an unreadable liveness must fail closed and hold the lane: $out"
  assert_contains "$out" "Codex lane occupied in this home" "refusal did not name the occupied lane"
  [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "refused spawn must not write $id.meta"
  pass "unknown liveness keeps the Codex lane occupied"
}

test_dead_local_codex_endpoint_releases_the_lane() {
  local rec id out status
  id=codexlane-dead-z3
  rec=$(make_case dead "$id")
  read_case_record "$rec"
  write_sibling_meta "$HOME_DIR" other-codex-task codex ship

  out=$(run_codex_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" env)
  status=$?
  expect_code 0 "$status" "a positively dead codex endpoint must free the lane: $out"
  assert_grep "harness=codex" "$HOME_DIR/state/$id.meta" "the freed lane did not publish the codex task"
  pass "a positively dead local codex endpoint releases the lane"
}

test_remote_codex_meta_does_not_hold_the_local_lane() {
  local rec id out status
  id=codexlane-remote-z4
  rec=$(make_case remote "$id")
  read_case_record "$rec"
  # A remote-routed codex agent runs on another host and never touches this
  # home's codex rediscovery or version probe, so it must not hold this lane.
  cat > "$HOME_DIR/state/remote-codex-task.meta" <<EOF
window=remote:remote-codex-task
endpoint_task_id=remote-codex-task
harness=codex
kind=secondmate
model=gpt-5
remote_host=pc02
remote_backend=herdr
remote_target=herdr-remote
EOF

  out=$(run_codex_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    env FM_FAKE_LIST_WINDOWS_ERR=1)
  status=$?
  expect_code 0 "$status" "a remote-routed codex meta must not block a local codex spawn: $out"
  assert_grep "harness=codex" "$HOME_DIR/state/$id.meta" "the local codex spawn did not publish its task"
  pass "a remote-routed codex meta leaves this home's Codex lane free"
}

test_live_local_codex_secondmate_holds_the_lane() {
  local rec id out status
  id=codexlane-secondmate-z5
  rec=$(make_case secondmate "$id")
  read_case_record "$rec"
  write_sibling_meta "$HOME_DIR" codex-secondmate codex secondmate

  out=$(run_codex_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    env FM_FAKE_WINDOWS='fm-codex-secondmate
')
  status=$?
  expect_code 1 "$status" "a live local codex secondmate must hold the lane: $out"
  assert_contains "$out" "codex-secondmate" "refusal did not name the occupying secondmate"
  [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "refused spawn must not write $id.meta"
  pass "a live local codex secondmate occupies the lane for a codex worker spawn"
}

test_lane_is_codex_only_in_both_directions() {
  local rec id out status
  id=codexlane-otherharness-z6
  rec=$(make_case otherharness "$id" codexlane-codexnext-z7)
  read_case_record "$rec"
  write_sibling_meta "$HOME_DIR" other-codex-task codex ship

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    env FM_FAKE_WINDOWS='fm-other-codex-task
' -- --harness claude --model sonnet)
  status=$?
  expect_code 0 "$status" "a live codex task must not block a non-codex spawn: $out"
  assert_grep "harness=claude" "$HOME_DIR/state/$id.meta" "the non-codex spawn did not publish its task"

  rm -f "$HOME_DIR/state/other-codex-task.meta" "$HOME_DIR/state/$id.meta"
  write_sibling_meta "$HOME_DIR" other-claude-task claude ship
  out=$(run_codex_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" codexlane-codexnext-z7 "$PROJ_DIR" \
    env FM_FAKE_WINDOWS='fm-other-claude-task
')
  status=$?
  expect_code 0 "$status" "a live non-codex task must not occupy the Codex lane: $out"
  pass "the Codex lane only counts codex metas, in both directions"
}

test_locked_task_set_refuses_the_codex_relaunch_lane_read() {
  local rec id out status lockdir holder_pid before
  id=codexlane-locked-z8
  rec=$(make_case locked "$id")
  read_case_record "$rec"

  out=$(run_codex_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" env)
  status=$?
  expect_code 0 "$status" "the initial codex spawn should succeed: $out"
  before=$(cat "$HOME_DIR/state/$id.meta")

  # A relaunch is exempt from the fresh-spawn task-set lock, so it is the path
  # where the guard's own lock branch decides: an unreadable task set must
  # refuse rather than race a concurrent spawn for the single Codex lane.
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
    --harness codex --model gpt-5 --effort high 2>&1)
  status=$?
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  rm -rf "$lockdir"
  expect_code 1 "$status" "a codex relaunch must refuse while the lane read cannot be made authoritative: $out"
  assert_contains "$out" "Codex lane check cannot be made authoritative" \
    "refusal did not come from the codex lane guard's own lock branch"
  [ "$(cat "$HOME_DIR/state/$id.meta")" = "$before" ] || fail "the refused relaunch must not republish $id.meta"
  pass "a locked task set refuses the codex relaunch rather than racing the lane read"
}

test_live_local_codex_task_holds_the_lane
test_unknown_liveness_keeps_the_lane_occupied
test_dead_local_codex_endpoint_releases_the_lane
test_remote_codex_meta_does_not_hold_the_local_lane
test_live_local_codex_secondmate_holds_the_lane
test_lane_is_codex_only_in_both_directions
test_locked_task_set_refuses_the_codex_relaunch_lane_read
test_multi_pair_codex_batch_is_refused
test_multi_pair_raw_codex_launch_batch_is_refused
test_single_pair_codex_batch_still_spawns

echo "# all fm-spawn-codex-lane-guard tests passed"
