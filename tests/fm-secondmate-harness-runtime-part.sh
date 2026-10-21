#!/usr/bin/env bash
# Runtime pin cases sourced by fm-secondmate-harness.test.sh.

test_spawn_bare_harness_no_model_effort_flag() {
  local w sm meta launchlog launch out status
  w="$TMP_ROOT/spawn-bare-tokens"
  sm="$w/sm"
  launchlog="$w/launch.log"
  mkdir -p "$w/home/config"
  printf 'claude\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  out=$(spawn_secondmate_capture "$w" sm "$sm" "$launchlog" 2>&1); status=$?
  expect_code 0 "$status" "bare-harness secondmate spawn should succeed"

  meta="$w/home/state/sm.meta"
  [ "$(meta_field "$meta" model)" = default ] || fail "bare-tokens: meta model not default (got '$(meta_field "$meta" model)')"
  [ "$(meta_field "$meta" effort)" = default ] || fail "bare-tokens: meta effort not default (got '$(meta_field "$meta" effort)')"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "CLAUDE_CODE_SEND_FEEDBACK=0 claude" \
    "bare-tokens: Claude secondmate launch did not disable feedback drafts"
  assert_not_contains "$launch" "--model" "bare-tokens: launch must not carry a --model flag"
  assert_not_contains "$launch" "--effort" "bare-tokens: launch must not carry an --effort flag"
  pass "C2 spawn: a bare harness-only secondmate-harness file launches with no model/effort flag (backward-compat)"
}

# "<harness> <model>" durably threads --model into the secondmate launch and
# records it in meta, with no --effort flag (no effort token supplied).
test_spawn_secondmate_harness_model_token() {
  local w sm meta launchlog launch
  w="$TMP_ROOT/spawn-model-token"
  sm="$w/sm"
  launchlog="$w/launch.log"
  mkdir -p "$w/home/config"
  printf 'claude opus\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  spawn_secondmate_capture "$w" sm "$sm" "$launchlog" >/dev/null 2>&1

  meta="$w/home/state/sm.meta"
  [ "$(meta_field "$meta" harness)" = claude ] || fail "model-token: meta harness not claude"
  [ "$(meta_field "$meta" model)" = opus ] || fail "model-token: meta model not opus (got '$(meta_field "$meta" model)')"
  [ "$(meta_field "$meta" effort)" = default ] || fail "model-token: meta effort not default (got '$(meta_field "$meta" effort)')"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "claude --dangerously-skip-permissions $(sm_claude_add_dir "$w" sm)--settings '$(sm_claude_settings "$w" sm)' --model 'opus'" \
    "model-token: launch did not carry --model opus"
  jq -e '.feedbackDrafts == "off" and .attribution.commit == "" and .attribution.pr == "" and .attribution.sessionUrl == false and .hooks.UserPromptSubmit' \
    "$(sm_claude_settings "$w" sm)" >/dev/null \
    || fail "model-token: the --settings file did not carry the session keys and busy hooks"
  assert_not_contains "$launch" "--effort" "model-token: launch must not carry an --effort flag"
  pass "C3 spawn: config/secondmate-harness's model token threads --model into the launch and meta"
}

# "<harness> <model> <effort>" threads both flags into the launch and meta.
test_spawn_secondmate_harness_model_and_effort_tokens() {
  local w sm meta launchlog launch
  w="$TMP_ROOT/spawn-model-effort-tokens"
  sm="$w/sm"
  launchlog="$w/launch.log"
  mkdir -p "$w/home/config"
  printf 'claude opus high\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  spawn_secondmate_capture "$w" sm "$sm" "$launchlog" >/dev/null 2>&1

  meta="$w/home/state/sm.meta"
  [ "$(meta_field "$meta" model)" = opus ] || fail "model-effort-tokens: meta model not opus"
  [ "$(meta_field "$meta" effort)" = high ] || fail "model-effort-tokens: meta effort not high (got '$(meta_field "$meta" effort)')"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "claude --dangerously-skip-permissions $(sm_claude_add_dir "$w" sm)--settings '$(sm_claude_settings "$w" sm)' --model 'opus' --effort 'high'" \
    "model-effort-tokens: launch did not carry both --model opus and --effort high"
  pass "C4 spawn: config/secondmate-harness's model+effort tokens thread into the launch and meta"
}

