#!/usr/bin/env bash
# Runtime pin cases sourced by fm-control-relaunch.test.sh.

test_secondmate_relaunch_picks_up_the_configured_harness_pin() {
  local dir home out rc
  dir=$(new_case smpin sm3)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'codex some-model high\n' > "$home/config/secondmate-harness"
  mkdir -p "$home/data/sm3"
  printf '# secondmate brief\n' > "$home/data/sm3/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm3\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm3"
    echo "endpoint_task_id=sm3"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm3.meta"
  printf '%s\n' "fm-sm3" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm3 relaunch); rc=$?
  expect_code 0 "$rc" "a configured secondmate harness should relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" sm3 to_harness)" = codex ] \
    || fail "a secondmate relaunch should pick up the configured harness pin, got '$(journal_field "$dir" sm3 to_harness)'"
  [ "$(journal_field "$dir" sm3 to_model)" = some-model ] \
    || fail "the configured model token should come with the pin"
  [ "$(journal_field "$dir" sm3 to_effort)" = high ] \
    || fail "the configured effort token should come with the pin"
  assert_not_contains "$out" "not a verified harness" "codex is a verified harness"
  pass "fm-control relaunch: a secondmate relaunch re-resolves its durable configured harness pin"
}

# The relaunch half of the opt-in scope: a pin file that declares no
# "mate <id>:" line is read exactly as it was before that grammar existed, so a
# second default line and a fourth token must not stop the relaunch. The mate
# still lands on the first line's runtime.
test_secondmate_relaunch_with_a_legacy_pin_file_uses_the_first_line() {
  local dir home out rc
  dir=$(new_case smlegacy sml2)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sml2"
  printf 'codex some-model high extra\ngrok other-model low\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/sml2/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sml2\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sml2"
    echo "endpoint_task_id=sml2"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sml2.meta"
  printf '%s\n' "fm-sml2" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sml2 relaunch); rc=$?
  expect_code 0 "$rc" "a legacy pin file must not refuse a secondmate relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" sml2 to_harness)" = codex ] \
    || fail "the relaunch should take the first line's harness, got '$(journal_field "$dir" sml2 to_harness)'"
  [ "$(journal_field "$dir" sml2 to_model)" = some-model ] \
    || fail "the relaunch should take the first line's model token, got '$(journal_field "$dir" sml2 to_model)'"
  [ "$(journal_field "$dir" sml2 to_effort)" = high ] \
    || fail "the relaunch should take the first line's effort token, got '$(journal_field "$dir" sml2 to_effort)'"
  pass "fm-control relaunch: a legacy secondmate pin file still relaunches the mate onto its first line"
}

test_secondmate_claude_relaunch_keeps_local_settings() {
  local dir home prior settings out rc
  dir=$(new_case smlocal sml)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sml"
  printf 'codex gpt-5 high\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/sml/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-local-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin" "$dir/smhome/.claude"
  printf 'sml\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  prior='{"permissions":{"allow":["Bash(echo hi)"]}}'
  printf '%s\n' "$prior" > "$dir/smhome/.claude/settings.local.json"
  printf '%s\n' '{"feedbackDrafts":"on"}' > "$home/state/sml.claude-settings.json"
  printf 'gen=retired\n' > "$dir/smhome/.fm-busy-stop"
  {
    echo "window=fmses:fm-sml"
    echo "endpoint_task_id=sml"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sml.meta"
  printf '%s\n' "fm-sml" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sml relaunch); rc=$?
  expect_code 0 "$rc" "a claude secondmate relaunch should retire wiring without touching local settings"$'\n'"$out"
  settings="$dir/smhome/.claude/settings.local.json"
  [ "$(cat "$settings")" = "$prior" ] \
    || fail "relaunch rewrote the mate home's settings.local.json"
  [ ! -e "$home/state/sml.claude-settings.json" ] \
    || fail "relaunch left the retired claude settings file in place"
  [ ! -e "$dir/smhome/.fm-busy-stop" ] \
    || fail "relaunch left the retired Stop pointer in the mate home"
  pass "fm-control relaunch: a claude secondmate keeps settings.local.json and retires the state settings file and the Stop pointer"
}

