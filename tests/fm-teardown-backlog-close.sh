#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh -- split from fm-teardown.test.sh.
#
# Sourced by fm-teardown.test.sh which runs the full suite.
# Each file contains a logical group of test cases that were extracted
# from the original 3546-line file to reduce per-script test timeout.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-teardown-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-lib.sh"
set -u

fm_git_identity fmtest fmtest@example.invalid

test_legacy_record_teardown_completes_when_landed_and_endpoint_dead() {
  local case_dir out
  case_dir=$(make_case legacy-allow)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  # The default fakebin tmux answers every query with success and no output, so
  # the classifier reads the recorded window as authoritatively missing.

  out=$(run_teardown "$case_dir" --legacy-record) \
    || fail "legacy-allow: teardown refused a landed legacy record with a dead endpoint"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "legacy-allow: teardown returned success with its backlog item still open"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing, incarnation legacy-' \
    || fail "legacy-allow: the teardown line did not log the accepted legacy incarnation: $out"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "legacy-allow: a landed legacy close left its pending-close record behind"
  assert_absent "$case_dir/state/task-x1.meta" \
    "legacy-allow: teardown left the task record behind"
  pass "a landed legacy record with a dead endpoint tears down and logs its accepted incarnation"
}
test_legacy_record_teardown_refuses_unlanded_work() {
  local case_dir rc before
  case_dir=$(make_case legacy-unlanded)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  # Real content committed but pushed nowhere and merged nowhere.
  wt_commit_file "$case_dir" feature.txt unique-legacy-content "real unlanded work"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-unlanded: --legacy-record must not relax the unlanded-work refusal"
  grep -q REFUSED "$case_dir/stderr" \
    || fail "legacy-unlanded: no REFUSED line for unlanded legacy work"
  [ "$(legacy_meta_gen_count "$case_dir")" = 0 ] \
    || fail "legacy-unlanded: the unlanded refusal stamped a spawn generation into the record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-unlanded: the unlanded refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-unlanded: the unlanded refusal closed the backlog item anyway"
  pass "--legacy-record never relaxes the unlanded-work refusal"
}
test_legacy_record_teardown_refuses_an_ambiguous_endpoint() {
  local case_dir rc before
  case_dir=$(make_case legacy-ambiguous)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  add_unreadable_tmux "$case_dir"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-ambiguous: an unreadable endpoint must refuse the legacy acceptance"
  grep -q "not confidently dead or agent-less" "$case_dir/stderr" \
    || fail "legacy-ambiguous: the refusal did not name the endpoint state"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-ambiguous: the endpoint refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-ambiguous: the endpoint refusal closed the backlog item anyway"
  pass "an endpoint that cannot be confidently read as dead refuses --legacy-record teardown"
}
test_legacy_record_rolls_the_stamp_back_when_the_marker_write_fails() {
  local case_dir rc before
  case_dir=$(make_case legacy-stamp-rollback)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=not-a-valid-url' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" \
    "legacy-stamp-rollback: an unrecordable close must fail the teardown after accepting the legacy record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-stamp-rollback: the failed marker write left the record modified"
  grep -q "rolled back" "$case_dir/stderr" \
    || fail "legacy-stamp-rollback: the refusal did not report the rolled-back stamp"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-stamp-rollback: the failed teardown closed the backlog item anyway"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-rollback: the flag-less retry must not sail past the endpoint gate on the rolled-back record"
  grep -q -- '--legacy-record' "$case_dir/stderr2" \
    || fail "legacy-stamp-rollback: the retry refusal did not name the flag path"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-stamp-rollback: the flag-less retry modified the record"
  pass "--legacy-record teardown rolls its stamp back when the close marker write fails"
}
test_retained_legacy_stamp_still_faces_the_endpoint_gate() {
  local case_dir rc stamped
  case_dir=$(make_case legacy-stamp-retained)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=not-a-valid-url' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  add_failing_truncate_perl "$case_dir"

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-retained: an unrecordable close must fail the teardown after accepting the legacy record"
  grep -q "could not be rolled back" "$case_dir/stderr" \
    || fail "legacy-stamp-retained: the fixture did not exercise a failed rollback"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "legacy-stamp-retained: the abandoned attempt did not leave its stamp on the record"
  stamped=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  # The stamp the failed rollback left behind is the whole risk: a retry must
  # not read it as an incarnation some spawn published and sail past the
  # dead-or-agent-less endpoint gate onto a reused endpoint.
  add_unreadable_tmux "$case_dir"
  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-retained: the retry must re-run the endpoint gate on the retained stamp"
  grep -q "not confidently dead or agent-less" "$case_dir/stderr2" \
    || fail "legacy-stamp-retained: the retry skipped the dead-or-agent-less endpoint gate"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "legacy-stamp-retained: the retry stamped a second incarnation into the record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$stamped" ] \
    || fail "legacy-stamp-retained: the endpoint refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-stamp-retained: the endpoint refusal closed the backlog item anyway"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout3" 2> "$case_dir/stderr3"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-retained: a flag-less retry must refuse the retained legacy stamp"
  grep -q -- '--legacy-record' "$case_dir/stderr3" \
    || fail "legacy-stamp-retained: the flag-less refusal did not name the flag path"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$stamped" ] \
    || fail "legacy-stamp-retained: the flag-less refusal modified the task record"
  pass "a legacy stamp a failed rollback left behind still faces the endpoint gate"
}
test_close_removes_opencode_session_and_gcs_the_routing_row() {
  local case_dir out
  case_dir=$(make_case opencode-routing-close)
  write_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed work"
  add_fork_with_pushed_branch "$case_dir"
  : > "$case_dir/state/task-x1.opencode-session"
  FM_DATA_OVERRIDE="$case_dir/data" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-backlog-routing.sh" set task-x1 pc02 >/dev/null \
    || fail "opencode-routing-close: fixture could not seed a routing row"

  out=$(run_teardown "$case_dir") || fail "opencode-routing-close: teardown failed: $out"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "opencode-routing-close: teardown returned success with its backlog item still open"
  assert_absent "$case_dir/state/task-x1.opencode-session" \
    "opencode-routing-close: teardown left the opencode session id file behind"
  FM_DATA_OVERRIDE="$case_dir/data" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-backlog-routing.sh" get task-x1 >/dev/null 2>&1 \
    && fail "opencode-routing-close: the routing row survived a real close"
  pass "closing a task removes its opencode session id file and its routing classification"
}
test_retain_keeps_the_routing_row_for_the_still_open_item() {
  local case_dir out
  case_dir=$(make_case retain-keeps-routing)
  write_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold task-x1 --reason "fixture hold" >/dev/null \
    || fail "retain-keeps-routing: fixture could not hold the item for the captain"
  wt_commit "$case_dir" "work in progress"
  add_fork_with_pushed_branch "$case_dir"
  FM_DATA_OVERRIDE="$case_dir/data" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-backlog-routing.sh" set task-x1 pc02 >/dev/null \
    || fail "retain-keeps-routing: fixture could not seed a routing row"

  out=$(run_teardown "$case_dir") || fail "retain-keeps-routing: teardown failed: $out"
  [ "$(backlog_row_state "$case_dir")" = "queued" ] \
    || fail "retain-keeps-routing: a captain-held item must return to Queued, not close"
  FM_DATA_OVERRIDE="$case_dir/data" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-backlog-routing.sh" get task-x1 >/dev/null 2>&1 \
    || fail "retain-keeps-routing: the routing row for a still-open item must not be garbage collected"
  pass "a retain transition (captain hold) leaves the routing row in place, since the item is still open"
}
# Parking retires the worker but keeps its work where it is: unlanded commits
# and uncommitted edits survive in place on their branch, the local copy is
# never returned, and the row goes back to Queued held as parked with the
# retained copy's path recorded on it.
test_park_retains_the_local_copy_and_queues_the_item_held_parked() {
  local case_dir out show
  case_dir=$(make_case park-retains-copy)
  write_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "unlanded experiment"
  printf 'scratch\n' > "$case_dir/wt/uncommitted.txt"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  FM_DATA_OVERRIDE="$case_dir/data" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-backlog-routing.sh" set task-x1 pc02 >/dev/null \
    || fail "park-retains-copy: fixture could not seed a routing row"

  out=$(run_teardown "$case_dir" --park) || fail "park-retains-copy: park failed: $out"
  assert_contains "$out" "parked" "park-retains-copy: the outcome did not say the task was parked"
  assert_absent "$case_dir/state/task-x1.meta" "park-retains-copy: the task record survived the park"
  [ -f "$case_dir/wt/uncommitted.txt" ] \
    || fail "park-retains-copy: an uncommitted edit in the retained copy was lost"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD)" = fm/task-x1 ] \
    || fail "park-retains-copy: the retained copy left its task branch"
  git -C "$case_dir/wt" log -1 --format=%s | grep -qx 'unlanded experiment' \
    || fail "park-retains-copy: the unlanded commit is gone from the retained copy"
  if grep -q 'return' "$case_dir/treehouse.log" 2>/dev/null; then
    fail "park-retains-copy: the retained copy was returned to the pool: $(cat "$case_dir/treehouse.log")"
  fi
  show=$(tasks-axi show task-x1 --full --file "$case_dir/data/backlog.md")
  [ "$(backlog_row_state "$case_dir")" = queued ] \
    || fail "park-retains-copy: the item did not return to Queued: $show"
  printf '%s\n' "$show" | grep -qx '  held: yes' \
    || fail "park-retains-copy: the item is not held: $show"
  printf '%s\n' "$show" | grep -qx '  hold_kind: parked' \
    || fail "park-retains-copy: the item is not held as parked: $show"
  printf '%s\n' "$show" | grep -F "Retained local copy: $case_dir/wt" >/dev/null \
    || fail "park-retains-copy: the retained copy path was not recorded on the item: $show"
  FM_DATA_OVERRIDE="$case_dir/data" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-backlog-routing.sh" get task-x1 >/dev/null 2>&1 \
    || fail "park-retains-copy: the routing row for a still-open item was garbage collected"
  pass "parking keeps the local copy in place and returns the item to Queued held as parked"
}

