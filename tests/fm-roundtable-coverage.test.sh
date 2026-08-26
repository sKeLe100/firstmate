#!/usr/bin/env bash
# Behavior tests for bin/fm-roundtable-coverage.sh: a roundtable report must
# disclose exactly what it saw, so this must count reads and unread dirs
# against the same tracked-file walk fm-roundtable-factsheet.sh used.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-roundtable-coverage)
fm_git_identity fmtest fmtest@example.invalid

make_fixture() {
  local dir
  dir=$(mktemp -d "$TMP_ROOT/fixture-XXXXXX")
  rmdir "$dir"
  git init -q -b main "$dir"
  mkdir -p "$dir/src" "$dir/tests" "$dir/docs"
  printf 'print(1)\n' > "$dir/src/main.py"
  printf 'print(2)\n' > "$dir/src/other.py"
  printf 'def test_x(): pass\n' > "$dir/tests/test_main.py"
  printf '# doc\n' > "$dir/docs/guide.md"
  printf '# Fixture\n' > "$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
  printf '%s\n' "$dir"
}

test_unmatched_args_are_reported() {
  local dir out
  dir=$(make_fixture)
  out="$TMP_ROOT/unmatched-out.txt"
  "$ROOT/bin/fm-roundtable-coverage.sh" "$dir" src/main.py "$dir/src/other.py" nope.py > "$out"

  assert_grep "read 1 of 5 files" "$out" "only the clone-relative tracked path counts as read"
  assert_grep "unmatched read args" "$out" \
    "arguments that match no tracked file must be reported, not silently dropped"
  assert_grep "nope.py" "$out" "the misspelled argument must be named"
  assert_grep "$dir/src/other.py" "$out" "the absolute-path argument must be named"

  pass "fm-roundtable-coverage: unmatched read arguments are disclosed"
}

test_non_ascii_paths() {
  local dir out
  dir=$(mktemp -d "$TMP_ROOT/utf8-XXXXXX")
  rmdir "$dir"
  git init -q -b main "$dir"
  mkdir -p "$dir/café"
  printf 'x = 1\n' > "$dir/café/é.py"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init

  out="$TMP_ROOT/utf8-out.txt"
  "$ROOT/bin/fm-roundtable-coverage.sh" "$dir" 'café/é.py' > "$out"

  assert_grep "read 1 of 1 files, unread dirs: none" "$out" \
    "a non-ASCII path the reviewer read must count as read, not as a quoted mismatch"
  assert_no_grep '\\303' "$out" "paths must not be reported in git's C-quoted form"

  pass "fm-roundtable-coverage: non-ASCII tracked paths are matched byte-accurately"
}

test_large_tree_is_bounded() {
  local dir i start elapsed
  dir=$(mktemp -d "$TMP_ROOT/big-XXXXXX")
  rmdir "$dir"
  git init -q -b main "$dir"
  mkdir -p "$dir/a/b/c"
  for i in $(seq 1 2000); do printf 'x\n' > "$dir/a/b/c/f$i.py"; done
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init

  start=$SECONDS
  FM_ROUNDTABLE_MARKS_FILE="$TMP_ROOT/big-marks.tsv" \
    "$ROOT/bin/fm-roundtable-factsheet.sh" "$dir" > "$TMP_ROOT/big-out.txt"
  elapsed=$((SECONDS - start))
  [ "$elapsed" -lt 20 ] ||
    fail "factsheet on a 2000-file clone must stay bounded in seconds, took ${elapsed}s"
  assert_grep "a/b " "$TMP_ROOT/big-out.txt" "the collapsed dir row must still be emitted"

  pass "fm-roundtable-factsheet: tree walk stays bounded on a large clone (${elapsed}s)"
}

test_partial_coverage() {
  local dir out out_file unread entry
  dir=$(make_fixture)
  out=$("$ROOT/bin/fm-roundtable-coverage.sh" "$dir" src/main.py README.md)
  out_file="$TMP_ROOT/partial-out.txt"
  printf '%s\n' "$out" > "$out_file"

  assert_grep "read 2 of 5 files, unread dirs:" "$out_file" \
    "must count exactly the read files against the total tracked-file count"
  case "$out" in
    *tests*) : ;;
    *) fail "tests dir has no read files and must be listed unread: $out" ;;
  esac
  case "$out" in
    *docs*) : ;;
    *) fail "docs dir has no read files and must be listed unread: $out" ;;
  esac
  unread=${out#*unread dirs: }
  for entry in $(printf '%s' "$unread" | tr ',' ' '); do
    [ "$entry" = "." ] && fail "root dir has a read file (README.md) and must not be listed unread: $out"
  done

  pass "fm-roundtable-coverage: partial coverage names unread dirs correctly"
}

