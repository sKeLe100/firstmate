#!/usr/bin/env bash
# Post-green verification gate: grep-verify that a claim text's referenced
# file paths were actually touched in this branch's diff, catching a "done"
# summary that names files never committed.
# Usage: fm-claim-check.sh <base-ref> [claim-file]
# Reads the claim text from <claim-file>, or stdin when omitted.
# Extracts path-shaped tokens (containing a "/" and a file extension) from
# the claim text and fails, listing each one, if any is absent from
# `git diff --name-only <base-ref>...HEAD`.
# Exit 0: every claimed path was touched (or no path-shaped tokens found).
# Exit 1: at least one claimed path was not touched in the diff.
# Exit 2: usage or git error.
set -u

usage() {
  cat <<'EOF'
Usage: fm-claim-check.sh <base-ref> [claim-file]

Grep-verifies a claim text's referenced file paths against the diff of
HEAD against <base-ref>. Reads the claim text from <claim-file>, or from
stdin when <claim-file> is omitted or "-".

Exit 0: every path-shaped token in the claim text was touched in the diff.
Exit 1: at least one claimed path was not touched; unverified paths are
        printed one per line on stdout.
Exit 2: usage error or the diff could not be computed.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage >&2
  exit 2
fi

BASE_REF=$1
CLAIM_FILE=${2:--}

if [ "$CLAIM_FILE" = "-" ]; then
  CLAIM_TEXT=$(cat)
else
  CLAIM_TEXT=$(cat -- "$CLAIM_FILE") || { echo "error: cannot read claim file '$CLAIM_FILE'" >&2; exit 2; }
fi

DIFF_FILES=$(git diff --name-only "${BASE_REF}...HEAD" 2>/dev/null) \
  || { echo "error: cannot diff HEAD against '$BASE_REF'" >&2; exit 2; }

CLAIMED_PATHS=$(printf '%s\n' "$CLAIM_TEXT" | grep -oE '[A-Za-z0-9_./-]+/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' | sort -u)

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
done <<EOF
$CLAIMED_PATHS
EOF

if [ -n "$UNVERIFIED" ]; then
  printf '%s' "$UNVERIFIED"
  exit 1
fi

exit 0
