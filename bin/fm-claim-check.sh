#!/usr/bin/env bash
# Post-green verification gate: check that the file paths named in a claim
# text exist as git facts, catching a "done" summary that names a file the
# branch never produced.
# Usage: fm-claim-check.sh <base-ref>
# Reads the claim text from stdin.
# Every path-shaped token (containing a "/" and a file extension) is
# classified against git alone, never against the surrounding prose:
#   - touched in `git diff --name-only <base-ref>...HEAD`  -> verified
#   - untouched but tracked at HEAD                        -> cited reference
#   - neither                                              -> unverified
# Deliberate limitation: a path that is tracked but untouched passes, because
# a done summary legitimately cites unchanged files (docs, contracts, prior
# art) and no mechanical rule separates "I changed X" from "matches X" in
# prose. This gate catches the claim that names a file which does not exist
# in the branch at all; it does not judge what the prose asserts about an
# existing file. Do not reintroduce verb or phrasing heuristics to close that
# gap - they are unbounded in English and were removed for that reason.
# Exit 0: every claimed path is a git fact (or the claim names no paths).
# Exit 1: at least one claimed path exists neither in the diff nor at HEAD.
# Exit 2: usage or git error.
set -u

usage() {
  cat <<'EOF'
Usage: fm-claim-check.sh <base-ref>

Verifies the file paths named in a claim text against git facts. Reads the
claim text from stdin and compares each path-shaped token against the diff
of HEAD versus <base-ref> and against the files tracked at HEAD.

A path that was touched in the diff, or that is tracked at HEAD, passes; a
path that is neither is reported as unverified. Paths are classified from
git alone, so a summary may cite unchanged files freely. The gate therefore
catches a claim naming a file the branch never produced, not a mis-stated
claim about an existing file.

Exit 0: every claimed path is a git fact, or the claim names no paths.
Exit 1: at least one claimed path is unverified; those paths are printed one
        per line on stdout.
Exit 2: usage error, or the diff could not be computed.
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

TRACKED_FILES=$(git ls-tree -r --name-only HEAD 2>/dev/null) \
  || { echo "error: cannot list files tracked at HEAD" >&2; exit 2; }

KNOWN_FILES=$(printf '%s\n%s\n' "$DIFF_FILES" "$TRACKED_FILES")

# A claimed path may be written "./bin/x.sh" or wrapped in backticks, quotes,
# or trailing punctuation; normalize both away before matching git's paths.
CLAIMED_PATHS=$(printf '%s\n' "$CLAIM_TEXT" \
  | grep -oE '[A-Za-z0-9_./-]+/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' \
  | sed 's|^\./||' | sort -u)

if [ -z "$CLAIMED_PATHS" ]; then
  exit 0
fi

UNVERIFIED=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if ! printf '%s\n' "$KNOWN_FILES" | grep -qxF "$path"; then
    UNVERIFIED="$UNVERIFIED$path
"
  fi
done <<EOF
$CLAIMED_PATHS
EOF

if [ -n "$UNVERIFIED" ]; then
  printf '%s' "$UNVERIFIED"
  exit 1
fi

exit 0
