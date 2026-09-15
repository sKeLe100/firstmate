#!/usr/bin/env bash
# Tests for bin/fm-upstream-batch.sh: planning the next bounded upstream sync
# batch as an exact merge target.
#
# Guarantees under test:
#   - A pending delta larger than the bound is cut to exactly batch_max
#     first-parent commits, the target is the Nth oldest pending commit, and
#     batch_remaining accounts for every commit left for the next sync.
#   - A pending delta within the bound targets upstream's tip with nothing
#     remaining.
#   - --max overrides FM_UPSTREAM_AUTOSYNC_BATCH_MAX, which overrides the
#     default; an unusable value falls back to the default rather than to an
#     unbounded plan.
#   - The cut lands on upstream's first-parent line: an upstream PR merge with
#     side commits is never split, and `behind` still counts every commit.
#   - No upstream remote, no upstream ref, and an up-to-date fork each report
#     status=unknown with a reason and exit 0, never a bogus target.
#   - Planning is read-only: it moves no ref and touches no working tree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BATCH="$ROOT/bin/fm-upstream-batch.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-upstream-batch-tests)

new_repo() {
  local dir=$1
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  printf 'seed\n' > "$dir/seed.txt"
  git -C "$dir" add seed.txt
  git -C "$dir" commit -qm seed
}

# A repo whose upstream/main has N linear commits past main, and main has one
# local commit of its own, so the merge-base is the seed.
setup_repo() {  # <root-dir> <upstream-commits>
  local root=$1 n=$2 i
  new_repo "$root"
  git -C "$root" remote add upstream "$root"
  git -C "$root" branch upstream-src main
  for ((i = 1; i <= n; i++)); do
    git -C "$root" checkout -q upstream-src
    printf 'u%s\n' "$i" > "$root/upstream-file-$i.txt"
    git -C "$root" add "upstream-file-$i.txt"
    git -C "$root" commit -qm "upstream $i"
  done
  git -C "$root" update-ref refs/remotes/upstream/main refs/heads/upstream-src
  git -C "$root" checkout -q main
  printf 'local\n' > "$root/local.txt"
  git -C "$root" add local.txt
  git -C "$root" commit -qm "local work"
}

