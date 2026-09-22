#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's Gemini session-cap lane guard
# (gemini_lane_guard, bin/fm-spawn.sh): a spawn onto a Gemini-family model
# refuses once the Gemini-family session cap (data/captain.md "PROVIDER
# SESSION CAPS", FM_GEMINI_SESSION_CAP=2) is reached. Mirrors
# tests/fm-spawn-pc02-lane-guard.test.sh's end-to-end pattern: lock
# acquisition, the meta scan (counting live Gemini records, excluding self,
# excluding dead endpoints), liveness classification, and the refusal
# message. Fake tmux controls the liveness read the same way.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-gemini-lane-guard)

GEMINI_MODEL='gemini-openai/gemini-3.7-flash'

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
    printf '# Task\n## Captain'"'"'s intent\nbrief for %s\n\n## Firstmate spec\nExercise the spawn behavior under test.\n' "$id" > "$home/data/$id/brief.md"
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
harness=claude
kind=ship
model=$3
EOF
}

write_remote_gemini_meta() {  # <home> <task>
  cat > "$1/state/$2.meta" <<EOF
window=remote:$2
endpoint_task_id=$2
harness=opencode
kind=secondmate
model=$GEMINI_MODEL
remote_host=pc02
remote_backend=herdr
remote_target=herdr-remote
EOF
}

run_gemini_spawn() {
  local home=$1 wt=$2 fakebin=$3 id=$4 proj=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' PATH="$fakebin:$PATH" \
    "$@" "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off \
    --model "$GEMINI_MODEL" 2>&1
}

test_refuses_at_session_cap() {
  local rec id out status
  id=gemini-guard-z1
  rec=$(make_case atcap "$id")
  read_case_record "$rec"
  write_other_meta "$HOME_DIR" other-gemini-1 "$GEMINI_MODEL"
  write_other_meta "$HOME_DIR" other-gemini-2 "$GEMINI_MODEL"

  out=$(run_gemini_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    env FM_FAKE_WINDOWS='fm-other-gemini-1
fm-other-gemini-2
')
  status=$?
  expect_code 1 "$status" "spawn should refuse once the Gemini session cap is reached: $out"
  assert_contains "$out" "Gemini session cap reached" "refusal did not name the session cap"
  assert_contains "$out" "2 live Gemini-family sessions" "refusal did not name the live session count"
  [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "refused spawn must not write $id.meta"
  pass "a spawn refuses once two live Gemini-family sessions already occupy the cap"
}

test_proceeds_under_cap() {
  local rec id out status
  id=gemini-guard-z2
  rec=$(make_case undercap "$id")
  read_case_record "$rec"
  write_other_meta "$HOME_DIR" other-gemini-1 "$GEMINI_MODEL"

  out=$(run_gemini_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    env FM_FAKE_WINDOWS='fm-other-gemini-1
')
  status=$?
  expect_code 0 "$status" "spawn should proceed with one slot still free under the cap: $out"
  assert_grep "model=$GEMINI_MODEL" "$HOME_DIR/state/$id.meta" "meta missing the gemini model"
  pass "a spawn proceeds while under the Gemini session cap"
}

test_dead_endpoint_excluded_from_count() {
  local rec id out status
  id=gemini-guard-z3
  rec=$(make_case deadexcluded "$id")
  read_case_record "$rec"
  write_other_meta "$HOME_DIR" other-gemini-1 "$GEMINI_MODEL"
  write_other_meta "$HOME_DIR" other-gemini-2 "$GEMINI_MODEL"

  # Only other-gemini-1's window is listed; other-gemini-2 is positively dead
  # and must not count toward the cap.
  out=$(run_gemini_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    env FM_FAKE_WINDOWS='fm-other-gemini-1
')
  status=$?
  expect_code 0 "$status" "a positively dead Gemini endpoint must not occupy a cap slot: $out"
  assert_grep "model=$GEMINI_MODEL" "$HOME_DIR/state/$id.meta" "meta missing the gemini model"
  pass "a positively dead Gemini endpoint is excluded from the session count"
}

test_unknown_liveness_still_counts_toward_cap() {
  local rec id out status
  id=gemini-guard-z4
  rec=$(make_case unknown "$id")
  read_case_record "$rec"
  write_other_meta "$HOME_DIR" other-gemini-1 "$GEMINI_MODEL"
  write_other_meta "$HOME_DIR" other-gemini-2 "$GEMINI_MODEL"

  out=$(run_gemini_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    env FM_FAKE_LIST_WINDOWS_ERR=1)
  status=$?
  expect_code 1 "$status" "spawn should refuse while other Gemini endpoints' liveness is unknown: $out"
  assert_contains "$out" "Gemini session cap reached" "refusal did not name the session cap"
  pass "unknown liveness keeps both other Gemini sessions counted toward the cap"
}

test_remote_gemini_meta_counts_toward_cap() {
  local rec id out status
  id=gemini-guard-z5
  rec=$(make_case remotecap "$id")
  read_case_record "$rec"
  # A remote secondmate's meta carries no local endpoint to probe (its target
  # lives behind the remote host), so it must count toward the cap rather than
  # be skipped as unreachable.
  write_remote_gemini_meta "$HOME_DIR" remote-gemini-task
  write_other_meta "$HOME_DIR" other-gemini-1 "$GEMINI_MODEL"

  out=$(run_gemini_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    env FM_FAKE_WINDOWS='fm-other-gemini-1
')
  status=$?
  expect_code 1 "$status" "a remote Gemini session must count toward the cap: $out"
  assert_contains "$out" "Gemini session cap reached" "refusal did not name the session cap"
  pass "a remote secondmate's live Gemini session counts toward the cap"
}

test_ignores_non_gemini_metas() {
  local rec id out status
  id=gemini-guard-z6
  rec=$(make_case nongemini "$id")
  read_case_record "$rec"
  write_other_meta "$HOME_DIR" other-1 pc02-llamaswap/qwen3.6-35b-a3b-dispatch
  write_other_meta "$HOME_DIR" other-2 claude-sonnet-5

  out=$(run_gemini_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    env FM_FAKE_LIST_WINDOWS_ERR=1)
  status=$?
  expect_code 0 "$status" "non-Gemini metas must never occupy a Gemini session slot: $out"
  pass "non-Gemini metas never count toward the Gemini session cap"
}

test_refuses_while_task_set_locked() {
  local rec id out status lockdir holder_pid
  id=gemini-guard-z7
  rec=$(make_case tasksetlock "$id")
  read_case_record "$rec"

  lockdir="$HOME_DIR/state/.task-set.lock"
  mkdir -p "$lockdir"
  /bin/sleep 30 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" > "$lockdir/pid"

  out=$(run_gemini_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" env)
  status=$?
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  expect_code 1 "$status" "a Gemini spawn must refuse while the task set is locked: $out"
  assert_contains "$out" "task set is locked" "refusal did not name the task-set lock"
  [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "refused spawn must not write $id.meta"

  rm -rf "$lockdir"
  pass "a Gemini spawn refuses to make the session-cap read authoritative while the task set is locked"
}

test_refuses_at_session_cap
test_proceeds_under_cap
test_dead_endpoint_excluded_from_count
test_unknown_liveness_still_counts_toward_cap
test_remote_gemini_meta_counts_toward_cap
test_ignores_non_gemini_metas
test_refuses_while_task_set_locked

echo "# all fm-spawn-gemini-lane-guard tests passed"
