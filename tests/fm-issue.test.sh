#!/usr/bin/env bash
# tests/fm-issue.test.sh - behavior tests for bin/fm-issue.sh, the small
# issue layer over tasks-axi: parent/child progress, related and
# discovered-from links, the typed append-only log, captain-question routing,
# and the one bounded `show` lookup.
#
# Every case runs against a scratch home; nothing here reads or writes the
# live home's backlog or sidecar. The row store stays tasks-axi's, which is why
# the suite skips when tasks-axi is absent.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

ISSUE="$ROOT/bin/fm-issue.sh"
TMP_ROOT=$(fm_test_tmproot fm-issue-tests)

# The developer shell may pin any of these; every case states its own home.
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE \
  FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

make_home() {  # <name>; prints the scratch home
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/data" "$dir/state" "$dir/config"
  fm_test_tasks_toml "$dir/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  printf '%s\n' "$dir"
}

add_item() {  # <home> <id> <title> [tasks-axi add flags...]
  local home=$1 id=$2 title=$3
  shift 3
  (cd "$home" && tasks-axi add "$id" "$title" "$@") >/dev/null 2>&1 \
    || fail "could not create fixture item $id"
}

issue() {  # <home> <fm-issue args...>
  local home=$1
  shift
  FM_HOME="$home" "$ISSUE" "$@"
}

sidecar() {  # <home>
  printf '%s/data/issue-index.tsv' "$1"
}

test_show_returns_item_parent_children_blockers_links_and_log() {
  local home out
  home=$(make_home show)
  add_item "$home" epic-1 "Epic one" --kind ship
  add_item "$home" slice-a "Slice A" --kind ship
  add_item "$home" slice-b "Slice B" --kind ship
  add_item "$home" blocker-1 "Blocker one" --kind ship
  add_item "$home" blocker-2 "Blocker two" --kind ship
  add_item "$home" slice-c "Slice C" --kind ship --blocked-by blocker-1 --blocked-by blocker-2

  issue "$home" parent slice-a epic-1 >/dev/null || fail "parent refused a valid child"
  issue "$home" parent slice-b epic-1 >/dev/null || fail "parent refused a second valid child"
  issue "$home" link slice-a related blocker-1 >/dev/null || fail "related link refused"
  issue "$home" link slice-b discovered-from slice-a >/dev/null || fail "discovered-from link refused"
  issue "$home" log slice-a "done" "wrote the parser" >/dev/null || fail "done log refused"
  issue "$home" log slice-b failed "first attempt broke" >/dev/null || fail "failed log refused"

  out=$(issue "$home" show epic-1) || fail "show failed on the epic"
  assert_contains "$out" "id: epic-1" "show omitted the item"
  assert_contains "$out" "title: Epic one" "show omitted the title"
  assert_contains "$out" "epic: 0/2 children done, 2 open" "show omitted epic progress"
  assert_contains "$out" "slice-a [queued] Slice A" "show omitted an open child"
  assert_contains "$out" "slice-b [queued] Slice B" "show omitted the second open child"

  out=$(issue "$home" show slice-b) || fail "show failed on a child"
  assert_contains "$out" "parent: epic-1 [queued] Epic one" "show omitted the parent"
  assert_contains "$out" "discovered from: slice-a [queued] Slice A" "show omitted the discovered-from origin"
  assert_contains "$out" "failed: first attempt broke" "show omitted the item log"

  out=$(issue "$home" show slice-c) || fail "show failed on a blocked item"
  assert_contains "$out" "blockers (open):" "show omitted the open blocker heading"
  assert_contains "$out" "blocker-1 [queued] Blocker one" "show omitted the first blocking item"
  assert_contains "$out" "blocker-2 [queued] Blocker two" "show omitted the second quoted blocking item"
  assert_contains "$out" "dependency edges:" "show omitted the dependency edges"

  pass "show returns the item, parent, open children, blockers, links and log"
}

test_show_is_read_only_and_does_not_create_the_sidecar() {
  local home out
  home=$(make_home read-only)
  add_item "$home" lonely-1 "Lonely item"
  out=$(issue "$home" show lonely-1) || fail "show failed on an item with no sidecar"
  assert_contains "$out" "issue-layer:" "show omitted the issue-layer section"
  assert_absent "$(sidecar "$home")" "show created a sidecar while only reading"
  pass "show reads a home with no sidecar and writes nothing"
}

