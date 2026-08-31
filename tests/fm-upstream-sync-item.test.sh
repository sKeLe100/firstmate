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

test_dedup_refreshes_in_place
test_below_threshold_stays_ineligible_with_config
test_at_threshold_is_eligible_with_config
test_at_threshold_stays_ineligible_without_config