# Parking replaces the row's hold, so it must never run over a captain call, and
# it keeps the copy, so it has no business beside --force. Both refusals leave
# the record and the row exactly as they were.
test_park_refuses_a_captain_call_and_force() {
  local case_dir rc
  case_dir=$(make_case park-refusals)
  write_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  set +e
  run_teardown "$case_dir" --park --force > "$case_dir/out1" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "park-refusals: --park --force was not refused (rc=$rc): $(cat "$case_dir/out1")"
  FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold task-x1 --reason "fixture hold" >/dev/null \
    || fail "park-refusals: fixture could not hold the item for the captain"
  set +e
  run_teardown "$case_dir" --park > "$case_dir/out2" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "park-refusals: parking over an open captain call succeeded"
  grep -q 'held for the captain' "$case_dir/out2" \
    || fail "park-refusals: the refusal did not name the captain call: $(cat "$case_dir/out2")"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "park-refusals: the refusal removed the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "park-refusals: the refusal moved the item"
  pass "parking refuses an open captain call and --force, changing nothing"
}

# Parking keeps the local copy in place instead of returning it, so it refuses
# outright when the task has no local copy of its own left to keep.
test_park_refuses_a_missing_local_copy() {
  local case_dir rc
  case_dir=$(make_case park-missing-copy)
  write_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  rm -rf "$case_dir/wt"

  set +e
  run_teardown "$case_dir" --park > "$case_dir/out1" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "park-missing-copy: parking with no local copy succeeded"
  grep -q 'has no local copy of its own to retain' "$case_dir/out1" \
    || fail "park-missing-copy: the refusal did not name the missing copy: $(cat "$case_dir/out1")"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "park-missing-copy: the refusal removed the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "park-missing-copy: the refusal moved the item"
  pass "parking refuses a task with no local copy of its own to retain"
}

