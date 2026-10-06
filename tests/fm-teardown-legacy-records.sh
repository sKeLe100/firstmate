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

test_legacy_record_without_the_flag_refuses() {
  local case_dir rc
  case_dir=$(make_case legacy-noflag)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-noflag: a record without spawn_gen must refuse without --legacy-record"
  grep -q -- '--legacy-record' "$case_dir/stderr" \
    || fail "legacy-noflag: the refusal did not name the --legacy-record path"
  [ "$(legacy_meta_gen_count "$case_dir")" = 0 ] \
    || fail "legacy-noflag: the refusal stamped a spawn generation into the record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-noflag: the refusal closed the backlog item anyway"
  assert_present "$case_dir/state/task-x1.meta" \
    "legacy-noflag: the refusal removed the task record"
  pass "a record predating spawn_gen refuses teardown until --legacy-record is passed"
}
test_stale_index_lock_cleared_and_teardown_succeeds() {
  local case_dir rc lock
  case_dir=$(make_case stale-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-index-lock: teardown should succeed after clearing the provably stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "stale-index-lock: stale lock file should have been removed"
  pass "provably-stale worktree index.lock (old, no live holder) is cleared and teardown succeeds"
}
test_live_index_lock_is_never_removed_and_teardown_refuses() {
  local case_dir rc lock
  case_dir=$(make_case live-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Even an old mtime must not be enough on its own: a live holder always wins.
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "live-index-lock: teardown should refuse when the lock has a live holder"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "live-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "live-index-lock: teardown removed a lock with a live holder"
  [ -e "$lock" ] || fail "live-index-lock: live-held lock file was removed"
  pass "live-held worktree index.lock is never removed and teardown refuses"
}
test_lsof_error_never_clears_index_lock() {
  local case_dir rc lock
  case_dir=$(make_case lsof-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lsof-error-index-lock: teardown should refuse when lsof errors"
  assert_grep "REFUSED: cannot determine leaked processes" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not report the lsof failure"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "lsof-error-index-lock: teardown removed a lock after lsof failed"
  [ -e "$lock" ] || fail "lsof-error-index-lock: lock file was removed after lsof failed"
  pass "lsof errors leave worktree index.lock in place and refuse teardown"
}
test_stale_index_lock_cleanup_rechecks_dirty_worktree() {
  local case_dir rc lock
  case_dir=$(make_case stale-lock-dirty-recheck)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt landed "landed work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' dirty > "$case_dir/wt/feature.txt"

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_git_status_lock_failure "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-lock-dirty-recheck: teardown should refuse dirty work after clearing the stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not report clearing the stale lock"
  assert_grep "uncommitted changes present" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not re-run the dirty check"
  assert_absent "$lock" "stale-lock-dirty-recheck: stale lock file should have been removed"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "stale-lock-dirty-recheck: teardown completed despite dirty work"
  pass "stale lock cleanup rechecks and refuses dirty worktree before return"
}
test_non_linked_index_lock_path_is_checked_from_worktree() {
  local case_dir rc lock
  case_dir=$(make_case non-linked-index-lock)
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git clone -q "$case_dir/origin.git" "$case_dir/wt"
  git -C "$case_dir/wt" checkout -q -b fm/task-x1
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable normal clone work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/wt" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "non-linked-index-lock: teardown should clear a normal repo index.lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "non-linked-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "non-linked-index-lock: stale lock file should have been removed"
  pass "normal repo index.lock is resolved from the worktree and cleared when stale"
}

write_windowless_legacy_meta() {
  local case_dir=$1 mode=$2 kind=$3 worktree
  worktree=${4:-$case_dir/wt}
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "worktree=$worktree" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "harness=codex"
}

test_windowless_legacy_record_with_gone_worktree_tears_down() {
  local case_dir out
  case_dir=$(make_case windowless-gone)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir") \
    || fail "windowless-gone: teardown refused a leftover with no window, no spawn_gen, and no worktree"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing' \
    || fail "windowless-gone: the teardown line did not log the missing-endpoint leftover: $out"
  printf '%s\n' "$out" | grep -Fq 'window none' \
    || fail "windowless-gone: the teardown line did not say there was no window: $out"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "windowless-gone: teardown returned success with its backlog item still open"
  assert_absent "$case_dir/state/task-x1.meta" \
    "windowless-gone: teardown left the leftover record"
  pass "a windowless leftover with no spawn_gen and no worktree tears down without --legacy-record"
}

test_windowless_legacy_record_tears_down_with_the_legacy_flag() {
  local case_dir out
  case_dir=$(make_case windowless-flag)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir" --legacy-record) \
    || fail "windowless-flag: --legacy-record refused a leftover with no window and no spawn_gen"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing' \
    || fail "windowless-flag: the teardown line did not log the missing-endpoint leftover: $out"
  assert_absent "$case_dir/state/task-x1.meta" \
    "windowless-flag: teardown left the leftover record"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "windowless-flag: teardown returned success with its backlog item still open"
  pass "a windowless leftover with no spawn_gen also tears down when --legacy-record is passed"
}

test_windowless_legacy_record_still_refuses_unlanded_work() {
  local case_dir rc before
  case_dir=$(make_case windowless-unlanded)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit_file "$case_dir" feature.txt unique-windowless-content "real unlanded work"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "windowless-unlanded: a still-present unlanded worktree must refuse"
  grep -q REFUSED "$case_dir/stderr" \
    || fail "windowless-unlanded: no REFUSED line for unlanded windowless work"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "windowless-unlanded: the unlanded refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "windowless-unlanded: the unlanded refusal closed the backlog item anyway"
  pass "a windowless leftover still refuses while its worktree holds unlanded work"
}

assert_windowless_record_refuses() {  # <case-dir> <description> <refusal>
  local case_dir=$1 description=$2 refusal=$3 rc before
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "$description: a windowless record outside the leftover class must refuse"
  grep -Fq "$refusal" "$case_dir/stderr" \
    || fail "$description: the refusal was not '$refusal': $(cat "$case_dir/stderr")"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "$description: the refusal modified the task record"
}

test_windowless_record_outside_the_leftover_class_still_refuses() {
  local case_dir
  case_dir=$(make_case windowless-spawn-gen)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'spawn_gen=s1700000000.1.abc' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-spawn-gen "missing, empty, or ambiguous window endpoint"

  case_dir=$(make_case windowless-orca)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'backend=orca' 'terminal=term-7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-orca "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-no-backlog)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  assert_windowless_record_refuses "$case_dir" windowless-no-backlog "missing, empty, or ambiguous window endpoint"

  case_dir=$(make_case windowless-dup-project)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' "project=$case_dir/other-project" >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-dup-project "no spawn_gen that identifies one exact incarnation"
  case_dir=$(make_case windowless-foreign-binding)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'endpoint_task_id=task-other' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-foreign-binding "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-terminal)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'terminal=term-7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-terminal "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-herdr-identity)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'backend=tmux' 'herdr_session=s1' 'herdr_pane_id=p1' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-herdr-identity "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-cmux-identity)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'cmux_surface_id=surface-1' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-cmux-identity "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-control-char)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing"$'\t'"wt"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-control-char "no spawn_gen that identifies one exact incarnation"
  pass "a windowless record with a spawn_gen, a non-tmux backend or endpoint identity, no backlog validation, or ambiguous, foreign, or malformed identity still refuses"
}

test_windowless_leftover_retries_its_retained_legacy_stamp_without_the_flag() {
  local case_dir rc out
  case_dir=$(make_case windowless-retry)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'pr=not-a-valid-url' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  add_failing_truncate_perl "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "windowless-retry: an unrecordable close must fail the first attempt"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "windowless-retry: the failed attempt did not leave its legacy stamp on the record"

  rm -f "$case_dir/fakebin/perl"
  sed -i.bak '/^pr=/d' "$case_dir/state/task-x1.meta" && rm -f "$case_dir/state/task-x1.meta.bak"
  out=$(run_teardown "$case_dir") \
    || fail "windowless-retry: the flag-less retry refused the retained legacy stamp"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing' \
    || fail "windowless-retry: the retry did not accept the missing-endpoint leftover: $out"
  assert_absent "$case_dir/state/task-x1.meta" \
    "windowless-retry: the retry left the leftover record"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "windowless-retry: the retry returned success with its backlog item still open"
  pass "a windowless leftover retries its retained legacy stamp without --legacy-record"
}