test_parent_refuses_cycles_second_parents_and_done_parents() {
  local home out rc
  home=$(make_home parent-guards)
  add_item "$home" epic-a "Epic A"
  add_item "$home" epic-b "Epic B"
  add_item "$home" child-a "Child A"
  add_item "$home" child-b "Child B"
  issue "$home" parent child-a epic-a >/dev/null || fail "parent refused the first valid edge"

  out=$(issue "$home" parent epic-a child-a 2>&1)
  rc=$?
  expect_code 2 "$rc" "parent cycle"
  assert_contains "$out" "cycle" "a parent cycle was not named"

  out=$(issue "$home" parent child-a epic-b 2>&1)
  rc=$?
  expect_code 2 "$rc" "second parent"
  assert_contains "$out" "already has parent epic-a" "a second parent was not refused by name"

  issue "$home" parent child-b epic-a >/dev/null || fail "parent refused a second valid child"
  (cd "$home" && tasks-axi close epic-a >/dev/null 2>&1) || fail "could not close the epic fixture"
  out=$(issue "$home" parent child-a epic-b 2>&1)
  rc=$?
  expect_code 2 "$rc" "parent is already done"

  issue "$home" unparent child-a >/dev/null || fail "unparent refused"
  issue "$home" parent child-a epic-b >/dev/null || fail "parent refused after unparent"
  out=$(issue "$home" show epic-a) || fail "show failed on the old parent"
  case "$out" in *child-a*) fail "old parent still lists the reparented child" ;; esac
  pass "parent refuses cycles, second parents and done parents"
}

test_related_links_are_undirected_and_unlink_is_a_tombstone() {
  local home out
  home=$(make_home related)
  add_item "$home" item-a "Item A"
  add_item "$home" item-b "Item B"
  issue "$home" link item-b related item-a >/dev/null || fail "related link refused"

  out=$(issue "$home" show item-a) || fail "show failed on the first endpoint"
  assert_contains "$out" "related: item-b [queued] Item B" "related link was not visible from the first endpoint"
  out=$(issue "$home" show item-b) || fail "show failed on the second endpoint"
  assert_contains "$out" "related: item-a [queued] Item A" "related link was not visible from the second endpoint"

  issue "$home" unlink item-a related item-b >/dev/null || fail "unlink refused"
  out=$(issue "$home" show item-a) || fail "show failed after unlink"
  assert_contains "$out" "links: none" "unlink did not hide the related link from the first endpoint"
  out=$(issue "$home" show item-b) || fail "show failed after unlink"
  assert_contains "$out" "links: none" "unlink did not hide the related link from the second endpoint"
  assert_grep "unlink	related	item-a	item-b" "$(sidecar "$home")" "unlink was not recorded as a tombstone"
  pass "related links are undirected and unlink tombstones both directions"
}

test_discovered_from_links_keep_their_direction() {
  local home out
  home=$(make_home discovered)
  add_item "$home" origin-1 "Origin"
  add_item "$home" found-1 "Found"
  issue "$home" link found-1 discovered-from origin-1 >/dev/null || fail "discovered-from link refused"
  out=$(issue "$home" show found-1) || fail "show failed on the discovered item"
  assert_contains "$out" "discovered from: origin-1 [queued] Origin" "the discovered item lost its origin"
  out=$(issue "$home" show origin-1) || fail "show failed on the origin"
  assert_contains "$out" "discovered here: found-1 [queued] Found" "the origin lost the item discovered from it"
  pass "discovered-from links keep their direction on both endpoints"
}

test_log_is_append_only_typed_and_single_line() {
  local home out before after
  home=$(make_home log)
  add_item "$home" log-1 "Log item"
  issue "$home" log log-1 note "first note" >/dev/null || fail "note refused"
  printf 'line one\nline with\ttab\n' | issue "$home" log log-1 failed >/dev/null || fail "stdin failed log refused"
  issue "$home" log log-1 followup "see followup-1" >/dev/null || fail "followup refused"

  out=$(issue "$home" show log-1) || fail "show failed on the logged item"
  assert_contains "$out" "note: first note" "the first log entry was lost"
  assert_contains "$out" "failed: line one line with tab" "the stdin entry was not normalized to one line"
  assert_contains "$out" "followup: see followup-1" "the later log entry was lost"
  assert_contains "$out" "log: 3 entries" "the log count was wrong"

  before=$(grep -c '^log	' "$(sidecar "$home")")
  out=$(issue "$home" log log-1 "done" "second completion" 2>&1)
  rc=$?
  expect_code 0 "$rc" "done log after existing history"
  after=$(grep -c '^log	' "$(sidecar "$home")")
  assert_equals "$((before + 1))" "$after" "an append rewrote instead of appending"
  assert_contains "$out" "done recorded" "the appended entry was not reported"

  out=$(issue "$home" log log-1 bogus "nope" 2>&1)
  rc=$?
  expect_code 2 "$rc" "unknown log type"
  assert_contains "$out" "log type must be" "an unknown log type was not named"
  pass "log appends typed single-line entries and refuses unknown types"
}