# A pin file the captain wrote before the override grammar existed - a second
# default line, a fourth token, anything else after the first line - must still
# launch a secondmate exactly as it did then: the first non-empty, non-comment
# line supplies the runtime and the rest of the file is ignored, never a
# refusal. This is the spawn half of the opt-in scope.
test_spawn_secondmate_with_a_legacy_pin_file_uses_the_first_line() {
  local w sm meta launchlog launch out status
  w="$TMP_ROOT/spawn-legacy-pin"
  sm="$w/sm"
  launchlog="$w/launch.log"
  mkdir -p "$w/home/config"
  printf 'claude opus high extra\ngrok other-model low\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  out=$(spawn_secondmate_capture "$w" sm "$sm" "$launchlog" 2>&1); status=$?
  expect_code 0 "$status" "a legacy pin file must not refuse a secondmate spawn"$'\n'"$out"

  meta="$w/home/state/sm.meta"
  [ "$(meta_field "$meta" harness)" = claude ] || fail "legacy-pin: meta harness not claude"
  [ "$(meta_field "$meta" model)" = opus ] || fail "legacy-pin: meta model not opus (got '$(meta_field "$meta" model)')"
  [ "$(meta_field "$meta" effort)" = high ] || fail "legacy-pin: meta effort not high (got '$(meta_field "$meta" effort)')"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--model 'opus' --effort 'high'" \
    "legacy-pin: the launch did not carry the first line's tokens"
  assert_not_contains "$launch" "extra" \
    "legacy-pin: the fourth token of the first line must not reach the launch"
  pass "C10 spawn: a legacy secondmate-harness file still launches on its first line (opt-in scope)"
}

