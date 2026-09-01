#!/usr/bin/env bash
# Behavior tests for bin/fm-retry-pressure.sh: band derivation from durable
# records, threshold-file parsing, and zero-evidence defaults.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-retry-pressure)
HELPER="$ROOT/bin/fm-retry-pressure.sh"

mk_home() {
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/data/llm-usage" "$h/state" "$h/config"
  printf '%s' "$h"
}

emit() {  # <home> <task>
  FM_HOME="$1" "$HELPER" "$2"
}

field() {  # <line> <key>
  printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"
}

delegation_row() {  # <task>
  printf '{"event_type":"delegation","task_id":"%s","trigger":"relaunch"}\n' "$1"
}

test_fresh_home_reads_ok() {
  local home out
  home=$(mk_home fresh)
  out=$(emit "$home" some-task) || fail "helper failed on a fresh home"
  [ "$(field "$out" retry_band)" = "ok" ] || fail "fresh home is not ok: $out"
  [ "$(field "$out" relaunches)" = "0" ] || fail "fresh home relaunches not 0: $out"
  pass "fm-retry-pressure.sh: zero evidence reads ok with zero counts"
}
test_fresh_home_reads_ok

test_halt_at_relaunch_ceiling_and_reset_on_landed_outcome() {
  local home out t=halt-task
  home=$(mk_home halt)
  { delegation_row "$t"; delegation_row "$t"; delegation_row "$t"; } \
    >> "$home/data/llm-usage/firstmate.jsonl"
  out=$(emit "$home" "$t")
  [ "$(field "$out" retry_band)" = "halt" ] || fail "3 relaunches did not halt: $out"

  printf '{"event_type":"outcome","task_id":"%s","result":"landed"}\n' "$t" \
    >> "$home/data/llm-usage/firstmate.jsonl"
  out=$(emit "$home" "$t")
  [ "$(field "$out" retry_band)" = "ok" ] || fail "landed outcome did not reset count: $out"
  [ "$(field "$out" relaunches)" = "0" ] || fail "relaunch count not reset: $out"
  pass "fm-retry-pressure.sh: halt at the relaunch ceiling, reset by a landed outcome"
}
test_halt_at_relaunch_ceiling_and_reset_on_landed_outcome

test_worker_keyed_report_reads_loop() {
  local home out t=loop-task
  home=$(mk_home loop)
  printf 'blocked [key=retry-loop]: 2 fix no-ops, HEAD unmoved\n' > "$home/state/$t.status"
  out=$(emit "$home" "$t")
  [ "$(field "$out" retry_band)" = "loop" ] || fail "keyed retry-loop report not read as loop: $out"
  [ "$(field "$out" retry_loop_reported)" = "1" ] || fail "retry_loop_reported not set: $out"
  pass "fm-retry-pressure.sh: a worker's keyed retry-loop report reads as loop"
}
test_worker_keyed_report_reads_loop

test_resolved_keyed_line_clears_loop() {
  local home out t=resolved-task
  home=$(mk_home resolved)
  printf 'blocked [key=retry-loop]: 2 fix no-ops, HEAD unmoved\nresolved [key=retry-loop]: new approach, tests moving\n' > "$home/state/$t.status"
  out=$(emit "$home" "$t")
  [ "$(field "$out" retry_loop_reported)" = "0" ] || fail "resolved line did not clear the report: $out"
  [ "$(field "$out" retry_band)" = "ok" ] || fail "resolved retry-loop still reads loop: $out"
  printf 'blocked [key=retry-loop]: looping again\n' >> "$home/state/$t.status"
  out=$(emit "$home" "$t")
  [ "$(field "$out" retry_band)" = "loop" ] || fail "reopened retry-loop not read as loop: $out"
  pass "fm-retry-pressure.sh: a resolved keyed line clears the loop until it reopens"
}
test_resolved_keyed_line_clears_loop

test_thresholds_file_overrides_and_malformed_rejected() {
  local home out t=cfg-task
  home=$(mk_home cfg)
  delegation_row "$t" >> "$home/data/llm-usage/firstmate.jsonl"
  printf 'relaunch=1\n' > "$home/config/retry-thresholds"
  out=$(emit "$home" "$t")
  [ "$(field "$out" retry_band)" = "halt" ] || fail "relaunch=1 override not applied: $out"

  printf 'relaunch=zero\n' > "$home/config/retry-thresholds"
  if FM_HOME="$home" "$HELPER" "$t" >/dev/null 2>&1; then
    fail "malformed config/retry-thresholds was not rejected"
  fi
  pass "fm-retry-pressure.sh: threshold file overrides apply and malformed files fail loudly"
}
test_thresholds_file_overrides_and_malformed_rejected
