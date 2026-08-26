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
  git -C "$clone" -c core.quotePath=false ls-tree -r --name-only HEAD
}

# Prints "path<TAB>size_bytes" for every HEAD-tracked file in the clone.
fm_roundtable_file_sizes() {
  local clone=$1
  git -C "$clone" -c core.quotePath=false ls-tree -r -l HEAD |
    awk -F'\t' '{ split($1, meta, " "); printf "%s\t%s\n", $2, meta[4] }'
}

# True (exit 0) when $1 looks like a test file by common naming convention.
# Anchored on the basename (test_x, x_test.y, x.test.y, x.spec.y) or a
# tests/ or spec/ path component, never a bare substring of the path.
fm_roundtable_is_test_file() {
  local rel=$1 base=${1##*/}
  case "$rel" in
    tests/*|test/*|spec/*|specs/*|*/tests/*|*/test/*|*/spec/*|*/specs/*) return 0 ;;
  esac
  case "$base" in
    test_*|test-*|spec_*|spec-*) return 0 ;;
    *_test|*_test.*|*-test.*|*.test.*|*_spec|*_spec.*|*-spec.*|*.spec.*) return 0 ;;
    *Test.*|*Tests.*|*Spec.*) return 0 ;;
    *) return 1 ;;
  esac
}

# Collapses a relative dir path to at most max_depth segments. Must stay in
# exact agreement with the depth cap in bin/fm-roundtable-coverage.sh so every
# dir the coverage ledger names is a dir the fact sheet could have printed.
fm_roundtable_collapse_dir() {
  local dir=$1 max_depth=$2
  { [ -z "$dir" ] || [ "$max_depth" -lt 1 ]; } && { printf '.\n'; return; }
  printf '%s\n' "$dir" | cut -d/ -f"1-$max_depth"
}

# Prints "dir<TAB>file_count<TAB>total_bytes" for every directory up to
# max_depth (0 = root only, files bucketed by their collapsed ancestor dir).
fm_roundtable_dir_tree() {
  local clone=$1 max_depth=$2
  fm_roundtable_file_sizes "$clone" | awk -F'\t' -v maxd="$max_depth" '
    {
      n = split($1, parts, "/")
      depth = n - 1
      if (depth > maxd) depth = maxd
      dir = (depth < 1) ? "." : parts[1]
      for (i = 2; i <= depth; i++) dir = dir "/" parts[i]
      c[dir]++
      s[dir] += $2 + 0
    }
    END { for (d in c) printf "%s\t%d\t%d\n", d, c[d], s[d] }
  ' | sort
}
