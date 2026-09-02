#!/usr/bin/env bash
# Behavior tests for bin/fm-autonomous-thresholds.sh: the nudge-threshold
# logic for the /autonomous skill.  Tests the bundle-size threshold (>= 5
# chat-rulable decisions) and the time threshold (oldest pending decision
# >= 48h old) per the captain's 2026-09-01 ruling (Q3).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-autonomous-thresholds)

SCRIPT="$ROOT/bin/fm-autonomous-thresholds.sh"

# --- test helpers -----------------------------------------------------------

make_decisions() {
  # $1 = number of decisions to generate (each with verb=captain-hold)
  local n=$1 created_at=${2:-}
  local decisions="["
  for i in $(seq 1 "$n"); do
    [ "$i" -gt 1 ] && decisions="$decisions,"
    decisions="$decisions{\"id\":\"task-$i\",\"key\":\"task-$i\",\"verb\":\"captain-hold\",\"summary\":\"Title $i: reason $i\",\"owner\":\"(main)\",\"declared_priority\":false"
    [ -n "$created_at" ] && decisions="$decisions,\"created_at\":$created_at"
    decisions="$decisions}"
  done
  decisions="$decisions]"
  printf '%s' "$decisions"
}

make_decision() {
  # Create a single decision row
  local id=${1:-task-1} verb=${2:-captain-hold} summary=${3:-"Title: reason"} owner=${4:-"(main)"}
  printf '{"id":"%s","key":"%s","verb":"%s","summary":"%s","owner":"%s","declared_priority":false}' \
    "$id" "$id" "$verb" "$summary" "$owner"
}

feed() {
  # Feed input to the script and capture output + exit code
  local input="$1"
  local stdout capture_status
  stdout=$(printf '%s' "$input" | "$SCRIPT" 2>/dev/null) || true
  printf '%s' "$input" | "$SCRIPT" >/dev/null 2>&1
  capture_status=$?
  FM_TEST_FEED_OUTPUT="$stdout"
  FM_TEST_FEED_STATUS=$capture_status
}

# --- tests ------------------------------------------------------------------

test_empty_array_is_no_nudge() {
  feed '[]'
  [ "$FM_TEST_FEED_STATUS" -eq 1 ] || fail "empty array must exit 1 (no nudge)"
  [ "$FM_TEST_FEED_OUTPUT" = "none" ] || fail "empty array output must be 'none', got: $FM_TEST_FEED_OUTPUT"

  pass "autonomous-thresholds: empty array -> no nudge"
}

test_bundle_size_threshold_at_exactly_five() {
  feed "$(make_decisions 5)"
  [ "$FM_TEST_FEED_STATUS" -eq 0 ] || fail "5 decisions must exit 0 (nudge needed)"
  echo "$FM_TEST_FEED_OUTPUT" | grep -q 'bundle-size' || fail "output must mention 'bundle-size', got: $FM_TEST_FEED_OUTPUT"

  pass "autonomous-thresholds: 5 decisions fires bundle-size threshold"
}

test_bundle_size_threshold_below_five() {
  feed "$(make_decisions 4)"
  [ "$FM_TEST_FEED_STATUS" -eq 1 ] || fail "4 decisions must exit 1 (no nudge)"

  pass "autonomous-thresholds: 4 decisions -> no nudge"
}

test_bundle_size_threshold_above_five() {
  feed "$(make_decisions 10)"
  [ "$FM_TEST_FEED_STATUS" -eq 0 ] || fail "10 decisions must exit 0 (nudge needed)"
  echo "$FM_TEST_FEED_OUTPUT" | grep -q 'bundle-size' || fail "output must mention 'bundle-size', got: $FM_TEST_FEED_OUTPUT"

  pass "autonomous-thresholds: 10 decisions fires bundle-size threshold"
}

test_time_threshold_older_than_48h() {
  local old_epoch=1000000
  feed "$(make_decisions 2 "$old_epoch")"
  [ "$FM_TEST_FEED_STATUS" -eq 0 ] || fail "decision older than 48h must exit 0 (nudge needed)"
  echo "$FM_TEST_FEED_OUTPUT" | grep -q 'time' || fail "output must mention 'time', got: $FM_TEST_FEED_OUTPUT"

  pass "autonomous-thresholds: decision > 48h old fires time threshold"
}

