#!/usr/bin/env bash
# .no-mistakes.yaml test-command regression guard owned by
# bin/fm-lint-nomistakes-config.sh.
#
# Regression origin: PR #111 swapped commands.test from the canonical
# `bin/fm-test-run.sh --changed ...` selector for a fixed list of explicit
# tests/ paths "to fit the gate's time cap", with a comment scoping the swap
# to "this branch" (see fm-revert-nm111-test-regression). That per-branch
# workaround landed as standing policy in the trusted default-branch copy:
# every no-mistakes run afterward tested only those scripts regardless of the
# actual diff, while GitHub's required check still certified full coverage.
# This guard must fail on either symptom in any shape, not only the exact
# string that regressed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM_CONFIG="$ROOT/bin/fm-lint-nomistakes-config.sh"

fm_nm_write_canonical() {  # <path>
  cat > "$1" <<'YAML'
commands:
  lint: 'bin/fm-lint.sh'
  test: 'bin/fm-test-run.sh --changed --exclude-family real-herdr-gated'

test:
  evidence:
    store_in_repo: true
YAML
}

test_no_config_file_passes() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-nm-missing)
  rc=0
  out=$("$NM_CONFIG" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a repo with no .no-mistakes.yaml must pass, got $rc"$'\n'"$out"
  assert_contains "$out" "nothing to check" "missing-config run did not explain there is nothing to check"
  pass "a missing .no-mistakes.yaml passes with nothing to check"
}

test_canonical_command_passes() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-nm-canonical)
  fm_nm_write_canonical "$tmp/.no-mistakes.yaml"
  rc=0
  out=$("$NM_CONFIG" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the canonical commands.test must pass, got $rc"$'\n'"$out"
  assert_contains "$out" "ok" "canonical-config run did not report ok"
  pass "the canonical --changed commands.test passes"
}

test_explicit_tests_path_fails() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-nm-explicit-path)
  cat > "$tmp/.no-mistakes.yaml" <<'YAML'
commands:
  lint: 'bin/fm-lint.sh'
  test: 'bin/fm-test-run.sh --exclude-family real-herdr-gated tests/fm-brief.test.sh'

test:
  evidence:
    store_in_repo: true
YAML
  rc=0
  out=$("$NM_CONFIG" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "commands.test naming an explicit tests/ path unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "explicit tests/ path" "explicit-path failure did not explain why"
  assert_contains "$out" "tests/fm-brief.test.sh" "explicit-path failure did not quote the offending value"
  pass "commands.test naming an explicit tests/ path fails"
}

test_this_branch_comment_fails() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-nm-this-branch)
  cat > "$tmp/.no-mistakes.yaml" <<'YAML'
commands:
  lint: 'bin/fm-lint.sh'
  # Scoped to this branch only, to fit the gate's time cap.
  test: 'bin/fm-test-run.sh --changed --exclude-family real-herdr-gated'

test:
  evidence:
    store_in_repo: true
YAML
  rc=0
  out=$("$NM_CONFIG" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a 'this branch' comment unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "this branch" "this-branch failure did not quote the flagged comment"
  pass "a comment scoping the config to 'this branch' fails"
}

test_this_branch_comment_is_case_insensitive() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-nm-this-branch-case)
  cat > "$tmp/.no-mistakes.yaml" <<'YAML'
commands:
  lint: 'bin/fm-lint.sh'
  # This Branch needs a faster test command.
  test: 'bin/fm-test-run.sh --changed --exclude-family real-herdr-gated'
YAML
  rc=0
  out=$("$NM_CONFIG" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a differently-cased 'this branch' comment unexpectedly passed"$'\n'"$out"
  pass "a differently-cased 'this branch' comment still fails"
}

test_unrelated_comment_passes() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-nm-unrelated-comment)
  cat > "$tmp/.no-mistakes.yaml" <<'YAML'
# Pin lint to the same owner CI invokes.
commands:
  lint: 'bin/fm-lint.sh'
  test: 'bin/fm-test-run.sh --changed --exclude-family real-herdr-gated'
YAML
  rc=0
  out=$("$NM_CONFIG" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "an unrelated comment must not trip the guard, got $rc"$'\n'"$out"
  pass "an unrelated comment does not trip the guard"
}

test_explicit_file_argument() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-nm-explicit-file)
  fm_nm_write_canonical "$tmp/custom.yaml"
  rc=0
  out=$("$NM_CONFIG" "$tmp/custom.yaml" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "an explicit canonical file path must pass, got $rc"$'\n'"$out"
  pass "an explicit file argument is checked directly"
}

test_current_repo_config_passes() {
  local out rc
  rc=0
  out=$("$NM_CONFIG" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the real repo's .no-mistakes.yaml must pass, got $rc"$'\n'"$out"
  pass "the real repo's .no-mistakes.yaml passes the regression-pattern guard"
}

test_no_config_file_passes
test_canonical_command_passes
test_explicit_tests_path_fails
test_this_branch_comment_fails
test_this_branch_comment_is_case_insensitive
test_unrelated_comment_passes
test_explicit_file_argument
test_current_repo_config_passes
