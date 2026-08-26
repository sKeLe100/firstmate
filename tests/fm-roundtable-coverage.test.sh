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
    "$ROOT/bin/fm-roundtable-factsheet.sh" "$dir" | awk '{print $1}' > "$tree"
  cov=$("$ROOT/bin/fm-roundtable-coverage.sh" "$dir")
  unread=${cov#*unread dirs: }
  for entry in $(printf '%s' "$unread" | tr ',' ' '); do
    grep -qx -- "$entry" "$tree" ||
      fail "coverage named unread dir '$entry' which the factsheet tree never prints: $cov"
  done

  pass "fm-roundtable-coverage: unread dirs match the factsheet tree at nested depth"
}

test_partial_coverage
test_full_coverage
test_deep_dirs_match_factsheet_tree
