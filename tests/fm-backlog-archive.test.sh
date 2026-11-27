#!/usr/bin/env bash
# tests/fm-backlog-archive.test.sh - behavior tests for the parked-backlog
# archive path (bin/fm-backlog-archive.sh and its bin/fm-tasks-axi.sh
# delegation).
#
# The point of the path is a byte-exact round trip: a parked row leaves the
# live backlog with its hold, hold reason, body, and blocked-by links intact,
# stays readable as an ordinary tasks-axi markdown backlog, and comes back
# unchanged. The suite also pins the refusals that keep the two files from
# silently split dependencies: an unknown or Done id, an id already at the
# destination, archiving a row that still blocks live work, and unarchiving a
# row whose dependency would dangle in the live queue.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || {
  echo "skip: tasks-axi not found (required by the parked-archive path)"
  exit 0
}

ARCHIVE="$ROOT/bin/fm-backlog-archive.sh"
WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-archive)

# A fixture home: `<root>/.tasks.toml` plus `<root>/data/backlog.md`.
make_home() {  # <name>; prints the home directory
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
- [ ] blocker-b1 - active blocker (repo: x) (kind: ship) (since 2026-10-01)
- [ ] parked-p3 - parked thing blocked-by: blocker-b1 (repo: x) (kind: ship) (since 2026-10-02) (hold: paused PC02) (hold-kind: parked)
  Body line one.
  Body line two.

  Second paragraph.
- [ ] other-o4 - unrelated open thing (repo: x) (kind: ship) (since 2026-10-03)
## Done
- [x] old-d5 - finished thing (repo: x) (kind: ship) (since 2026-09-01) (done 2026-09-02)
EOF
  printf '%s\n' "$home"
}

run_archive() {  # <home> <args...>
  local home=$1
  shift
  ( cd "$TMP_ROOT" && FM_DATA_OVERRIDE="$home/data" "$ARCHIVE" "$@" )
}

run_wrapper() {  # <home> <args...>
  local home=$1
  shift
  ( cd "$TMP_ROOT" && FM_DATA_OVERRIDE="$home/data" "$WRAPPER" "$@" )
}

show_archived() {  # <home> <id>
  local home=$1 id=$2
  ( cd "$home" && tasks-axi show "$id" --file "$home/data/backlog-archive.md" 2>&1 )
}

show_live() {  # <home> <id>
  local home=$1 id=$2
  ( cd "$home" && tasks-axi show "$id" --file "$home/data/backlog.md" 2>&1 )
}

test_archive_preserves_hold_links_and_body() {
  local home out archived
  home=$(make_home preserve)
  out=$(run_archive "$home" archive parked-p3 2>&1) || fail "archive failed: $out"

  assert_no_grep "parked-p3" "$home/data/backlog.md" "the archived row stayed in the live backlog"
  assert_grep "blocker-b1" "$home/data/backlog.md" "an unrelated blockers row was disturbed"
  assert_grep "other-o4" "$home/data/backlog.md" "an unrelated queued row was disturbed"
  assert_grep "old-d5" "$home/data/backlog.md" "Done history was disturbed"

  assert_grep "parked-p3" "$home/data/backlog-archive.md" "the row did not reach the archive"
  assert_grep "blocked-by: blocker-b1" "$home/data/backlog-archive.md" "the blocked-by link was not preserved"
  assert_grep "Body line one." "$home/data/backlog-archive.md" "the first body line did not move"
  assert_grep "Body line two." "$home/data/backlog-archive.md" "the second body line did not move"
  assert_grep "Second paragraph." "$home/data/backlog-archive.md" "the second body paragraph did not move"

  archived=$(show_archived "$home" parked-p3)
  assert_contains "$archived" "held: yes" "the archived row lost its hold"
  assert_contains "$archived" "hold_reason: paused PC02" "the archived row lost its hold reason"
  assert_contains "$archived" "hold_kind: parked" "the archived row lost its hold kind"
  assert_contains "$archived" 'deps: "blocked-by:blocker-b1"' "the archived row lost its dependency edge"
  assert_contains "$archived" "Body line two." "tasks-axi did not read the moved body"
  pass "archive keeps the hold, hold reason, blocked-by link, and multi-paragraph body while leaving everything else in place"
}

test_unarchive_round_trips_byte_exact() {
  local home after
  home=$(make_home roundtrip)
  run_archive "$home" archive parked-p3 >/dev/null || fail "archive failed"
  run_archive "$home" unarchive parked-p3 >/dev/null || fail "unarchive failed"

  assert_no_grep "parked-p3" "$home/data/backlog-archive.md" "the restored row stayed in the archive"
  assert_grep "parked-p3" "$home/data/backlog.md" "the restored row did not return to the live backlog"

  after=$(show_live "$home" parked-p3)
  assert_contains "$after" "hold_reason: paused PC02" "the restored row lost its hold reason"
  assert_contains "$after" "hold_kind: parked" "the restored row lost its hold kind"
  assert_contains "$after" "blocked_by: blocker-b1" "the restored row lost its live blocker link"
  assert_contains "$after" "Second paragraph." "the restored row lost its body"

  # Restoring appends at the end of Queued, so compare the item block itself.
  case "$(cat "$home/data/backlog.md")" in
    *"- [ ] parked-p3 - parked thing blocked-by: blocker-b1 (repo: x) (kind: ship) (since 2026-10-02) (hold: paused PC02) (hold-kind: parked)"*) ;;
    *) fail "the restored bullet was not byte-identical to the archived one" ;;
  esac
  pass "unarchive restores the row byte-exact with its hold and blocked-by link"
}

