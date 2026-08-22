#!/usr/bin/env bash
# Tests for bin/fm-upstream-behind-check.sh: the read-only daily check of a
# home's tracked code root against its configured `upstream` remote.
#
# Guarantees under test:
#   - Reports correct behind/ahead counts and the newest upstream commit date,
#     and never mutates the checked repo (no branch, HEAD, or worktree change).
#   - A missing `upstream` remote degrades quietly to status=unknown.
#   - An unreachable `upstream` remote degrades quietly to status=unknown.
#   - A reachable `upstream` that lacks the default branch is reported as
#     no-default-branch, distinctly from an unreachable network.
#   - A normal invocation is a no-op once a report already exists within the
#     gate interval; it only redoes the work once that interval has elapsed
#     (or --force is passed).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-upstream-behind-check.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-upstream-behind-check-tests)
HOME_N=0

# new_home: fresh isolated FM_HOME with an empty state/ dir. Echoes the home dir.
new_home() {
  HOME_N=$((HOME_N + 1))
  local h="$TMP_ROOT/home-$HOME_N"
  mkdir -p "$h/state"
  printf '%s\n' "$h"
}

# new_repo <dir>: a fresh repo at <dir> on branch main with one commit. The
# branch is forced to "main" via symbolic-ref before the first commit, so the
# fixture never depends on the host's init.defaultBranch setting.
new_repo() {
  local dir=$1
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  printf 'seed\n' > "$dir/seed.txt"
  git -C "$dir" add seed.txt
  git -C "$dir" commit -qm seed
}

run_check() {  # <home> <root> [args...]
  local home=$1 root=$2
  shift 2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$CHECK" "$@"
}

test_reports_behind_and_ahead() {
  set -e
  local home root upstream_src upstream_bare out before_head
  home=$(new_home)
  root="$TMP_ROOT/repo-behind-ahead"
  upstream_src="$TMP_ROOT/upstream-src-1"

  new_repo "$upstream_src"
  git clone --quiet --bare "$upstream_src" "$TMP_ROOT/upstream-1.git"
  upstream_bare="$TMP_ROOT/upstream-1.git"

  # Two more commits land upstream after the clone point.
  printf 'u2\n' >> "$upstream_src/seed.txt"
  git -C "$upstream_src" commit -qam u2
  printf 'u3\n' >> "$upstream_src/seed.txt"
  git -C "$upstream_src" commit -qam u3
  git -C "$upstream_src" push --quiet "$upstream_bare" main

  # Local clone reset to the original (pre-u2/u3) commit, plus one commit of
  # its own, and an `upstream` remote pointing at the bare repo.
  git clone --quiet "$upstream_src" "$root"
  git -C "$root" reset -q --hard "$(git -C "$upstream_src" rev-list --max-parents=0 HEAD)"
  git -C "$root" remote remove origin
  git -C "$root" remote add upstream "$upstream_bare"
  printf 'local\n' >> "$root/seed.txt"
  git -C "$root" commit -qam local1

  before_head=$(git -C "$root" rev-parse HEAD)

  out=$(run_check "$home" "$root" --force)

  assert_contains "$out" "status=ok" "behind/ahead: reports ok status"
  assert_contains "$out" "behind=2" "behind/ahead: two upstream-only commits reported as behind"
  assert_contains "$out" "ahead=1" "behind/ahead: one local-only commit reported as ahead"
  printf '%s' "$out" | grep -Eq 'newest_upstream_date=[0-9]{4}-[0-9]{2}-[0-9]{2}' \
    || fail "behind/ahead: newest_upstream_date missing or malformed: $out"

  [ "$(git -C "$root" rev-parse HEAD)" = "$before_head" ] || fail "behind/ahead: HEAD moved - check must never mutate the repo"
  [ -z "$(git -C "$root" status --porcelain)" ] || fail "behind/ahead: working tree left dirty"
  assert_present "$home/state/.upstream-behind-check.report" "behind/ahead: durable report was not written"
  pass "reports behind/ahead counts and newest upstream date without mutating the repo"
}

