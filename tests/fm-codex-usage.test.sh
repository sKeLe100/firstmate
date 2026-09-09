#!/usr/bin/env bash
# tests/fm-codex-usage.test.sh - behavior tests for bin/fm-codex-usage.sh.
# Exercises the helper through its executable interface with synthetic inline
# rollout fixtures: the reported context band, weekly quota, model
# attribution, and telemetry emission must all match the data in the file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-usage)
HELPER="$ROOT/bin/fm-codex-usage.sh"

# --- helper functions -------------------------------------------------------

# field <line> <key> - extract the value after <key>= from a data line.
field() {
  printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"
}

# emit <home> <rollout_path> - run the helper in a given home, capturing stdout.
emit() {
  local home="$1" rollout="$2"
  ( cd "$home" && FM_HOME="$home" FM_CONFIG_OVERRIDE="${FM_CONFIG_OVERRIDE:-}" CODEX_HOME="${CODEX_HOME:-}" \
      "$HELPER" "$rollout" )
}

# mk_line <ordinal> <input_tokens> <output_tokens> <context_window> <used_percent> <resets_at>
#   Emit a single token_count JSONL line at a given ordinal.
#   Computes total_tokens as input + output.
mk_line() {
  local ord="$1" in_tok="$2" out_tok="$3" ctx_win="$4" used_pct="$5" resets="$6"
  local total=$(( in_tok + out_tok ))
  printf '{"ordinal":%d,"timestamp":"2026-09-06T19:49:48.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%d,"output_tokens":%d,"total_tokens":%d},"last_token_usage":{"input_tokens":%d,"output_tokens":%d,"total_tokens":%d},"model_context_window":%d},"rate_limits":{"primary":{"used_percent":%s,"window_minutes":10080,"resets_at":%s}}}}\n' \
    "$ord" "$in_tok" "$out_tok" "$total" "$in_tok" "$out_tok" "$total" "$ctx_win" "$used_pct" "$resets"
}

# mk_turn_context <model>
# Emit a turn_context JSONL line with a given model.
mk_turn_context() {
  printf '{"timestamp":"2026-09-06T19:49:49.000Z","ordinal":1,"type":"turn_context","payload":{"model":"%s","text":"test"}}\n' "$1"
}

# mk_astra_null_info - emit a rollout mimicking the astra burn session:
# info=null and rate_limits.primary=null, with a turn_context model.
mk_astra_null_info() {
  printf '{"timestamp":"2026-09-07T23:23:43.000Z","ordinal":0,"type":"session_meta","payload":{"session_id":"astra","model_provider":"openai"}}\n'
  mk_turn_context "gpt-6-astra"
  printf '{"timestamp":"2026-09-07T23:23:43.000Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":null}}}\n'
}

# --- tests ------------------------------------------------------------------

test_explicit_path_reads_all_fields() {
  # Create an inline fixture mimicking a multi-turn terra session.
  local home out
  home="$TMP_ROOT/test1"
  mkdir -p "$home"
  {
    # session_meta
    printf '{"timestamp":"2026-09-06T19:49:48.000Z","ordinal":0,"type":"session_meta","payload":{"session_id":"abc","model_provider":"openai"}}\n'
    # turn_context with model
    mk_turn_context "gpt-5.6-terra"
    # 5 token_count records at different ordinals
    mk_line 1 60000 6000 258400 75.0 1789236167
    mk_line 2 65000 7500 258400 76.0 1789236167
    mk_line 3 70000 8000 258400 77.0 1789236167
    mk_line 4 62000 3500 258400 77.5 1789236167
    mk_line 5 65750 2030 258400 77.0 1789236167
  } > "$TMP_ROOT/terraform-inline.jsonl"
  out=$(emit "$home" "$TMP_ROOT/terraform-inline.jsonl")

  # context_tokens and window come from the last token_count's info.
  [ "$(field "$out" context_tokens)" != "" ] || fail "context_tokens missing"
  [ "$(field "$out" window)" = "258400" ] || fail "window should be 258400: $out"
  # band=ok because 65750 < 150000 (default warn).
  [ "$(field "$out" band)" = "ok" ] || fail "band should be ok: $out"
  # models_seen from turn_context records.
  [ "$(field "$out" models_seen)" = "gpt-5.6-terra" ] || fail "models_seen should be gpt-5.6-terra: $out"
  # turns = number of token_count records.
  [ "$(field "$out" turns)" = "5" ] || fail "turns should be 5: $out"
  # weekly_resets_at should be populated from the last record's rate_limits.
  [ "$(field "$out" weekly_resets_at)" != "" ] || fail "weekly_resets_at should be populated: $out"
  pass "fm-codex-usage.sh: explicit path reads all fields correctly"
}

