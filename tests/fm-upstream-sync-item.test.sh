#!/usr/bin/env bash
# Tests for bin/fm-upstream-sync-item.sh: filing/refreshing the one stable-id
# upstream sync backlog item and reporting auto-dispatch eligibility.
#
# Guarantees under test:
#   - Filing twice for the same open episode refreshes the existing backlog
#     block in place rather than creating a duplicate.
#   - Below-threshold drift with config/upstream-autosync present stays
#     eligible=no.
#   - At/above-threshold drift with config/upstream-autosync present reports
#     eligible=yes.
#   - At/above-threshold drift with config/upstream-autosync ABSENT reports
#     eligible=no, i.e. today's ask-only behavior is unchanged.
#   - On the default tasks-axi backend the item really carries the required
#     payload (eligibility line, commit count, delta) and its title is
#     refreshed on the second episode instead of keeping the stale count.
#   - A data/backlog.md whose upstream-sync end marker was lost is left
#     untouched rather than truncated from the start marker onward.
#   - The manual write is skipped, not raced, while the reserved `backlog`
#     lease is held by the other supervision actor.
#   - A `backlog` lease held by this script's OWN actor survives the run: the
#     lease is actor-scoped and outlives any single process, so this
#     unattended script must never release the supervising session's lease.
#   - A hand-indented marker pair is still refreshed in place, rather than
#     reporting action=refreshed while silently dropping the new payload.
#   - The gate really is inherited by a secondmate home, as AGENTS.md and
#     docs/configuration.md promise: propagating the primary's config with the
#     declared allowlist leaves the secondmate reporting eligible=yes.
#   - Refreshing the stable-id item after it was completed reopens it, so the
#     always-on filing yields a dispatchable item on EVERY drift episode, not
#     only the first one per home.
#   - Refreshing while a crewmate has the item in flight leaves it in flight.
#   - An unparseable/unknown newest-upstream date reports days_behind=unknown
#     rather than a definite 0 that can never cross the 14-day rule.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ITEM="$ROOT/bin/fm-upstream-sync-item.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-upstream-sync-item-tests)

new_home() {
  local h
  h=$(mktemp -d "$TMP_ROOT/home-XXXXXX") || return 1
  mkdir -p "$h/state" "$h/data"
  mkdir -p "$h/config"
  printf 'manual\n' > "$h/config/backlog-backend"
  printf '%s\n' "$h"
}

new_repo() {
  local dir=$1
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  printf 'seed\n' > "$dir/seed.txt"
  git -C "$dir" add seed.txt
  git -C "$dir" commit -qm seed
}

# Builds a repo where upstream has N extra commits past the local branch, with
# no tasks-axi on PATH so the manual data/backlog.md fallback is exercised.
setup_repo() {  # <root-dir> <upstream-commits>
  local root=$1 n=$2 i
  new_repo "$root"
  git -C "$root" remote add upstream "$root"
  git -C "$root" branch upstream-src main
  for ((i = 1; i <= n; i++)); do
    printf 'u%s\n' "$i" > "$root/upstream-file-$i.txt"
    git -C "$root" checkout -q upstream-src
    git -C "$root" add "upstream-file-$i.txt"
    git -C "$root" commit -qm "upstream $i"
  done
  git -C "$root" update-ref refs/remotes/upstream/main refs/heads/upstream-src
  git -C "$root" checkout -q main
}

file_once() {  # <home> <root> <behind> [date]
  local home=$1 root=$2 behind=$3 date=${4:-$(date +%F)}
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$ITEM" file "$behind" "$date" main
}

test_dedup_refreshes_in_place() {
  set -e
  local home root out1 out2 count
  home=$(new_home)
  root="$TMP_ROOT/repo-dedup"
  setup_repo "$root" 3

  out1=$(file_once "$home" "$root" 3)
  assert_contains "$out1" "action=filed" "sync-item: first call must file"
  out2=$(file_once "$home" "$root" 4)
  assert_contains "$out2" "action=refreshed" "sync-item: second call for the same item must refresh"

  count=$(grep -c "upstream-sync:start" "$home/data/backlog.md")
  [ "$count" -eq 1 ] || fail "sync-item: dedup must leave exactly one filed block, found $count"
  pass "filing twice for one open episode refreshes the item in place, never duplicates it"
}

