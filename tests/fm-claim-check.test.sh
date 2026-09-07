#!/usr/bin/env bash
# Behavior tests for fm-claim-check.sh: a claimed path passes when git knows
# it - touched in the diff, or tracked at HEAD - and fails only when the
# branch produced no such file. Detection is git-fact only, so the prose
# around a path never changes the verdict.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLAIM_CHECK="$ROOT/bin/fm-claim-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-claim-check)

make_repo() {
  local name=$1 repo
  repo="$TMP_ROOT/$name"
  mkdir -p "$repo/docs"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  printf 'seed\n' > "$repo/seed.txt"
  printf 'architecture\n' > "$repo/docs/architecture.md"
  git -C "$repo" add seed.txt docs/architecture.md
  git -C "$repo" commit -q -m seed
  printf '%s\n' "$repo"
}

REPO=$(make_repo happy)
git -C "$REPO" checkout -q -b work
mkdir -p "$REPO/bin"
printf 'new\n' > "$REPO/bin/fm-new-thing.sh"
git -C "$REPO" add bin/fm-new-thing.sh
git -C "$REPO" commit -q -m add-thing

# --- a path touched in the diff: exit 0, no output ---
OUT=$(cd "$REPO" && "$CLAIM_CHECK" main <<<'implemented bin/fm-new-thing.sh')
STATUS=$?
[ "$STATUS" -eq 0 ] || fail "expected exit 0 for a verified claim, got $STATUS"
[ -z "$OUT" ] || fail "expected no output for a verified claim, got: $OUT"

# --- a path the branch never produced: exit 1, path listed ---
OUT=$(cd "$REPO" && "$CLAIM_CHECK" main <<<'implemented bin/fm-never-existed.sh' 2>/dev/null)
STATUS=$?
[ "$STATUS" -eq 1 ] || fail "expected exit 1 for an unverified claim, got $STATUS"
assert_contains "$OUT" "bin/fm-never-existed.sh" "unverified path listed in output"

# --- claim text with no path-shaped token: vacuously verified ---
OUT=$(cd "$REPO" && "$CLAIM_CHECK" main <<<'wired up the new gate' 2>/dev/null)
STATUS=$?
[ "$STATUS" -eq 0 ] || fail "expected exit 0 when no path-shaped token is present, got $STATUS"
[ -z "$OUT" ] || fail "expected no output when no path-shaped token is present, got: $OUT"

# --- an unchanged file cited as reference is tracked, so it passes ---
# This is what the prose-heuristic design kept getting wrong: a done summary
# legitimately names files it did not change, and tracked-at-HEAD settles that
# without reading the sentence.
OUT=$(cd "$REPO" && "$CLAIM_CHECK" main <<<'wired the gate in bin/fm-new-thing.sh; behavior matches docs/architecture.md' 2>/dev/null)
STATUS=$?
[ "$STATUS" -eq 0 ] || fail "expected exit 0 when an unchanged path is tracked, got $STATUS: $OUT"
[ -z "$OUT" ] || fail "expected no output for a tracked cited path, got: $OUT"

# --- the same tracked path passes even under a change verb: the documented
# --- limitation. Detection never reads the prose, in either direction.
OUT=$(cd "$REPO" && "$CLAIM_CHECK" main <<<'updated docs/architecture.md' 2>/dev/null)
STATUS=$?
[ "$STATUS" -eq 0 ] || fail "expected exit 0 for a tracked-but-untouched path, got $STATUS: $OUT"
[ -z "$OUT" ] || fail "expected no output for a tracked-but-untouched path, got: $OUT"

# --- a summary mixing a tracked citation with a nonexistent claim reports
# --- only the nonexistent one ---
OUT=$(cd "$REPO" && "$CLAIM_CHECK" main <<<'added bin/fm-never-existed.sh; behavior matches docs/architecture.md' 2>/dev/null)
STATUS=$?
[ "$STATUS" -eq 1 ] || fail "expected exit 1 for a nonexistent claimed path, got $STATUS"
assert_contains "$OUT" "bin/fm-never-existed.sh" "nonexistent path listed in output"
case $OUT in *docs/architecture.md*) fail "tracked path must not be reported: $OUT";; esac

# --- a "./"-prefixed claim resolves to the repo-relative git path ---
OUT=$(cd "$REPO" && "$CLAIM_CHECK" main <<<'updated ./bin/fm-new-thing.sh')
STATUS=$?
[ "$STATUS" -eq 0 ] || fail "expected exit 0 for a ./-prefixed verified claim, got $STATUS: $OUT"
[ -z "$OUT" ] || fail "expected no output for a ./-prefixed verified claim, got: $OUT"

OUT=$(cd "$REPO" && "$CLAIM_CHECK" main <<<'updated ./bin/fm-never-existed.sh' 2>/dev/null)
STATUS=$?
[ "$STATUS" -eq 1 ] || fail "expected exit 1 for a ./-prefixed unverified claim, got $STATUS"
assert_contains "$OUT" "bin/fm-never-existed.sh" "normalized unverified path listed in output"

# --- usage errors ---
"$CLAIM_CHECK" >/dev/null 2>&1 && fail "expected non-zero exit with no arguments"
"$CLAIM_CHECK" main extra </dev/null >/dev/null 2>&1 && fail "expected non-zero exit with a second argument"
"$CLAIM_CHECK" --help >/dev/null 2>&1 || fail "expected --help to succeed"

# --- an unresolvable base ref is a usage-class error, not a failed claim ---
(cd "$REPO" && "$CLAIM_CHECK" no-such-ref <<<'implemented bin/fm-new-thing.sh' >/dev/null 2>&1)
STATUS=$?
[ "$STATUS" -eq 2 ] || fail "expected exit 2 for an unresolvable base ref, got $STATUS"

# --- the DOD block hands workers an invokable claim-check command ---
# The rendered DOD block is a generated agent-facing interface; the command it
# emits must run from a project worktree that is not firstmate's own checkout.
. "$ROOT/bin/fm-dod-lib.sh"
OTHER_CWD="$TMP_ROOT/elsewhere"
mkdir -p "$OTHER_CWD"
for MODE in direct-PR local-only no-mistakes; do
  BLOCK=$(fm_dod_block "$MODE" demo) || fail "fm_dod_block failed for mode $MODE"
  # shellcheck disable=SC2016  # the backticks delimit the DOD block's markdown
  # code span, not a command substitution.
  CMD=$(printf '%s\n' "$BLOCK" | sed -n 's/.*`\([^`]*fm-claim-check\.sh\) main`.*/\1/p' | head -1)
  [ -n "$CMD" ] || fail "no claim-check command rendered for mode $MODE"
  (cd "$OTHER_CWD" && "$CMD" --help >/dev/null 2>&1) \
    || fail "claim-check command '$CMD' from mode $MODE is not invokable outside the firstmate checkout"
done

pass "fm-claim-check verifies claimed paths against git facts"
