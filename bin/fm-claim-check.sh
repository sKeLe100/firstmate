#!/usr/bin/env bash
# Post-green verification gate: grep-verify that a claim text's asserted
# file paths were actually touched in this branch's diff, catching a "done"
# summary that names files never committed.
# Usage: fm-claim-check.sh <base-ref>
# Reads the claim text from stdin.
# Splits the claim into clauses, and from each clause that asserts a change
# (created/added/modified/updated/wired/...) extracts path-shaped tokens
# (containing a "/" and a file extension). Fails, listing each one, if any is
# absent from `git diff --name-only <base-ref>...HEAD`. Paths merely cited in
# a non-mutating clause are not treated as claims.
# Exit 0: every asserted path was touched (or none was asserted).
# Exit 1: at least one asserted path was not touched in the diff.
# Exit 2: usage or git error.
set -u

CHANGE_VERBS='add|added|adding|creat(e|ed|ing)|introduc(e|ed|ing)|implement(|ed|ing)|writ(e|ing)|wrote|modif(y|ied|ying)|updat(e|ed|ing)|chang(e|ed|ing)|edit(|ed|ing)|patch(|ed|ing)|fix(|ed|ing)|refactor(|ed|ing)|renam(e|ed|ing)|mov(e|ed|ing)|remov(e|ed|ing)|delet(e|ed|ing)|drop(|ped|ping)|wir(e|ed|ing)|extend(|ed|ing)|touch(|ed|ing)|replac(e|ed|ing)|reworked|rewrote|rewritten|hardened|split|ported'

usage() {
  cat <<'EOF'
Usage: fm-claim-check.sh <base-ref>

Grep-verifies a claim text's asserted file paths against the diff of HEAD
against <base-ref>. Reads the claim text from stdin. Only path-shaped
tokens in a clause that asserts a change are treated as claims; a path
merely cited (e.g. "behavior matches docs/architecture.md") is ignored.

Exit 0: every asserted path was touched in the diff.
Exit 1: at least one asserted path was not touched; unverified paths are
        printed one per line on stdout.
Exit 2: usage error or the diff could not be computed.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 2
fi

BASE_REF=$1
CLAIM_TEXT=$(cat)

DIFF_FILES=$(git diff --name-only "${BASE_REF}...HEAD" 2>/dev/null) \
  || { echo "error: cannot diff HEAD against '$BASE_REF'" >&2; exit 2; }

CLAIMED_PATHS=$(
  printf '%s\n' "$CLAIM_TEXT" \
    | sed -E 's/[;,]/\n/g; s/\.[[:space:]]+/.\n/g' \
    | grep -iE "(^|[^A-Za-z])($CHANGE_VERBS)([^A-Za-z]|$)" \
    | grep -oE '[A-Za-z0-9_./-]+/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' \
    | sort -u
)

if [ -z "$CLAIMED_PATHS" ]; then
  exit 0
fi

UNVERIFIED=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if ! printf '%s\n' "$DIFF_FILES" | grep -qxF "$path"; then
    UNVERIFIED="$UNVERIFIED$path
"
  fi
done <<<"$CLAIMED_PATHS"

if [ -n "$UNVERIFIED" ]; then
  printf '%s' "$UNVERIFIED"
  exit 1
fi

exit 0