test_below_threshold_stays_ineligible_with_config() {
  set -e
  local home root out
  home=$(new_home)
  mkdir -p "$home/config"
  : > "$home/config/upstream-autosync"
  root="$TMP_ROOT/repo-below"
  setup_repo "$root" 3

  out=$(FM_UPSTREAM_AUTOSYNC_COMMIT_THRESHOLD=5 FM_UPSTREAM_AUTOSYNC_DAYS_THRESHOLD=14 \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$ITEM" file 3 "$(date +%F)" main)
  assert_contains "$out" "eligible=no" "sync-item: 3 commits behind must stay ineligible below a 5-commit threshold"
  pass "below-threshold drift with the gate present stays queued, not eligible"
}

test_at_threshold_is_eligible_with_config() {
  set -e
  local home root out
  home=$(new_home)
  mkdir -p "$home/config"
  : > "$home/config/upstream-autosync"
  root="$TMP_ROOT/repo-at"
  setup_repo "$root" 5

  out=$(FM_UPSTREAM_AUTOSYNC_COMMIT_THRESHOLD=5 FM_UPSTREAM_AUTOSYNC_DAYS_THRESHOLD=14 \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$ITEM" file 5 "$(date +%F)" main)
  assert_contains "$out" "eligible=yes" "sync-item: 5 commits behind must be eligible at a 5-commit threshold"
  pass "at-threshold drift with the gate present reports eligible"
}

test_at_threshold_stays_ineligible_without_config() {
  set -e
  local home root out
  home=$(new_home)
  root="$TMP_ROOT/repo-noconfig"
  setup_repo "$root" 5

  out=$(FM_UPSTREAM_AUTOSYNC_COMMIT_THRESHOLD=5 FM_UPSTREAM_AUTOSYNC_DAYS_THRESHOLD=14 \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$ITEM" file 5 "$(date +%F)" main)
  assert_contains "$out" "eligible=no" "sync-item: absent config/upstream-autosync must keep today's ask-only behavior unchanged"
  pass "at-threshold drift with the gate absent stays not eligible, i.e. unchanged from today"
}

# The tasks-axi backend keeps its backlog in <cwd>/backlog.md, so this home
# omits config/backlog-backend to select it and asserts through tasks-axi's own
# read surface rather than over the file text.
test_tasks_axi_backend_carries_payload_and_refreshes_title() {
  set -e
  local home root out1 out2 shown
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip - tasks-axi not installed"; return 0; }
  home=$(new_home)
  rm -f "$home/config/backlog-backend"
  : > "$home/config/upstream-autosync"
  root="$TMP_ROOT/repo-axi"
  setup_repo "$root" 6

  out1=$(file_once "$home" "$root" 5) || fail "sync-item: tasks-axi backend filing failed: $out1"
  assert_contains "$out1" "action=filed" "sync-item: first tasks-axi call must file"
  shown=$(cd "$home" && tasks-axi show upstream-sync --full)
  assert_contains "$shown" "5 commits behind" "sync-item: the tasks-axi title must carry the commit count"
  assert_contains "$shown" "Auto-dispatch eligible: yes" \
    "sync-item: the tasks-axi item body must carry the eligibility signal"
  assert_contains "$shown" "Pending upstream commits" "sync-item: the tasks-axi item body must carry the commit delta"
  assert_contains "$shown" "ship" "sync-item: the filed item must be an ordinary ship task, ready to dispatch"
  assert_contains "$shown" "firstmate" "sync-item: the filed item must name the data/projects.md project it ships against"
  assert_not_contains "$shown" "sKeLe100/" \
    "sync-item: --repo is a data/projects.md project name, not an owner/repo slug, or posture resolution falls back"

  out2=$(file_once "$home" "$root" 21) || fail "sync-item: tasks-axi backend refresh failed: $out2"
  assert_contains "$out2" "action=refreshed" "sync-item: a second episode must report refreshed, not filed"
  shown=$(cd "$home" && tasks-axi show upstream-sync --full)
  assert_contains "$shown" "21 commits behind" "sync-item: the refresh must update the stale commit count in the title"
  assert_not_contains "$(cd "$home" && tasks-axi list --state queued)" "5 commits behind" \
    "sync-item: the stale title must not survive the refresh"
  pass "the tasks-axi backend carries the full payload and refreshes the title in place"
}

test_missing_end_marker_leaves_backlog_intact() {
  set -e
  local home root before after
  home=$(new_home)
  root="$TMP_ROOT/repo-marker"
  setup_repo "$root" 3

  file_once "$home" "$root" 3 >/dev/null
  # Lose the end marker the way a hand edit would, then keep a later item.
  grep -v -- "upstream-sync:end" "$home/data/backlog.md" > "$home/data/backlog.md.tmp"
  mv "$home/data/backlog.md.tmp" "$home/data/backlog.md"
  printf '### later-item\nmust survive\n' >> "$home/data/backlog.md"
  before=$(cat "$home/data/backlog.md")

  file_once "$home" "$root" 4 >/dev/null 2>&1 || true
  after=$(cat "$home/data/backlog.md")
  [ "$before" = "$after" ] || fail "sync-item: an unterminated block must leave data/backlog.md untouched"
  assert_contains "$after" "later-item" "sync-item: items after an unterminated block must not be truncated"
  pass "a lost end marker abandons the rewrite instead of truncating the backlog"
}

test_held_backlog_lease_skips_the_write() {
  set -e
  local home root out before holder
  home=$(new_home)
  root="$TMP_ROOT/repo-lease"
  setup_repo "$root" 3

  file_once "$home" "$root" 3 >/dev/null
  before=$(cat "$home/data/backlog.md")
  # A lease only reads as live when its pid is the session-lock holder
  # (bin/fm-lease-lib.sh fm_lease_live), so stand up both for a live branch.
  sleep 30 &
  holder=$!
  printf '%s\n' "$holder" > "$home/state/.lock"
  printf 'branch\t%s\t%s\n' "$holder" "$(date +%s)" > "$home/state/.lease-backlog"

  out=$(FM_SUPERVISION_ACTOR=main file_once "$home" "$root" 9 2>/dev/null)
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  assert_contains "$out" "action=skipped" "sync-item: a contended backlog lease must skip the write"
  assert_contains "$out" "eligible=" "sync-item: a skipped write must still report eligibility"
  [ "$before" = "$(cat "$home/data/backlog.md")" ] \
    || fail "sync-item: the write must not proceed while the other actor holds the backlog lease"
  pass "a backlog lease held by the other actor skips the write instead of racing it"
}

test_same_actor_backlog_lease_survives_the_run() {
  set -e
  local home root holder out
  home=$(new_home)
  root="$TMP_ROOT/repo-samelease"
  setup_repo "$root" 3

  # The supervising session of the SAME actor is mid-write under its lease.
  sleep 30 &
  holder=$!
  printf '%s\n' "$holder" > "$home/state/.lock"
  printf 'main\t%s\t%s\n' "$holder" "$(date +%s)" > "$home/state/.lease-backlog"

  out=$(FM_SUPERVISION_ACTOR=main file_once "$home" "$root" 3 2>/dev/null)
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  assert_contains "$out" "action=filed" "sync-item: an own-actor lease must not block this write"
  [ -e "$home/state/.lease-backlog" ] \
    || fail "sync-item: the run released the supervising session's own backlog lease, freeing the other actor to race it"
  pass "a backlog lease held by this script's own actor survives the run"
}

test_unknown_date_is_not_reported_as_zero_days() {
  set -e
  local home root out
  home=$(new_home)
  : > "$home/config/upstream-autosync"
  root="$TMP_ROOT/repo-unknown"
  setup_repo "$root" 2

  # days_behind now comes from the oldest unmerged upstream commit, so "unknown"
  # is provoked through that source: a branch with no upstream ref has no delta.
  out=$(FM_UPSTREAM_AUTOSYNC_COMMIT_THRESHOLD=5 FM_UPSTREAM_AUTOSYNC_DAYS_THRESHOLD=14 \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$ITEM" file 2 unknown no-such-branch)
  assert_contains "$out" "days_behind=unknown" \
    "sync-item: an undeterminable upstream date must not be reported as a definite 0 days"
  assert_contains "$out" "eligible=no" "sync-item: an unknown date below the commit threshold stays ineligible"
  assert_contains "$out" "could not be determined" \
    "sync-item: eligible_reason must say the day rule could not be evaluated"
  assert_not_contains "$(cat "$home/data/backlog.md")" "is 0 days old" \
    "sync-item: the filed note must not assert a freshly-synced 0-day age it does not know"
  pass "an unknown newest-upstream date reports unknown rather than a definite zero"
}

test_indented_markers_are_still_refreshed() {
  set -e
  local home root out body
  home=$(new_home)
  : > "$home/config/upstream-autosync"
  root="$TMP_ROOT/repo-indent"
  setup_repo "$root" 8

  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$ITEM" file 3 "$(date +%F)" main >/dev/null
  # data/backlog.md is hand-edited; an editor reindents the marker pair.
  sed -i -E 's/^(<!-- upstream-sync:(start|end) -->)$/  \1/' "$home/data/backlog.md"

  out=$(FM_UPSTREAM_AUTOSYNC_COMMIT_THRESHOLD=5 FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$ITEM" file 8 "$(date +%F)" main)
  assert_contains "$out" "action=refreshed" "sync-item: an indented marker pair must still refresh in place"
  body=$(cat "$home/data/backlog.md")
  assert_contains "$body" "8 commits behind" "sync-item: the refresh must actually replace the stale payload"
  assert_contains "$body" "Auto-dispatch eligible: yes" \
    "sync-item: the refreshed block must carry the new eligibility signal"
  assert_not_contains "$body" "3 commits behind" "sync-item: the stale payload must not survive the refresh"
  [ "$(grep -c "upstream-sync:start" "$home/data/backlog.md")" -eq 1 ] \
    || fail "sync-item: the refresh must not leave a second sync block"
  pass "a hand-indented marker pair is refreshed in place, not silently skipped"
}

# Exercises the real propagation entry point with the DECLARED allowlist (no
# FM_INHERITABLE_CONFIG override), then the sync item's own eligibility output
# in the receiving home, so the documented inheritance is proven end to end.
test_gate_is_inherited_by_a_secondmate_home() {
  set -e
  local primary second root out
  # shellcheck source=bin/fm-config-inherit-lib.sh
  . "$ROOT/bin/fm-config-inherit-lib.sh"
  primary=$(new_home)
  : > "$primary/config/upstream-autosync"
  second=$(new_home)
  git init -q -b main "$second"
  printf 'config/\n' > "$second/.gitignore"
  printf 'seed\n' > "$second/README.md"
  git -C "$second" add -A && git -C "$second" commit -qm seed
  root="$TMP_ROOT/repo-inherit"
  setup_repo "$root" 6

  propagate_inheritable_config "$primary/config" "$second/config" \
    || fail "sync-item: propagating the primary's config failed"
  [ -e "$second/config/upstream-autosync" ] \
    || fail "sync-item: config/upstream-autosync is documented as inherited but was not propagated"

  out=$(FM_UPSTREAM_AUTOSYNC_COMMIT_THRESHOLD=5 FM_HOME="$second" FM_ROOT_OVERRIDE="$root" \
    "$ITEM" file 6 "$(date +%F)" main)
  assert_contains "$out" "eligible=yes" \
    "sync-item: the inherited gate must make the secondmate home dispatch-eligible too"
  pass "the autosync gate is inherited by a secondmate home, as documented"
}

# tasks-axi's own list/show output is the persisted backlog state contract
# these two assert against; the item's column is the observable behavior.
axi_state() {  # <home> <id>
  (cd "$1" && tasks-axi show "$2" 2>/dev/null) | sed -n 's/^[[:space:]]*state:[[:space:]]*//p' | head -n 1
}

test_refresh_reopens_a_completed_item() {
  set -e
  local home root out
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip - tasks-axi not installed"; return 0; }
  home=$(new_home)
  rm -f "$home/config/backlog-backend"
  : > "$home/config/upstream-autosync"
  root="$TMP_ROOT/repo-reopen"
  setup_repo "$root" 9

  file_once "$home" "$root" 5 >/dev/null
  (cd "$home" && tasks-axi done upstream-sync >/dev/null)
  [ "$(axi_state "$home" upstream-sync)" = done ] || fail "sync-item: fixture failed to complete the item"

  out=$(file_once "$home" "$root" 9) || fail "sync-item: refresh after completion failed: $out"
  assert_contains "$out" "action=refreshed" "sync-item: a later episode must refresh the stable id"
  [ "$(axi_state "$home" upstream-sync)" = queued ] \
    || fail "sync-item: a new drift episode must leave a dispatchable (queued) item, not a retitled done one"
  assert_contains "$(cd "$home" && tasks-axi list --state queued)" "9 commits behind" \
    "sync-item: the reopened item must carry the new episode's payload"
  pass "a new drift episode reopens the completed sync item so it is dispatchable again"
}

test_refresh_leaves_an_in_flight_item_alone() {
  set -e
  local home root
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip - tasks-axi not installed"; return 0; }
  home=$(new_home)
  rm -f "$home/config/backlog-backend"
  : > "$home/config/upstream-autosync"
  root="$TMP_ROOT/repo-inflight"
  setup_repo "$root" 9

  file_once "$home" "$root" 5 >/dev/null
  (cd "$home" && tasks-axi start upstream-sync >/dev/null)

  file_once "$home" "$root" 9 >/dev/null
  [ "$(axi_state "$home" upstream-sync)" = in_flight ] \
    || fail "sync-item: refreshing must not pull back work a crewmate has in flight"
  pass "a refresh leaves an in-flight sync item in flight"
}

# An upstream that ships daily always has a tip dated today. Eligibility must
# track the oldest change this fork has NOT taken, or the days rule is dead code
# on exactly the busy upstreams it exists for.
test_days_behind_measures_the_oldest_unmerged_commit() {
  set -e
  local home root out old_epoch
  home=$(new_home)
  : > "$home/config/upstream-autosync"
  old_epoch=$(( $(date +%s) - 90 * 86400 ))
  root="$TMP_ROOT/repo-oldest"
  new_repo "$root"
  git -C "$root" remote add upstream "$root"
  git -C "$root" branch upstream-src main
  git -C "$root" checkout -q upstream-src
  # An old unmerged commit, then a fresh tip: 2 commits behind, under the
  # 5-commit arm, so only the days arm can make this eligible.
  printf 'old\n' > "$root/old.txt"
  git -C "$root" add old.txt
  GIT_AUTHOR_DATE="@$old_epoch +0000" GIT_COMMITTER_DATE="@$old_epoch +0000" \
    git -C "$root" commit -qm "upstream old"
  printf 'new\n' > "$root/new.txt"
  git -C "$root" add new.txt
  git -C "$root" commit -qm "upstream fresh tip"
  git -C "$root" update-ref refs/remotes/upstream/main refs/heads/upstream-src
  git -C "$root" checkout -q main

  out=$(FM_UPSTREAM_AUTOSYNC_COMMIT_THRESHOLD=5 FM_UPSTREAM_AUTOSYNC_DAYS_THRESHOLD=14 \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$ITEM" file 2 "$(date +%F)" main)
  case "$out" in
    *days_behind=[0-9]*) ;;
    *) fail "sync-item: days_behind must be numeric here: $out" ;;
  esac
  [ "$(printf '%s\n' "$out" | sed -n 's/^days_behind=//p')" -ge 14 ] \
    || fail "sync-item: days_behind must measure the 90-day-old unmerged commit, not the fresh tip: $out"
  assert_contains "$out" "eligible=yes" \
    "sync-item: a fork 2 commits behind whose oldest unmerged commit is 90 days old must cross the days arm"
  pass "days behind measures the oldest unmerged upstream commit, not upstream's tip"
}

test_commit_delta_is_capped_with_a_truncation_marker() {
  set -e
  local home root body shown
  home=$(new_home)
  root="$TMP_ROOT/repo-deltacap"
  setup_repo "$root" 7

  FM_UPSTREAM_AUTOSYNC_DELTA_SHOWN=3 FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$ITEM" file 7 "$(date +%F)" main >/dev/null
  body=$(cat "$home/data/backlog.md")
  shown=$(printf '%s\n' "$body" | grep -c "^[0-9a-f]\{7,\} upstream ")
  [ "$shown" -eq 3 ] \
    || fail "sync-item: the commit delta must be capped at the configured limit, printed $shown"
  assert_contains "$body" "... and 4 more" \
    "sync-item: a truncated delta must disclose exactly how many commits were omitted"
  pass "the commit delta is capped and discloses the omitted count"
}

test_dedup_refreshes_in_place
test_below_threshold_stays_ineligible_with_config
test_at_threshold_is_eligible_with_config
test_at_threshold_stays_ineligible_without_config
test_tasks_axi_backend_carries_payload_and_refreshes_title
test_missing_end_marker_leaves_backlog_intact
test_held_backlog_lease_skips_the_write
test_same_actor_backlog_lease_survives_the_run
test_unknown_date_is_not_reported_as_zero_days
test_indented_markers_are_still_refreshed
test_gate_is_inherited_by_a_secondmate_home
test_refresh_reopens_a_completed_item
test_refresh_leaves_an_in_flight_item_alone
test_days_behind_measures_the_oldest_unmerged_commit
test_commit_delta_is_capped_with_a_truncation_marker
