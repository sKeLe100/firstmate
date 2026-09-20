#!/usr/bin/env bash
# Behavior tests for the deterministic Gemini dispatch/quota guard.
#
# The facts pinned here are the captain's Gemini routing and quota rules from
# data/captain.md, in executable form (bin/fm-gemini-guard-lib.sh owns the
# dispatch preflight; bin/fm-classify-lib.sh owns the bounded provider-error
# loop classification):
#   1. Gemini 3.1 Pro is prohibited in every provider prefix and suffix.
#   2. The exact medium and economy pins (gemini-3.7-flash, gemini-3.5-flash-lite)
#      require exact catalog support, and a moving alias or sibling never
#      substitutes.
#   3. Authentication and quota must be positively verified - uncertainty refuses.
#   4. The Gemini-family session cap is two concurrent sessions.
#   5. An oversized economy Flash-Lite input is rejected before dispatch.
#   6. A before-launch accounting baseline is written, and an unwritable record
#      refuses.
#   7. A repeated RESOURCE_EXHAUSTED/quota response is a bounded terminal loop:
#      one retry, then interrupt-and-hold, never discard.
#   8. A non-Gemini launch passes through untouched.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=bin/fm-gemini-guard-lib.sh
. "$ROOT/bin/fm-gemini-guard-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-gemini-guard)

# fm_gemini_fake_provider <dir> <models> <auth> <quota-json>
# Writes fake opencode and quota-axi binaries into <dir> and echoes the fakebin
# dir. The opencode fake answers `models` with <models> and `auth list` with
# <auth>; the quota-axi fake answers --json with <quota-json>. The payloads are
# written as sibling files the fakes cat at runtime, so no env propagation or
# shell escaping is needed through fm_run_timed's bounded runner.
fm_gemini_fake_provider() {
  local dir=$1 models=$2 auth=$3 quota_json=$4 fakebin
  fakebin=$(fm_fakebin "$dir")
  printf '%s\n' "$models" > "$fakebin/models"
  printf '%s\n' "$auth" > "$fakebin/auth"
  printf '%s\n' "$quota_json" > "$fakebin/quota"
  cat > "$fakebin/opencode" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  models) cat "$(dirname "$0")/models"; exit 0 ;;
  auth) cat "$(dirname "$0")/auth"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/opencode"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
cat "$(dirname "$0")/quota"
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

FM_GEMINI_HEALTHY_QUOTA='{"schemaVersion":5,"providers":[{"provider":"google","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"week","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}}]}'
FM_GEMINI_EXHAUSTED_QUOTA='{"schemaVersion":5,"providers":[{"provider":"google","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"week","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]}'
FM_GEMINI_NO_QUOTA='{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"week","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}}]}'

test_model_class_maps_the_pins() {
  [ "$(fm_gemini_model_class 'gemini-openai/gemini-3.8-flash')" = senior ] || fail "3.8-flash must classify senior"
  [ "$(fm_gemini_model_class 'gemini-openai/gemini-3.7-flash')" = medium ] || fail "3.7-flash must classify medium"
  [ "$(fm_gemini_model_class 'gemini-openai/gemini-3.5-flash-lite')" = economy ] || fail "3.5-flash-lite must classify economy"
  [ "$(fm_gemini_model_class 'gemini-openai/gemini-3.1-pro-preview')" = prohibited ] || fail "3.1-pro-preview must classify prohibited"
  [ "$(fm_gemini_model_class 'google/gemini-3.1-pro-preview')" = prohibited ] || fail "a google/-prefixed 3.1-pro must still classify prohibited"
  [ "$(fm_gemini_model_class 'gemini-openai/gemini-flash-latest')" = other-gemini ] || fail "a moving alias must classify other-gemini"
  [ "$(fm_gemini_model_class 'google/gemini-3.5-flash')" = other-gemini ] || fail "regular 3.5 Flash must classify other-gemini, never economy"
  [ "$(fm_gemini_model_class 'deepseek/deepseek-v4-pro')" = not-gemini ] || fail "deepseek must classify not-gemini"
  [ "$(fm_gemini_model_class 'claude-sonnet-5')" = not-gemini ] || fail "claude must classify not-gemini"
  pass "fm-gemini-guard-lib.sh: model class maps the pins and rejects aliases"
}