test_auto_discovery_picks_newest_rollout() {
  # Create a fake ~/.codex/sessions with two rollouts; the helper should
  # pick the most recently modified one.
  local home fake_codex older newer
  home="$TMP_ROOT/test2"
  mkdir -p "$home"
  fake_codex="$home/codex/sessions/2026/09/06"
  mkdir -p "$fake_codex"

  older="$fake_codex/rollout-2026-09-06T10-00-00-abc.jsonl"
  newer="$fake_codex/rollout-2026-09-06T20-00-00-def.jsonl"

  # Both files have one token_count line.
  mk_line 0 1000 1000 258400 50.0 1789236167 > "$older"
  touch -d '2 hours ago' "$older"

  mk_line 0 4000 400 258400 65.0 1789236167 > "$newer"

  FM_HOME="$home" CODEX_HOME="$home/codex" "$HELPER" | {
      read -r line
      # The newest file has context_tokens=4000 (last line).
      [ "$(field "$line" context_tokens)" = "4000" ] || \
        fail "auto-discovery should pick newest (4000), got $(field "$line" context_tokens)"
    }
  pass "fm-codex-usage.sh: auto-discovery picks the newest rollout"
}

test_context_bands_ok_warn_restart() {
  # Create a fixture where context_tokens sits in each band.
  local home out
  home="$TMP_ROOT/test3"
  mkdir -p "$home"

  # ok: below 150000 (default warn).
  { printf '{"timestamp":"2026-09-06T19:49:48.000Z","ordinal":0,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50000,"output_tokens":1000,"total_tokens":51000},"last_token_usage":{"input_tokens":50000,"output_tokens":1000,"total_tokens":51000},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":50.0,"window_minutes":10080,"resets_at":1789236167}}}}\n'; } \
    > "$TMP_ROOT/ok.jsonl"
  out=$(emit "$home" "$TMP_ROOT/ok.jsonl")
  [ "$(field "$out" band)" = "ok" ] || fail "50000 tokens should be band=ok: $out"

  # warn: at/above 150000.
  { printf '{"timestamp":"2026-09-06T19:49:48.000Z","ordinal":0,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150000,"output_tokens":1000,"total_tokens":151000},"last_token_usage":{"input_tokens":150000,"output_tokens":1000,"total_tokens":151000},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":50.0,"window_minutes":10080,"resets_at":1789236167}}}}\n'; } \
    > "$TMP_ROOT/warn.jsonl"
  out=$(emit "$home" "$TMP_ROOT/warn.jsonl")
  [ "$(field "$out" band)" = "warn" ] || fail "150000 tokens should be band=warn: $out"

  # restart: at/above 180000 (default restart).
  { printf '{"timestamp":"2026-09-06T19:49:48.000Z","ordinal":0,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":180000,"output_tokens":1000,"total_tokens":181000},"last_token_usage":{"input_tokens":180000,"output_tokens":1000,"total_tokens":181000},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":50.0,"window_minutes":10080,"resets_at":1789236167}}}}\n'; } \
    > "$TMP_ROOT/restart.jsonl"
  out=$(emit "$home" "$TMP_ROOT/restart.jsonl")
  [ "$(field "$out" band)" = "restart" ] || fail "180000 tokens should be band=restart: $out"

  pass "fm-codex-usage.sh: context bands ok/warn/restart at thresholds"
}

test_weekly_quota_fields() {
  # Verify weekly_used_percent and weekly_resets_at come from rate_limits.
  local home out
  home="$TMP_ROOT/test4"
  mkdir -p "$home"

  { printf '{"timestamp":"2026-09-06T19:49:48.000Z","ordinal":0,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"output_tokens":100,"total_tokens":1100},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":77.5,"window_minutes":10080,"resets_at":1789236167}}}}\n'; } \
    > "$TMP_ROOT/quota.jsonl"

  out=$(emit "$home" "$TMP_ROOT/quota.jsonl")
  [ "$(field "$out" weekly_used_percent)" = "77.5" ] || fail "used_percent should be 77.5: $out"
  [ "$(field "$out" weekly_resets_at)" = "2026-09-12T18:02:47+00:00" ] || \
    fail "resets_at should be ISO: $out"
  pass "fm-codex-usage.sh: weekly quota fields from rate_limits"
}

