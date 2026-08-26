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
#   - `check` fires one actionable drift line once the cached count reaches the
#     threshold, stays silent while the gap grows by less than another full
#     threshold, fires again once that much genuinely new drift has landed (with
#     the baseline advancing), and clears the episode when the gap closes.
#   - When the watcher's per-check bound leaves no room for a network probe,
#     `check` skips the probe and still publishes a degraded report, so the
#     once-daily gate is stamped rather than the run being killed mid-probe.
#   - `check` degrades silently when the refresh cannot reach upstream, and a
#     degrade never closes or reopens an episode.
#   - `arm` leaves a registered shim the watcher will accept, and `disarm`
#     removes the shim, its binding, and the episode record.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-upstream-behind-check.sh"

# fm_custom_check_registered and fm_pr_file_mode are how the watcher itself
# decides an armed shim is authentic, so the arm test asserts through them
# rather than restating the trust format.
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-upstream-behind-check-tests)

# new_home: fresh isolated FM_HOME with an empty state/ dir. Echoes the home dir.
# The directory is minted with mktemp rather than a counter, because every
# caller runs this in a command substitution, so a counter would be incremented
# in a subshell and every test would silently share one home - and a durable
# record one test leaves behind would then decide the next test's outcome.
new_home() {
  local h
  h=$(mktemp -d "$TMP_ROOT/home-XXXXXX") || return 1
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

test_files_directly_under_skills_dir_are_not_named_as_skills() {
  set -e
  local home root upstream_src upstream_bare out
  home=$(new_home)
  root="$TMP_ROOT/repo-skills-root-file"
  upstream_src="$TMP_ROOT/upstream-src-skills-root"
  new_repo "$upstream_src"
  git clone --quiet --bare "$upstream_src" "$TMP_ROOT/upstream-skills-root.git"
  upstream_bare="$TMP_ROOT/upstream-skills-root.git"

  git clone --quiet "$upstream_src" "$root"
  git -C "$root" remote remove origin
  git -C "$root" remote add upstream "$upstream_bare"

  # A file living directly at .agents/skills/ is not a skill directory.
  mkdir -p "$upstream_src/.agents/skills/real-skill"
  printf 'index\n' > "$upstream_src/.agents/skills/README.md"
  printf 'body\n' > "$upstream_src/.agents/skills/real-skill/SKILL.md"
  git -C "$upstream_src" add .agents
  git -C "$upstream_src" commit -qm "skills index plus a real skill"
  git -C "$upstream_src" push --quiet "$upstream_bare" main

  out=$(run_check "$home" "$root" --force)

  assert_contains "$out" "area_count_agents_skills=2" "skills-root: both files count toward the area"
  assert_contains "$out" "skill=real-skill" "skills-root: the real skill is named"
  assert_contains "$out" "skills_total=1" "skills-root: only the real skill is totalled"
  printf '%s' "$out" | grep -q '^skill=README.md$' && fail "skills-root: a bare file must not be named as a skill: $out"
  pass "files directly under .agents/skills are counted but never named as skills"
}

test_degrade_preserves_last_known_good_and_retries() {
  set -e
  local home root upstream_src upstream_bare report ok_checked fresh aged out
  home=$(new_home)
  root="$TMP_ROOT/repo-stale-carry"
  upstream_src="$TMP_ROOT/upstream-src-stale"
  new_repo "$upstream_src"
  git clone --quiet --bare "$upstream_src" "$TMP_ROOT/upstream-stale.git"
  upstream_bare="$TMP_ROOT/upstream-stale.git"

  printf 'u2\n' >> "$upstream_src/seed.txt"
  git -C "$upstream_src" commit -qam u2
  git -C "$upstream_src" push --quiet "$upstream_bare" main

  git clone --quiet "$upstream_bare" "$root"
  git -C "$root" reset -q --hard HEAD~1
  git -C "$root" remote remove origin
  git -C "$root" remote add upstream "$upstream_bare"

  out=$(run_check "$home" "$root" --force)
  assert_contains "$out" "behind=1" "stale-carry: the good result is recorded first"
  report="$home/state/.upstream-behind-check.report"
  ok_checked=$(sed -n 's/^checked_at=//p' "$report" | tail -1)

  # The remote disappears from under the home; the next check must degrade.
  git -C "$root" remote set-url upstream "file://$TMP_ROOT/vanished.git"
  out=$(run_check "$home" "$root" --force)

  assert_contains "$out" "status=unknown" "stale-carry: degrades to unknown"
  assert_contains "$out" "reason=unreachable" "stale-carry: names the reason"
  assert_contains "$out" "stale_behind=1" "stale-carry: last-known behind survives the degrade"
  assert_contains "$out" "stale_ahead=0" "stale-carry: last-known ahead survives the degrade"
  assert_contains "$out" "stale_checked_at=$ok_checked" "stale-carry: discloses when the good result was taken"
  [ "$(sed -n 's/^checked_at=//p' "$report" | tail -1)" = "$ok_checked" ] \
    || fail "stale-carry: a degrade must not advance the gate stamp past the good result: $(cat "$report")"

  # Because the stamp did not advance, an ordinary (non-forced) call retries
  # rather than sitting on the unknown for the rest of the day.
  out=$(FM_UPSTREAM_CHECK_INTERVAL=1 run_check "$home" "$root")
  assert_contains "$out" "reason=unreachable" "stale-carry: an unforced call retries instead of caching the unknown"
  assert_contains "$out" "stale_behind=1" "stale-carry: repeated degrades keep carrying the last-known result"

  # A sustained outage must not retry forever: once the carried-forward good
  # result has itself aged past the interval, the degrade stamps the current
  # time again so the once-per-interval work ceiling still holds. Age the
  # cached report's own stamps to simulate the outage lasting past the window.
  aged=$((ok_checked - 200000))
  sed -i.bak "s/^checked_at=.*/checked_at=$aged/; s/^stale_checked_at=.*/stale_checked_at=$aged/" "$report"
  out=$(run_check "$home" "$root")
  fresh=$(sed -n 's/^checked_at=//p' "$report" | tail -1)
  assert_contains "$out" "stale_checked_at=$aged" "stale-carry: the aged good result is still disclosed"
  assert_contains "$out" "stale_behind=1" "stale-carry: the aged good counts are still carried"
  [ "$fresh" -gt "$aged" ] \
    || fail "stale-carry: a degrade past the good result's window must restamp: $(cat "$report")"
  # With the stamp restored to now, the next ordinary call is a cached no-op.
  run_check "$home" "$root" >/dev/null
  [ "$(sed -n 's/^checked_at=//p' "$report" | tail -1)" = "$fresh" ] \
    || fail "stale-carry: the restamped degrade must close the gate again"

  # Once the remote is reachable again, the report goes back to a fresh ok.
  git -C "$root" remote set-url upstream "$upstream_bare"
  out=$(run_check "$home" "$root" --force)
  assert_contains "$out" "status=ok" "stale-carry: recovery republishes a live result"
  printf '%s' "$out" | grep -q '^stale_' && fail "stale-carry: a recovered ok must not keep stale fields: $out"
  pass "a degrade preserves the last-known-good counts and leaves the gate open for a retry"
}

# drift_fixture <root> <upstream-bare> <n>: a repo whose main is <n> commits
# behind the bare upstream and shares its history, so the behind count is real
# rather than simulated by editing the cached report.
drift_fixture() {
  local root=$1 bare=$2 n=$3 src i
  src="$root.src"
  new_repo "$src"
  git clone --quiet --bare "$src" "$bare"
  for ((i = 1; i <= n; i++)); do
    printf 'u%s\n' "$i" >> "$src/seed.txt"
    git -C "$src" commit -qam "u$i"
  done
  git -C "$src" push --quiet "$bare" main
  git clone --quiet "$src" "$root"
  git -C "$root" reset -q --hard "$(git -C "$src" rev-list --max-parents=0 HEAD)"
  git -C "$root" remote remove origin
  git -C "$root" remote add upstream "$bare"
}

# run_drift <home> <root> [args...]: a `check` run with the daily gate disabled,
# so a test can drive several refreshes without waiting a day between them.
run_drift() {
  local home=$1 root=$2
  shift 2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_UPSTREAM_CHECK_INTERVAL=0 "$CHECK" "$@"
}

test_drift_trigger_fires_once_per_episode() {
  set -e
  local home root bare out record i

  home=$(new_home)
  root="$TMP_ROOT/drift-episode"
  bare="$TMP_ROOT/drift-episode-upstream.git"
  drift_fixture "$root" "$bare" 6

  # Under the threshold: the gap is real but not yet worth a dispatch.
  out=$(FM_UPSTREAM_DRIFT_THRESHOLD=8 run_drift "$home" "$root" check)
  [ -z "$out" ] || fail "drift-episode: a gap under the threshold must stay silent: $out"
  assert_absent "$home/state/.upstream-drift" "drift-episode: a silent run must open no episode"

  # Crossing the threshold is news exactly once.
  out=$(FM_UPSTREAM_DRIFT_THRESHOLD=6 run_drift "$home" "$root" check)
  assert_contains "$out" "6 commits behind upstream" "drift-episode: the fired line names the real gap"
  assert_contains "$out" "threshold 6" "drift-episode: the fired line names the threshold it crossed"
  assert_contains "$out" "dispatch an upstream sync task" "drift-episode: the fired line asks for the sync task"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')" = 1 ] \
    || fail "drift-episode: the watcher contract allows exactly one line: $out"
  record="$home/state/.upstream-drift"
  assert_present "$record" "drift-episode: a fired episode must be recorded durably"

  out=$(FM_UPSTREAM_DRIFT_THRESHOLD=6 run_drift "$home" "$root" check)
  [ -z "$out" ] || fail "drift-episode: the same open episode must not report twice: $out"

  # A growing gap is the same episode, not a fresh one: the point of the record
  # is that a persistent drift stops being news after the first report.
  printf 'u7\n' >> "$root.src/seed.txt"
  git -C "$root.src" commit -qam u7
  git -C "$root.src" push --quiet "$bare" main
  out=$(FM_UPSTREAM_DRIFT_THRESHOLD=6 run_drift "$home" "$root" check)
  [ -z "$out" ] || fail "drift-episode: a gap growing by less than a threshold must stay silent: $out"
  assert_contains "$(cat "$record")" "reported_behind=6" "drift-episode: the record still names the reported episode"

  # Another full threshold of genuinely new upstream work IS news again: this
  # fork lands syncs as squash merges, so the absolute count never falls and a
  # reset keyed only on that would latch the trigger silent forever.
  for i in 8 9 10 11 12 13; do
    printf 'u%s\n' "$i" >> "$root.src/seed.txt"
    git -C "$root.src" commit -qam "u$i"
  done
  git -C "$root.src" push --quiet "$bare" main
  out=$(FM_UPSTREAM_DRIFT_THRESHOLD=6 run_drift "$home" "$root" check)
  assert_contains "$out" "13 commits behind upstream" "drift-episode: a new threshold-sized block of drift must fire again"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')" = 1 ] \
    || fail "drift-episode: the watcher contract allows exactly one line: $out"
  assert_contains "$(cat "$record")" "reported_behind=13" "drift-episode: each firing re-baselines the record"

  out=$(FM_UPSTREAM_DRIFT_THRESHOLD=6 run_drift "$home" "$root" check)
  [ -z "$out" ] || fail "drift-episode: the re-baselined episode must go quiet again: $out"
  pass "the drift trigger reports one threshold-sized block of new drift at a time, re-baselining each firing"
}

test_drift_check_skips_the_probe_when_no_bound_fits() {
  set -e
  local home root bare out report

  home=$(new_home)
  root="$TMP_ROOT/drift-budget"
  bare="$TMP_ROOT/drift-budget-upstream.git"
  drift_fixture "$root" "$bare" 6

  # FM_CHECK_TIMEOUT is the watcher's own per-check kill. At 3s there is no
  # room for two bounded network probes, so the refresh must not attempt one:
  # a killed run would print nothing AND stamp nothing, making the next
  # watcher cycle repeat the same doomed probe instead of honoring the gate.
  out=$(FM_CHECK_TIMEOUT=3 FM_UPSTREAM_DRIFT_THRESHOLD=6 run_drift "$home" "$root" check)
  [ -z "$out" ] || fail "drift-budget: a skipped probe must print nothing: $out"
  report="$home/state/.upstream-behind-check.report"
  assert_present "$report" "drift-budget: the refresh must still publish a report"
  assert_contains "$(cat "$report")" "status=unknown" "drift-budget: a skipped probe degrades quietly"
  assert_contains "$(cat "$report")" "reason=timeout-budget" "drift-budget: the degrade names why the probe was skipped"
  assert_contains "$(cat "$report")" "checked_at=" "drift-budget: the once-daily gate must still be stamped"
  assert_absent "$home/state/.upstream-drift" "drift-budget: a degrade must not open an episode"

  # With the watcher's normal bound the same home does the real probe and fires.
  out=$(FM_UPSTREAM_DRIFT_THRESHOLD=6 run_drift "$home" "$root" check)
  assert_contains "$out" "dispatch an upstream sync task" "drift-budget: a fitting bound must still do the real check"
  pass "check skips the network probe and still stamps the gate when no bound fits the watcher's budget"
}

test_drift_episode_resets_after_a_sync_lands() {
  set -e
  local home root bare out

  home=$(new_home)
  root="$TMP_ROOT/drift-reset"
  bare="$TMP_ROOT/drift-reset-upstream.git"
  drift_fixture "$root" "$bare" 6

  out=$(FM_UPSTREAM_DRIFT_THRESHOLD=6 run_drift "$home" "$root" check)
  assert_contains "$out" "dispatch an upstream sync task" "drift-reset: the first episode must fire"

  # The sync lands: fast-forwarding main onto upstream closes the gap.
  git -C "$root" merge -q --ff-only upstream/main
  out=$(FM_UPSTREAM_DRIFT_THRESHOLD=6 run_drift "$home" "$root" check)
  [ -z "$out" ] || fail "drift-reset: a closed gap must report nothing: $out"
  assert_absent "$home/state/.upstream-drift" "drift-reset: a landed sync must clear the episode record"

  # A fresh gap past the threshold is news again, which is the whole point of
  # clearing the record rather than latching the trigger permanently.
  local i
  for ((i = 1; i <= 6; i++)); do
    printf 'n%s\n' "$i" >> "$root.src/seed.txt"
    git -C "$root.src" commit -qam "n$i"
  done
  git -C "$root.src" push --quiet "$bare" main
  out=$(FM_UPSTREAM_DRIFT_THRESHOLD=6 run_drift "$home" "$root" check)
  assert_contains "$out" "dispatch an upstream sync task" "drift-reset: a new episode must fire again"
  pass "a landed sync closes the episode and the next drift episode fires again"
}

test_drift_check_degrades_quietly_offline() {
  set -e
  local home root bare out

  home=$(new_home)
  root="$TMP_ROOT/drift-offline"
  bare="$TMP_ROOT/drift-offline-upstream.git"
  drift_fixture "$root" "$bare" 6

  # Offline before any episode opened: silent, and nothing recorded.
  git -C "$root" remote set-url upstream "$TMP_ROOT/drift-offline-absent.git"
  out=$(FM_UPSTREAM_DRIFT_THRESHOLD=6 FM_UPSTREAM_CHECK_TIMEOUT=2 run_drift "$home" "$root" check)
  [ -z "$out" ] || fail "drift-offline: an unreachable upstream must print nothing: $out"
  assert_absent "$home/state/.upstream-drift" "drift-offline: a degrade must not open an episode"

  # Reachable again: the real gap fires normally.
  git -C "$root" remote set-url upstream "$bare"
  out=$(FM_UPSTREAM_DRIFT_THRESHOLD=6 run_drift "$home" "$root" check)
  assert_contains "$out" "dispatch an upstream sync task" "drift-offline: recovery must fire the real episode"

  # Offline mid-episode must not close it, or the next reachable run would
  # report the same drift a second time.
  git -C "$root" remote set-url upstream "$TMP_ROOT/drift-offline-absent.git"
  out=$(FM_UPSTREAM_DRIFT_THRESHOLD=6 FM_UPSTREAM_CHECK_TIMEOUT=2 run_drift "$home" "$root" check)
  [ -z "$out" ] || fail "drift-offline: a degrade mid-episode must print nothing: $out"
  assert_present "$home/state/.upstream-drift" "drift-offline: a degrade must not close an open episode"

  git -C "$root" remote set-url upstream "$bare"
  out=$(FM_UPSTREAM_DRIFT_THRESHOLD=6 run_drift "$home" "$root" check)
  [ -z "$out" ] || fail "drift-offline: coming back online must not re-report an open episode: $out"
  pass "the drift check degrades silently offline and a degrade never opens or closes an episode"
}

test_drift_arm_registers_a_shim_the_watcher_accepts() {
  set -e
  local home root bare out shim

  home=$(new_home)
  root="$TMP_ROOT/drift-arm"
  bare="$TMP_ROOT/drift-arm-upstream.git"
  drift_fixture "$root" "$bare" 6

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$CHECK" arm)
  assert_contains "$out" "armed: state/upstream-drift.check.sh" "drift-arm: arm must report what it armed"
  shim="$home/state/upstream-drift.check.sh"
  assert_present "$shim" "drift-arm: the poll shim was not written"
  assert_present "$home/state/upstream-drift.check-trust" "drift-arm: the shim was left without a trust binding"
  [ "$(fm_pr_file_mode "$shim")" = 700 ] || fail "drift-arm: the shim must be mode 0700"

  # The binding is over the shim's exact bytes, so the watcher accepts the armed
  # shim as authentic and would reject an edited one.
  fm_custom_check_registered "$home/state" upstream-drift \
    || fail "drift-arm: the armed shim is not registered as a trusted check"
  printf '\n# edited\n' >> "$shim"
  ! fm_custom_check_registered "$home/state" upstream-drift \
    || fail "drift-arm: an edited shim must stop authenticating"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$CHECK" arm >/dev/null \
    || fail "drift-arm: re-arming must restore the bound shim"

  # Re-arming an already-armed home is idempotent rather than an error.
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$CHECK" arm >/dev/null \
    || fail "drift-arm: re-arming an armed home must succeed"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$CHECK" disarm)
  assert_contains "$out" "disarmed: state/upstream-drift.check.sh" "drift-arm: disarm must report what it removed"
  assert_absent "$shim" "drift-arm: disarm must remove the shim"
  assert_absent "$home/state/upstream-drift.check-trust" "drift-arm: disarm must remove the trust binding"
  assert_absent "$home/state/.upstream-drift" "drift-arm: disarm must remove the episode record"
  pass "arm registers a drift poll shim the watcher accepts and disarm removes every artifact"
}

test_reports_behind_and_ahead
test_missing_upstream_remote
test_unreachable_upstream
test_once_daily_noop_then_refreshes_after_interval
test_summarizes_drift_by_area_and_skill
test_bounds_skill_list_and_discloses_the_cut
test_upstream_missing_default_branch
test_files_directly_under_skills_dir_are_not_named_as_skills
test_degrade_preserves_last_known_good_and_retries
test_drift_trigger_fires_once_per_episode
test_drift_episode_resets_after_a_sync_lands
test_drift_check_skips_the_probe_when_no_bound_fits
test_drift_check_degrades_quietly_offline
test_drift_arm_registers_a_shim_the_watcher_accepts