test_model_is_gemini_ignores_provider_prefix() {
  fm_gemini_model_is_gemini 'gemini-openai/gemini-3.8-flash' || fail "gemini-openai model is gemini"
  fm_gemini_model_is_gemini 'openrouter/google/gemini-3.1-pro-preview' || fail "openrouter/google model is gemini"
  ! fm_gemini_model_is_gemini 'deepseek/deepseek-flash' || fail "deepseek is not gemini"
  ! fm_gemini_model_is_gemini '' || fail "an empty model is not gemini"
  pass "fm-gemini-guard-lib.sh: gemini identity ignores the provider prefix"
}

test_prohibited_model_is_prohibited() {
  fm_gemini_model_prohibited 'gemini-openai/gemini-3.1-pro-preview' || fail "gemini-openai 3.1 Pro is prohibited"
  fm_gemini_model_prohibited 'google/gemini-3.1-pro-preview-customtools' || fail "google 3.1 Pro with a suffix is prohibited"
  ! fm_gemini_model_prohibited 'gemini-openai/gemini-3.8-flash' || fail "3.8-flash is not prohibited"
  pass "fm-gemini-guard-lib.sh: Gemini 3.1 Pro is prohibited everywhere"
}

test_input_size_rejects_only_oversized_economy() {
  fm_gemini_input_tokens_ok 'gemini-openai/gemini-3.5-flash-lite' 1000 || fail "under-bound economy input must pass"
  ! fm_gemini_input_tokens_ok 'gemini-openai/gemini-3.5-flash-lite' 200000 || fail "oversized Flash-Lite input must be rejected"
  fm_gemini_input_tokens_ok 'gemini-openai/gemini-3.8-flash' 200000 || fail "senior model is not input-capped here"
  pass "fm-gemini-guard-lib.sh: only an oversized Flash-Lite input is rejected"
}

test_session_cap_is_two() {
  fm_gemini_session_cap_ok 0 || fail "0 sessions is under cap"
  fm_gemini_session_cap_ok 1 || fail "1 session is under cap"
  ! fm_gemini_session_cap_ok 2 || fail "2 sessions is at cap, a third must refuse"
  ! fm_gemini_session_cap_ok 3 || fail "3 sessions is over cap"
  pass "fm-gemini-guard-lib.sh: the Gemini session cap is two concurrent sessions"
}

test_input_token_estimate_is_conservative() {
  local file="$TMP_ROOT/brief.md" out
  printf 'a%.0s' {1..40} > "$file"
  out=$(fm_gemini_estimate_input_tokens "$file")
  [ "$out" = 10 ] || fail "40 bytes must estimate 10 tokens (ceil 40/4), got '$out'"
  out=$(fm_gemini_estimate_input_tokens "$TMP_ROOT/missing.md")
  [ "$out" = 0 ] || fail "a missing file estimates 0, got '$out'"
  pass "fm-gemini-guard-lib.sh: input tokens are estimated conservatively"
}

test_catalog_requires_the_exact_pin() {
  local catalog='gemini-openai/gemini-3.1-pro-preview
gemini-openai/gemini-3.8-flash
gemini-openai/gemini-flash-latest
gemini-openai/gemini-pro-latest'
  fm_gemini_catalog_has "$catalog" 'gemini-openai/gemini-3.8-flash' || fail "the exact 3.8-flash pin must match"
  ! fm_gemini_catalog_has "$catalog" 'gemini-openai/gemini-3.7-flash' || fail "the unsupported 3.7-flash pin must not match"
  ! fm_gemini_catalog_has "$catalog" 'gemini-openai/gemini-3.5-flash-lite' || fail "the unsupported 3.5-flash-lite pin must not match"
  pass "fm-gemini-guard-lib.sh: the catalog requires the exact pin, never an alias"
}

