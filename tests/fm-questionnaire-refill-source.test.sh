#!/usr/bin/env bash
# Behavior tests for bin/fm-questionnaire-refill-source.sh: the questionnaire
# skill's empty-bundle Refill step must reuse a recent roundtable/roadmap
# report instead of paying for a fresh scout, per the captain's 2026-08-31
# ruling on questionnaire-skill-design call 2.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-questionnaire-refill-source)

touch_days_ago() {
  local path="$1" days="$2"
  local epoch
  epoch=$(( $(date +%s) - days * 86400 ))
  touch -d "@$epoch" "$path" 2>/dev/null || touch -t "$(date -r "$epoch" +%Y%m%d%H%M.%S)" "$path"
}

test_no_data_dir_fails() {
  local dir
  dir=$(mktemp -d "$TMP_ROOT/nodata-XXXXXX")

  if "$ROOT/bin/fm-questionnaire-refill-source.sh" --data-dir "$dir/data" >"$TMP_ROOT/capture.txt" 2>/dev/null; then
    fail "must exit nonzero when the data dir is absent"
  fi
  [ ! -s "$TMP_ROOT/capture.txt" ] || fail "must print nothing when no data dir exists"

  pass "fm-questionnaire-refill-source: absent data dir -> no match"
}

test_fresh_roundtable_report_is_offered() {
  local data_dir report
  data_dir="$TMP_ROOT/fresh/data"
  mkdir -p "$data_dir/roundtable-20260830"
  report="$data_dir/roundtable-20260830/report.md"
  printf '# Roundtable\ncandidate: still open\n' > "$report"
  touch_days_ago "$report" 1

  local out
  out=$("$ROOT/bin/fm-questionnaire-refill-source.sh" --data-dir "$data_dir" --max-age-days 3)

  [ "$out" = "$report" ] || fail "expected $report, got: $out"

  pass "fm-questionnaire-refill-source: report younger than the window is offered"
}

test_stale_report_is_not_offered() {
  local data_dir report
  data_dir="$TMP_ROOT/stale/data"
  mkdir -p "$data_dir/life-os-roadmap-review"
  report="$data_dir/life-os-roadmap-review/report.md"
  printf '# Roadmap review\n' > "$report"
  touch_days_ago "$report" 5

  if "$ROOT/bin/fm-questionnaire-refill-source.sh" --data-dir "$data_dir" --max-age-days 3 >"$TMP_ROOT/capture.txt" 2>/dev/null; then
    fail "a report older than the window must not be offered"
  fi
  [ ! -s "$TMP_ROOT/capture.txt" ] || fail "must print nothing for a stale-only data dir"

  pass "fm-questionnaire-refill-source: report older than the window is skipped"
}

test_newest_matching_report_wins() {
  local data_dir older newer
  data_dir="$TMP_ROOT/newest/data"
  mkdir -p "$data_dir/roundtable-old" "$data_dir/shop-design-roundtable"
  older="$data_dir/roundtable-old/report.md"
  newer="$data_dir/shop-design-roundtable/report.md"
  printf 'older\n' > "$older"
  printf 'newer\n' > "$newer"
  touch_days_ago "$older" 2
  touch_days_ago "$newer" 1

  local out
  out=$("$ROOT/bin/fm-questionnaire-refill-source.sh" --data-dir "$data_dir" --max-age-days 3)

  [ "$out" = "$newer" ] || fail "expected the newest matching report ($newer), got: $out"

  pass "fm-questionnaire-refill-source: newest matching report wins when several are fresh"
}

test_non_roundtable_reports_are_ignored() {
  local data_dir report
  data_dir="$TMP_ROOT/unrelated/data"
  mkdir -p "$data_dir/questionnaire-skill-design"
  report="$data_dir/questionnaire-skill-design/report.md"
  printf 'design report, not a roundtable\n' > "$report"
  touch_days_ago "$report" 0

  if "$ROOT/bin/fm-questionnaire-refill-source.sh" --data-dir "$data_dir" --max-age-days 3 >"$TMP_ROOT/capture.txt" 2>/dev/null; then
    fail "a design-scout report dir must not match the roundtable/roadmap glob"
  fi
  [ ! -s "$TMP_ROOT/capture.txt" ] || fail "must print nothing for an unrelated report dir"

  pass "fm-questionnaire-refill-source: non-roundtable/roadmap reports are ignored"
}

test_missing_option_value_is_a_usage_error() {
  local status
  set +e
  "$ROOT/bin/fm-questionnaire-refill-source.sh" --data-dir >/dev/null 2>&1
  status=$?
  set +e
  [ "$status" -eq 2 ] || fail "--data-dir without a value must exit 2, got: $status"

  set +e
  "$ROOT/bin/fm-questionnaire-refill-source.sh" --max-age-days >/dev/null 2>&1
  status=$?
  set +e
  [ "$status" -eq 2 ] || fail "--max-age-days without a value must exit 2, got: $status"

  set +e
  "$ROOT/bin/fm-questionnaire-refill-source.sh" --max-age-days not-a-number >/dev/null 2>&1
  status=$?
  set +e
  [ "$status" -eq 2 ] || fail "a non-numeric --max-age-days must exit 2, got: $status"

  pass "fm-questionnaire-refill-source: missing or non-numeric option value is a usage error, not a no-match"
}

test_roundtable_in_data_dir_path_does_not_match_everything() {
  local data_dir report
  data_dir="$TMP_ROOT/roundtable-workspace/data"
  mkdir -p "$data_dir/questionnaire-skill-design"
  report="$data_dir/questionnaire-skill-design/report.md"
  printf 'unrelated scout report\n' > "$report"
  touch_days_ago "$report" 0

  if "$ROOT/bin/fm-questionnaire-refill-source.sh" --data-dir "$data_dir" --max-age-days 3 >"$TMP_ROOT/capture.txt" 2>/dev/null; then
    fail "a data dir path containing 'roundtable' must not make every report match"
  fi
  [ ! -s "$TMP_ROOT/capture.txt" ] || fail "must print nothing when only unrelated reports exist"

  pass "fm-questionnaire-refill-source: data-dir prefix is not part of the roundtable match"
}

test_no_data_dir_fails
test_fresh_roundtable_report_is_offered
test_stale_report_is_not_offered
test_newest_matching_report_wins
test_non_roundtable_reports_are_ignored
test_missing_option_value_is_a_usage_error
test_roundtable_in_data_dir_path_does_not_match_everything