plan_field() {  # <plan-output> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}

nth_pending() {  # <root> <n>
  git -C "$1" rev-list --first-parent --reverse main..refs/remotes/upstream/main | sed -n "$2p"
}

test_large_delta_is_cut_to_the_bound() {
  set -e
  local root out
  root="$TMP_ROOT/repo-large"
  setup_repo "$root" 9
  out=$(FM_ROOT_OVERRIDE="$root" "$BATCH" plan --max 4)
  [ "$(plan_field "$out" status)" = ok ] || fail "batch: expected status=ok, got: $out"
  [ "$(plan_field "$out" behind)" = 9 ] || fail "batch: behind must count every pending commit, got: $out"
  [ "$(plan_field "$out" batch_count)" = 4 ] || fail "batch: a 9-commit delta must be cut to 4, got: $out"
  [ "$(plan_field "$out" batch_remaining)" = 5 ] || fail "batch: 5 must remain after a 4-of-9 cut, got: $out"
  [ "$(plan_field "$out" batch_target)" = "$(nth_pending "$root" 4)" ] \
    || fail "batch: the target must be the 4th oldest pending commit, got: $out"
  [ "$(plan_field "$out" merge_base)" = "$(git -C "$root" merge-base main refs/remotes/upstream/main)" ] \
    || fail "batch: merge_base must be the real merge-base, got: $out"
  assert_contains "$out" "batch_log_hint=git log --oneline --first-parent" "batch: the plan must name the command listing exactly this batch"
  pass "a delta larger than the bound is cut to exactly batch_max oldest commits with the remainder disclosed"
}

test_small_delta_targets_the_tip() {
  set -e
  local root out
  root="$TMP_ROOT/repo-small"
  setup_repo "$root" 3
  out=$(FM_ROOT_OVERRIDE="$root" "$BATCH" plan --max 20)
  [ "$(plan_field "$out" batch_count)" = 3 ] || fail "batch: a 3-commit delta under a 20 bound must take all 3, got: $out"
  [ "$(plan_field "$out" batch_remaining)" = 0 ] || fail "batch: nothing must remain, got: $out"
  [ "$(plan_field "$out" batch_target)" = "$(git -C "$root" rev-parse refs/remotes/upstream/main)" ] \
    || fail "batch: the target must be upstream's tip, got: $out"
  pass "a delta within the bound targets upstream's tip with nothing remaining"
}

test_bound_precedence_and_fallback() {
  set -e
  local root out
  root="$TMP_ROOT/repo-bound"
  setup_repo "$root" 30
  out=$(FM_ROOT_OVERRIDE="$root" "$BATCH" plan)
  [ "$(plan_field "$out" batch_max)" = 20 ] || fail "batch: default bound must be 20, got: $out"
  [ "$(plan_field "$out" batch_count)" = 20 ] || fail "batch: default bound must cut 30 to 20, got: $out"
  out=$(FM_UPSTREAM_AUTOSYNC_BATCH_MAX=7 FM_ROOT_OVERRIDE="$root" "$BATCH" plan)
  [ "$(plan_field "$out" batch_count)" = 7 ] || fail "batch: FM_UPSTREAM_AUTOSYNC_BATCH_MAX must set the bound, got: $out"
  out=$(FM_UPSTREAM_AUTOSYNC_BATCH_MAX=7 FM_ROOT_OVERRIDE="$root" "$BATCH" plan --max 3)
  [ "$(plan_field "$out" batch_count)" = 3 ] || fail "batch: --max must win over the environment, got: $out"
  out=$(FM_UPSTREAM_AUTOSYNC_BATCH_MAX=0 FM_ROOT_OVERRIDE="$root" "$BATCH" plan)
  [ "$(plan_field "$out" batch_count)" = 20 ] || fail "batch: an unusable bound must fall back to the default, never unbounded, got: $out"
  out=$(FM_UPSTREAM_AUTOSYNC_BATCH_MAX=lots FM_ROOT_OVERRIDE="$root" "$BATCH" plan)
  [ "$(plan_field "$out" batch_count)" = 20 ] || fail "batch: a non-numeric bound must fall back to the default, got: $out"
  pass "--max wins over FM_UPSTREAM_AUTOSYNC_BATCH_MAX, and an unusable bound falls back to the default"
}

test_cut_lands_on_upstream_first_parent_line() {
  set -e
  local root out i
  root="$TMP_ROOT/repo-merges"
  new_repo "$root"
  git -C "$root" remote add upstream "$root"
  git -C "$root" branch upstream-src main
  # Upstream lands three PRs as merge commits, each carrying two side commits.
  for i in 1 2 3; do
    git -C "$root" checkout -q -b "pr-$i" upstream-src
    printf 'a%s\n' "$i" > "$root/pr-$i-a.txt"
    git -C "$root" add "pr-$i-a.txt"
    git -C "$root" commit -qm "pr $i commit a"
    printf 'b%s\n' "$i" > "$root/pr-$i-b.txt"
    git -C "$root" add "pr-$i-b.txt"
    git -C "$root" commit -qm "pr $i commit b"
    git -C "$root" checkout -q upstream-src
    git -C "$root" merge -q --no-ff -m "Merge pr-$i" "pr-$i"
  done
  git -C "$root" update-ref refs/remotes/upstream/main refs/heads/upstream-src
  git -C "$root" checkout -q main
  out=$(FM_ROOT_OVERRIDE="$root" "$BATCH" plan --max 2)
  [ "$(plan_field "$out" behind)" = 9 ] || fail "batch: behind must count merge and side commits alike, got: $out"
  [ "$(plan_field "$out" batch_count)" = 2 ] || fail "batch: the bound counts first-parent steps, got: $out"
  [ "$(plan_field "$out" batch_remaining)" = 1 ] || fail "batch: one PR must remain, got: $out"
  [ "$(plan_field "$out" batch_target)" = "$(nth_pending "$root" 2)" ] \
    || fail "batch: the target must be the second PR's merge commit, got: $out"
  git -C "$root" cat-file -p "$(plan_field "$out" batch_target)" | grep -q '^parent .*' \
    && [ "$(git -C "$root" rev-list --parents -n 1 "$(plan_field "$out" batch_target)" | wc -w)" -eq 3 ] \
    || fail "batch: the target must be a merge commit, never a side commit inside a PR, got: $out"
  pass "the batch is cut between upstream PR merges, never inside one"
}

test_unplannable_states_report_unknown() {
  set -e
  local root out
  root="$TMP_ROOT/repo-no-remote"
  new_repo "$root"
  out=$(FM_ROOT_OVERRIDE="$root" "$BATCH" plan)
  [ "$(plan_field "$out" status)" = unknown ] || fail "batch: no upstream remote must be unknown, got: $out"
  [ "$(plan_field "$out" reason)" = no-upstream-remote ] || fail "batch: expected reason=no-upstream-remote, got: $out"
  assert_not_contains "$out" "batch_target=" "batch: an unknown plan must carry no target"

  git -C "$root" remote add upstream "$root"
  out=$(FM_ROOT_OVERRIDE="$root" "$BATCH" plan)
  [ "$(plan_field "$out" reason)" = no-upstream-ref ] || fail "batch: a remote with no fetched ref must be unknown, got: $out"

  git -C "$root" update-ref refs/remotes/upstream/main refs/heads/main
  out=$(FM_ROOT_OVERRIDE="$root" "$BATCH" plan)
  [ "$(plan_field "$out" reason)" = up-to-date ] || fail "batch: a level fork must be up-to-date, got: $out"
  pass "no remote, no upstream ref, and a level fork each report status=unknown with a reason"
}

test_plan_is_read_only() {
  set -e
  local root before after out
  root="$TMP_ROOT/repo-readonly"
  setup_repo "$root" 6
  before=$(git -C "$root" for-each-ref --format='%(refname) %(objectname)'; git -C "$root" status --porcelain)
  out=$(FM_ROOT_OVERRIDE="$root" "$BATCH" plan --max 2)
  [ "$(plan_field "$out" status)" = ok ] || fail "batch: expected a plan, got: $out"
  after=$(git -C "$root" for-each-ref --format='%(refname) %(objectname)'; git -C "$root" status --porcelain)
  [ "$before" = "$after" ] || fail "batch: planning must move no ref and touch no file"
  pass "planning a batch is read-only"
}

test_usage_errors_exit_nonzero() {
  set -e
  local rc
  rc=0
  "$BATCH" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "batch: a missing action must be a usage error"
  rc=0
  "$BATCH" plan --bogus >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "batch: an unknown flag must be a usage error"
  "$BATCH" --help | grep -q 'fm-upstream-batch.sh plan' || fail "batch: --help must print the usage"
  pass "usage errors exit non-zero and --help prints the contract"
}

test_large_delta_is_cut_to_the_bound
test_small_delta_targets_the_tip
test_bound_precedence_and_fallback
test_cut_lands_on_upstream_first_parent_line
test_unplannable_states_report_unknown
test_plan_is_read_only
test_usage_errors_exit_nonzero