test_auth_requires_a_google_or_gemini_credential() {
  fm_gemini_auth_ok 'Google  api' || fail "a Google credential must pass"
  fm_gemini_auth_ok 'Environment  GEMINI_API_KEY' || fail "a GEMINI_API_KEY must pass"
  ! fm_gemini_auth_ok 'OpenRouter  api' || fail "an OpenRouter-only listing is unverified auth"
  ! fm_gemini_auth_ok '' || fail "an empty auth listing is unverified"
  pass "fm-gemini-guard-lib.sh: auth requires a Google/Gemini credential"
}

test_quota_requires_a_healthy_gemini_row() {
  fm_gemini_quota_ok "$FM_GEMINI_HEALTHY_QUOTA" || fail "a healthy Google quota row must pass"
  ! fm_gemini_quota_ok "$FM_GEMINI_NO_QUOTA" || fail "a missing Gemini-family row is unverified quota"
  ! fm_gemini_quota_ok "$FM_GEMINI_EXHAUSTED_QUOTA" || fail "an exhausted quota row must refuse"
  ! fm_gemini_quota_ok '' || fail "an empty quota snapshot is unverified"
  pass "fm-gemini-guard-lib.sh: quota requires a healthy Gemini-family row"
}

test_preflight_passes_non_gemini_untouched() {
  local state="$TMP_ROOT/state"
  mkdir -p "$state"
  fm_gemini_preflight opencode 'deepseek/deepseek-v4-pro' "$state" task-1 0 \
    || fail "a non-Gemini launch must pass untouched"
  fm_gemini_preflight opencode 'deepseek/deepseek-v4-pro' "$state" task-1 0 \
    || fail "a non-Gemini launch is a no-op with no external call"
  pass "fm-gemini-guard-lib.sh: a non-Gemini launch passes untouched"
}

test_preflight_refuses_prohibited_model() {
  local state="$TMP_ROOT/state" out
  mkdir -p "$state"
  out=$(fm_gemini_preflight opencode 'gemini-openai/gemini-3.1-pro-preview' "$state" task-1 0 2>&1) \
    && fail "prohibited 3.1 Pro must refuse"
  printf '%s' "$out" | grep -q 'prohibited' || fail "prohibited refusal must name the prohibition, got: $out"
  pass "fm-gemini-guard-lib.sh: preflight refuses the prohibited model"
}

