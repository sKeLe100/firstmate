#!/usr/bin/env bash
# bin/fm-roundtable-factsheet.sh - deterministic, read-only, bounded project
# snapshot for a design-review roundtable.
#
# Why: a roundtable that only reads README/ROADMAP heads and bounded excerpts
# has no disclosed picture of what it saw. This generates a fresh factsheet
# from the project's own HEAD every run, never a hand-maintained document that
# can rot, so the reviewer starts from current reality and its coverage can be
# checked against the same tree walk (fm-roundtable-coverage.sh).
#
# Usage: fm-roundtable-factsheet.sh <project-clone-path> [--since <ref-or-tag>] [--mark]
#   --since <ref>  add a delta section (files changed, commits, ROADMAP diff
#                  stat) between <ref> and HEAD. Defaults to this project's
#                  last recorded roundtable mark, if one exists.
#   --mark         after printing, record this run's HEAD as the mark this
#                  project was reviewed at (data/roundtable-marks.tsv).
#
# Never prints README.md/ROADMAP.md contents - only their paths and line
# counts. The reviewer reads the content itself; this discloses what exists.
# No network access; reads only the local git object database at HEAD.

set -euo pipefail

FM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=bin/fm-roundtable-lib.sh
. "$FM_ROOT/bin/fm-roundtable-lib.sh"

MARKS_FILE="${FM_ROUNDTABLE_MARKS_FILE:-$FM_ROOT/data/roundtable-marks.tsv}"
MAX_DEPTH=2

usage() {
  echo "Usage: $(basename "$0") <project-clone-path> [--since <ref-or-tag>] [--mark]" >&2
  exit 1
}

CLONE=""
SINCE=""
DO_MARK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE=${2:?--since requires a ref}; shift 2 ;;
    --mark) DO_MARK=1; shift ;;
    -h|--help) usage ;;
    *) [ -z "$CLONE" ] || usage; CLONE=$1; shift ;;
  esac
done
[ -n "$CLONE" ] || usage
git -C "$CLONE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: not a git clone: $CLONE" >&2; exit 1; }

CLONE=$(cd "$CLONE" && pwd)
PROJECT=$(basename "$CLONE")
HEAD_SHA=$(git -C "$CLONE" rev-parse HEAD)
HEAD_DATE=$(git -C "$CLONE" log -1 --format=%cd --date=short HEAD)

echo "# Roundtable factsheet: $PROJECT"
echo "HEAD: $HEAD_SHA"
echo "Commit date: $HEAD_DATE"
echo

echo "## File tree (depth <= $MAX_DEPTH, files/bytes per dir)"
fm_roundtable_dir_tree "$CLONE" "$MAX_DEPTH" | while IFS=$'\t' read -r dir count size; do
  printf '%-40s %5s files  %8s bytes\n' "$dir" "$count" "$size"
done
echo

CODE_N=0
TEST_N=0
while IFS= read -r rel; do
  if fm_roundtable_is_test_file "$rel"; then
    TEST_N=$((TEST_N + 1))
  else
    CODE_N=$((CODE_N + 1))
  fi
done < <(fm_roundtable_files "$CLONE")
echo "## Code vs test files"
echo "code: $CODE_N"
echo "test: $TEST_N"
echo

echo "## Last 15 commits"
git -C "$CLONE" log -15 --oneline
echo

echo "## Key docs (paths + line counts only, not contents)"
for doc in README.md ROADMAP.md; do
  path=$(fm_roundtable_files "$CLONE" | grep -m1 -E "(^|/)$doc\$" || true)
  if [ -n "$path" ]; then
    lines=$(git -C "$CLONE" show "HEAD:$path" | wc -l)
    printf '%s: %s lines\n' "$path" "$lines"
  else
    printf '%s: absent\n' "$doc"
  fi
done
echo

if [ -z "$SINCE" ] && [ -f "$MARKS_FILE" ]; then
  SINCE=$(awk -F'\t' -v p="$PROJECT" '$1 == p {print $2}' "$MARKS_FILE" | tail -1)
fi

if [ -n "$SINCE" ]; then
  if git -C "$CLONE" rev-parse --verify -q "$SINCE^{commit}" >/dev/null; then
    echo "## Delta since $SINCE"
    echo "Files changed:"
    git -C "$CLONE" diff --name-only "$SINCE" HEAD | sed 's/^/  /'
    echo "Commits since:"
    git -C "$CLONE" log --oneline "$SINCE..HEAD"
    echo "ROADMAP.md diff stat:"
    git -C "$CLONE" diff --stat "$SINCE" HEAD -- ROADMAP.md || true
  else
    echo "## Delta since $SINCE"
    echo "error: ref not found in this clone, skipping delta"
  fi
  echo
fi

if [ "$DO_MARK" -eq 1 ]; then
  mkdir -p "$(dirname "$MARKS_FILE")"
  TMP=$(mktemp "${MARKS_FILE}.XXXXXX")
  if [ -f "$MARKS_FILE" ]; then
    awk -F'\t' -v p="$PROJECT" '$1 != p' "$MARKS_FILE" > "$TMP"
  else
    : > "$TMP"
  fi
  printf '%s\t%s\t%s\n' "$PROJECT" "$HEAD_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$TMP"
  mv "$TMP" "$MARKS_FILE"
  echo "## Mark recorded: $PROJECT @ $HEAD_SHA"
fi
