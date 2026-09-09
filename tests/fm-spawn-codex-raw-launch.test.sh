#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's handling of a raw (hand-composed) launch
# command. The line is read once with the shell's own lexical rules
# (bin/fm-raw-launch-lib.sh; tests/fm-raw-launch-lib.test.sh pins the reader
# against bash itself), so the executable word decides the harness however it
# is quoted and whatever quoting precedes it, and a launch classified codex
# additionally takes the per-launch exe rediscovery and --version probe, the
# executable pin, and the fast-modifier refusal. A launch whose executable word
# cannot be resolved without running it, or that would run a second command, is
# refused; a codex launch with an expanding argument is refused too; launches
# classified as another harness keep the unverified-adapter escape hatch and
# spawn verbatim.
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

test_env_prefixed_launch_still_classifies_codex() {
  local rec id out status launch
  id=rawcodex-env-a1
  rec=$(make_case rawcodex-env "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" 'RUST_LOG=debug codex --dangerously-bypass-approvals-and-sandbox')
  status=$?
  expect_code 0 "$status" "an env prefix must not break a raw codex launch"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=codex" "the env prefix hid the codex executable word"
  assert_grep "codex_exe=$FAKEBIN_DIR/codex" "$HOME_DIR/state/$id.meta" "codex exe rediscovery did not run"
  assert_grep "codex_version=codex-cli" "$HOME_DIR/state/$id.meta" "codex version probe did not run"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "RUST_LOG=debug '$FAKEBIN_DIR/codex' --dangerously-bypass-approvals-and-sandbox" \
    "the launch kept its env prefix but was not pinned to the probed executable"$'\n'"actual: $launch"
  pass "a raw codex launch behind an unquoted env prefix takes the codex guards"
}

# Quoted whitespace inside an environment value moved the word boundaries for
# every reader that split on whitespace before removing quotes; the one-pass
# reader keeps the assignment whole, so the executable word is still codex and
# every codex guard fires. The prefix is sent to the pane byte for byte.
test_quoted_env_value_still_classifies_codex() {
  local rec id out status launch
  id=rawcodex-quotedenv-a9
  rec=$(make_case rawcodex-quotedenv "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" 'RUST_LOG="a b" codex --dangerously-bypass-approvals-and-sandbox')
  status=$?
  expect_code 0 "$status" "a quoted env value must not break a raw codex launch"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=codex" "a quoted env value hid the codex executable word"
  assert_grep "codex_exe=$FAKEBIN_DIR/codex" "$HOME_DIR/state/$id.meta" "codex exe rediscovery did not run"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "RUST_LOG=\"a b\" '$FAKEBIN_DIR/codex' --dangerously-bypass-approvals-and-sandbox" \
    "the quoted env prefix was not preserved verbatim around the pinned executable"$'\n'"actual: $launch"
  pass "a raw codex launch behind a quoted env value takes the codex guards"
}

# The four quoting spellings that each defeated a previous reader, every one
# carrying --fast: quoted whitespace in an env value, backslash-escaped
# whitespace in an env value, a split-quoted executable word, and a
# split-quoted fast modifier. Each must be refused for the fast modifier,
# which proves the launch was classified codex first.
test_quoting_before_the_executable_cannot_hide_fast() {
  local rec id out status spelling n=0
  for spelling in \
    'RUST_LOG="a b" codex --fast --dangerously-bypass-approvals-and-sandbox' \
    'FOO=bar\ baz codex --fast --dangerously-bypass-approvals-and-sandbox' \
    "FOO='bar baz' codex --fast --dangerously-bypass-approvals-and-sandbox" \
    'co"dex" --fast --dangerously-bypass-approvals-and-sandbox' \
    "codex --f'ast' --dangerously-bypass-approvals-and-sandbox" \
    'codex --fa\st --dangerously-bypass-approvals-and-sandbox'; do
    n=$((n + 1))
    id="rawcodex-hidefast-a$n"
    rec=$(make_case "rawcodex-hidefast-$n" "$id")
    read_case_record "$rec"
    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" "$spelling" 2>&1)
    status=$?
    expect_code 1 "$status" "quoting must not smuggle the fast modifier past the guard: [$spelling]"$'\n'"$out"
    assert_contains "$out" "fast modifier" "refusal did not name the fast modifier for [$spelling]"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not write task metadata: [$spelling]"
  done
  pass "no quoting spelling before or inside the fast modifier hides it from the codex guard"
}