# A park interrupted after its pending record was written replays at the next
# session start into the same parked row, exactly as a close or a retention does.
test_park_pending_record_replays_to_a_parked_row() {
  local case_dir out
  case_dir=$(make_case park-replay)
  write_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  out=$(
    # shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
    . "$ROOT/bin/fm-tasks-axi-lib.sh"
    # shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
    . "$ROOT/bin/fm-backlog-transition-lib.sh"
    fm_backlog_close_marker_write "$case_dir/state" task-x1 "$case_dir/data" \
      teardown-test-task-x1 --park --copy "$case_dir/wt" \
      || { echo "write: $FM_BACKLOG_TRANSITION_ERROR"; exit 1; }
    fm_backlog_close_marker_replay "$case_dir/state" "$case_dir/state/task-x1.backlog-close" \
      "$case_dir/data" || { echo "replay: $FM_BACKLOG_TRANSITION_ERROR"; exit 1; }
    printf '%s\n' "$FM_BACKLOG_CLOSE_REPLAY_RESULT"
  ) || fail "park-replay: $out"
  [ "$out" = parked_incomplete ] || fail "park-replay: replay reported $out, not parked_incomplete"
  assert_absent "$case_dir/state/task-x1.meta" "park-replay: replay left the task record"
  assert_absent "$case_dir/state/task-x1.backlog-close" "park-replay: replay left the pending record"
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" | grep -qx '  hold_kind: parked' \
    || fail "park-replay: the replayed item is not held as parked"
  [ -d "$case_dir/wt" ] || fail "park-replay: replay touched the retained copy"
  pass "an interrupted park replays into the same parked row"
}