test_time_threshold_under_48h() {
  local recent_epoch=$(( $(date +%s) - 3600 ))
  feed "$(make_decisions 2 "$recent_epoch")"
  [ "$FM_TEST_FEED_STATUS" -eq 1 ] || fail "decision < 48h old must exit 1 (no nudge)"

  pass "autonomous-thresholds: decision < 48h old -> no nudge"
}

test_both_thresholds_met() {
  local old_epoch=1000000
  feed "$(make_decisions 5 "$old_epoch")"
  [ "$FM_TEST_FEED_STATUS" -eq 0 ] || fail "both thresholds met must exit 0 (nudge needed)"
  echo "$FM_TEST_FEED_OUTPUT" | grep -q 'both' || fail "output must mention 'both', got: $FM_TEST_FEED_OUTPUT"

  pass "autonomous-thresholds: both thresholds met -> 'both'"
}

test_non_captain_hold_decisions_are_ignored() {
  # Create a decision with verb != captain-hold
  local input='[{"id":"task-1","key":"task-1","verb":"status-update","summary":"All good","owner":"(main)","declared_priority":false}]'
  feed "$input"
  [ "$FM_TEST_FEED_STATUS" -eq 1 ] || fail "non-captain-hold decisions must be ignored"

  pass "autonomous-thresholds: non-captain-hold decisions are ignored"
}

test_mixed_verb_array_counts_only_captain_hold() {
  local mixed='[
    {"id":"task-1","key":"task-1","verb":"captain-hold","summary":"Title: reason","owner":"(main)","declared_priority":false},
    {"id":"task-2","key":"task-2","verb":"status-update","summary":"All good","owner":"(main)","declared_priority":false},
    {"id":"task-3","key":"task-3","verb":"captain-hold","summary":"Title: reason","owner":"(main)","declared_priority":false},
    {"id":"task-4","key":"task-4","verb":"status-update","summary":"All good","owner":"(main)","declared_priority":false},
    {"id":"task-5","key":"task-5","verb":"captain-hold","summary":"Title: reason","owner":"(main)","declared_priority":false}
  ]'
  feed "$mixed"
  [ "$FM_TEST_FEED_STATUS" -eq 1 ] || fail "3 captain-hold out of 5 total must not fire bundle-size (only 3 < 5)"

  pass "autonomous-thresholds: mixed verbs count only captain-hold"
}

test_missing_created_at_does_not_fire_time_threshold() {
  feed "$(make_decisions 2)"
  [ "$FM_TEST_FEED_STATUS" -eq 1 ] || fail "missing created_at must not fire time threshold"

  pass "autonomous-thresholds: missing created_at -> time threshold not fired"
}

test_single_decision_does_not_fire_any_threshold() {
  feed "$(make_decisions 1)"
  [ "$FM_TEST_FEED_STATUS" -eq 1 ] || fail "1 decision must not fire any threshold"

  pass "autonomous-thresholds: single decision -> no nudge"
}

test_exactly_48h_old_fires_time_threshold() {
  local now_epoch
  now_epoch=$(date +%s)
  local exactly_48h=$(( now_epoch - 172800 ))
  feed "$(make_decisions 1 "$exactly_48h")"
  [ "$FM_TEST_FEED_STATUS" -eq 0 ] || fail "decision exactly 48h old must fire time threshold"

  pass "autonomous-thresholds: exactly 48h old fires time threshold"
}

test_four_decisions_with_one_old_does_not_fire_bundle() {
  local old_epoch=1000000
  feed "$(make_decisions 4 "$old_epoch")"
  # Both thresholds fire: 4 >= 5 is false, but old time fires.
  # So the output should be "time" (or "both" if 4 >= 5, which it isn't)
  echo "$FM_TEST_FEED_OUTPUT" | grep -q 'time' || fail "4 old decisions must fire time threshold, got: $FM_TEST_FEED_OUTPUT"

  pass "autonomous-thresholds: 4 old decisions -> time only (not bundle)"
}

test_usage_error_on_unknown_option() {
  set +e
  "$SCRIPT" --bad-option 2>/dev/null
  local status=$?
  set -e
  [ "$status" -eq 2 ] || fail "unknown option must exit 2, got: $status"

  pass "autonomous-thresholds: unknown option -> usage error exit 2"
}