# The other half of the same scope: a file that DOES declare an override is
# validated as a whole, so a malformed one refuses the spawn loudly instead of
# quietly launching the mate onto the default runtime.
test_spawn_secondmate_with_a_malformed_declared_pin_refuses() {
  local w sm out status
  w="$TMP_ROOT/spawn-bad-declared-pin"
  sm="$w/sm"
  mkdir -p "$w/home/config"
  printf 'claude opus high\nmate sm: claude opus max\nmate sm: grok other-model low\n' \
    > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  out=$(spawn_secondmate_capture "$w" sm "$sm" "$w/launch.log" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a malformed declared pin must refuse the spawn"$'\n'"$out"
  assert_contains "$out" "config/secondmate-harness line 3" \
    "the refusal must name the offending line of the pin file"
  [ ! -f "$w/home/state/sm.meta" ] \
    || fail "a refused spawn must not publish a mate record"
  pass "C11 spawn: a declared pin file that is malformed refuses the spawn with its line number"
}

# Precedence: an explicit per-spawn --model overrides the file's model token.
test_spawn_explicit_model_overrides_secondmate_harness_token() {
  local w sm meta launchlog launch
  w="$TMP_ROOT/spawn-explicit-model"
  sm="$w/sm"
  launchlog="$w/launch.log"
  mkdir -p "$w/home/config"
  printf 'claude opus high\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  spawn_secondmate_capture "$w" sm "$sm" "$launchlog" --model sonnet >/dev/null 2>&1

  meta="$w/home/state/sm.meta"
  [ "$(meta_field "$meta" model)" = sonnet ] \
    || fail "explicit-model: meta model not sonnet (got '$(meta_field "$meta" model)'), explicit flag did not win over file token"
  [ "$(meta_field "$meta" effort)" = high ] || fail "explicit-model: file's effort token should still apply"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--model 'sonnet'" "explicit-model: launch did not use the explicit --model"
  assert_not_contains "$launch" "--model 'opus'" "explicit-model: launch leaked the file's model token"
  pass "C5 spawn: an explicit --model overrides config/secondmate-harness's model token; the file's effort token still applies"
}

# Precedence: an explicit per-spawn --effort overrides the file's effort token.
test_spawn_explicit_effort_overrides_secondmate_harness_token() {
  local w sm meta launchlog launch
  w="$TMP_ROOT/spawn-explicit-effort"
  sm="$w/sm"
  launchlog="$w/launch.log"
  mkdir -p "$w/home/config"
  printf 'claude opus high\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  spawn_secondmate_capture "$w" sm "$sm" "$launchlog" --effort low >/dev/null 2>&1

  meta="$w/home/state/sm.meta"
  [ "$(meta_field "$meta" model)" = opus ] || fail "explicit-effort: file's model token should still apply"
  [ "$(meta_field "$meta" effort)" = low ] \
    || fail "explicit-effort: meta effort not low (got '$(meta_field "$meta" effort)'), explicit flag did not win over file token"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--effort 'low'" "explicit-effort: launch did not use the explicit --effort"
  assert_not_contains "$launch" "--effort 'high'" "explicit-effort: launch leaked the file's effort token"
  pass "C6 spawn: an explicit --effort overrides config/secondmate-harness's effort token; the file's model token still applies"
}

test_spawn_explicit_harness_does_not_inherit_secondmate_harness_tokens() {
  local w sm meta launchlog launch
  w="$TMP_ROOT/spawn-explicit-harness-no-tokens"
  sm="$w/sm"
  launchlog="$w/launch.log"
  mkdir -p "$w/home/config"
  printf 'claude opus high\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  # grok (not codex) here: codex never resolves to a default model/effort, so
  # it cannot demonstrate the clean-defaults case this test is about.
  spawn_secondmate_capture "$w" sm "$sm" "$launchlog" --harness grok >/dev/null 2>&1

  meta="$w/home/state/sm.meta"
  [ "$(meta_field "$meta" harness)" = grok ] || fail "explicit-harness-no-tokens: meta harness not grok"
  [ "$(meta_field "$meta" model)" = default ] || fail "explicit-harness-no-tokens: meta model should stay default"
  [ "$(meta_field "$meta" effort)" = default ] || fail "explicit-harness-no-tokens: meta effort should stay default"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "grok --always-approve" \
    "explicit-harness-no-tokens: launch did not use grok"
  assert_not_contains "$launch" "--model" "explicit-harness-no-tokens: launch must not carry a --model flag"
  assert_not_contains "$launch" "--reasoning-effort" \
    "explicit-harness-no-tokens: launch must not carry a grok effort flag"
  pass "C7 spawn: an explicit --harness starts with clean model/effort defaults"
}

test_spawn_explicit_harness_uses_explicit_profile_axes() {
  local w sm meta launchlog launch
  w="$TMP_ROOT/spawn-explicit-harness-explicit-axes"
  sm="$w/sm"
  launchlog="$w/launch.log"
  mkdir -p "$w/home/config"
  printf 'claude opus high\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  spawn_secondmate_capture "$w" sm "$sm" "$launchlog" --harness codex --model gpt-5.5 --effort xhigh >/dev/null 2>&1

  meta="$w/home/state/sm.meta"
  [ "$(meta_field "$meta" harness)" = codex ] || fail "explicit-harness-explicit-axes: meta harness not codex"
  [ "$(meta_field "$meta" model)" = gpt-5.5 ] || fail "explicit-harness-explicit-axes: meta model did not use explicit value"
  [ "$(meta_field "$meta" effort)" = xhigh ] || fail "explicit-harness-explicit-axes: meta effort did not use explicit value"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--model 'gpt-5.5'" \
    "explicit-harness-explicit-axes: launch did not use the explicit --model"
  assert_contains "$launch" "-c 'model_reasoning_effort=\"xhigh\"'" \
    "explicit-harness-explicit-axes: launch did not use the explicit --effort"
  assert_not_contains "$launch" "--model 'opus'" \
    "explicit-harness-explicit-axes: launch leaked the file's model token"
  assert_not_contains "$launch" "model_reasoning_effort=\"high\"" \
    "explicit-harness-explicit-axes: launch leaked the file's effort token"
  pass "C8 spawn: an explicit --harness still honors explicit model/effort flags"
}

test_spawned_secondmate_uses_its_harness_supervision_model() {
  local harness expected w sm launchlog launch fakebin out
  for harness in codex claude; do
    w="$TMP_ROOT/spawn-supervision-model-$harness"
    sm="$w/sm"
    launchlog="$w/launch.log"
    mkdir -p "$w/home/config"
    if [ "$harness" = codex ]; then
      # codex requires an explicit model/effort (it never resolves to
      # default), so its config line carries tokens; claude still needs none.
      printf 'codex gpt-5 high\n' > "$w/home/config/secondmate-harness"
    else
      printf '%s\n' "$harness" > "$w/home/config/secondmate-harness"
    fi
    make_seeded_home "$sm" sm
    spawn_secondmate_capture "$w" sm "$sm" "$launchlog" >/dev/null 2>&1
    fm_write_meta "$sm/state/task.meta" "window=firstmate:fm-task" "kind=ship"
    touch "$sm/state/.last-watcher-beat"
    fakebin="$w/tmux-sm/fakebin"
    # Point the guard at the fixture home, not at whatever checkout this suite
    # happens to be running from. The guard also reports a tangled primary
    # checkout, so without this the branch a contributor is working on decides
    # whether this assertion passes.
    cat > "$fakebin/$harness" <<SH
#!/usr/bin/env bash
FM_ROOT_OVERRIDE="$sm" "$ROOT/bin/fm-guard.sh"
SH
    chmod +x "$fakebin/$harness"
    launch=$(cat "$launchlog")
    out=$(PATH="$fakebin:$BASE_PATH" CLAUDECODE=1 bash -c "$launch" 2>&1)
    case "$harness" in
      codex)
        expected='WATCHER DOWN - SUPERVISION IS OFF'
        assert_contains "$out" "$expected" \
          "Codex secondmate inherited Claude auto-arm despite its persistent watcher model"
        ;;
      claude)
        [ -z "$out" ] \
          || fail "Claude secondmate with a fresh beacon should use auto-arm supervision, got: $out"
        ;;
    esac
  done
  pass "C9 spawn: secondmate launch pins supervision to its own harness"
}

# The harness fallback chain (secondmate-harness -> crew-harness -> own) still
# resolves correctly with no model/effort tokens anywhere in the chain, and a
# crew/scout (non-secondmate) launch is entirely unaffected by this feature: no
# model/effort is invented for it even though its own project has no profile set.
