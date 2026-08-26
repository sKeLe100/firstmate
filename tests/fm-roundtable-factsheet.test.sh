#!/usr/bin/env bash
# Behavior tests for bin/fm-roundtable-factsheet.sh: the roundtable needs a
# fresh, generated picture of each project (never a hand-maintained one), and
# it must never print README/ROADMAP contents - only paths and line counts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-roundtable-factsheet)
fm_git_identity fmtest fmtest@example.invalid

# Builds a two-commit fixture repo with code, a test file, and docs. Echoes
# its path and, on stdout fd 3, the first commit's sha (for --since tests).
make_fixture() {
  local dir
  dir=$(mktemp -d "$TMP_ROOT/fixture-XXXXXX")
  rmdir "$dir"
  git init -q -b main "$dir"
  mkdir -p "$dir/src" "$dir/tests"
  printf 'print(1)\n' > "$dir/src/main.py"
  printf 'def test_x(): pass\n' > "$dir/tests/test_main.py"
  printf '# Fixture\n' > "$dir/README.md"
  printf '# Roadmap\n- item1\n- item2\n' > "$dir/ROADMAP.md"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
  printf 'print(2)\n' > "$dir/src/other.py"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "add other"
  printf '%s\n' "$dir"
}

test_basic_output() {
  local dir out
  dir=$(make_fixture)
  out="$TMP_ROOT/basic-out.txt"
  "$ROOT/bin/fm-roundtable-factsheet.sh" "$dir" > "$out"

  assert_grep "# Roundtable factsheet: $(basename "$dir")" "$out" \
    "must name the project from the clone dir"
  assert_grep "HEAD: $(git -C "$dir" rev-parse HEAD)" "$out" \
    "must report the exact HEAD sha"
  assert_grep "code: 4" "$out" "must count non-test tracked files as code"
  assert_grep "test: 1" "$out" "must count the test file separately"
  assert_grep "README.md: 1 lines" "$out" \
    "must report README.md's line count, not its contents"
  assert_grep "ROADMAP.md: 3 lines" "$out" \
    "must report ROADMAP.md's line count, not its contents"
  assert_no_grep "item1" "$out" \
    "must never print ROADMAP.md contents, only path and line count"
  assert_grep "add other" "$out" "must list recent commits oneline"

  pass "fm-roundtable-factsheet: basic project snapshot is accurate and content-free"
}

test_since_delta() {
  local dir out first_sha
  dir=$(make_fixture)
  first_sha=$(git -C "$dir" log --format=%H | tail -1)
  out="$TMP_ROOT/since-out.txt"
  "$ROOT/bin/fm-roundtable-factsheet.sh" "$dir" --since "$first_sha" > "$out"

  assert_grep "## Delta since $first_sha" "$out" "must label the delta section by ref"
  assert_grep "  src/other.py" "$out" "must list the file added since the ref"

  pass "fm-roundtable-factsheet: --since reports an accurate delta"
}

test_mark_round_trip() {
  local dir head_sha out
  dir=$(make_fixture)
  "$ROOT/bin/fm-roundtable-factsheet.sh" "$dir" --mark >/dev/null
  head_sha=$(git -C "$dir" rev-parse HEAD)
  assert_grep "$(basename "$dir")	$head_sha	" "$FM_ROUNDTABLE_MARKS_FILE" \
    "--mark must record this project's reviewed HEAD"

  git -C "$dir" commit -q --allow-empty -m "later commit"
  out="$TMP_ROOT/mark-out.txt"
  "$ROOT/bin/fm-roundtable-factsheet.sh" "$dir" > "$out"
  assert_grep "## Delta since $head_sha" "$out" \
    "with no --since, must default to the last recorded mark for this project"

  pass "fm-roundtable-factsheet: --mark records HEAD and becomes the default --since"
}

# Redirect the marks file into the temp root so this test never touches the
# real firstmate data/roundtable-marks.tsv.
export FM_ROUNDTABLE_MARKS_FILE="$TMP_ROOT/roundtable-marks.tsv"