test_preflight_refuses_unsupported_exact_pin() {
  local fakebin state out
  fakebin=$(fm_gemini_fake_provider "$TMP_ROOT/unsupported" \
    'gemini-openai/gemini-3.1-pro-preview
gemini-openai/gemini-3.8-flash' \
    'Google  api' "$FM_GEMINI_HEALTHY_QUOTA")
  state="$TMP_ROOT/state-unsupported"
  mkdir -p "$state"
  out=$(FM_GEMINI_OPENCODE_BIN="$fakebin/opencode" \
    FM_GEMINI_QUOTA_AXI_BIN="$fakebin/quota-axi" \
    FM_GEMINI_SENIOR=1 \
    fm_gemini_preflight opencode 'gemini-openai/gemini-3.7-flash' "$state" task-1 0 2>&1) \
    && fail "an unsupported 3.7-flash pin must refuse"
  printf '%s' "$out" | grep -q 'not exactly listed' || fail "unsupported-pin refusal must name the catalog, got: $out"
  pass "fm-gemini-guard-lib.sh: preflight refuses an unsupported exact pin"
}

test_preflight_requires_senior_assertion() {
  local state="$TMP_ROOT/state-senior" out
  mkdir -p "$state"
  out=$(fm_gemini_preflight opencode 'gemini-openai/gemini-3.8-flash' "$state" task-1 0 2>&1) \
    && fail "3.8-flash without a senior assertion must refuse"
  printf '%s' "$out" | grep -q 'senior' || fail "senior refusal must name the senior restriction, got: $out"
  pass "fm-gemini-guard-lib.sh: preflight requires a senior assertion for 3.8-flash"
}

test_preflight_refuses_auth_uncertainty() {
  local fakebin state out
  fakebin=$(fm_gemini_fake_provider "$TMP_ROOT/unauth" 'gemini-openai/gemini-3.8-flash' '' "$FM_GEMINI_HEALTHY_QUOTA")
  state="$TMP_ROOT/state-unauth"
  mkdir -p "$state"
  out=$(FM_GEMINI_OPENCODE_BIN="$fakebin/opencode" \
    FM_GEMINI_QUOTA_AXI_BIN="$fakebin/quota-axi" \
    FM_GEMINI_SENIOR=1 \
    fm_gemini_preflight opencode 'gemini-openai/gemini-3.8-flash' "$state" task-1 0 2>&1) \
    && fail "unverified auth must refuse"
  printf '%s' "$out" | grep -q 'authentication' || fail "auth refusal must name authentication, got: $out"
  pass "fm-gemini-guard-lib.sh: preflight refuses auth uncertainty"
}

test_preflight_refuses_quota_uncertainty() {
  local fakebin state out
  fakebin=$(fm_gemini_fake_provider "$TMP_ROOT/unoquota" 'gemini-openai/gemini-3.8-flash' 'Google  api' "$FM_GEMINI_NO_QUOTA")
  state="$TMP_ROOT/state-unoquota"
  mkdir -p "$state"
  out=$(FM_GEMINI_OPENCODE_BIN="$fakebin/opencode" \
    FM_GEMINI_QUOTA_AXI_BIN="$fakebin/quota-axi" \
    FM_GEMINI_SENIOR=1 \
    fm_gemini_preflight opencode 'gemini-openai/gemini-3.8-flash' "$state" task-1 0 2>&1) \
    && fail "unverified quota must refuse"
  printf '%s' "$out" | grep -q 'quota' || fail "quota refusal must name quota, got: $out"
  pass "fm-gemini-guard-lib.sh: preflight refuses quota uncertainty"
}

test_preflight_writes_the_accounting_baseline() {
  local fakebin state record
  fakebin=$(fm_gemini_fake_provider "$TMP_ROOT/baseline" 'gemini-openai/gemini-3.8-flash' 'Google  api' "$FM_GEMINI_HEALTHY_QUOTA")
  state="$TMP_ROOT/state-baseline"
  mkdir -p "$state"
  FM_GEMINI_OPENCODE_BIN="$fakebin/opencode" \
    FM_GEMINI_QUOTA_AXI_BIN="$fakebin/quota-axi" \
    FM_GEMINI_SENIOR=1 \
    fm_gemini_preflight opencode 'gemini-openai/gemini-3.8-flash' "$state" task-1 4321 \
    || fail "a verified senior Gemini dispatch must pass"
  record="$state/task-1.gemini-baseline"
  [ -f "$record" ] || fail "the before-launch baseline must be written"
  grep -q '^model=gemini-openai/gemini-3.8-flash$' "$record" || fail "baseline must record the model"
  grep -q '^input_tokens=4321$' "$record" || fail "baseline must record the input tokens"
  grep -q '^quota_available=true$' "$record" || fail "baseline must record the quota verdict"
  [ -f "$state/task-1.gemini-baseline.quota.json" ] || fail "baseline must persist the raw quota snapshot"
  pass "fm-gemini-guard-lib.sh: preflight writes the before-launch accounting baseline"
}

test_preflight_refuses_an_unwritable_baseline() {
  local fakebin state out
  fakebin=$(fm_gemini_fake_provider "$TMP_ROOT/nowrite" 'gemini-openai/gemini-3.8-flash' 'Google  api' "$FM_GEMINI_HEALTHY_QUOTA")
  state="$TMP_ROOT/readonly-state"
  mkdir -p "$state"
  chmod 0555 "$state"
  out=$(FM_GEMINI_OPENCODE_BIN="$fakebin/opencode" \
    FM_GEMINI_QUOTA_AXI_BIN="$fakebin/quota-axi" \
    FM_GEMINI_SENIOR=1 \
    fm_gemini_preflight opencode 'gemini-openai/gemini-3.8-flash' "$state" task-1 0 2>&1) \
    && fail "an unwritable baseline record must refuse"
  chmod 0755 "$state"
  printf '%s' "$out" | grep -q 'baseline' || fail "baseline refusal must name the record, got: $out"
  pass "fm-gemini-guard-lib.sh: preflight refuses when the baseline cannot be written"
}

test_quota_line_detection() {
  status_is_quota_exhaustion_line 'working: hit RESOURCE_EXHAUSTED again' || fail "RESOURCE_EXHAUSTED is a quota event"
  status_is_quota_exhaustion_line 'error: You exceeded your current quota, please check your plan' || fail "a Google quota phrase is a quota event"
  status_is_quota_exhaustion_line 'working: Quota exceeded for metric: generate_content_free_tier_requests' || fail "a quota-exceeded phrase is a quota event"
  ! status_is_quota_exhaustion_line 'working: compiling the fix' || fail "an unrelated working line is not a quota event"
  ! status_is_quota_exhaustion_line '' || fail "an empty line is not a quota event"
  pass "fm-classify-lib.sh: quota-exhaustion lines are detected"
}

test_quota_loop_is_bounded_then_hold() {
  local status="$TMP_ROOT/loop.status" out
  : > "$status"
  printf 'working: hit RESOURCE_EXHAUSTED\n' > "$status"
  out=$(status_provider_quota_loop "$status")
  [ "$out" = '1 retry' ] || fail "one exhaustion allows one bounded retry, got '$out'"
  status_provider_quota_loop "$status" >/dev/null && fail "one exhaustion is not yet a terminal loop"
  printf 'working: Quota exceeded again\n' >> "$status"
  out=$(status_provider_quota_loop "$status")
  [ "$out" = '2 hold' ] || fail "the second exhaustion is terminal hold, got '$out'"
  status_provider_quota_loop "$status" >/dev/null || fail "the second exhaustion must hold"
  printf 'working: RESOURCE_EXHAUSTED a third time\n' >> "$status"
  out=$(status_provider_quota_loop "$status")
  [ "$out" = '3 hold' ] || fail "a third exhaustion stays bounded at hold, got '$out'"
  pass "fm-classify-lib.sh: a repeated quota response is one retry then a terminal hold"
}

test_quota_loop_never_discards_work() {
  local status="$TMP_ROOT/discard.status" out
  printf 'working: hit RESOURCE_EXHAUSTED\nworking: RESOURCE_EXHAUSTED again\n' > "$status"
  out=$(status_provider_quota_loop "$status")
  case "$out" in
    *' hold') ;;
    *) fail "the terminal verdict must be hold (preserve work), got '$out'" ;;
  esac
  printf '%s' "$out" | grep -qv 'discard\|teardown\|failed' \
    || fail "the terminal verdict must never discard or tear down work, got '$out'"
  pass "fm-classify-lib.sh: the terminal loop holds work instead of discarding it"
}

test_model_class_maps_the_pins
test_model_is_gemini_ignores_provider_prefix
test_prohibited_model_is_prohibited
test_input_size_rejects_only_oversized_economy
test_session_cap_is_two
test_input_token_estimate_is_conservative
test_catalog_requires_the_exact_pin
test_auth_requires_a_google_or_gemini_credential
test_quota_requires_a_healthy_gemini_row
test_preflight_passes_non_gemini_untouched
test_preflight_refuses_prohibited_model
test_preflight_refuses_unsupported_exact_pin
test_preflight_requires_senior_assertion
test_preflight_refuses_auth_uncertainty
test_preflight_refuses_quota_uncertainty
test_preflight_writes_the_accounting_baseline
test_preflight_refuses_an_unwritable_baseline
test_quota_line_detection
test_quota_loop_is_bounded_then_hold
test_quota_loop_never_discards_work