test_archive_parked_selects_only_parked_rows() {
  local home
  home=$(make_home parked-only)
  ( cd "$home" && tasks-axi add parked-q1 "second parked" --kind ship --repo x >/dev/null ) || fail "add parked-q1 failed"
  ( cd "$home" && tasks-axi hold parked-q1 --reason "waiting on hardware" --kind parked >/dev/null ) || fail "hold parked-q1 failed"
  ( cd "$home" && tasks-axi add captain-c2 "captain call" --kind captain --repo x >/dev/null ) || fail "add captain-c2 failed"
  ( cd "$home" && tasks-axi hold captain-c2 --reason "awaiting the captain" --kind captain >/dev/null ) || fail "hold captain-c2 failed"

  run_archive "$home" archive --parked >/dev/null || fail "--parked failed"

  assert_grep "parked-q1" "$home/data/backlog-archive.md" "--parked missed a parked-kind row"
  assert_grep "parked-p3" "$home/data/backlog-archive.md" "--parked missed the blocker-linked parked row"
  assert_no_grep "captain-c2" "$home/data/backlog-archive.md" "--parked archived a captain hold"
  assert_grep "captain-c2" "$home/data/backlog.md" "--parked removed a captain hold from the live backlog"
  pass "--parked selects only hold-kind parked rows"
}

test_refusals_leave_both_files_unchanged() {
  local home before live_before out rc
  home=$(make_home refusals)
  run_archive "$home" archive parked-p3 >/dev/null || fail "setup archive failed"
  before=$(cat "$home/data/backlog-archive.md")
  live_before=$(cat "$home/data/backlog.md")

  out=$(run_archive "$home" archive no-such-id 2>&1)
  rc=$?
  expect_code 2 "$rc" "unknown id"
  assert_contains "$out" "no item matched" "the unknown-id refusal did not explain itself"

  out=$(run_archive "$home" archive old-d5 2>&1)
  rc=$?
  expect_code 2 "$rc" "Done id"
  assert_contains "$out" "Done (historical)" "the Done refusal did not explain itself"

  out=$(run_archive "$home" archive parked-p3 2>&1)
  rc=$?
  expect_code 2 "$rc" "already archived id"
  assert_contains "$out" "already in" "the already-archived refusal did not explain itself"

  out=$(run_archive "$home" unarchive blocker-b1 2>&1)
  rc=$?
  expect_code 2 "$rc" "unarchive an id that is live"
  assert_contains "$out" "already in" "the already-live refusal did not explain itself"

  assert_equals "$before" "$(cat "$home/data/backlog-archive.md")" "a refused call changed the archive"
  assert_equals "$live_before" "$(cat "$home/data/backlog.md")" "a refused call changed the live backlog"
  pass "unknown, Done, already-archived, and already-live refusals change nothing"
}

test_archive_refuses_a_live_dependent() {
  local home before out rc
  home=$(make_home stranding)
  ( cd "$home" && tasks-axi block other-o4 --by parked-p3 >/dev/null ) || fail "block other-o4 failed"
  before=$(cat "$home/data/backlog.md")

  out=$(run_archive "$home" archive parked-p3 2>&1)
  rc=$?
  expect_code 2 "$rc" "archive with a live dependent"
  assert_contains "$out" "other-o4 is still blocked by it" "the stranding refusal did not name the dependent"
  assert_equals "$before" "$(cat "$home/data/backlog.md")" "the refused archive changed the live backlog"
  assert_absent "$home/data/backlog-archive.md" "the refused archive created an archive file"
  pass "archive refuses to leave a live task blocked by an archived id"
}

test_unarchive_preserves_a_dangling_dependency() {
  local home out after
  home=$(make_home dangling-dep)
  run_archive "$home" archive parked-p3 >/dev/null || fail "archiving the dependent failed"
  run_archive "$home" archive blocker-b1 >/dev/null || fail "archiving the blocker failed"

  out=$(run_archive "$home" unarchive parked-p3 2>&1) || fail "unarchiving a row whose blocker stayed archived failed: $out"
  assert_grep "parked-p3" "$home/data/backlog.md" "the dependent did not return to the live backlog"
  after=$(show_live "$home" parked-p3)
  assert_contains "$after" 'deps: "blocked-by:blocker-b1"' "the dangling blocked-by link was not carried back"
  assert_contains "$after" "hold_kind: parked" "the restored row lost its hold kind"
  pass "unarchive carries a blocked-by link whose target stays archived, matching the pruned-blocker case"
}

test_wrapper_delegates_and_keeps_tasks_axi_reads() {
  local home out
  home=$(make_home wrapper)
  out=$(run_wrapper "$home" archive parked-p3 2>&1) || fail "wrapper archive failed: $out"
  assert_grep "parked-p3" "$home/data/backlog-archive.md" "the wrapper did not reach the archive path"
  assert_no_grep "parked-p3" "$home/data/backlog.md" "the wrapper left the row live"

  out=$(run_wrapper "$home" list --state queued 2>&1) || fail "wrapper list failed after the archive change: $out"
  assert_contains "$out" "blocker-b1" "the normal tasks-axi list no longer reports live work"
  assert_not_contains "$out" "parked-p3" "the normal tasks-axi list still reports an archived row"

  out=$(run_wrapper "$home" archived 2>&1) || fail "wrapper archived listing failed: $out"
  assert_contains "$out" "parked-p3" "the archived listing did not report the parked row"
  pass "fm-tasks-axi.sh delegates archive and archived while ordinary reads still see only live work"
}

test_archive_preserves_hold_links_and_body
test_unarchive_round_trips_byte_exact
test_archive_parked_selects_only_parked_rows
test_refusals_leave_both_files_unchanged
test_archive_refuses_a_live_dependent
test_unarchive_preserves_a_dangling_dependency
test_wrapper_delegates_and_keeps_tasks_axi_reads

echo "PASS fm-backlog-archive.test.sh"