test_weekly_delta_computed() {
  # Two token_count records: used_percent goes from 50.0 to 55.0 => delta=5.0.
  local home out
  home="$TMP_ROOT/test5"
  mkdir -p "$home"

  {
    printf '{"timestamp":"2026-09-06T19:49:48.000Z","ordinal":0,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"output_tokens":100,"total_tokens":1100},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":50.0,"window_minutes":10080,"resets_at":1789236167}}}}\n'
    printf '{"timestamp":"2026-09-06T19:50:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"output_tokens":200,"total_tokens":2200},"last_token_usage":{"input_tokens":2000,"output_tokens":200,"total_tokens":2200},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":55.0,"window_minutes":10080,"resets_at":1789236167}}}}\n'
  } > "$TMP_ROOT/delta.jsonl"

  out=$(emit "$home" "$TMP_ROOT/delta.jsonl")
  [ "$(field "$out" weekly_delta_points)" = "5.0" ] || \
    fail "delta should be 5.0: $out"
  pass "fm-codex-usage.sh: weekly delta computed between two records"
}

test_model_attribution_from_turn_context() {
  # One turn_context with model "gpt-5.6-terra".
  local home out
  home="$TMP_ROOT/test6"
  mkdir -p "$home"

  {
    printf '{"timestamp":"2026-09-06T19:49:48.000Z","ordinal":0,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"output_tokens":100,"total_tokens":1100},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":50.0,"window_minutes":10080,"resets_at":1789236167}}}}\n'
    mk_turn_context "gpt-5.6-terra"
    mk_turn_context "gpt-5.6-terra"
  } > "$TMP_ROOT/model.jsonl"

  out=$(emit "$home" "$TMP_ROOT/model.jsonl")
  [ "$(field "$out" models_seen)" = "gpt-5.6-terra" ] || \
    fail "models_seen should be gpt-5.6-terra: $out"
  pass "fm-codex-usage.sh: model attribution from turn_context records"
}

test_model_attribution_multiple_models() {
  # Two turn_context records with different models.
  local home out
  home="$TMP_ROOT/test6b"
  mkdir -p "$home"

  {
    printf '{"timestamp":"2026-09-06T19:49:48.000Z","ordinal":0,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"output_tokens":100,"total_tokens":1100},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":50.0,"window_minutes":10080,"resets_at":1789236167}}}}\n'
    mk_turn_context "gpt-5.6-terra"
    mk_turn_context "gpt-5.6-sol"
  } > "$TMP_ROOT/multi-model.jsonl"

  out=$(emit "$home" "$TMP_ROOT/multi-model.jsonl")
  # Models should be comma-separated and sorted.
  case "$(field "$out" models_seen)" in
    gpt-5.6-sol,gpt-5.6-terra) ;;
    *) fail "models_seen should be sorted comma list: $(field "$out" models_seen)" ;;
  esac
  pass "fm-codex-usage.sh: multiple models tracked and sorted"
}

test_no_models_seen_is_none() {
  # A rollout with token_count records but no turn_context.
  local home out
  home="$TMP_ROOT/test6c"
  mkdir -p "$home"

  mk_line 0 1000 1000 258400 50.0 1789236167 > "$TMP_ROOT/no-models.jsonl"
  out=$(emit "$home" "$TMP_ROOT/no-models.jsonl")
  [ "$(field "$out" models_seen)" = "none" ] || \
    fail "models_seen should be 'none': $out"
  pass "fm-codex-usage.sh: no models_seen is 'none'"
}

