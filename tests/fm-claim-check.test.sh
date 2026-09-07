#!/usr/bin/env bash
# Behavior tests for fm-claim-check.sh: pass when every claimed path was
# touched in the diff, fail and list unverified paths otherwise, and treat
# claim text with no path-shaped token as vacuously verified.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLAIM_CHECK="$ROOT/bin/fm-claim-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-claim-check)

make_repo() {
  local name=$1 repo
  repo="$TMP_ROOT/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  printf 'seed\n' > "$repo/seed.txt"
  git -C "$repo" add seed.txt
  git -C "$repo" commit -q -m seed
  printf '%s\n' "$repo"
}

# --- every claimed path was touched: exit 0, no output ---
REPO=$(make_repo happy)
git -C "$REPO" checkout -q -b work
mkdir -p "$REPO/bin"
printf 'new\n' > "$REPO/bin/fm-new-thing.sh"
git -C "$REPO" add bin/fm-new-thing.sh
git -C "$REPO" commit -q -m add-thing
OUT=$(cd "$REPO" && "$CLAIM_CHECK" main <<<'implemented bin/fm-new-thing.sh')
STATUS=$?
[ "$STATUS" -eq 0 ] || fail "expected exit 0 for a verified claim, got $STATUS"
[ -z "$OUT" ] || fail "expected no output for a verified claim, got: $OUT"

# --- a claimed path never touched: exit 1, path listed ---
OUT=$(cd "$REPO" && "$CLAIM_CHECK" main <<<'implemented bin/fm-never-touched.sh' 2>/dev/null)
STATUS=$?
[ "$STATUS" -eq 1 ] || fail "expected exit 1 for an unverified claim, got $STATUS"
assert_contains "$OUT" "bin/fm-never-touched.sh" "unverified path listed in output"

# --- claim text with no path-shaped token: vacuously verified ---
OUT=$(cd "$REPO" && "$CLAIM_CHECK" main <<<'wired up the new gate' 2>/dev/null)
STATUS=$?
[ "$STATUS" -eq 0 ] || fail "expected exit 0 when no path-shaped token is present, got $STATUS"
[ -z "$OUT" ] || fail "expected no output when no path-shaped token is present, got: $OUT"

# --- usage errors ---
"$CLAIM_CHECK" >/dev/null 2>&1 && fail "expected non-zero exit with no arguments"
"$CLAIM_CHECK" --help >/dev/null 2>&1 || fail "expected --help to succeed"

pass "fm-claim-check verifies claimed paths against the diff"