# If the row becomes an open captain call in the window between marker staging
# and replay (a process crash during teardown), replay must never overwrite
# that hold with a parked hold, since that would drop the captain's question;
# it escalates to a retain and still records the retained copy's path.
test_park_replay_escalates_to_retain_over_a_captain_hold() {
  local case_dir out show
  case_dir=$(make_case park-replay-captain)
  write_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold task-x1 --reason "fixture hold" >/dev/null \
    || fail "park-replay-captain: fixture could not hold the item for the captain"
  out=$(
    # shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
    . "$ROOT/bin/fm-tasks-axi-lib.sh"
    # shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
    . "$ROOT/bin/fm-backlog-transition-lib.sh"
    fm_backlog_close_marker_write "$case_dir/state" task-x1 "$case_dir/data" \
      teardown-test-task-x1 --park --copy "$case_dir/wt" \
      || { echo "write: $FM_BACKLOG_TRANSITION_ERROR"; exit 1; }
    fm_backlog_close_marker_replay "$case_dir/state" "$case_dir/state/task-x1.backlog-close" \
      "$case_dir/data" || { echo "replay: $FM_BACKLOG_TRANSITION_ERROR"; exit 1; }
    printf '%s\n' "$FM_BACKLOG_CLOSE_REPLAY_RESULT"
  ) || fail "park-replay-captain: $out"
  [ "$out" = retained_incomplete ] \
    || fail "park-replay-captain: replay reported $out, not retained_incomplete"
  assert_absent "$case_dir/state/task-x1.meta" "park-replay-captain: replay left the task record"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "park-replay-captain: replay left the pending record"
  show=$(tasks-axi show task-x1 --full --file "$case_dir/data/backlog.md")
  printf '%s\n' "$show" | grep -qx '  hold_kind: captain' \
    || fail "park-replay-captain: the captain hold was replaced: $show"
  printf '%s\n' "$show" | grep -F "Retained local copy: $case_dir/wt" >/dev/null \
    || fail "park-replay-captain: the retained copy path was not recorded on the item: $show"
  pass "an interrupted park replayed over a captain hold escalates to retain, keeping the hold"
}

test_legacy_record_never_accepts_a_corrupt_spawn_gen() {
  local case_dir rc
  case_dir=$(make_case legacy-corrupt)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf 'spawn_gen=one\nspawn_gen=two\n' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-corrupt: an ambiguous spawn_gen must refuse even with --legacy-record"
  grep -q "unreadable spawn_gen" "$case_dir/stderr" \
    || fail "legacy-corrupt: the refusal did not name the unreadable spawn_gen"
  [ "$(legacy_meta_gen_count "$case_dir")" = 2 ] \
    || fail "legacy-corrupt: the refusal rewrote the corrupt record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-corrupt: the refusal closed the backlog item anyway"
  pass "a corrupt spawn_gen is never accepted as a legacy record"
}
