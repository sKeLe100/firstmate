#!/usr/bin/env bash
# tests/fm-backlog-archive.test.sh - behavior tests for the parked-backlog
# archive path (bin/fm-backlog-archive.sh and its bin/fm-tasks-axi.sh
# delegation).
#
# The point of the path is a byte-exact round trip: a parked row leaves the
# live backlog with its hold, hold reason, body, and blocked-by links intact,
# stays readable as an ordinary tasks-axi markdown backlog, and comes back
# unchanged, with file modes and section layout stable across cycles. The suite
# also pins the refusals: an unknown or Done id, an id already at the
# destination, an In flight id or one with a task record, archiving a row that
# still blocks live work, unarchiving a row whose blocker is still open in the
# archive (a pruned blocker is allowed), a held or stale lock, a noncanonical
# body, and the restore of both files after a failed rename or read-back.
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
  ( cd "$TMP_ROOT" && FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" "$ARCHIVE" "$@" )
}

run_wrapper() {  # <home> <args...>
  local home=$1
  shift
  ( cd "$TMP_ROOT" && FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" "$WRAPPER" "$@" )
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

test_unarchive_refuses_a_parked_blocker() {
  local home before live_before out rc
  home=$(make_home parked-blocker)
  run_archive "$home" archive parked-p3 >/dev/null || fail "archiving the dependent failed"
  run_archive "$home" archive blocker-b1 >/dev/null || fail "archiving the blocker failed"
  before=$(cat "$home/data/backlog-archive.md")
  live_before=$(cat "$home/data/backlog.md")

  out=$(run_archive "$home" unarchive parked-p3 2>&1)
  rc=$?
  expect_code 2 "$rc" "unarchive with a parked blocker"
  assert_contains "$out" "blocker blocker-b1 is still parked" "the refusal did not name the parked blocker"
  assert_equals "$before" "$(cat "$home/data/backlog-archive.md")" "the refused unarchive changed the archive"
  assert_equals "$live_before" "$(cat "$home/data/backlog.md")" "the refused unarchive changed the live backlog"

  out=$(run_archive "$home" unarchive parked-p3 blocker-b1 2>&1) || fail "restoring both together failed: $out"
  assert_contains "$(show_live "$home" parked-p3)" "blocked: yes" "the restored row is no longer blocked"
  pass "unarchive refuses a row whose blocker stays parked and accepts both together"
}

test_unarchive_allows_a_pruned_blocker() {
  local home out
  home=$(make_home pruned-blocker)
  run_archive "$home" archive parked-p3 >/dev/null || fail "archive failed"
  ( cd "$home" && tasks-axi rm blocker-b1 >/dev/null ) || fail "removing the blocker failed"
  out=$(run_archive "$home" unarchive parked-p3 2>&1) || fail "unarchive with a pruned blocker failed: $out"
  assert_contains "$(show_live "$home" parked-p3)" 'deps: "blocked-by:blocker-b1"' "the blocked-by link was not carried back"
  pass "unarchive carries a link to a blocker that is no longer anywhere"
}

test_archive_refuses_active_work() {
  local home before out rc
  home=$(make_home active)
  mkdir -p "$home/state"
  : > "$home/state/other-o4.meta"
  ( cd "$home" && tasks-axi add flying-f6 "running" --kind ship --repo x >/dev/null &&
    tasks-axi start flying-f6 >/dev/null ) || fail "starting flying-f6 failed"
  before=$(cat "$home/data/backlog.md")
  for id in flying-f6 other-o4; do
    out=$(run_archive "$home" archive "$id" 2>&1)
    rc=$?
    expect_code 2 "$rc" "archive of active $id"
    assert_contains "$out" "task record: $id" "the active-work refusal did not name $id"
  done
  assert_equals "$before" "$(cat "$home/data/backlog.md")" "a refused archive changed the live backlog"
  assert_absent "$home/data/backlog-archive.md" "a refused archive created an archive file"
  pass "archive refuses In flight rows and rows with a task record"
}

test_round_trips_keep_layout_and_modes() {
  local home first
  home=$(make_home layout)
  printf '# Backlog\n\n## In flight\n\n## Queued\n- [ ] a1 - one\n  body\n\n  more\n- [ ] b2 - two\n\n## Done\n' > "$home/data/backlog.md"
  first=$(cat "$home/data/backlog.md")
  chmod 0640 "$home/data/backlog.md"
  for _ in 1 2 3; do
    ( umask 022 && run_archive "$home" archive b2 >/dev/null ) || fail "archive failed"
    run_archive "$home" unarchive b2 >/dev/null || fail "unarchive failed"
    assert_equals "$first" "$(cat "$home/data/backlog.md")" "a round trip changed the live bytes"
    assert_equals "$(printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done')" \
      "$(cat "$home/data/backlog-archive.md")" "a round trip changed the empty archive layout"
  done
  assert_equals 640 "$(stat -c %a "$home/data/backlog.md" 2>/dev/null || stat -f %Lp "$home/data/backlog.md")" "the live mode changed"
  assert_equals 644 "$(stat -c %a "$home/data/backlog-archive.md" 2>/dev/null || stat -f %Lp "$home/data/backlog-archive.md")" "the new archive ignored the umask"
  pass "repeated round trips keep bytes, section separators, and file modes"
}

test_lock_and_body_refusals() {
  local home before out rc
  home=$(make_home locks)
  before=$(cat "$home/data/backlog.md")
  printf 'other\n' > "$home/data/backlog.md.lock"
  out=$(run_archive "$home" archive parked-p3 2>&1)
  rc=$?
  expect_code 2 "$rc" "held lock"
  assert_contains "$out" "locked by another process" "the held lock was not reported"
  touch -t 202001010000 "$home/data/backlog.md.lock"
  out=$(run_archive "$home" archive parked-p3 2>&1)
  rc=$?
  expect_code 2 "$rc" "stale lock"
  assert_contains "$out" "looks stale" "the stale lock was not reported"
  assert_equals other "$(cat "$home/data/backlog.md.lock")" "a foreign lock was disturbed"
  assert_absent "$home/data/backlog-archive.md.lock" "our own lock was left behind"
  assert_equals "$before" "$(cat "$home/data/backlog.md")" "a locked call changed the live backlog"
  rm "$home/data/backlog.md.lock"

  printf '# Backlog\n\n## Queued\n- [ ] tab-t1 - tabbed\n\tbad line\n' > "$home/data/backlog.md"
  before=$(cat "$home/data/backlog.md")
  out=$(run_archive "$home" archive tab-t1 2>&1)
  rc=$?
  expect_code 2 "$rc" "noncanonical body"
  assert_contains "$out" "non-2-space continuation" "the body refusal did not explain itself"
  assert_equals "$before" "$(cat "$home/data/backlog.md")" "the body refusal changed the live backlog"
  pass "held locks, stale locks, and noncanonical bodies are refused"
}

test_failed_writes_restore_both_files() {
  local home before out rc shim tool real
  for tool in mv tasks-axi; do
    home=$(make_home "restore-$tool")
    before=$(cat "$home/data/backlog.md")
    shim="$home/shim"
    mkdir -p "$shim"
    real=$(command -v "$tool")
    if [ "$tool" = mv ]; then
      # Fail only the second rename, after the destination was replaced.
      # shellcheck disable=SC2016
      printf '#!/usr/bin/env bash\necho x >> "%s/calls"\n[ "$(wc -l < "%s/calls")" -ne 2 ] || exit 1\nexec "%s" "$@"\n' "$shim" "$shim" "$real" > "$shim/$tool"
    else
      # shellcheck disable=SC2016
      printf '#!/usr/bin/env bash\n[ "$1" != show ] || exit 1\nexec "%s" "$@"\n' "$real" > "$shim/$tool"
    fi
    chmod +x "$shim/$tool"
    out=$(PATH="$shim:$PATH" run_archive "$home" archive parked-p3 2>&1)
    rc=$?
    expect_code 2 "$rc" "failing $tool: $out"
    assert_equals "$before" "$(cat "$home/data/backlog.md")" "failing $tool left the live backlog changed"
    assert_absent "$home/data/backlog-archive.md" "failing $tool left a new archive behind"
  done
  pass "a failed rename or read-back restores both files"
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
test_refusals_leave_both_files_unchanged
test_archive_refuses_a_live_dependent
test_unarchive_refuses_a_parked_blocker
test_unarchive_allows_a_pruned_blocker
test_archive_refuses_active_work
test_round_trips_keep_layout_and_modes
test_lock_and_body_refusals
test_failed_writes_restore_both_files
test_wrapper_delegates_and_keeps_tasks_axi_reads

echo "PASS fm-backlog-archive.test.sh"
