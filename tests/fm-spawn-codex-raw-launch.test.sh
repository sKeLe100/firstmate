#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's quote-aware classification of a raw
# (hand-composed) launch command. The classifier decides which harness a raw
# launch is, and every codex spawn guard - the lane cap, the per-launch exe
# rediscovery/--version probe and executable pin, and the fast-modifier refusal
# - keys off that decision, so a launch whose quoting hides the executable word
# must never slip through as some other harness.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-codex-raw-launch)

make_case() {  # <name> <task-id>
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  cat > "$fakebin/some-tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/some-tool"
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<<"$1"
}

run_spawn() {  # <home> <wt> <fakebin> <launchlog> <spawn args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off
}

test_quoted_env_value_still_classifies_codex() {
  local rec id out status launch
  id=rawcodex-env-a1
  rec=$(make_case rawcodex-env "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" 'RUST_LOG="a b" codex --dangerously-bypass-approvals-and-sandbox')
  status=$?
  expect_code 0 "$status" "a quoted env value must not break a raw codex launch"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=codex" "a quoted env value hid the codex executable word"
  assert_grep "codex_exe=$FAKEBIN_DIR/codex" "$HOME_DIR/state/$id.meta" "codex exe rediscovery did not run"
  assert_grep "codex_version=codex-cli" "$HOME_DIR/state/$id.meta" "codex version probe did not run"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "RUST_LOG=\"a b\" '$FAKEBIN_DIR/codex' --dangerously-bypass-approvals-and-sandbox" \
    "the launch kept its env prefix but was not pinned to the probed executable"$'\n'"actual: $launch"
  pass "a raw codex launch behind a quoted env value takes the codex guards"
}

test_quoted_env_value_codex_launch_refuses_fast() {
  local rec id out status
  id=rawcodex-fast-a2
  rec=$(make_case rawcodex-fast "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" 'RUST_LOG="a b" codex --fast --dangerously-bypass-approvals-and-sandbox' 2>&1)
  status=$?
  expect_code 1 "$status" "a codex launch carrying --fast must be refused"$'\n'"$out"
  assert_contains "$out" "fast modifier" "refusal did not name the fast modifier"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not write task metadata"
  pass "a raw codex launch carrying --fast is refused"
}

test_non_codex_quoted_env_launch_still_spawns() {
  local rec id out status launch
  id=rawother-env-a3
  rec=$(make_case rawother-env "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" 'FOO="a b" some-tool --flag')
  status=$?
  expect_code 0 "$status" "the unverified-adapter escape hatch must survive a quoted env value"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=some-tool" "the escape hatch misclassified the executable"
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = 'FOO="a b" some-tool --flag' ] || fail "a non-codex raw launch was rewritten"$'\n'"actual: $launch"
  pass "a non-codex raw launch with a quoted env value still spawns verbatim"
}

test_expanded_executable_word_is_refused() {
  local rec id out status
  id=rawexpand-a4
  rec=$(make_case rawexpand "$id")
  read_case_record "$rec"

  # shellcheck disable=SC2016  # the unexpanded $MYBIN is the input under test
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" '$MYBIN --flag' 2>&1)
  status=$?
  expect_code 1 "$status" "an executable word produced by an expansion must be refused"$'\n'"$out"
  assert_contains "$out" "executable word cannot be identified" "refusal did not explain the unidentifiable executable"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not write task metadata"
  pass "a raw launch whose executable is a shell expansion is refused"
}

test_unterminated_quote_is_refused() {
  local rec id out status
  id=rawquote-a5
  rec=$(make_case rawquote "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "FOO='a b codex --flag" 2>&1)
  status=$?
  expect_code 1 "$status" "an unterminated quote before the executable must be refused"$'\n'"$out"
  assert_contains "$out" "executable word cannot be identified" "refusal did not explain the unidentifiable executable"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not write task metadata"
  pass "a raw launch with an unterminated quote before the executable is refused"
}

test_quoted_env_value_still_classifies_codex
test_quoted_env_value_codex_launch_refuses_fast
test_non_codex_quoted_env_launch_still_spawns
test_expanded_executable_word_is_refused
test_unterminated_quote_is_refused

echo "# all fm-spawn-codex-raw-launch tests passed"