test_missing_upstream_remote() {
  set -e
  local home root out
  home=$(new_home)
  root="$TMP_ROOT/repo-no-upstream"
  new_repo "$root"

  out=$(run_check "$home" "$root" --force)

  assert_contains "$out" "status=unknown" "no-remote: degrades to unknown status"
  assert_contains "$out" "reason=no-upstream-remote" "no-remote: names the missing-remote reason"
  pass "a missing upstream remote degrades quietly to status=unknown"
}

test_unreachable_upstream() {
  set -e
  local home root out
  home=$(new_home)
  root="$TMP_ROOT/repo-unreachable"
  new_repo "$root"
  git -C "$root" remote add upstream "file://$TMP_ROOT/does-not-exist.git"

  out=$(run_check "$home" "$root" --force)

  assert_contains "$out" "status=unknown" "unreachable: degrades to unknown status"
  assert_contains "$out" "reason=unreachable" "unreachable: names the unreachable reason"
  pass "an unreachable upstream remote degrades quietly to status=unknown"
}

test_once_daily_noop_then_refreshes_after_interval() {
  set -e
  local home root upstream_src upstream_bare first second third
  home=$(new_home)
  root="$TMP_ROOT/repo-daily-gate"
  upstream_src="$TMP_ROOT/upstream-src-2"
  new_repo "$upstream_src"
  git clone --quiet --bare "$upstream_src" "$TMP_ROOT/upstream-2.git"
  upstream_bare="$TMP_ROOT/upstream-2.git"

  git clone --quiet "$upstream_src" "$root"
  git -C "$root" remote remove origin
  git -C "$root" remote add upstream "$upstream_bare"

  first=$(run_check "$home" "$root" --force)
  assert_contains "$first" "behind=0" "daily-gate: starts even"

  # A new upstream commit lands, but an ordinary (non-forced) call within the
  # gate interval must stay a no-op and keep reporting the stale snapshot.
  printf 'u2\n' >> "$upstream_src/seed.txt"
  git -C "$upstream_src" commit -qam u2
  git -C "$upstream_src" push --quiet "$upstream_bare" main

  second=$(run_check "$home" "$root")
  [ "$second" = "$first" ] || fail "daily-gate: an ordinary call inside the interval must not redo the check (first=$first second=$second)"

  # Force the gate open by pretending the cached report is old, then confirm
  # an ordinary call now redoes the work and picks up the new upstream commit.
  third=$(FM_UPSTREAM_CHECK_INTERVAL=0 run_check "$home" "$root")
  assert_contains "$third" "behind=1" "daily-gate: once the interval elapses, an ordinary call refreshes and sees the new commit"
  pass "does real work at most once per day and refreshes once the interval elapses"
}

test_summarizes_drift_by_area_and_skill() {
  set -e
  local home root upstream_src upstream_bare out
  home=$(new_home)
  root="$TMP_ROOT/repo-drift-summary"
  upstream_src="$TMP_ROOT/upstream-src-3"

  new_repo "$upstream_src"
  git clone --quiet --bare "$upstream_src" "$TMP_ROOT/upstream-3.git"
  upstream_bare="$TMP_ROOT/upstream-3.git"

  git clone --quiet "$upstream_src" "$root"
  git -C "$root" remote remove origin
  git -C "$root" remote add upstream "$upstream_bare"

  # Two upstream-only commits: one touching a skill file, one touching bin/.
  mkdir -p "$upstream_src/.agents/skills/example-skill"
  printf 'skill body\n' > "$upstream_src/.agents/skills/example-skill/SKILL.md"
  git -C "$upstream_src" add .agents/skills/example-skill/SKILL.md
  git -C "$upstream_src" commit -qm "add example-skill"
  mkdir -p "$upstream_src/bin"
  printf 'echo hi\n' > "$upstream_src/bin/tool.sh"
  git -C "$upstream_src" add bin/tool.sh
  git -C "$upstream_src" commit -qm "add tool.sh"
  git -C "$upstream_src" push --quiet "$upstream_bare" main

  out=$(run_check "$home" "$root" --force)

  assert_contains "$out" "area_count_agents_skills=1" "drift-summary: one file changed under .agents/skills/"
  assert_contains "$out" "area_count_bin=1" "drift-summary: one file changed under bin/"
  assert_contains "$out" "skill=example-skill" "drift-summary: names the changed skill"
  assert_contains "$out" "detail_hint=" "drift-summary: includes a pointer command for the full commit list"
  assert_not_contains "$out" "add example-skill" "drift-summary: never inlines individual commit subjects"
  pass "groups pending upstream drift by area and names changed skills, bounded with a detail pointer"
}

