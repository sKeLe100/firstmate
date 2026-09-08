#!/usr/bin/env bash
# fm-nomistakes-gate-check.sh - detect whether a local branch's HEAD has
# diverged from the no-mistakes pipeline's own gate ref before pushing.
#
# Usage:
#   fm-nomistakes-gate-check.sh [branch]
#
# Resolves the no-mistakes remote, reads the gate config (v2:<hash>), and
# compares the gate hash against local HEAD using two ancestry checks:
#   1. git merge-base --is-ancestor <gate> HEAD   (gate is before HEAD)
#   2. git merge-base --is-ancestor HEAD <gate>   (HEAD is before gate)
#
# Prints exactly one of: equal, ahead, behind, diverged
#   equal   - HEAD and gate hash match exactly
#   ahead   - HEAD is ahead of the gate (gate is an ancestor of HEAD)
#   behind  - the gate is ahead of HEAD (HEAD is an ancestor of gate)
#   diverged - neither is an ancestor of the other
#
# This script is read-only: it never writes, pushes, or attempts to fix
# anything. It only detects the relationship.
#
# Exit codes:
#   0 - one of the four status values printed to stdout
#   1 - usage error, git error, or gate config unreadable
set -u

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: fm-nomistakes-gate-check.sh [branch]

Detects whether a local branch's HEAD has diverged from the no-mistakes
pipeline's own gate ref before pushing.

Resolves the no-mistakes remote, reads the gate config (v2:<hash>), and
compares the gate hash against local HEAD using two ancestry checks:
  git merge-base --is-ancestor <gate> HEAD   (gate is before HEAD)
  git merge-base --is-ancestor HEAD <gate>   (HEAD is before gate)

Prints exactly one of: equal, ahead, behind, diverged.
This script is read-only: it never writes, pushes, or attempts to fix anything.

Exit 0: one of the four status values printed to stdout.
Exit 1: usage error, git error, or gate config unreadable.

Optional <branch> argument: the local branch to check against.
Defaults to the current branch.
EOF
}

# --- locate the no-mistakes gate config -------------------------------------

# no-mistakes gate config lives in the no-mistakes repo directory alongside
# the local repo's .git/worktrees/<name> or .git directory. We resolve the
# no-mistakes remote URL to find the correct gate config.
resolve_gate_config() {
  local nm_remote nm_url gate_file
  nm_remote=$(git remote | grep -xi no-mistakes || true)
  if [ -z "$nm_remote" ]; then
    echo "error: no-mistakes remote not found" >&2
    return 1
  fi
  nm_url=$(git config --get "remote.$nm_remote.url" || true)
  if [ -z "$nm_url" ]; then
    echo "error: no-mistakes remote has no URL" >&2
    return 1
  fi
  # Strip file:// prefix if present
  nm_url="${nm_url#file://}"
  # nm_url points to a directory like /home/sean_/.no-mistakes/repos/4936102b4bcf.git
  gate_file="$nm_url/no-mistakes-gate-config"
  if [ ! -f "$gate_file" ]; then
    echo "error: gate config not found at $gate_file" >&2
    return 1
  fi
  printf '%s\n' "$gate_file"
}

# --- read the gate hash from the config --------------------------------------

read_gate_hash() {
  local gate_file=$1 line hash
  line=$(head -n 1 "$gate_file" 2>/dev/null) || return 1
  # Expected format: v2:<sha>
  case "$line" in
    v2:*)
      hash="${line#v2:}"
      if [ -z "$hash" ]; then
        echo "error: empty hash in gate config" >&2
        return 1
      fi
      printf '%s\n' "$hash"
      return 0
      ;;
    *)
      echo "error: unexpected gate config format: $line (expected v2:<sha>)" >&2
      return 1
      ;;
  esac
}

# --- ancestry comparison ----------------------------------------------------

compare_heads() {
  local gate_hash=$1 head_hash=$2

  # If they are the same commit, they are equal.
  if [ "$gate_hash" = "$head_hash" ]; then
    printf 'equal\n'
    return 0
  fi

  # Check ancestry in both directions.
  local gate_before_head=0 head_before_gate=0

  # Is gate an ancestor of HEAD? (gate is behind HEAD)
  if git merge-base --is-ancestor "$gate_hash" HEAD 2>/dev/null; then
    gate_before_head=1
  fi

  # Is HEAD an ancestor of gate? (HEAD is behind gate)
  if git merge-base --is-ancestor HEAD "$gate_hash" 2>/dev/null; then
    head_before_gate=1
  fi

  if [ "$gate_before_head" -eq 1 ] && [ "$head_before_gate" -eq 1 ]; then
    # Both are ancestors of each other but hashes differ - should not happen
    # with valid commits, but handle it as diverged.
    printf 'diverged\n'
  elif [ "$gate_before_head" -eq 1 ]; then
    printf 'ahead\n'
  elif [ "$head_before_gate" -eq 1 ]; then
    printf 'behind\n'
  else
    printf 'diverged\n'
  fi
}

# --- main -------------------------------------------------------------------

TARGET="${1:-}"

# If the argument is a directory (worktree), cd into it and use its default
# branch. This lets callers pass a worktree path and have the script resolve
# HEAD from within that worktree.
if [ -n "$TARGET" ] && [ -d "$TARGET" ] && { [ -f "$TARGET/.git" ] || [ -d "$TARGET/.git" ]; }; then
  cd -- "$TARGET" || exit 1
  HEAD_REF="HEAD"
elif [ -n "$TARGET" ]; then
  # Treat as a branch ref; verify it exists in the current repo
  if ! git rev-parse --verify "$TARGET" >/dev/null 2>&1; then
    die "branch '$TARGET' does not exist"
  fi
  HEAD_REF="$TARGET"
else
  HEAD_REF="HEAD"
fi

HEAD_HASH=$(git rev-parse "$HEAD_REF" 2>/dev/null) || die "cannot resolve HEAD hash"

GATE_FILE=$(resolve_gate_config) || die "cannot resolve gate config"
GATE_HASH=$(read_gate_hash "$GATE_FILE") || die "cannot read gate hash"

compare_heads "$GATE_HASH" "$HEAD_HASH"