# Fixture with a nested README/ROADMAP that sorts before the root ones and
# code files whose paths merely contain "test"/"spec" as a substring.
make_tricky_fixture() {
  local dir
  dir=$(mktemp -d "$TMP_ROOT/tricky-XXXXXX")
  rmdir "$dir"
  git init -q -b main "$dir"
  mkdir -p "$dir/AGENTS" "$dir/src/protest" "$dir/a/b/c"
  printf 'nested\nreadme\n' > "$dir/AGENTS/README.md"
  printf 'nested\nroadmap\n' > "$dir/AGENTS/ROADMAP.md"
  printf '# Fixture\n' > "$dir/README.md"
  printf '# Roadmap\n- item1\n- item2\n' > "$dir/ROADMAP.md"
  printf 'x = 1\n' > "$dir/src/latest.py"
  printf 'x = 2\n' > "$dir/src/protest/x.py"
  printf 'def test_x(): pass\n' > "$dir/src/test_real.py"
  printf 'y = 1\n' > "$dir/a/b/c/f.py"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
  printf '%s\n' "$dir"
}

test_root_docs_preferred() {
  local dir out
  dir=$(make_tricky_fixture)
  out="$TMP_ROOT/tricky-docs.txt"
  "$ROOT/bin/fm-roundtable-factsheet.sh" "$dir" > "$out"

  assert_grep "README.md: 1 lines" "$out" \
    "must report the root README.md, not a nested one that sorts earlier"
  assert_grep "ROADMAP.md: 3 lines" "$out" \
    "must report the root ROADMAP.md, not a nested one that sorts earlier"
  assert_no_grep "AGENTS/README.md: 2 lines" "$out" \
    "must not present a nested README as the project README"

  pass "fm-roundtable-factsheet: prefers root-level key docs"
}

test_test_classification_is_anchored() {
  local dir out
  dir=$(make_tricky_fixture)
  out="$TMP_ROOT/tricky-classify.txt"
  "$ROOT/bin/fm-roundtable-factsheet.sh" "$dir" > "$out"

  assert_grep "test: 1" "$out" \
    "only src/test_real.py is a test file; latest.py and protest/x.py are not"
  assert_grep "code: 7" "$out" \
    "every other tracked file must be counted as code"

  pass "fm-roundtable-factsheet: test detection is anchored, not a substring match"
}

test_absent_docs_do_not_abort() {
  local dir out status
  dir=$(mktemp -d "$TMP_ROOT/nodocs-XXXXXX")
  rmdir "$dir"
  git init -q -b main "$dir"
  printf 'a = 1\n' > "$dir/a.py"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init

  out="$TMP_ROOT/nodocs-out.txt"
  status=0
  "$ROOT/bin/fm-roundtable-factsheet.sh" "$dir" --mark > "$out" 2>&1 || status=$?
  [ "$status" -eq 0 ] || fail "a project with no README/ROADMAP must not abort the fact sheet (exit $status)"

  assert_grep "README.md: absent" "$out" "must report a missing README as absent"
  assert_grep "ROADMAP.md: absent" "$out" "must report a missing ROADMAP as absent"
  assert_grep "## Mark recorded: $(basename "$dir")" "$out" \
    "the run must continue past the key-docs section and still record the mark"

  pass "fm-roundtable-factsheet: missing key docs are an absent case, not an abort"
}

test_doc_name_match_is_literal() {
  local dir out
  dir=$(mktemp -d "$TMP_ROOT/dotdoc-XXXXXX")
  rmdir "$dir"
  git init -q -b main "$dir"
  printf 'not a readme\n' > "$dir/READMEXmd"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init

  out="$TMP_ROOT/dotdoc-out.txt"
  "$ROOT/bin/fm-roundtable-factsheet.sh" "$dir" > "$out"

  assert_grep "README.md: absent" "$out" \
    "a file named READMEXmd must not be reported as the project README"

  pass "fm-roundtable-factsheet: key-doc names match literally, not as regexes"
}

test_delta_paths_are_not_quoted() {
  local dir out
  dir=$(mktemp -d "$TMP_ROOT/nonascii-XXXXXX")
  rmdir "$dir"
  git init -q -b main "$dir"
  printf 'a = 1
' > "$dir/a.py"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
  mkdir -p "$dir/café"
  printf 'b = 2
' > "$dir/café/é.py"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m add-nonascii

  out="$TMP_ROOT/nonascii-out.txt"
  "$ROOT/bin/fm-roundtable-factsheet.sh" "$dir" --since HEAD~1 > "$out"

  assert_grep "café/é.py" "$out"     "the delta must name non-ASCII paths literally, matching the tree walk"
  grep -qF '\303' "$out" &&
    fail "the delta must not C-quote non-ASCII paths: $(grep -F '\303' "$out")"

  pass "fm-roundtable-factsheet: delta paths are not C-quoted"
}

test_basic_output
test_since_delta
test_mark_round_trip
test_root_docs_preferred
test_test_classification_is_anchored
test_absent_docs_do_not_abort
test_doc_name_match_is_literal
test_delta_paths_are_not_quoted