test_astra_null_info_handled_gracefully() {
  local home out
  home="$TMP_ROOT/test7"
  mkdir -p "$home"
  mk_astra_null_info > "$TMP_ROOT/astra-inline.jsonl"
  out=$(emit "$home" "$TMP_ROOT/astra-inline.jsonl")
  # context_tokens should be 0 (info is null).
  [ "$(field "$out" context_tokens)" = "0" ] || fail "astra context_tokens should be 0: $out"
  # session_total should be 0.
  [ "$(field "$out" session_total)" = "0" ] || fail "astra session_total should be 0: $out"
  # models_seen should still be collected from turn_context.
  [ "$(field "$out" models_seen)" = "gpt-6-astra" ] || \
    fail "astra models_seen should be gpt-6-astra: $out"
  pass "fm-codex-usage.sh: astra null-info handled gracefully"
}

test_config_thresholds_override() {
  # config/codex-context-thresholds overrides the defaults.
  local home out
  home="$TMP_ROOT/test8"
  mkdir -p "$home/config"
  printf 'warn=50000\nrestart=100000\n' > "$home/config/codex-context-thresholds"

  # 70000 tokens with warn=50000 => band=warn.
  mk_line 0 70000 70000 258400 50.0 1789236167 > "$TMP_ROOT/thresh.jsonl"
  out=$(emit "$home" "$TMP_ROOT/thresh.jsonl")
  [ "$(field "$out" band)" = "warn" ] || fail "70000 with warn=50000 should be warn: $out"

  # 110000 tokens with restart=100000 => band=restart.
  mk_line 0 110000 110000 258400 50.0 1789236167 > "$TMP_ROOT/thresh2.jsonl"
  out=$(emit "$home" "$TMP_ROOT/thresh2.jsonl")
  [ "$(field "$out" band)" = "restart" ] || fail "110000 with restart=100000 should be restart: $out"

  pass "fm-codex-usage.sh: config/codex-context-thresholds overrides defaults"
}

test_config_thresholds_malformed_rejected() {
  local home
  home="$TMP_ROOT/test9"
  mkdir -p "$home/config"

  # Malformed warn value.
  printf 'warn=abc\n' > "$home/config/codex-context-thresholds"
  mk_line 0 1000 100 258400 50.0 1789236167 > "$TMP_ROOT/malf.jsonl"
  if FM_HOME="$home" "$HELPER" "$TMP_ROOT/malf.jsonl" >/dev/null 2>&1; then
    fail "malformed warn value should be rejected"
  fi

  # warn > restart.
  printf 'warn=200000\nrestart=100000\n' > "$home/config/codex-context-thresholds"
  if FM_HOME="$home" "$HELPER" "$TMP_ROOT/malf.jsonl" >/dev/null 2>&1; then
    fail "warn > restart should be rejected"
  fi

  # Unknown key.
  printf 'bogus=1\n' > "$home/config/codex-context-thresholds"
  if FM_HOME="$home" "$HELPER" "$TMP_ROOT/malf.jsonl" >/dev/null 2>&1; then
    fail "unknown config key should be rejected"
  fi

  pass "fm-codex-usage.sh: malformed thresholds rejected loudly"
}

test_partial_threshold_config_keeps_other_default() {
  # Only restart=300000; warn should keep the default 150000.
  local home out
  home="$TMP_ROOT/test10"
  mkdir -p "$home/config"
  printf 'restart=300000\n' > "$home/config/codex-context-thresholds"

  mk_line 0 160000 160000 258400 50.0 1789236167 > "$TMP_ROOT/partial.jsonl"
  out=$(emit "$home" "$TMP_ROOT/partial.jsonl")
  [ "$(field "$out" band)" = "warn" ] || fail "160000 with default warn=150000 should be warn: $out"
  pass "fm-codex-usage.sh: partial threshold config keeps the other default"
}

test_telemetry_emits_usage_event() {
  local home out
  home="$TMP_ROOT/test11"
  mkdir -p "$home/data/llm-usage"
  local telemetry_file="$home/data/llm-usage/firstmate.jsonl"
  rm -f "$telemetry_file"

  mk_line 0 5000 500 258400 60.0 1789236167 > "$TMP_ROOT/tele.jsonl"
  out=$(FM_HOME="$home" "$HELPER" --telemetry --task-id task-abc "$TMP_ROOT/tele.jsonl")
  # stdout still has the data line.
  [ "$(field "$out" context_tokens)" = "5000" ] || fail "stdout data line broken: $out"
  # Telemetry file should have one JSON event.
  [ -f "$telemetry_file" ] || fail "telemetry file not created"
  local event
  event=$(cat "$telemetry_file")
  printf '%s\n' "$event" | python3 -c "
import json, sys
row = json.loads(sys.stdin.readline())
assert row['event_type'] == 'usage', f'event_type should be usage: {row}'
assert row['task_id'] == 'task-abc', f'task_id should be task-abc: {row}'
assert row['harness'] == 'codex', f'harness should be codex: {row}'
assert row['context_tokens'] == '5000', f'context_tokens mismatch: {row}'
assert row['weekly_used_percent'] == '60.0', f'weekly_used_percent mismatch: {row}'
" || fail "telemetry event shape incorrect: $event"
  pass "fm-codex-usage.sh: --telemetry emits a usage event to firstmate.jsonl"
}

