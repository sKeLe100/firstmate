#!/usr/bin/env bash
# tests/fm-dispatch-calibration.test.sh - read-only replay of recorded dispatch
# decisions against the LLM usage telemetry archive
# (bin/fm-dispatch-calibration.sh, docs/llm-usage-telemetry.md).
# Proves the outcome join (terminal outcome, redelegation, issue-triggered
# delegation), unresolved exclusion, per-band reliability table, Brier score,
# FM_DATA_OVERRIDE defaulting, malformed records, and that the helper never
# mutates the archive.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-dispatch-calibration.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-calibration)

require_python3() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required by this test to validate JSON output"
}

archive_fixture() {  # <path>
  cat > "$1" <<'EOF'
{"schema_version":1,"ts":"2026-11-01T00:00:00Z","source":"firstmate","event_type":"dispatch","task_id":"a","decision_record":"{\"confidence\":90,\"chosen_profile\":\"opus\"}"}
{"schema_version":1,"ts":"2026-11-01T01:00:00Z","source":"firstmate","event_type":"outcome","task_id":"a","result":"landed"}
{"schema_version":1,"ts":"2026-11-01T00:00:00Z","source":"firstmate","event_type":"dispatch","task_id":"b","decision_record":"{\"confidence\":80,\"chosen_profile\":\"sonnet\"}"}
{"schema_version":1,"ts":"2026-11-01T01:00:00Z","source":"firstmate","event_type":"outcome","task_id":"b","result":"abandoned"}
{"schema_version":1,"ts":"2026-11-01T00:00:00Z","source":"firstmate","event_type":"dispatch","task_id":"c","decision_record":"{\"confidence\":60,\"chosen_profile\":\"go\"}"}
{"schema_version":1,"ts":"2026-11-01T02:00:00Z","source":"firstmate","event_type":"dispatch","task_id":"c2","from_task_id":"c"}
{"schema_version":1,"ts":"2026-11-01T00:00:00Z","source":"firstmate","event_type":"dispatch","task_id":"d","decision_record":"{\"confidence\":50}"}
{"schema_version":1,"ts":"2026-11-01T00:00:00Z","source":"firstmate","event_type":"dispatch","task_id":"e","decision_record":"{\"confidence\":95}"}
{"schema_version":1,"ts":"2026-11-01T01:00:00Z","source":"firstmate","event_type":"delegation","task_id":"e","had_issue":"true","trigger":"relaunch"}
{"schema_version":1,"ts":"2026-11-01T00:00:00Z","source":"firstmate","event_type":"dispatch","task_id":"f"}
{"schema_version":1,"ts":"2026-11-01T00:00:00Z","source":"firstmate","event_type":"dispatch","task_id":"g","decision_record":"not-json"}
EOF
}

test_reports_brier_and_reliability_bands() {
  require_python3
  local dir out
  dir="$TMP_ROOT/replay-$RANDOM"
  mkdir -p "$dir"
  archive_fixture "$dir/archive.jsonl"

  out=$("$HELPER" --archive "$dir/archive.jsonl" --json) || fail "helper failed on a fixture archive"

  python3 - "$out" <<'PY' || fail "calibration summary did not match the fixture"
import json, sys
got = json.loads(sys.argv[1])
assert got["decisions"] == 5, got
assert got["resolved"] == 4, got
assert got["unresolved"] == 1, got
assert abs(got["brier"] - 0.478125) < 1e-9, got["brier"]
bands = {b["band"]: b for b in got["bands"]}
assert set(bands) == {"60-69", "80-89", "90-100"}, bands
assert bands["60-69"]["n"] == 1 and bands["60-69"]["observed"] == 0, bands["60-69"]
assert bands["80-89"]["n"] == 1 and bands["80-89"]["observed"] == 0, bands["80-89"]
assert bands["90-100"]["n"] == 2 and abs(bands["90-100"]["mean_confidence"] - 92.5) < 1e-9, bands["90-100"]
PY
  pass "fm-dispatch-calibration.sh: joins outcomes to decisions and reports Brier plus reliability bands"
}