test_usage_error_on_missing_input_file() {
  set +e
  "$SCRIPT" --input 2>/dev/null
  local status=$?
  set -e
  [ "$status" -eq 2 ] || fail "--input without value must exit 2, got: $status"

  pass "autonomous-thresholds: --input without value -> usage error exit 2"
}

test_invalid_json_is_a_usage_error() {
  set +e
  feed 'not-json'
  set -e
  [ "$FM_TEST_FEED_STATUS" -eq 2 ] || fail "invalid JSON must exit 2, got: $FM_TEST_FEED_STATUS"

  pass "autonomous-thresholds: invalid JSON -> usage error exit 2"
}

test_non_array_json_is_a_usage_error() {
  set +e
  feed '{"id":"task-1"}'
  set -e
  [ "$FM_TEST_FEED_STATUS" -eq 2 ] || fail "non-array JSON must exit 2, got: $FM_TEST_FEED_STATUS"

  pass "autonomous-thresholds: non-array JSON -> usage error exit 2"
}

test_declared_priority_rows_dont_affect_count() {
  # 5 decisions, 3 declared_priority=true, 2 false - bundle threshold should fire
  local input='[
    {"id":"task-1","key":"task-1","verb":"captain-hold","summary":"Title: reason","owner":"(main)","declared_priority":true},
    {"id":"task-2","key":"task-2","verb":"captain-hold","summary":"Title: reason","owner":"(main)","declared_priority":true},
    {"id":"task-3","key":"task-3","verb":"captain-hold","summary":"Title: reason","owner":"(main)","declared_priority":true},
    {"id":"task-4","key":"task-4","verb":"captain-hold","summary":"Title: reason","owner":"(main)","declared_priority":false},
    {"id":"task-5","key":"task-5","verb":"captain-hold","summary":"Title: reason","owner":"(main)","declared_priority":false}
  ]'
  feed "$input"
  [ "$FM_TEST_FEED_STATUS" -eq 0 ] || fail "5 mixed-priority decisions must fire bundle-size"

  pass "autonomous-thresholds: declared_priority does not affect bundle count"
}

test_empty_input_pipe_is_no_nudge() {
  set +e
  printf '' | "$SCRIPT" >/dev/null 2>&1
  local status=$?
  set -e
  [ "$status" -eq 2 ] || fail "empty pipe must exit 2 (invalid input), got: $status"

  pass "autonomous-thresholds: empty pipe -> usage error exit 2"
}

test_input_via_flag() {
  local tmp_input="$TMP_ROOT/input.json"
  printf '%s' "$(make_decisions 5)" > "$tmp_input"

  local stdout
  stdout=$("$SCRIPT" --input "$tmp_input" 2>/dev/null) || true
  [ "$stdout" = "nudge: bundle-size" ] || fail "via --input flag: expected 'nudge: bundle-size', got: $stdout"

  pass "autonomous-thresholds: --input flag works"
}

test_input_via_flag_on_missing_file() {
  set +e
  "$SCRIPT" --input "/nonexistent/path.json" >/dev/null 2>&1
  local status=$?
  set -e
  [ "$status" -eq 2 ] || fail "missing --input file must exit 2, got: $status"

  pass "autonomous-thresholds: missing --input file -> usage error exit 2"
}

# --- run all tests ---------------------------------------------------------

test_empty_array_is_no_nudge
test_bundle_size_threshold_at_exactly_five
test_bundle_size_threshold_below_five
test_bundle_size_threshold_above_five
test_time_threshold_older_than_48h
test_time_threshold_under_48h
test_both_thresholds_met
test_non_captain_hold_decisions_are_ignored
test_mixed_verb_array_counts_only_captain_hold
test_missing_created_at_does_not_fire_time_threshold
test_single_decision_does_not_fire_any_threshold
test_exactly_48h_old_fires_time_threshold
test_four_decisions_with_one_old_does_not_fire_bundle
test_usage_error_on_unknown_option
test_usage_error_on_missing_input_file
test_invalid_json_is_a_usage_error
test_non_array_json_is_a_usage_error
test_declared_priority_rows_dont_affect_count
test_empty_input_pipe_is_no_nudge
test_input_via_flag
test_input_via_flag_on_missing_file
