#!/usr/bin/env bash
# tests/fm-primary-scope-lib.test.sh - unit tests for the primary-vs-child-
# worktree predicate (bin/fm-primary-scope-lib.sh). Pure functions, no backend
# required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot "fm-primary-scope") || fail "tmproot"

# Build a "primary" checkout: a plain (non-worktree) clone that looks like a
# real firstmate home, plus a linked task worktree of that same repo standing
# in for a crewmate's isolated checkout of the firstmate repo itself. The lib
# file itself must be tracked BEFORE the worktree is added so the crew
# worktree's own bin/ physically carries a copy - fm_primary_scope_matches
# keys its classification off its own on-disk location (this library's
# sourced path), never the caller's cwd, exactly like a real hook script
# sources its neighboring copy of this lib.
PRIMARY="$TMP/primary"
CREW_WT="$TMP/crew-worktree"
fm_git_init_commit "$PRIMARY"
mkdir -p "$PRIMARY/bin" "$PRIMARY/state"
cp "$ROOT/bin/fm-primary-scope-lib.sh" "$PRIMARY/bin/fm-primary-scope-lib.sh"
: > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" add -A
git -C "$PRIMARY" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "primary contents"
git -C "$PRIMARY" worktree add --quiet -b crew-branch "$CREW_WT"

# --- genuine primary session: sourced from the real primary's own bin/ ------

(
  # shellcheck source=/dev/null
  . "$PRIMARY/bin/fm-primary-scope-lib.sh"
  fm_primary_scope_matches "$PRIMARY" "$PRIMARY/state"
) || fail "a real primary session (lib sourced from its own root, no env leak) must classify as PRIMARY"
pass "fm_primary_scope_matches classifies a genuine primary checkout as PRIMARY"

# --- leaked-env crewmate worktree: root/state point at the primary home but --
# --- the guarded process actually sources its own copy of the lib from a  ---
# --- linked task worktree of the firstmate repo -----------------------------

if (
  # shellcheck source=/dev/null
  . "$CREW_WT/bin/fm-primary-scope-lib.sh"
  fm_primary_scope_matches "$PRIMARY" "$PRIMARY/state"
); then
  fail "a crew task worktree with root/state env-leaked to the real primary home must NOT classify as PRIMARY"
fi
pass "fm_primary_scope_matches rejects a firstmate-repo crew worktree even when root/state name the real primary home"

# A crew worktree evaluated honestly against its own root (no env leak) is
# still correctly excluded, because it is a linked worktree, not a plain
# checkout.
if (
  # shellcheck source=/dev/null
  . "$CREW_WT/bin/fm-primary-scope-lib.sh"
  fm_primary_scope_matches "$CREW_WT" "$PRIMARY/state"
); then
  fail "a crew task worktree must not classify as PRIMARY even when evaluated against its own root"
fi
pass "fm_primary_scope_matches still rejects a crew worktree evaluated against its own (linked) root"
