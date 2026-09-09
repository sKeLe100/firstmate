#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's handling of a raw (hand-composed) launch
# command: first-word classification decides which harness a raw launch is, and
# a launch classified codex additionally takes the per-launch exe rediscovery
# and --version probe, the executable pin, and the fast-modifier refusal.
# Launches classified as anything else keep the unverified-adapter escape hatch
# untouched and spawn verbatim.
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

# The documented limitation: classification is plain word splitting, so a QUOTED
# environment value splits into words that are not an assignment and the launch
# classifies as some other harness, bypassing the codex guards.
test_quoted_env_value_classifies_elsewhere() {
  local rec id out status
  id=rawcodex-quotedenv-a9
  rec=$(make_case rawcodex-quotedenv "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" 'RUST_LOG="a b" codex --dangerously-bypass-approvals-and-sandbox')
  status=$?
  expect_code 0 "$status" "a quoted env value must keep the escape hatch spawning"$'\n'"$out"
  case "$out" in
    *"spawned $id harness=codex"*) fail "a quoted env value is documented as classifying elsewhere, but it classified codex" ;;
  esac
  grep -q '^codex_exe=' "$HOME_DIR/state/$id.meta" && fail "a launch not classified codex must not record codex rediscovery evidence"
  pass "a quoted environment value classifies as another harness (documented limitation)"
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

test_non_codex_expanded_executable_still_spawns() {
  local rec id out status launch
  id=rawexpand-a8
  rec=$(make_case rawexpand "$id")
  read_case_record "$rec"

  # shellcheck disable=SC2016  # the unexpanded $MYBIN is the input under test
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" '$MYBIN --flag')
  status=$?
  expect_code 0 "$status" "the unverified-adapter escape hatch must keep spawning non-codex raw launches"$'\n'"$out"
  assert_contains "$out" 'spawned '"$id"' harness=$MYBIN' "the escape hatch misclassified the executable"
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = '$MYBIN --flag' ] || fail "a non-codex raw launch was rewritten"$'\n'"actual: $launch"
  pass "a non-codex raw launch whose executable word is a shell expansion still spawns verbatim"
}

test_env_prefixed_launch_still_classifies_codex
test_quoted_env_value_classifies_elsewhere
test_glob_env_value_codex_launch_is_pinned_intact
test_quoted_env_value_codex_launch_refuses_fast
test_non_codex_quoted_env_launch_still_spawns
test_codex_absent_from_path_is_refused
test_failing_version_probe_is_refused
test_empty_version_probe_is_refused
test_foreign_codex_executable_is_refused
test_non_codex_expanded_executable_still_spawns

echo "# all fm-spawn-codex-raw-launch tests passed"