test_bounds_skill_list_and_discloses_the_cut() {
  set -e
  local home root upstream_src upstream_bare out i
  home=$(new_home)
  root="$TMP_ROOT/repo-drift-bound"
  upstream_src="$TMP_ROOT/upstream-src-4"

  new_repo "$upstream_src"
  git clone --quiet --bare "$upstream_src" "$TMP_ROOT/upstream-4.git"
  upstream_bare="$TMP_ROOT/upstream-4.git"

  git clone --quiet "$upstream_src" "$root"
  git -C "$root" remote remove origin
  git -C "$root" remote add upstream "$upstream_bare"

  i=1
  while [ "$i" -le 3 ]; do
    mkdir -p "$upstream_src/.agents/skills/skill-$i"
    printf 'body\n' > "$upstream_src/.agents/skills/skill-$i/SKILL.md"
    git -C "$upstream_src" add ".agents/skills/skill-$i/SKILL.md"
    git -C "$upstream_src" commit -qm "add skill-$i"
    i=$((i + 1))
  done
  git -C "$upstream_src" push --quiet "$upstream_bare" main

  out=$(FM_UPSTREAM_SKILLS_SHOWN=2 run_check "$home" "$root" --force)

  assert_contains "$out" "skills_total=3" "drift-bound: total reflects every changed skill"
  assert_contains "$out" "skills_shown=2" "drift-bound: shown count respects the bound"
  [ "$(printf '%s' "$out" | grep -c '^skill=')" -eq 2 ] || fail "drift-bound: expected exactly 2 skill= lines, got: $out"
  pass "bounds the skill list and discloses how many were cut"
}

test_upstream_missing_default_branch() {
  set -e
  local home root upstream_src upstream_bare out
  home=$(new_home)
  root="$TMP_ROOT/repo-missing-default"
  upstream_src="$TMP_ROOT/upstream-src-missing-default"

  # Upstream is perfectly reachable but publishes only `master`, while this
  # home's default branch is `main` - a naming mismatch, not a network fault.
  new_repo "$upstream_src"
  git -C "$upstream_src" branch -m main master
  git clone --quiet --bare "$upstream_src" "$TMP_ROOT/upstream-missing-default.git"
  upstream_bare="$TMP_ROOT/upstream-missing-default.git"

  new_repo "$root"
  git -C "$root" remote add upstream "$upstream_bare"

  out=$(run_check "$home" "$root" --force)

  assert_contains "$out" "status=unknown" "missing-default: degrades to unknown status"
  assert_contains "$out" "reason=no-default-branch" "missing-default: names the missing branch, not a network fault"
  pass "a reachable upstream without the default branch reports no-default-branch"
}

test_reports_behind_and_ahead
test_missing_upstream_remote
test_unreachable_upstream
test_once_daily_noop_then_refreshes_after_interval
test_summarizes_drift_by_area_and_skill
test_bounds_skill_list_and_discloses_the_cut
test_upstream_missing_default_branch