# The captain's per-mate override line must win at the relaunch decision, so a
# later change to the default pin cannot migrate a mate that has its own runtime
# ruling onto the default. Synthetic mate ids only - no real home's pin values.
test_secondmate_relaunch_lands_on_the_per_mate_pin() {
  local dir home out rc
  dir=$(new_case smpinmate smp1)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/smp1"
  printf 'codex default-model high\nmate smp1: claude mate-model xhigh\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/smp1/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'smp1\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-smp1"
    echo "endpoint_task_id=smp1"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=codex"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/smp1.meta"
  printf '%s\n' "fm-smp1" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'claude' > "$dir/fake/becomes"
  out=$(run_control "$dir" smp1 relaunch); rc=$?
  expect_code 0 "$rc" "a per-mate pin should relaunch that mate onto its own runtime"$'\n'"$out"
  [ "$(journal_field "$dir" smp1 to_harness)" = claude ] \
    || fail "the mate's own override should win over the default pin, got '$(journal_field "$dir" smp1 to_harness)'"
  [ "$(journal_field "$dir" smp1 to_model)" = mate-model ] \
    || fail "the override's model token should be used, got '$(journal_field "$dir" smp1 to_model)'"
  [ "$(journal_field "$dir" smp1 to_effort)" = xhigh ] \
    || fail "the override's effort token should be used, got '$(journal_field "$dir" smp1 to_effort)'"
  pass "fm-control relaunch: a mate with a per-mate override line lands on that override, not the default pin"
}

# A mate with no override line keeps resolving through the default line, so
# adding the override grammar cannot change any other mate's resolution.
test_secondmate_relaunch_uses_the_default_for_an_unpinned_mate() {
  local dir home out rc
  dir=$(new_case smdefault smp2)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/smp2"
  printf 'codex default-model high\nmate some-other-mate: claude opus max\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/smp2/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'smp2\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-smp2"
    echo "endpoint_task_id=smp2"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=codex"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/smp2.meta"
  printf '%s\n' "fm-smp2" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" smp2 relaunch); rc=$?
  expect_code 0 "$rc" "an unpinned mate should relaunch onto the default pin"$'\n'"$out"
  [ "$(journal_field "$dir" smp2 to_harness)" = codex ] \
    || fail "a mate with no override must take the default harness, got '$(journal_field "$dir" smp2 to_harness)'"
  [ "$(journal_field "$dir" smp2 to_model)" = default-model ] \
    || fail "the default model token should be used, got '$(journal_field "$dir" smp2 to_model)'"
  [ "$(journal_field "$dir" smp2 to_effort)" = high ] \
    || fail "the default effort token should be used, got '$(journal_field "$dir" smp2 to_effort)'"
  pass "fm-control relaunch: a mate with no override line still resolves the default pin"
}

# A pin file this home cannot parse must stop the relaunch, because the
# alternative is launching the mate onto whatever it happened to run last time -
# the silent migration the override grammar exists to prevent.
test_secondmate_relaunch_refuses_an_unreadable_configured_pin_before_stop() {
  local dir home out rc
  dir=$(new_case smbadminpin smp3)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/smp3"
  printf 'codex default-model high\nmate smp3: claude mate-model xhigh\nmate smp3: grok other-model max\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/smp3/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'smp3\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-smp3"
    echo "endpoint_task_id=smp3"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/smp3.meta"
  printf '%s\n' "fm-smp3" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  out=$(run_control "$dir" smp3 relaunch); rc=$?
  expect_code 1 "$rc" "an unparseable configured pin must refuse the relaunch"$'\n'"$out"
  assert_contains "$out" "config/secondmate-harness" \
    "the refusal should name the pin file the mate cannot be resolved from"
  assert_contains "$out" "line 3" "the refusal should name the offending line"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a refused relaunch must not stop or replace the running agent"
  [ "$(meta_field "$dir" smp3 harness)" = claude ] \
    || fail "a refused relaunch must leave the durable record on the recorded harness"
  pass "fm-control relaunch: an unparseable secondmate pin refuses before anything is stopped"
}

test_secondmate_relaunch_ignores_invalid_configured_effort_before_stop() {
  local dir home out rc
  dir=$(new_case invalid-effort sm6)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sm6"
  # grok (not codex) here: codex now requires an explicit, valid effort, so it
  # cannot demonstrate an invalid token being ignored and normalized to default.
  printf 'grok some-model impossible\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/sm6/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm6\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm6"
    echo "endpoint_task_id=sm6"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm6.meta"
  printf '%s\n' "fm-sm6" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'grok' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm6 relaunch); rc=$?
  expect_code 0 "$rc" "an invalid configured effort should be ignored before stop"$'\n'"$out"
  assert_contains "$out" "effort token 'impossible'" \
    "relaunch should surface the same warning as a normal secondmate spawn"
  [ "$(journal_field "$dir" sm6 to_effort)" = default ] \
    || fail "invalid configured effort should normalize to default"
  pass "fm-control relaunch: invalid configured effort is ignored before stop"
}

