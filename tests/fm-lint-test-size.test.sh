#!/usr/bin/env bash
# Test-file size ceiling guard owned by bin/fm-lint-test-size.sh.
#
# A single tests/*.test.sh growing past a few thousand lines or a few hundred
# test_ cases becomes its own retry-unit problem: one unrelated failure forces
# re-running the whole file (the fm-teardown-test-split incident, at 160
# cases). This guard must refuse a new oversized file, honor the shrinking
# allowlist for already-grandfathered files, and force a stale allowlist
# entry (a split file, or one that no longer exists) to be removed rather
# than left to rot.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SIZE="$ROOT/bin/fm-lint-test-size.sh"

fm_lint_test_size_write_file() {  # <path> <lines> [test-func-count]
  local path=$1 lines=$2 funcs=${3:-0} i
  : > "$path"
  i=0
  while [ "$i" -lt "$funcs" ]; do
    printf 'test_case_%s() {\n  :\n}\n' "$i" >> "$path"
    i=$((i + 1))
  done
  i=$(wc -l < "$path" | tr -d '[:space:]')
  while [ "$i" -lt "$lines" ]; do
    printf '# padding\n' >> "$path"
    i=$((i + 1))
  done
}

test_small_file_passes() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-size-small)
  mkdir -p "$tmp/tests"
  fm_lint_test_size_write_file "$tmp/tests/fm-example.test.sh" 20 3
  rc=0
  out=$("$SIZE" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a small test file must pass, got $rc"$'\n'"$out"
  assert_contains "$out" "sizes ok" "small-file run did not report ok"
  pass "a test file under both ceilings passes"
}

test_oversized_line_count_fails_ungrandfathered() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-size-lines)
  mkdir -p "$tmp/tests"
  fm_lint_test_size_write_file "$tmp/tests/fm-huge.test.sh" 3001 1
  rc=0
  out=$("$SIZE" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an oversized non-grandfathered file unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "fm-huge.test.sh" "line-ceiling failure did not name the file"
  assert_contains "$out" "exceeds the size ceiling" "line-ceiling failure did not explain why"
  pass "a test file over the line ceiling fails when not grandfathered"
}

test_oversized_function_count_fails_ungrandfathered() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-size-funcs)
  mkdir -p "$tmp/tests"
  fm_lint_test_size_write_file "$tmp/tests/fm-manycases.test.sh" 10 101
  rc=0
  out=$("$SIZE" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a test file over the function ceiling unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "fm-manycases.test.sh" "function-ceiling failure did not name the file"
  pass "a test file over the test_ function ceiling fails when not grandfathered"
}

test_grandfathered_file_passes() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-size-allowed)
  mkdir -p "$tmp/tests"
  fm_lint_test_size_write_file "$tmp/tests/fm-huge.test.sh" 3001 1
  printf 'fm-huge.test.sh\n' > "$tmp/tests/fm-lint-test-size-allowlist.txt"
  rc=0
  out=$("$SIZE" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a grandfathered oversized file must pass, got $rc"$'\n'"$out"
  assert_contains "$out" "1 allowlisted" "grandfathered run did not report the allowlist count"
  pass "an allowlisted oversized file passes"
}

test_stale_allowlist_entry_for_missing_file_fails() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-size-stale-missing)
  mkdir -p "$tmp/tests"
  fm_lint_test_size_write_file "$tmp/tests/fm-kept.test.sh" 5 1
  printf 'fm-gone.test.sh\n' > "$tmp/tests/fm-lint-test-size-allowlist.txt"
  rc=0
  out=$("$SIZE" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an allowlist entry for a missing file unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "fm-gone.test.sh" "stale-entry failure did not name the missing file"
  assert_contains "$out" "no longer exists" "stale-entry failure did not explain the file is gone"
  pass "an allowlist entry naming a file that no longer exists fails"
}

test_stale_allowlist_entry_below_ceiling_fails() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-size-stale-shrunk)
  mkdir -p "$tmp/tests"
  fm_lint_test_size_write_file "$tmp/tests/fm-shrunk.test.sh" 10 1
  printf 'fm-shrunk.test.sh\n' > "$tmp/tests/fm-lint-test-size-allowlist.txt"
  rc=0
  out=$("$SIZE" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an allowlist entry that no longer exceeds the ceiling unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "fm-shrunk.test.sh" "stale-entry failure did not name the shrunk file"
  assert_contains "$out" "no longer exceeds the ceiling" \
    "stale-entry failure did not explain the file is under ceiling now"
  pass "an allowlist entry for a file that no longer exceeds the ceiling fails"
}

test_no_tests_dir_passes() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-size-notests)
  rc=0
  out=$("$SIZE" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a repo with no tests directory must pass, got $rc"$'\n'"$out"
  pass "a missing tests directory passes with nothing to check"
}

test_current_repo_sizes_pass() {
  local out rc
  rc=0
  out=$("$SIZE" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the real repo's current tests/*.test.sh sizes must pass, got $rc"$'\n'"$out"
  pass "the real repo's tests/*.test.sh sizes pass against the shrinking allowlist"
}

test_small_file_passes
test_oversized_line_count_fails_ungrandfathered
test_oversized_function_count_fails_ungrandfathered
test_grandfathered_file_passes
test_stale_allowlist_entry_for_missing_file_fails
test_stale_allowlist_entry_below_ceiling_fails
test_no_tests_dir_passes
test_current_repo_sizes_pass
