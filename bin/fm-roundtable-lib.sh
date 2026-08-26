#!/usr/bin/env bash
# bin/fm-roundtable-lib.sh - shared file-tree walk for the roundtable
# instrumentation scripts.
#
# fm-roundtable-factsheet.sh and fm-roundtable-coverage.sh must walk the same
# tracked-file tree so a coverage ledger's "N of M files" always matches what
# the fact sheet just described. Both source this file rather than each
# reimplementing the walk.
#
# Every function reads from the git object database at HEAD (via ls-tree),
# never the working tree, so results are deterministic and read-only
# regardless of a dirty checkout.

set -u

# Prints every HEAD-tracked file path in the clone, one per line, relative to
# the clone root.
fm_roundtable_files() {
  local clone=$1
  git -C "$clone" ls-tree -r --name-only HEAD
}

# Prints "path<TAB>size_bytes" for every HEAD-tracked file in the clone.
fm_roundtable_file_sizes() {
  local clone=$1
  git -C "$clone" ls-tree -r -l HEAD | while read -r _mode _type _sha size path; do
    printf '%s\t%s\n' "$path" "$size"
  done
}

# True (exit 0) when $1 looks like a test file by common naming convention.
fm_roundtable_is_test_file() {
  case "$1" in
    *test*|*spec*) return 0 ;;
    *) return 1 ;;
  esac
}

# Collapses a relative dir path to at most max_depth segments.
fm_roundtable_collapse_dir() {
  local dir=$1 max_depth=$2
  [ -z "$dir" ] && { printf '.\n'; return; }
  printf '%s\n' "$dir" | cut -d/ -f"1-$((max_depth + 1))"
}

# Prints "dir<TAB>file_count<TAB>total_bytes" for every directory up to
# max_depth (0 = root only, files bucketed by their collapsed ancestor dir).
fm_roundtable_dir_tree() {
  local clone=$1 max_depth=$2
  fm_roundtable_file_sizes "$clone" | while IFS=$'\t' read -r rel size; do
    local dir
    dir=$(dirname -- "$rel")
    [ "$dir" = "." ] && dir=""
    dir=$(fm_roundtable_collapse_dir "$dir" "$max_depth")
    printf '%s\t%s\n' "$dir" "${size:-0}"
  done | awk -F'\t' '{c[$1]++; s[$1]+=$2} END {for (d in c) printf "%s\t%d\t%d\n", d, c[d], s[d]}' | sort
}