# muse is a verified adapter, but only for crewmates and scouts: it has no
# primary supervision protocol, so bin/fm-spawn.sh refuses it for a secondmate.
# That refusal alone is not enough here, because the launch owner is reached
# only AFTER the running agent has been stopped - a secondmate would be left
# with no agent at all. The control plane asks the same capability question
# before it touches anything, so the refusal lands while the agent is still up.
test_secondmate_relaunch_onto_a_crewmate_only_adapter_refuses_before_stop() {
  local dir home out rc
  dir=$(new_case smkind sm7)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sm7"
  printf '# secondmate brief\n' > "$home/data/sm7/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm7\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm7"
    echo "endpoint_task_id=sm7"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm7.meta"
  printf '%s\n' "fm-sm7" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  out=$(run_control "$dir" sm7 relaunch --harness muse); rc=$?
  expect_code 1 "$rc" "a crewmate-only adapter should refuse a secondmate relaunch"
  assert_contains "$out" "not verified to run a secondmate task" \
    "the refusal should name the kind the adapter cannot run"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "the refusal must land before the running agent is stopped"
  [ "$(meta_field "$dir" sm7 harness)" = claude ] \
    || fail "a refused relaunch must leave the durable record on the recorded harness"
  pass "fm-control relaunch: an adapter unverified for this task kind refuses before the agent is stopped"
}

test_explicit_secondmate_harness_ignores_configured_profile_axes() {
  local dir home out rc
  dir=$(new_case smexplicit sm4)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude opus high\n' > "$home/config/secondmate-harness"
  mkdir -p "$home/data/sm4"
  printf '# secondmate brief\n' > "$home/data/sm4/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm4\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm4"
    echo "endpoint_task_id=sm4"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=opus"
    echo "effort=high"
    echo "home=$dir/smhome"
  } > "$home/state/sm4.meta"
  printf '%s\n' "fm-sm4" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  # grok (not codex) here: codex now refuses a relaunch that resolves no
  # explicit model/effort, so it cannot demonstrate the reset-to-default case
  # this test is about.
  printf 'grok' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm4 relaunch --harness grok); rc=$?
  expect_code 0 "$rc" "an explicit secondmate harness should relaunch"$'\n'"$out"
  [ "$(meta_field "$dir" sm4 model)" = default ] \
    || fail "an explicit secondmate harness must not inherit the configured model"
  [ "$(meta_field "$dir" sm4 effort)" = default ] \
    || fail "an explicit secondmate harness must not inherit the configured effort"
  printf 'claude opus high\nmate sm4: claude opus high\nmate sm4: codex other-model max\n' > "$home/config/secondmate-harness"
  out=$(run_control "$dir" sm4 relaunch --harness codex --model explicit-model --effort xhigh); rc=$?
  expect_code 0 "$rc" "an explicit profile must ignore an unreadable configured pin"$'\n'"$out"
  [ "$(meta_field "$dir" sm4 harness)" = codex ] \
    || fail "the explicit harness must be published"
  [ "$(meta_field "$dir" sm4 model)" = explicit-model ] \
    || fail "the explicit model must be published"
  [ "$(meta_field "$dir" sm4 effort)" = xhigh ] \
    || fail "the explicit effort must be published"
  # The same explicit profile must succeed whatever the file holds, including a
  # legacy file whose later lines and fourth token the strict rules would have
  # rejected, and a file with no usable line at all.
  printf 'claude opus high extra\ngrok other-model low\n' > "$home/config/secondmate-harness"
  out=$(run_control "$dir" sm4 relaunch --harness codex --model explicit-model --effort xhigh); rc=$?
  expect_code 0 "$rc" "an explicit profile must ignore a legacy configured pin"$'\n'"$out"
  [ "$(meta_field "$dir" sm4 harness)" = codex ] \
    || fail "the explicit harness must be published"
  [ "$(meta_field "$dir" sm4 model)" = explicit-model ] \
    || fail "the explicit model must be published"
  [ "$(meta_field "$dir" sm4 effort)" = xhigh ] \
    || fail "the explicit effort must be published"
  printf '# only a comment\n' > "$home/config/secondmate-harness"
  out=$(run_control "$dir" sm4 relaunch --harness codex --model explicit-model --effort xhigh); rc=$?
  expect_code 0 "$rc" "an explicit profile must ignore a configured pin with no usable line"$'\n'"$out"
  [ "$(meta_field "$dir" sm4 harness)" = codex ] \
    || fail "the explicit harness must be published"
  [ "$(meta_field "$dir" sm4 model)" = explicit-model ] \
    || fail "the explicit model must be published"
  [ "$(meta_field "$dir" sm4 effort)" = xhigh ] \
    || fail "the explicit effort must be published"
  pass "fm-control relaunch: explicit secondmate harness resets unnamed profile axes"
}