# A codex argument the pane would expand could expand to --fast, so a codex
# launch is refused unless every word after the executable is literal.
test_expansion_after_codex_executable_is_refused() {
  local rec id out status
  id=rawcodex-expandtail-a17
  rec=$(make_case rawcodex-expandtail "$id")
  read_case_record "$rec"

  # shellcheck disable=SC2016  # the unexpanded $MYARG is the input under test
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" 'codex --dangerously-bypass-approvals-and-sandbox $MYARG' 2>&1)
  status=$?
  expect_code 1 "$status" "a codex launch with an expanding argument must be refused"$'\n'"$out"
  assert_contains "$out" "only the pane can resolve" "refusal did not explain the unverifiable argument"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not write task metadata"
  pass "a raw codex launch whose argument only the pane can resolve is refused"
}

# A raw launch is one simple command: a second command reached through an
# operator or a command substitution could be codex --fast under a harness
# name the guards never saw, so the line is refused outright.
test_second_command_in_a_raw_launch_is_refused() {
  local rec id out status spelling n=0
  # shellcheck disable=SC2016  # the unexpanded $( ) is the input under test
  for spelling in \
    'true; codex --fast --dangerously-bypass-approvals-and-sandbox' \
    'some-tool $(codex --fast) --flag'; do
    n=$((n + 1))
    id="rawsecond-a$n"
    rec=$(make_case "rawsecond-$n" "$id")
    read_case_record "$rec"
    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" "$spelling" 2>&1)
    status=$?
    expect_code 1 "$status" "a raw launch running a second command must be refused: [$spelling]"$'\n'"$out"
    assert_contains "$out" "raw launch command refused" "refusal did not name the raw launch for [$spelling]"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not write task metadata: [$spelling]"
  done
  pass "a raw launch that would run a second command is refused"
}

test_unterminated_quote_is_refused() {
  local rec id out status
  id=rawunterminated-a18
  rec=$(make_case rawunterminated "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "'codex --dangerously-bypass-approvals-and-sandbox" 2>&1)
  status=$?
  expect_code 1 "$status" "an unterminated quote must be refused"$'\n'"$out"
  assert_contains "$out" "unterminated quote" "refusal did not name the unterminated quote"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not write task metadata"
  pass "a raw launch with an unterminated quote is refused"
}

test_backslash_quoted_codex_takes_the_guards() {
  local rec id out status launch
  id=rawcodex-backslash-a14
  rec=$(make_case rawcodex-backslash "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" '\codex --dangerously-bypass-approvals-and-sandbox')
  status=$?
  expect_code 0 "$status" "a backslash-quoted codex executable must still spawn"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=codex" "backslash quoting hid the codex classification"
  assert_grep "codex_exe=$FAKEBIN_DIR/codex" "$HOME_DIR/state/$id.meta" "codex exe rediscovery did not run"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$FAKEBIN_DIR/codex' --dangerously-bypass-approvals-and-sandbox" \
    "the backslash-quoted executable was not pinned to the probed binary"$'\n'"actual: $launch"
  pass "a backslash-quoted codex executable takes the codex guards"
}

test_backslash_quoted_codex_with_fast_is_refused() {
  local rec id out status
  id=rawcodex-backslashfast-a15
  rec=$(make_case rawcodex-backslashfast "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" '\codex \-\-fast --dangerously-bypass-approvals-and-sandbox' 2>&1)
  status=$?
  expect_code 1 "$status" "backslash quoting must not smuggle the fast modifier past the guard"$'\n'"$out"
  assert_contains "$out" "fast modifier" "refusal did not name the fast modifier"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not write task metadata"
  pass "a backslash-quoted fast modifier is refused"
}

# Regression: word splitting must not glob-expand, or the executable span is
# matched against text that is not in the command and the launch is duplicated.
test_glob_env_value_codex_launch_is_pinned_intact() {
  local rec id out status launch
  id=rawcodex-glob-a10
  rec=$(make_case rawcodex-glob "$id")
  read_case_record "$rec"
  : > "$CASE_DIR/FOO=a.txt"

  out=$(cd "$CASE_DIR" && run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" 'FOO=*.txt codex --dangerously-bypass-approvals-and-sandbox')
  status=$?
  expect_code 0 "$status" "a glob-shaped env value must not break a raw codex launch"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=codex" "a glob-shaped env value hid the codex executable word"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FOO=*.txt '$FAKEBIN_DIR/codex' --dangerously-bypass-approvals-and-sandbox" \
    "the launch was mangled by glob expansion"$'\n'"actual: $launch"
  case "$launch" in
    *--dangerously-bypass-approvals-and-sandbox*--dangerously-bypass-approvals-and-sandbox*)
      fail "glob expansion duplicated the launch command"$'\n'"actual: $launch" ;;
  esac
  pass "a glob-shaped env value leaves the pinned codex launch intact"
}

test_quoted_env_value_codex_launch_refuses_fast() {
  local rec id out status
  id=rawcodex-fast-a2
  rec=$(make_case rawcodex-fast "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" 'RUST_LOG=debug codex --fast --dangerously-bypass-approvals-and-sandbox' 2>&1)
  status=$?
  expect_code 1 "$status" "a codex launch carrying --fast must be refused"$'\n'"$out"
  assert_contains "$out" "fast modifier" "refusal did not name the fast modifier"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not write task metadata"
  pass "a raw codex launch carrying --fast is refused"
}

test_quoted_fast_modifier_is_refused() {
  local rec id out status
  id=rawcodex-quotedfast-a11
  rec=$(make_case rawcodex-quotedfast "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" 'codex "--fast" --dangerously-bypass-approvals-and-sandbox' 2>&1)
  status=$?
  expect_code 1 "$status" "shell quoting must not smuggle the fast modifier past the guard"$'\n'"$out"
  assert_contains "$out" "fast modifier" "refusal did not name the fast modifier"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not write task metadata"
  pass "a quoted fast modifier is refused like the bare spelling"
}

test_quoted_executable_word_still_classifies_codex() {
  local rec id out status launch
  id=rawcodex-quotedexe-a12
  rec=$(make_case rawcodex-quotedexe "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" '"codex" --dangerously-bypass-approvals-and-sandbox')
  status=$?
  expect_code 0 "$status" "a quoted codex executable word must still spawn"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=codex" "a quoted executable word hid the codex classification"
  assert_grep "codex_exe=$FAKEBIN_DIR/codex" "$HOME_DIR/state/$id.meta" "codex exe rediscovery did not run"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$FAKEBIN_DIR/codex' --dangerously-bypass-approvals-and-sandbox" \
    "the quoted executable was not pinned to the probed binary"$'\n'"actual: $launch"
  pass "a quoted codex executable word takes the codex guards"
}

test_quoted_executable_with_fast_is_refused() {
  local rec id out status
  id=rawcodex-quotedexefast-a13
  rec=$(make_case rawcodex-quotedexefast "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" '"codex" --fast --dangerously-bypass-approvals-and-sandbox' 2>&1)
  status=$?
  expect_code 1 "$status" "a quoted codex executable must not smuggle --fast past the guard"$'\n'"$out"
  assert_contains "$out" "fast modifier" "refusal did not name the fast modifier"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not write task metadata"
  pass "a quoted codex executable carrying --fast is refused"
}

test_non_codex_quoted_env_launch_still_spawns() {
  local rec id out status launch
  id=rawother-env-a3
  rec=$(make_case rawother-env "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" 'FOO=bar some-tool --flag')
  status=$?
  expect_code 0 "$status" "the unverified-adapter escape hatch must survive an env prefix"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=some-tool" "the escape hatch misclassified the executable"
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = 'FOO=bar some-tool --flag' ] || fail "a non-codex raw launch was rewritten"$'\n'"actual: $launch"
  pass "a non-codex raw launch with an env prefix still spawns verbatim"
}

