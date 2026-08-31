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
  assert_contains "$shown" "Pending commits" "sync-item: the tasks-axi item body must carry the commit delta"
  assert_contains "$shown" "ship" "sync-item: the filed item must be an ordinary ship task, ready to dispatch"
  assert_contains "$shown" "sKeLe100/firstmate" "sync-item: the filed item must name the repo it ships against"

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

  out=$(FM_UPSTREAM_AUTOSYNC_COMMIT_THRESHOLD=5 FM_UPSTREAM_AUTOSYNC_DAYS_THRESHOLD=14 \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$ITEM" file 2 unknown main)
  assert_contains "$out" "days_behind=unknown" \
    "sync-item: an undeterminable upstream date must not be reported as a definite 0 days"
  assert_contains "$out" "eligible=no" "sync-item: an unknown date below the commit threshold stays ineligible"
  assert_contains "$out" "could not be determined" \
    "sync-item: eligible_reason must say the day rule could not be evaluated"
  assert_not_contains "$(cat "$home/data/backlog.md")" "0 days since newest upstream commit" \
    "sync-item: the filed note must not assert a freshly-synced 0-day age it does not know"
  pass "an unknown newest-upstream date reports unknown rather than a definite zero"
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
