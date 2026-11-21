#!/usr/bin/env bash
# Tests for bin/fm-predispatch-check.sh: the advisory pre-dispatch check that
# warns when a ship task looks like work a merged pull request or a recent
# default-branch commit already landed.
#
# Guarantees under test:
#   - A merged pull request whose title shares the task's significant terms is
#     reported with its number, title, and full URL.
#   - A task id or ship branch appearing directly in a merged pull request's
#     head branch is reported even when the title wording differs.
#   - A recent commit on origin's default branch that shares the task's terms is
#     reported with its short hash and subject.
#   - Nothing is printed and the exit stays 0 when nothing matches.
#   - A missing gh, a non-GitHub origin, and a project with no commits degrade
#     quietly: no output and exit 0.
#   - A match never refuses: the exit is always 0, because a text match is
#     evidence rather than proof.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-predispatch-check.sh"

TMP_ROOT=$(fm_test_tmproot fm-predispatch-check)

fm_git_identity fmtest fmtest@example.invalid

# make_fake_gh <dir> <tsv-file>: writes a gh that ignores its arguments and
# prints the fixture TSV. Real gh would apply --jq and print the same rows.
make_fake_gh() {
  local fakebin=$1 rows=$2
  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
cat "$rows"
SH
  chmod +x "$fakebin/gh"
}

# new_repo <dir> [commit-subject]: a repo whose origin is the firstmate fork and
# whose origin/main points at one commit with <commit-subject>.
new_repo() {
  local dir=$1 subject=${2:-seed}
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" config user.email "fmtest@example.invalid"
  git -C "$dir" config user.name "fmtest"
  printf 'seed\n' > "$dir/seed.txt"
  git -C "$dir" add seed.txt
  git -C "$dir" commit -qm "$subject"
  git -C "$dir" update-ref refs/remotes/origin/main HEAD
  git -C "$dir" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$dir" remote add origin https://github.com/sKeLe100/firstmate.git
}

# pr_fixture <file>: one row matching the bearings PC02 disclosure task.
pr_fixture() {
  cat > "$1" <<'EOF'
289	feat(bearings): disclose PC02 lane in the fleet board	fm/bearings-pc02-disclosure	2026-11-20T12:00:00Z	https://github.com/sKeLe100/firstmate/pull/289
300	chore: unrelated housekeeping	fm/unrelated-housekeeping	2026-11-20T12:00:00Z	https://github.com/sKeLe100/firstmate/pull/300
EOF
}

run_check() {  # <fakebin> <args...>
  local fakebin=$1
  shift
  PATH="$fakebin:$PATH" "$CHECK" "$@"
}

test_reports_matching_merged_pr_and_commit() {
  set -e
  local repo rows fakebin out rc
  repo="$TMP_ROOT/repo-match"
  rows="$TMP_ROOT/prs-match.tsv"
  fakebin="$TMP_ROOT/fakebin-match"
  new_repo "$repo" "feat(bin): add bearings PC02 disclosure"
  pr_fixture "$rows"
  make_fake_gh "$fakebin" "$rows"

  rc=0
  out=$(run_check "$fakebin" bearings-pc02-disclosure-2 --project "$repo" \
    --text "Add a cheap check about bearings PC02 disclosure" 2>&1) || rc=$?
  expect_code 0 "$rc" "a match must never refuse the dispatch"
  assert_contains "$out" "merged pull request #289" "matching merged PR is reported"
  assert_contains "$out" "https://github.com/sKeLe100/firstmate/pull/289" "PR URL is the full URL"
  assert_contains "$out" "recent commit" "matching recent commit is reported"
  assert_contains "$out" "add bearings PC02 disclosure" "commit subject is reported"
  ! printf '%s\n' "$out" | grep -q "pull/300" || fail "unrelated merged PR must not be reported"
  pass "matching merged PR and recent commit are reported, exit stays 0"
}

test_direct_branch_match_reports_even_with_different_wording() {
  set -e
  local repo rows fakebin out
  repo="$TMP_ROOT/repo-direct"
  rows="$TMP_ROOT/prs-direct.tsv"
  fakebin="$TMP_ROOT/fakebin-direct"
  new_repo "$repo" "initial unrelated commit"
  pr_fixture "$rows"
  make_fake_gh "$fakebin" "$rows"

  out=$(run_check "$fakebin" bearings-pc02-disclosure --project "$repo" \
    --text "completely different wording here" 2>&1)
  assert_contains "$out" "merged pull request #289" "a matching head branch is a direct match"
  ! printf '%s\n' "$out" | grep -q "recent commit" || fail "unrelated commit must not be reported"
  pass "a matching merged PR head branch is reported on its own"
}

test_silent_when_nothing_matches() {
  set -e
  local repo rows fakebin out rc
  repo="$TMP_ROOT/repo-none"
  rows="$TMP_ROOT/prs-none.tsv"
  fakebin="$TMP_ROOT/fakebin-none"
  new_repo "$repo" "feat: upgrade quota display colors"
  pr_fixture "$rows"
  make_fake_gh "$fakebin" "$rows"

  rc=0
  out=$(run_check "$fakebin" totally-different-task --project "$repo" \
    --text "Adjust dashboard margins" 2>&1) || rc=$?
  expect_code 0 "$rc" "a no-match run exits 0"
  [ -z "$out" ] || fail "a no-match run must be silent, got: $out"
  pass "no match prints nothing and exits 0"
}

test_missing_gh_and_non_github_origin_degrade_quietly() {
  set -e
  local repo out rc nobin nogh
  repo="$TMP_ROOT/repo-degrade"
  new_repo "$repo" "feat(bin): add bearings PC02 disclosure"
  # Keep git and coreutils reachable while omitting gh from the PATH search.
  nobin="$TMP_ROOT/fakebin-nogh"
  mkdir -p "$nobin"
  nogh="$nobin:/usr/bin:/bin"

  rc=0
  out=$(PATH="$nogh" "$CHECK" bearings-pc02-disclosure-2 --project "$repo" \
    --text "bearings PC02 disclosure" 2>&1) || rc=$?
  expect_code 0 "$rc" "a missing gh exits 0"
  assert_contains "$out" "recent commit" "local commit history is still checked without gh"
  ! printf '%s\n' "$out" | grep -q "merged pull request" || fail "no gh means no PR search"

  git -C "$repo" remote set-url origin https://gitlab.example.invalid/owner/repo.git
  rows="$TMP_ROOT/prs-gitlab.tsv"
  fakebin="$TMP_ROOT/fakebin-gitlab"
  pr_fixture "$rows"
  make_fake_gh "$fakebin" "$rows"
  rc=0
  out=$(run_check "$fakebin" bearings-pc02-disclosure-2 --project "$repo" \
    --text "bearings PC02 disclosure" 2>&1) || rc=$?
  expect_code 0 "$rc" "a non-GitHub origin exits 0"
  ! printf '%s\n' "$out" | grep -q "merged pull request" || fail "a non-GitHub origin must not run the PR search"
  pass "missing gh and non-GitHub origin degrade quietly"
}

test_usage_errors_are_loud() {
  set -e
  local rc
  rc=0
  "$CHECK" only-an-id >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a missing --project is a usage error"
  rc=0
  "$CHECK" an-id --project "$TMP_ROOT/does-not-exist" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a missing project directory is a usage error"
  pass "usage errors exit 2"
}

test_reports_matching_merged_pr_and_commit
test_direct_branch_match_reports_even_with_different_wording
test_silent_when_nothing_matches
test_missing_gh_and_non_github_origin_degrade_quietly
test_usage_errors_are_loud