# The one deliberate, documented limitation of first-word classification
# (bin/fm-spawn.sh header, .agents/skills/harness-adapters/references/harness/codex.md):
# a wrapper such as `env codex ...` classifies as the wrapper, so the codex
# guards do not apply. Pinned so a classification change cannot widen or narrow
# it silently.
test_wrapper_launch_classifies_as_the_wrapper() {
  local rec id out status launch
  id=rawwrapper-env-a9
  rec=$(make_case rawwrapper-env "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" 'env codex --dangerously-bypass-approvals-and-sandbox')
  status=$?
  expect_code 0 "$status" "a wrapper launch classifies as the wrapper and spawns"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=env" "the wrapper was not classified as the wrapper"
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = 'env codex --dangerously-bypass-approvals-and-sandbox' ] \
    || fail "a wrapper raw launch was rewritten"$'\n'"actual: $launch"
  ! grep -q 'codex_exe=' "$HOME_DIR/state/$id.meta" \
    || fail "a wrapper launch must not record a codex exe pin"
  pass "a wrapper launch classifies as the wrapper and takes no codex guard"
}

# PATH minus every directory that carries a codex executable, so the "codex is
# not installed" exit is reached regardless of the developer's own PATH.
path_without_codex() {
  local out="" d dirs
  IFS=: read -ra dirs <<<"$PATH"
  for d in "${dirs[@]}"; do
    [ -x "$d/codex" ] && continue
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}