test_full_coverage() {
  local dir out
  dir=$(make_fixture)
  out="$TMP_ROOT/full-out.txt"
  "$ROOT/bin/fm-roundtable-coverage.sh" "$dir" \
    src/main.py src/other.py tests/test_main.py docs/guide.md README.md > "$out"

  assert_grep "read 5 of 5 files, unread dirs: none" "$out" \
    "reading every tracked file must report zero unread dirs"

  pass "fm-roundtable-coverage: full coverage reports no unread dirs"
}

# Regression: the ledger's unread dir names must be dirs the fact sheet's own
# tree walk could have printed at the same MAX_DEPTH (deeply nested fixture).
test_deep_dirs_match_factsheet_tree() {
  local dir cov unread entry tree
  dir=$(mktemp -d "$TMP_ROOT/deep-XXXXXX")
  rmdir "$dir"
  git init -q -b main "$dir"
  mkdir -p "$dir/a/b/c" "$dir/x/y"
  printf 'y = 1\n' > "$dir/a/b/c/f.py"
  printf 'y = 2\n' > "$dir/x/y/g.py"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init

  tree="$TMP_ROOT/deep-tree.txt"
  FM_ROUNDTABLE_MARKS_FILE="$TMP_ROOT/deep-marks.tsv" \
    "$ROOT/bin/fm-roundtable-factsheet.sh" "$dir" |
    awk '/^## File tree/ { intree = 1; next } intree && NF == 0 { intree = 0 } intree { print $1 }' > "$tree"
  cov=$("$ROOT/bin/fm-roundtable-coverage.sh" "$dir")
  unread=${cov#*unread dirs: }
  [ "$unread" != none ] || fail "fixture must have unread dirs to check the invariant: $cov"
  for entry in $(printf '%s' "$unread" | tr ',' ' '); do
    grep -qxF -- "$entry" "$tree" ||
      fail "coverage named unread dir '$entry' which the factsheet tree never prints: $cov"
  done

  pass "fm-roundtable-coverage: unread dirs match the factsheet tree at nested depth"
}

# Regression: an empty HEAD tree has no dirs at all, so the ledger must not
# invent a "." unread dir from the trailing newline of its input.
test_empty_tree_names_no_unread_dirs() {
  local dir out
  dir=$(mktemp -d "$TMP_ROOT/empty-XXXXXX")
  rmdir "$dir"
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  out="$TMP_ROOT/empty-out.txt"
  "$ROOT/bin/fm-roundtable-coverage.sh" "$dir" foo.py > "$out"

  assert_grep "read 0 of 0 files, unread dirs: none" "$out" \
    "an empty tracked tree must report no unread dirs, not a phantom '.'"

  pass "fm-roundtable-coverage: empty HEAD tree names no unread dirs"
}

# Regression: distinct tracked paths that a locale collation would fold
# together must stay distinct in the read/unmatched bookkeeping.
test_punctuation_paths_are_not_collapsed() {
  local dir out
  dir=$(mktemp -d "$TMP_ROOT/punct-XXXXXX")
  rmdir "$dir"
  git init -q -b main "$dir"
  mkdir -p "$dir/src"
  printf 'a = 1\n' > "$dir/src/a-b.py"
  printf 'a = 2\n' > "$dir/src/ab.py"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init

  local loc
  loc=$(locale -a 2>/dev/null | grep -iE '\.(utf-?8)$' | grep -viE '^(C|POSIX)' | head -1)
  out="$TMP_ROOT/punct-out.txt"
  LC_ALL="${loc:-C}" "$ROOT/bin/fm-roundtable-coverage.sh" "$dir" src/ab.py > "$out"

  assert_grep "read 1 of 2 files" "$out" \
    "a tracked path must count as read even when a locale collation would fold it with a sibling"
  grep -q "unmatched read args" "$out" &&
    fail "a tracked path must not also be reported as unmatched: $(cat "$out")"

  pass "fm-roundtable-coverage: punctuation-differing paths are not collapsed"
}

# Regression: the ", " list separator must not be confused with a comma that
# is part of a directory name.
test_comma_in_dirname_is_one_entry() {
  local dir out
  dir=$(mktemp -d "$TMP_ROOT/comma-XXXXXX")
  rmdir "$dir"
  git init -q -b main "$dir"
  mkdir -p "$dir/a,b"
  printf 'f = 1\n' > "$dir/a,b/f.py"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init

  out="$TMP_ROOT/comma-out.txt"
  "$ROOT/bin/fm-roundtable-coverage.sh" "$dir" > "$out"

  assert_grep "unread dirs: a,b" "$out" \
    "a directory named 'a,b' must be named as it is"
  assert_no_grep "unread dirs: a, b" "$out" \
    "a directory named 'a,b' must be one unread entry, not two"

  pass "fm-roundtable-coverage: a comma inside a dir name is not a list separator"
}

test_partial_coverage
test_full_coverage
test_empty_tree_names_no_unread_dirs
test_deep_dirs_match_factsheet_tree
test_unmatched_args_are_reported
test_non_ascii_paths
test_large_tree_is_bounded
test_punctuation_paths_are_not_collapsed
test_comma_in_dirname_is_one_entry
