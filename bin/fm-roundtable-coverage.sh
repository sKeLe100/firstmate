#!/usr/bin/env bash
# bin/fm-roundtable-coverage.sh - coverage ledger for a roundtable review.
#
# Given the list of files a reviewer actually read for a project, reports how
# much of the project's tracked tree that covers, walked with the same
# fm_roundtable_dir_tree logic fm-roundtable-factsheet.sh used, so the ledger
# a roundtable report ends with always matches the fact sheet it started from.
#
# Usage: fm-roundtable-coverage.sh <project-clone-path> <file>...
#   Each <file> is a path relative to the clone root (as it would appear in
#   `git ls-tree --name-only`, e.g. "src/foo.py", not an absolute path).

set -euo pipefail

FM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=bin/fm-roundtable-lib.sh
. "$FM_ROOT/bin/fm-roundtable-lib.sh"

MAX_DEPTH=$FM_ROUNDTABLE_MAX_DEPTH

usage() {
  echo "Usage: $(basename "$0") <project-clone-path> <file>..." >&2
  exit 1
}

[ $# -ge 1 ] || usage
CLONE=$1
shift
git -C "$CLONE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: not a git clone: $CLONE" >&2; exit 1; }
CLONE=$(cd "$CLONE" && pwd)

ALL_FILES=$(fm_roundtable_files "$CLONE")
TOTAL=$(printf '%s\n' "$ALL_FILES" | grep -c . || true)

READ_LIST_FILE=$(mktemp)
trap 'rm -f "$READ_LIST_FILE"' EXIT
printf '%s\n' "$@" | sort -u > "$READ_LIST_FILE"

READ_N=0
if [ $# -gt 0 ]; then
  READ_N=$(comm -12 <(printf '%s\n' "$ALL_FILES" | sort -u) "$READ_LIST_FILE" | grep -c . || true)
fi

# Directories with zero read files among their tracked files, walked at the
# same bounded depth as the fact sheet. One awk pass over all tracked files
# (not an O(dirs*files) shell loop) so this stays fast on large clones.
UNREAD_DIRS=$(
  awk -v maxd="$MAX_DEPTH" -F'\t' \
    "$FM_ROUNDTABLE_COLLAPSE_AWK"'
    NR == FNR { read[$0] = 1; next }
    $0 == "" { next }
    {
      rel = $0
      dir = fm_collapse_dir(rel, maxd)
      total[dir] = 1
      if (rel in read) readcount[dir] = 1
    }
    END { for (d in total) if (!(d in readcount)) print d }
  ' "$READ_LIST_FILE" - <<<"$ALL_FILES" | sort | fm_roundtable_join_list
)
[ -z "$UNREAD_DIRS" ] && UNREAD_DIRS="none"

UNMATCHED=$(comm -13 <(printf '%s\n' "$ALL_FILES" | sort -u) "$READ_LIST_FILE" | grep . | fm_roundtable_join_list || true)

echo "read $READ_N of $TOTAL files, unread dirs: $UNREAD_DIRS"
[ -n "$UNMATCHED" ] && echo "unmatched read args (not tracked at HEAD, expected clone-relative paths): $UNMATCHED"
exit 0