test_telemetry_requires_task_id() {
  local home err
  home="$TMP_ROOT/test11b"
  mkdir -p "$home"
  mk_line 0 5000 500 258400 60.0 1789236167 > "$TMP_ROOT/tele-no-id.jsonl"
  if err=$(FM_HOME="$home" "$HELPER" --telemetry "$TMP_ROOT/tele-no-id.jsonl" 2>&1 >/dev/null); then
    fail "--telemetry without --task-id should fail"
  fi
  case "$err" in *"requires --task-id"*) : ;; *) fail "unhelpful diagnostic: $err" ;; esac
  [ -e "$home/data/llm-usage/firstmate.jsonl" ] && fail "no usage event should be written"
  pass "fm-codex-usage.sh: --telemetry without --task-id refuses"
}

test_task_id_without_value_refuses() {
  local home err
  home="$TMP_ROOT/test11c"
  mkdir -p "$home"
  mk_line 0 5000 500 258400 60.0 1789236167 > "$TMP_ROOT/tele-dangling.jsonl"
  if err=$(FM_HOME="$home" "$HELPER" "$TMP_ROOT/tele-dangling.jsonl" --task-id 2>&1 >/dev/null); then
    fail "--task-id with no value should fail"
  fi
  case "$err" in *"--task-id requires a value"*) : ;; *) fail "unhelpful diagnostic: $err" ;; esac
  pass "fm-codex-usage.sh: --task-id with no value refuses"
}

test_telemetry_omits_unknown_fields() {
  local home
  home="$TMP_ROOT/test11d"
  mkdir -p "$home"
  mk_astra_null_info > "$TMP_ROOT/astra-telemetry.jsonl"
  FM_HOME="$home" "$HELPER" --telemetry --task-id task-null "$TMP_ROOT/astra-telemetry.jsonl" >/dev/null \
    || fail "telemetry run on null-info fixture failed"
  python3 -c "
import json, sys
row = json.loads(open('$home/data/llm-usage/firstmate.jsonl').readline())
assert 'weekly_used_percent' not in row, f'unknown weekly quota must be absent: {row}'
assert 'weekly_delta_points' not in row, f'unknown weekly delta must be absent: {row}'
" || fail "unknown telemetry fields were written as placeholders"
  pass "fm-codex-usage.sh: unknown telemetry fields are omitted"
}

test_missing_rollout_fails_loudly() {
  local home
  home="$TMP_ROOT/test12"
  mkdir -p "$home"
  if FM_HOME="$home" "$HELPER" "$TMP_ROOT/nope.jsonl" >/dev/null 2>&1; then
    fail "missing rollout should fail loudly"
  fi
  pass "fm-codex-usage.sh: missing rollout fails loudly"
}

test_no_token_count_records_fails_loudly() {
  local home
  home="$TMP_ROOT/test13"
  mkdir -p "$home"
  # A file with only session_meta, no token_count.
  printf '{"timestamp":"2026-09-06T19:49:48.000Z","ordinal":0,"type":"session_meta","payload":{"session_id":"abc","model_provider":"openai"}}\n' \
    > "$TMP_ROOT/no-tc.jsonl"
  if FM_HOME="$home" "$HELPER" "$TMP_ROOT/no-tc.jsonl" >/dev/null 2>&1; then
    fail "no token_count records should fail loudly"
  fi
  pass "fm-codex-usage.sh: no token_count records fails loudly"
}

