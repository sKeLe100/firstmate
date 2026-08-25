#!/usr/bin/env bash
# tests/fm-llm-usage-lib.test.sh - the firstmate-side LLM usage telemetry
# writer (bin/fm-llm-usage-lib.sh), the shared append-only archive contract
# documented in docs/llm-usage-telemetry.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-llm-usage-lib.sh"

require_python3() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required by this test to validate JSONL output"
}

test_emit_writes_one_valid_json_line_per_call() {
  require_python3
  local home archive
  home=$(fm_test_tmproot fm-llm-usage) || fail "could not create a temp home"
  mkdir -p "$home/state"
  archive="$home/data/llm-usage/firstmate.jsonl"

  fm_llm_usage_emit "$home/data" "$home/state" dispatch \
    "task_id=t1" "kind=ship" "purpose=code" "harness=claude" "model=default"
  fm_llm_usage_emit "$home/data" "$home/state" outcome \
    "task_id=t1" "kind=ship" "result=landed"

  [ -f "$archive" ] || fail "fm_llm_usage_emit did not create the archive file"
  [ "$(wc -l < "$archive" | tr -d ' ')" = 2 ] \
    || fail "expected exactly one JSON line per emit call, got: $(cat "$archive")"

  python3 - "$archive" <<'PY' || fail "archive does not parse as one JSON object per line"
import json, sys
for line in open(sys.argv[1]):
    obj = json.loads(line)
    assert obj["schema_version"] == 1
    assert obj["source"] == "firstmate"
    assert "event_type" in obj and obj["event_type"] in ("dispatch", "outcome")
PY
  pass "fm_llm_usage_emit: writes one valid JSON object per call, never rewriting the file"
}

test_emit_omits_empty_fields_rather_than_writing_empty_strings() {
  require_python3
  local home archive
  home=$(fm_test_tmproot fm-llm-usage) || fail "could not create a temp home"
  mkdir -p "$home/state"
  archive="$home/data/llm-usage/firstmate.jsonl"

  fm_llm_usage_emit "$home/data" "$home/state" dispatch "task_id=t2" "mode=" "purpose=planning"

  python3 - "$archive" <<'PY' || fail "empty-valued field was not omitted"
import json, sys
obj = json.loads(open(sys.argv[1]).readline())
assert "mode" not in obj, obj
assert obj["purpose"] == "planning"
PY
  pass "fm_llm_usage_emit: an empty field value is omitted, not written as an empty string"
}

test_emit_escapes_quotes_and_newlines_safely() {
  require_python3
  local home archive
  home=$(fm_test_tmproot fm-llm-usage) || fail "could not create a temp home"
  mkdir -p "$home/state"
  archive="$home/data/llm-usage/firstmate.jsonl"

  fm_llm_usage_emit "$home/data" "$home/state" delegation "task_id=t3" 'reason=said "hello"
and a new line'

  [ "$(wc -l < "$archive" | tr -d ' ')" = 1 ] \
    || fail "an embedded newline in a field value must not create a second JSONL record"
  python3 - "$archive" <<'PY' || fail "quoted/newline reason field did not round-trip"
import json, sys
obj = json.loads(open(sys.argv[1]).readline())
assert obj["reason"] == 'said "hello"\nand a new line', obj["reason"]
PY
  pass "fm_llm_usage_emit: quotes and embedded newlines are escaped, keeping one record per call"
}

test_emit_never_fails_when_home_is_unwritable() {
  local home
  home=$(fm_test_tmproot fm-llm-usage) || fail "could not create a temp home"
  mkdir -p "$home/state"
  chmod 000 "$home"
  # Root and some CI sandboxes bypass permission bits entirely; skip rather
  # than assert a guarantee the environment cannot actually exercise.
  if [ -w "$home" ]; then
    chmod 755 "$home"
    pass "fm_llm_usage_emit: skipped (unwritable-home check not enforceable as this user)"
    return 0
  fi
  fm_llm_usage_emit "$home/data" "$home/state" dispatch "task_id=t4"
  local status=$?
  chmod 755 "$home"
  [ "$status" -eq 0 ] \
    || fail "fm_llm_usage_emit must return success even when the archive cannot be written, so a dispatch is never blocked by telemetry"
  pass "fm_llm_usage_emit: an unwritable archive location never fails the caller"
}