test_text_output_is_human_readable() {
  local dir out
  dir="$TMP_ROOT/text-$RANDOM"
  mkdir -p "$dir"
  archive_fixture "$dir/archive.jsonl"

  out=$("$HELPER" --archive "$dir/archive.jsonl") || fail "helper failed on a fixture archive"
  assert_contains "$out" "decisions=5 resolved=4 unresolved=1 brier=0.4781" "summary line is missing or wrong"
  assert_contains "$out" "band" "reliability table header is missing"
  assert_contains "$out" "90-100" "the top confidence band is missing"
  pass "fm-dispatch-calibration.sh: text mode prints a summary line and a reliability table"
}

test_unresolved_and_decisionless_records_are_excluded() {
  require_python3
  local dir out
  dir="$TMP_ROOT/unresolved-$RANDOM"
  mkdir -p "$dir"
  archive_fixture "$dir/archive.jsonl"

  out=$("$HELPER" --archive "$dir/archive.jsonl" --json) || fail "helper failed"
  python3 - "$out" <<'PY' || fail "unresolved tasks leaked into the score"
import json, sys
got = json.loads(sys.argv[1])
# Five dispatches carry a parseable decision record (a,b,c,d,e); the
# decisionless spawn and the malformed one are not decisions at all.
assert got["decisions"] == 5, got
# Only d stays unresolved: it has no outcome, no redelegation, no issue retry.
assert got["unresolved"] == 1, got
PY
  pass "fm-dispatch-calibration.sh: decisionless and malformed records are ignored, unresolved tasks excluded"
}

test_defaults_to_the_overridden_data_dir() {
  require_python3
  local home out
  home="$TMP_ROOT/default-path-$RANDOM"
  mkdir -p "$home/data/llm-usage"
  archive_fixture "$home/data/llm-usage/firstmate.jsonl"

  out=$(cd /tmp && FM_HOME="$home" "$HELPER" --json) || fail "helper failed on its default archive path"
  python3 - "$out" <<'PY' || fail "FM_HOME default did not resolve the archive"
import json, sys
got = json.loads(sys.argv[1])
assert got["decisions"] == 5, got
PY
  out=$(cd /tmp && FM_HOME=/nonexistent FM_DATA_OVERRIDE="$home/data" "$HELPER" --json) \
    || fail "helper failed with FM_DATA_OVERRIDE"
  python3 - "$out" <<'PY' || fail "FM_DATA_OVERRIDE default did not resolve the archive"
import json, sys
got = json.loads(sys.argv[1])
assert got["decisions"] == 5, got
PY
  pass "fm-dispatch-calibration.sh: defaults to FM_HOME/data and honors FM_DATA_OVERRIDE"
}

test_empty_and_missing_archives() {
  require_python3
  local dir out rc
  dir="$TMP_ROOT/empty-$RANDOM"
  mkdir -p "$dir"
  : > "$dir/empty.jsonl"

  out=$("$HELPER" --archive "$dir/empty.jsonl" --json) || fail "an empty archive should report zero, not fail"
  python3 - "$out" <<'PY' || fail "empty archive did not report zero decisions and a null Brier score"
import json, sys
got = json.loads(sys.argv[1])
assert got["decisions"] == 0, got
assert got["resolved"] == 0, got
assert got["brier"] is None, got
assert got["bands"] == [], got
PY

  rc=0
  out=$("$HELPER" --archive "$dir/missing.jsonl" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing archive should be an error"
  assert_contains "$out" "archive not found" "missing-archive error was not explained"
  pass "fm-dispatch-calibration.sh: empty archives report zero; a missing archive is a clear error"
}

test_is_read_only() {
  local dir before after
  dir="$TMP_ROOT/readonly-$RANDOM"
  mkdir -p "$dir"
  archive_fixture "$dir/archive.jsonl"
  before=$(cksum < "$dir/archive.jsonl")

  "$HELPER" --archive "$dir/archive.jsonl" >/dev/null || fail "helper failed"

  after=$(cksum < "$dir/archive.jsonl")
  assert_equals "$before" "$after" "the calibration helper modified the archive"
  pass "fm-dispatch-calibration.sh: reads the archive without writing it"
}

test_reports_brier_and_reliability_bands
test_text_output_is_human_readable
test_unresolved_and_decisionless_records_are_excluded
test_defaults_to_the_overridden_data_dir
test_empty_and_missing_archives
test_is_read_only
