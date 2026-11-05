#!/usr/bin/env bash
# fm-control.sh relaunch --move-session: relocating a proven-gone herdr endpoint
# into the seat's session. Split from tests/fm-control-relaunch.test.sh (size
# ceiling); it reuses that file's hermetic helpers by sourcing it library-only.
set -u

FM_RELAUNCH_LIB_ONLY=1
# shellcheck source=tests/fm-control-relaunch.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-control-relaunch.test.sh"

test_herdr_move_session_relocates_a_proven_gone_endpoint() {
  local dir out rc=0 log branch_before head_before
  # The record names `fmlab` and its pane is gone; this seat sits in `firstmate`.
  # --move-session is the opt-in exception: both the endpoint and the record
  # follow the seat, while the worktree and branch stay untouched.
  herdr_case_or_skip move-session rl78 fmlab '%none' || {
    echo "skip - herdr move-session needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  printf 'landed on the branch\n' > "$dir/wt/committed.txt"
  git -C "$dir/wt" add committed.txt
  git -C "$dir/wt" -c user.email=t@example.com -c user.name=t commit -qm "work in progress"
  head_before=$(git -C "$dir/wt" rev-parse HEAD)
  branch_before=$(git -C "$dir/wt" rev-parse --abbrev-ref HEAD)

  out=$(FM_TEST_HERDR_SESSION=firstmate run_control "$dir" rl78 relaunch \
    --move-session --note "move the stranded task into the orchestrator session") || rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 0 "$rc" "a proven-gone endpoint should move into the seat's session"$'\n'"$out"$'\n'"$log"
  assert_contains "$log" "tab create" "the moved task must get a fresh endpoint"
  assert_contains "$(grep 'tab create' "$dir/fake/herdr-log")" "--session firstmate" \
    "the replacement endpoint must be created in the moving seat's session"
  [ "$(meta_field "$dir" rl78 herdr_session)" = firstmate ] || fail "the record must follow the endpoint into the seat's session"
  [ "$(meta_field "$dir" rl78 window)" = 'firstmate:%9' ] || fail "the record's endpoint must be the pane minted in firstmate"
  [ "$(meta_field "$dir" rl78 herdr_pane_id)" = '%9' ] || fail "the record's pane id must follow the move"
  [ "$(meta_field "$dir" rl78 herdr_workspace_id)" = wsnew ] || fail "the record's workspace must follow the move"
  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head_before" ] || fail "moving the endpoint moved the worktree's HEAD"
  [ "$(git -C "$dir/wt" rev-parse --abbrev-ref HEAD)" = "$branch_before" ] || fail "moving the endpoint changed the worktree's branch"
  assert_contains "$(cat "$dir/home/data/rl78/brief.md")" \
    "move the stranded task into the orchestrator session" "the move must still carry the progress note"
  pass "move-session: a proven-gone endpoint is relocated into the seat's session with the record"
}

test_herdr_move_session_requires_the_flag_for_a_cross_session_seat() {
  local dir out rc log
  # Same stranded task, and this seat is inside a pane of `firstmate` - but
  # without the flag the reclaim must keep today's cross-session refusal.
  herdr_case_or_skip move-session-noflag rl79 fmlab '%none' || {
    echo "skip - herdr move-session needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR

  out=$(FM_TEST_HERDR_SESSION=firstmate FM_TEST_HERDR_PANE=w7:p3 \
    run_spawn "$dir" rl79 --relaunch --harness claude); rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 1 "$rc" "a cross-session seat without --move-session must keep the refusal"$'\n'"$out"$'\n'"$log"
  assert_contains "$out" "never moves a task to another session" "the refusal should be the unchanged cross-session refusal"
  assert_contains "$out" "herdr session 'firstmate'" "the refusal should name the seat's session"
  assert_not_contains "$log" "tab create" "a refused move must not mint an endpoint"
  [ "$(meta_field "$dir" rl79 herdr_session)" = fmlab ] || fail "a refused move rewrote the recorded session"
  [ "$(meta_field "$dir" rl79 window)" = 'fmlab:%7' ] || fail "a refused move rewrote the recorded endpoint"
  pass "move-session: without the flag a cross-session reclaim keeps today's refusal"
}

test_herdr_move_session_refuses_a_seat_without_a_named_session() {
  local dir out rc log
  herdr_case_or_skip move-session-nosession rl81 fmlab '%none' || {
    echo "skip - herdr move-session needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR

  out=$(run_control "$dir" rl81 relaunch --move-session --note "no seat session"); rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 1 "$rc" "a seat with no herdr session must refuse a move"$'\n'"$out"$'\n'"$log"
  assert_contains "$out" "named herdr session" "the refusal should say why"
  assert_not_contains "$log" "tab create" "a refused move must not mint an endpoint in default"
  [ "$(meta_field "$dir" rl81 herdr_session)" = fmlab ] || fail "a refused move rewrote the recorded session"
  [ "$(meta_field "$dir" rl81 window)" = 'fmlab:%7' ] || fail "a refused move rewrote the recorded endpoint"
  pass "move-session: a seat with no named herdr session refuses before anything is stopped"
}

test_herdr_move_session_refuses_the_recorded_session() {
  local dir out rc log
  herdr_case_or_skip move-session-same rl82 firstmate '%none' || {
    echo "skip - herdr move-session needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR

  out=$(FM_TEST_HERDR_SESSION=firstmate run_control "$dir" rl82 relaunch --move-session --note "same session"); rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 1 "$rc" "a move into the recorded session must refuse"$'\n'"$out"$'\n'"$log"
  assert_contains "$out" "other than task rl82's recorded session" "the refusal should name the recorded session"
  assert_not_contains "$log" "tab create" "a refused move must not mint an endpoint"
  pass "move-session: a seat already in the recorded session refuses"
}

test_herdr_move_session_from_an_orchestrator_pane() {
  local dir out rc=0 log
  herdr_case_or_skip move-session-pane rl83 fmlab '%none' || {
    echo "skip - herdr move-session needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  mkdir -p "$dir/fake/sock"
  : > "$dir/fake/herdr-launcher"

  out=$(FM_TEST_HERDR_SESSION=firstmate FM_TEST_HERDR_PANE=w7:p3 \
    FM_TEST_HERDR_SOCKET="$dir/fake/sock/herdr.sock" \
    run_control "$dir" rl83 relaunch --move-session --note "move from the orchestrator pane") || rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 0 "$rc" "a move from a pane inside the target session should succeed"$'\n'"$out"$'\n'"$log"
  assert_contains "$(grep 'tab create' "$dir/fake/herdr-log")" "--session firstmate" \
    "the replacement endpoint must be created in the orchestrator's session"
  [ "$(meta_field "$dir" rl83 herdr_session)" = firstmate ] || fail "the record must follow the endpoint into the orchestrator's session"
  pass "move-session: a move from an orchestrator pane lands in its session"
}

test_herdr_move_session_names_both_sessions_when_the_recreate_fails() {
  local dir out rc log
  herdr_case_or_skip move-session-fails rl84 fmlab '%none' || {
    echo "skip - herdr move-session needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  : > "$dir/fake/herdr-workspace-create-fails"

  out=$(FM_TEST_HERDR_SESSION=firstmate run_spawn "$dir" rl84 --relaunch --harness claude --move-session); rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 1 "$rc" "a failed re-create during a move must refuse"$'\n'"$out"$'\n'"$log"
  assert_contains "$out" "moved from its recorded herdr session 'fmlab' into this seat's session 'firstmate'" \
    "the diagnostic must name the recorded and the target session"
  assert_not_contains "$out" "a reclaim never moves a task to another session" "a requested move must not claim moves are refused"
  [ "$(meta_field "$dir" rl84 herdr_session)" = fmlab ] || fail "a failed move rewrote the recorded session"
  pass "move-session: a failed re-create names both the recorded and target session"
}

test_herdr_move_session_refuses_an_endpoint_that_still_exists() {
  local dir out rc log brief_before
  # The pane survived and its agent is back. --move-session must refuse before
  # anything is stopped: moving a live endpoint would orphan it.
  herdr_case_or_skip move-session-live rl80 fmlab '%7' || {
    echo "skip - herdr move-session needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  : > "$dir/fake/herdr-agent-live"
  brief_before=$(cat "$dir/home/data/rl80/brief.md")

  out=$(FM_TEST_HERDR_SESSION=firstmate run_control "$dir" rl80 relaunch \
    --move-session --note "this note must never reach a live endpoint"); rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 1 "$rc" "an endpoint that still exists must refuse a move"$'\n'"$out"$'\n'"$log"
  assert_contains "$out" "only moves an endpoint proven gone" "the refusal should state the proven-gone requirement"
  assert_contains "$out" "alive" "the refusal should name the state it actually read"
  assert_not_contains "$log" "tab create" "a refused move must not mint a second endpoint"
  assert_not_contains "$log" "workspace create" "a refused move must not create a workspace"
  [ "$(meta_field "$dir" rl80 herdr_session)" = fmlab ] || fail "a refused move rewrote the recorded session"
  [ "$(meta_field "$dir" rl80 window)" = 'fmlab:%7' ] || fail "a refused move rewrote the recorded endpoint"
  [ "$(cat "$dir/home/data/rl80/brief.md")" = "$brief_before" ] || fail "a refused move edited instructions a live agent may still be reading"
  pass "move-session: an endpoint that still exists refuses before the agent is touched"
}

test_herdr_move_session_relocates_a_proven_gone_endpoint
test_herdr_move_session_requires_the_flag_for_a_cross_session_seat
test_herdr_move_session_refuses_a_seat_without_a_named_session
test_herdr_move_session_refuses_the_recorded_session
test_herdr_move_session_from_an_orchestrator_pane
test_herdr_move_session_names_both_sessions_when_the_recreate_fails
test_herdr_move_session_refuses_an_endpoint_that_still_exists