test_auto_discovery_finds_no_rollouts() {
  local home fake_codex
  home="$TMP_ROOT/test14"
  mkdir -p "$home"
  # Create a Codex sessions dir with no rollout files.
  fake_codex="$home/codex/sessions"
  mkdir -p "$fake_codex"
  if CODEX_HOME="$home/codex" FM_HOME="$home" \
     "$HELPER" >/dev/null 2>&1; then
    fail "no rollouts in sessions dir should fail"
  fi
  pass "fm-codex-usage.sh: empty sessions dir fails with clear message"
}

test_percent_computed_correctly() {
  # context_tokens=129200, window=258400 => percent=50.0
  local home out
  home="$TMP_ROOT/test15"
  mkdir -p "$home"
  mk_line 0 129200 129200 258400 50.0 1789236167 > "$TMP_ROOT/percent.jsonl"
  out=$(emit "$home" "$TMP_ROOT/percent.jsonl")
  [ "$(field "$out" percent)" = "50.0" ] || fail "percent should be 50.0: $out"
  pass "fm-codex-usage.sh: percent computed as context_tokens/window*100"
}

test_null_rate_limits_fallback_to_previous() {
  # Last token_count has primary:null; previous has primary with used_percent.
  # weekly_used_percent should be taken from the previous record.
  local home out
  home="$TMP_ROOT/test16"
  mkdir -p "$home"

  {
    printf '{"timestamp":"2026-09-06T19:49:48.000Z","ordinal":0,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"output_tokens":100,"total_tokens":1100},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":50.0,"window_minutes":10080,"resets_at":1789236167}}}}\n'
    printf '{"timestamp":"2026-09-06T19:50:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"output_tokens":200,"total_tokens":2200},"last_token_usage":{"input_tokens":2000,"output_tokens":200,"total_tokens":2200},"model_context_window":258400},"rate_limits":{"primary":null}}}\n'
  } > "$TMP_ROOT/null-primary.jsonl"

  out=$(emit "$home" "$TMP_ROOT/null-primary.jsonl")
  # weekly_used_percent should fall back to 50.0 from the previous record.
  [ "$(field "$out" weekly_used_percent)" = "50.0" ] || \
    fail "weekly_used_percent should fallback to 50.0: $out"
  # weekly_resets_at should also fallback.
  [ "$(field "$out" weekly_resets_at)" = "2026-09-12T18:02:47+00:00" ] || \
    fail "weekly_resets_at should fallback: $out"
  pass "fm-codex-usage.sh: null primary falls back to previous record"
}

test_fm_config_override_resolves_thresholds() {
  local home out
  home="$TMP_ROOT/test17"
  mkdir -p "$home/config"
  printf 'warn=50000\nrestart=100000\n' > "$home/config/codex-context-thresholds"

  mk_line 0 70000 70000 258400 50.0 1789236167 > "$TMP_ROOT/cfgovr.jsonl"

  # With FM_CONFIG_OVERRIDE pointing to a dir with different thresholds.
  mkdir -p "$TMP_ROOT/alt-config"
  printf 'warn=200000\nrestart=250000\n' > "$TMP_ROOT/alt-config/codex-context-thresholds"

  # 70000 with override warn=200000 => band=ok.
  out=$(FM_CONFIG_OVERRIDE="$TMP_ROOT/alt-config" emit "$home" "$TMP_ROOT/cfgovr.jsonl")
  [ "$(field "$out" band)" = "ok" ] || fail "70000 with warn=200000 should be ok: $out"
  pass "fm-codex-usage.sh: FM_CONFIG_OVERRIDE resolves thresholds"
}

# --- run all tests ----------------------------------------------------------

test_explicit_path_reads_all_fields
test_auto_discovery_picks_newest_rollout
test_context_bands_ok_warn_restart
test_weekly_quota_fields
test_weekly_delta_computed
test_model_attribution_from_turn_context
test_model_attribution_multiple_models
test_no_models_seen_is_none
test_astra_null_info_handled_gracefully
test_config_thresholds_override
test_config_thresholds_malformed_rejected
test_partial_threshold_config_keeps_other_default
test_telemetry_emits_usage_event
test_telemetry_requires_task_id
test_task_id_without_value_refuses
test_telemetry_omits_unknown_fields
test_missing_rollout_fails_loudly
test_no_token_count_records_fails_loudly
test_auto_discovery_finds_no_rollouts
test_percent_computed_correctly
test_null_rate_limits_fallback_to_previous
test_fm_config_override_resolves_thresholds

echo "PASS fm-codex-usage.test.sh"