test_emit_writes_are_append_only_across_calls() {
  require_python3
  local home archive first_line
  home=$(fm_test_tmproot fm-llm-usage) || fail "could not create a temp home"
  mkdir -p "$home/state"
  archive="$home/data/llm-usage/firstmate.jsonl"

  fm_llm_usage_emit "$home/data" "$home/state" dispatch "task_id=t5" "purpose=review"
  first_line=$(cat "$archive")
  fm_llm_usage_emit "$home/data" "$home/state" outcome "task_id=t5" "result=abandoned"

  [ "$(sed -n '1p' "$archive")" = "$first_line" ] \
    || fail "an earlier record was rewritten instead of a new one appended"
  [ "$(wc -l < "$archive" | tr -d ' ')" = 2 ] \
    || fail "expected the archive to grow by append, not by in-place rewrite"
  pass "fm_llm_usage_emit: prior records are never rewritten, only appended to"
}

test_emit_escapes_c0_control_characters_as_json_escapes() {
  require_python3
  local home archive reason
  home=$(fm_test_tmproot fm-llm-usage) || fail "could not create a temp home"
  mkdir -p "$home/state"
  archive="$home/data/llm-usage/firstmate.jsonl"

  reason=$(printf 'form\ffeed esc\033 bell\a low\001 back\bspace')
  fm_llm_usage_emit "$home/data" "$home/state" delegation "task_id=t6" "reason=$reason"

  python3 - "$archive" <<'PY' || fail "a reason carrying C0 control bytes produced an unparseable record"
import json, sys
obj = json.loads(open(sys.argv[1]).readline())
expected = "form\ffeed esc\x1b bell\a low\x01 back\bspace"
assert obj["reason"] == expected, repr(obj["reason"])
PY
  pass "fm_llm_usage_emit: C0 control characters stay parseable and round-trip exactly"
}

test_emit_diverts_write_failures_into_the_error_log_not_the_caller_stderr() {
  local home stderr_file
  home=$(fm_test_tmproot fm-llm-usage) || fail "could not create a temp home"
  mkdir -p "$home/state" "$home/data"
  stderr_file="$home/caller-stderr"
  chmod 500 "$home/data"
  # Root and some CI sandboxes bypass permission bits entirely; skip rather
  # than assert a guarantee the environment cannot actually exercise.
  if [ -w "$home/data" ]; then
    chmod 755 "$home/data"
    pass "fm_llm_usage_emit: skipped (unwritable-archive-dir check not enforceable as this user)"
    return 0
  fi

  fm_llm_usage_emit "$home/data" "$home/state" dispatch "task_id=t7" 2>"$stderr_file"
  local status=$?
  chmod 755 "$home/data"

  [ "$status" -eq 0 ] \
    || fail "fm_llm_usage_emit must return success even when the archive directory cannot be created"
  [ ! -s "$stderr_file" ] \
    || fail "a telemetry write failure leaked to the caller's stderr: $(cat "$stderr_file")"
  [ -s "$home/state/llm-usage-write-errors.log" ] \
    || fail "a telemetry write failure was not recorded in llm-usage-write-errors.log"
  pass "fm_llm_usage_emit: a write failure lands in the error log and never on the caller's stderr"
}

test_emit_writes_one_valid_json_line_per_call
test_emit_omits_empty_fields_rather_than_writing_empty_strings
test_emit_escapes_quotes_and_newlines_safely
test_emit_never_fails_when_home_is_unwritable
test_emit_writes_are_append_only_across_calls
test_emit_escapes_c0_control_characters_as_json_escapes
test_emit_diverts_write_failures_into_the_error_log_not_the_caller_stderr