test_question_routes_through_the_captain_hold() {
  local home out rc
  home=$(make_home question)
  add_item "$home" ask-1 "Ask item"
  out=$(issue "$home" log ask-1 question "Use SQLite (local) or Dolt?" 2>&1)
  rc=$?
  expect_code 0 "$rc" "captain question"
  assert_contains "$out" "waits for the captain" "the question was not routed to a hold"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" show ask-1) \
    || fail "could not read the held item"
  assert_contains "$out" "held: yes" "the captain question did not hold the item"
  assert_contains "$out" "hold_reason: \"Use SQLite (local) or Dolt?\"" "the hold lost the question text"
  out=$(issue "$home" show ask-1) || fail "show failed on the held item"
  assert_contains "$out" "question: Use SQLite (local) or Dolt?" "the question was not logged"

  (cd "$home" && tasks-axi close ask-1 >/dev/null 2>&1) || fail "could not close the question fixture"
  out=$(issue "$home" log ask-1 question "Another question?" 2>&1)
  rc=$?
  expect_code 2 "$rc" "question on a done item"
  pass "question records the log entry and routes the item through fm-captain-hold"
}

test_concurrent_log_appends_lose_nothing() {
  local home pids=() pid status=0 i out
  home=$(make_home concurrent)
  add_item "$home" race-1 "Race item"
  for i in $(seq 1 24); do
    (
      FM_HOME="$home" "$ISSUE" log race-1 note "concurrent $i" >/dev/null 2>&1
    ) &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || status=1
  done
  [ "$status" -eq 0 ] || fail "at least one concurrent append failed"

  [ "$(grep -c '^log	note	race-1	' "$(sidecar "$home")")" -eq 24 ] \
    || fail "concurrent appends lost a record"
  for i in $(seq 1 24); do
    grep -Fq "concurrent $i" "$(sidecar "$home")" \
      || fail "concurrent entry $i is missing from the sidecar"
  done
  out=$(issue "$home" show race-1) || fail "show failed after concurrent appends"
  assert_contains "$out" "log: 24 entries" "the log count after concurrent appends is wrong"
  pass "concurrent writers append under the lock without losing a record"
}

test_mutations_reject_unknown_items_and_bad_ids() {
  local home out rc
  home=$(make_home refusals)
  add_item "$home" real-1 "Real item"
  for spec in "log no-such-1 note hi" "parent no-such-1 real-1" "parent real-1 no-such-2" \
    "link real-1 related no-such-2" "link real-1 blocks real-1"; do
    # shellcheck disable=SC2086
    out=$(issue "$home" $spec 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] || fail "a bad reference was accepted: $spec"
  done
  out=$(issue "$home" show no-such-3 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "show accepted a missing item"
  assert_contains "$out" "not found" "show did not report a missing item"
  assert_absent "$(sidecar "$home")" "a refused mutation still created the sidecar"
  pass "mutations refuse unknown items, self-links and invalid types"
}

test_prime_is_short_and_id_first() {
  local out
  out=$("$ISSUE" prime) || fail "prime failed"
  assert_contains "$out" "bin/fm-issue.sh show <id>" "prime omitted the show entry point"
  assert_contains "$out" "bin/fm-issue.sh log <id>" "prime omitted the log entry point"
  assert_contains "$out" "captain" "prime omitted the captain-question rule"
  assert_contains "$out" "data/backlog.md" "prime omitted the row-store boundary"
  [ "${#out}" -lt 2000 ] || fail "prime is not short (${#out} chars)"
  pass "prime is a short id-first workflow"
}

test_show_returns_item_parent_children_blockers_links_and_log
test_show_is_read_only_and_does_not_create_the_sidecar
test_parent_refuses_cycles_second_parents_and_done_parents
test_related_links_are_undirected_and_unlink_is_a_tombstone
test_discovered_from_links_keep_their_direction
test_log_is_append_only_typed_and_single_line
test_question_routes_through_the_captain_hold
test_concurrent_log_appends_lose_nothing
test_mutations_reject_unknown_items_and_bad_ids
test_prime_is_short_and_id_first