test_codex_absent_from_path_is_refused() {
  local rec id out status
  id=rawcodex-absent-a4
  rec=$(make_case rawcodex-absent "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/codex"

  out=$(PATH=$(path_without_codex) run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex 2>&1)
  status=$?
  expect_code 1 "$status" "a codex spawn with no codex on PATH must be refused"$'\n'"$out"
  assert_contains "$out" "codex executable not found on PATH" "refusal did not name the missing executable"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not write task metadata"
  pass "a codex spawn with codex absent from PATH is refused"
}

test_failing_version_probe_is_refused() {
  local rec id out status
  id=rawcodex-badver-a5
  rec=$(make_case rawcodex-badver "$id")
  read_case_record "$rec"
  cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/usr/bin/env bash
exit 3
SH
  chmod +x "$FAKEBIN_DIR/codex"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex 2>&1)
  status=$?
  expect_code 1 "$status" "a codex binary whose --version fails must be refused"$'\n'"$out"
  assert_contains "$out" "failed to report --version" "refusal did not name the failed version probe"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not write task metadata"
  pass "a codex binary whose --version probe fails is refused"
}

test_empty_version_probe_is_refused() {
  local rec id out status
  id=rawcodex-emptyver-a6
  rec=$(make_case rawcodex-emptyver "$id")
  read_case_record "$rec"
  cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FAKEBIN_DIR/codex"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex 2>&1)
  status=$?
  expect_code 1 "$status" "a codex binary reporting an empty --version must be refused"$'\n'"$out"
  assert_contains "$out" "reported an empty --version" "refusal did not name the empty version report"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not write task metadata"
  pass "a codex binary reporting an empty --version is refused"
}

test_foreign_codex_executable_is_refused() {
  local rec id out status other
  id=rawcodex-foreign-a7
  rec=$(make_case rawcodex-foreign "$id")
  read_case_record "$rec"
  other="$CASE_DIR/other"
  mkdir -p "$other"
  cat > "$other/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$other/codex"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "$other/codex --dangerously-bypass-approvals-and-sandbox" 2>&1)
  status=$?
  expect_code 1 "$status" "a raw codex launch naming a foreign binary must be refused"$'\n'"$out"
  assert_contains "$out" "stale or foreign codex reference" "refusal did not name the stale/foreign reference"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not write task metadata"
  pass "a raw codex launch naming a codex binary other than the rediscovered one is refused"
}

test_expanded_executable_word_is_refused() {
  local rec id out status
  id=rawexpand-a8
  rec=$(make_case rawexpand "$id")
  read_case_record "$rec"

  # shellcheck disable=SC2016  # the unexpanded $MYBIN is the input under test
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" '$MYBIN --flag' 2>&1)
  status=$?
  expect_code 1 "$status" "an executable word only the pane can resolve must be refused"$'\n'"$out"
  assert_contains "$out" "cannot be resolved without running it" "refusal did not explain the unresolvable executable"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not write task metadata"
  pass "a raw launch whose executable word is a shell expansion is refused"
}

test_expansion_after_the_executable_still_spawns() {
  local rec id out status launch
  id=rawexpandtail-a16
  rec=$(make_case rawexpandtail "$id")
  read_case_record "$rec"

  # shellcheck disable=SC2016  # the unexpanded $MYARG is the input under test
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" 'some-tool --flag $MYARG')
  status=$?
  expect_code 0 "$status" "an expansion after the executable must keep the escape hatch spawning"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=some-tool" "the escape hatch misclassified the executable"
  launch=$(cat "$LAUNCH_LOG")
  # shellcheck disable=SC2016  # the unexpanded $MYARG must reach the pane verbatim
  [ "$launch" = 'some-tool --flag $MYARG' ] || fail "a non-codex raw launch was rewritten"$'\n'"actual: $launch"
  pass "an expansion after the executable word still spawns verbatim"
}

test_env_prefixed_launch_still_classifies_codex
test_quoted_env_value_still_classifies_codex
test_quoting_before_the_executable_cannot_hide_fast
test_expansion_after_codex_executable_is_refused
test_second_command_in_a_raw_launch_is_refused
test_unterminated_quote_is_refused
test_backslash_quoted_codex_takes_the_guards
test_backslash_quoted_codex_with_fast_is_refused
test_glob_env_value_codex_launch_is_pinned_intact
test_quoted_env_value_codex_launch_refuses_fast
test_quoted_fast_modifier_is_refused
test_quoted_executable_word_still_classifies_codex
test_quoted_executable_with_fast_is_refused
test_non_codex_quoted_env_launch_still_spawns
test_wrapper_launch_classifies_as_the_wrapper
test_codex_absent_from_path_is_refused
test_failing_version_probe_is_refused
test_empty_version_probe_is_refused
test_foreign_codex_executable_is_refused
test_expanded_executable_word_is_refused
test_expansion_after_the_executable_still_spawns

echo "# all fm-spawn-codex-raw-launch tests passed"
