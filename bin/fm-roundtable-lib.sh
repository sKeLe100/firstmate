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

# Byte-wise collation everywhere: sort/comm must agree with each other and
# with git's byte-ordered output, and the fact sheet must render identically
# on any machine regardless of the caller's locale.
export LC_ALL=C


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

# Single source of the bounded tree depth both scripts walk at. The
# cross-script invariant only holds while they apply the collapse rule with
# the same cap, so neither may declare its own.
FM_ROUNDTABLE_MAX_DEPTH=2

# Single source of the depth-collapse rule, as an awk function both this
# library and bin/fm-roundtable-coverage.sh prepend to their own awk program.
# Neither may reimplement it: every dir the coverage ledger names must be a dir
# the fact sheet could have printed.
FM_ROUNDTABLE_COLLAPSE_AWK='
function fm_collapse_dir(rel, maxd,   n, parts, depth, dir, i) {
  n = split(rel, parts, "/")
  depth = n - 1
  if (depth > maxd) depth = maxd
  dir = (depth < 1) ? "." : parts[1]
  for (i = 2; i <= depth; i++) dir = dir "/" parts[i]
  return dir
}
'

# Prints "dir<TAB>file_count<TAB>total_bytes" for every directory up to
# max_depth (0 = root only, files bucketed by their collapsed ancestor dir).
fm_roundtable_dir_tree() {
  local clone=$1 max_depth=$2
  fm_roundtable_file_sizes "$clone" | awk -F'\t' -v maxd="$max_depth" \
    "$FM_ROUNDTABLE_COLLAPSE_AWK"'
    $1 == "" { next }
    {
      dir = fm_collapse_dir($1, maxd)
      c[dir]++
      s[dir] += $2 + 0
    }
    END { for (d in c) printf "%s\t%d\t%d\n", d, c[d], s[d] }
  ' | sort
}

# Joins stdin lines into one ", "-separated line. The separator is written
# directly, never substituted, so a comma inside a path is not mistaken for
# one.
fm_roundtable_join_list() {
  awk 'NR > 1 { printf ", " } { printf "%s", $0 } END { if (NR > 0) print "" }'
}
