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
  [ "$(field "$out" review_rounds)" = "none" ] || fail "fresh home has review evidence: $out"
  [ "$(field "$out" review_cap_reached)" = "0" ] || fail "fresh home reached review cap: $out"
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

test_non_object_telemetry_line_is_zero_evidence() {
  local home out t=junk-task
  home=$(mk_home junk)
  { printf '123\n'; printf '[1,2]\n'; printf '"x"\n'; delegation_row "$t"; } \
    >> "$home/data/llm-usage/firstmate.jsonl"
  out=$(emit "$home" "$t") || fail "non-object telemetry line aborted the helper"
  [ "$(field "$out" relaunches)" = "1" ] || fail "non-object lines skewed the count: $out"
  [ "$(field "$out" retry_band)" = "ok" ] || fail "non-object telemetry did not read ok: $out"
  pass "fm-retry-pressure.sh: non-object telemetry lines are zero evidence, not an error"
}
test_non_object_telemetry_line_is_zero_evidence

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

test_note_head_key_and_captain_held_follow_shared_fold() {
  local home out t=fold-task
  home=$(mk_home fold)
  printf 'blocked: [key=retry-loop] 2 fix no-ops, HEAD unmoved\n' > "$home/state/$t.status"
  out=$(emit "$home" "$t")
  [ "$(field "$out" retry_band)" = "loop" ] || fail "note-head keyed report not read as loop: $out"
  printf 'captain-held [key=retry-loop]: tracked by the captain\n' >> "$home/state/$t.status"
  out=$(emit "$home" "$t")
  [ "$(field "$out" retry_loop_reported)" = "0" ] || fail "captain-held close did not clear the report: $out"
  [ "$(field "$out" retry_band)" = "ok" ] || fail "captain-held retry-loop still reads loop: $out"
  pass "fm-retry-pressure.sh: keyed retry-loop reads follow the shared status-key fold"
}
test_note_head_key_and_captain_held_follow_shared_fold

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

test_needs_decision_keyed_report_reads_loop() {
  local home out t=nd-task
  home=$(mk_home nd)
  printf 'needs-decision [key=retry-loop]: 4 review rounds, which approach do you want?\n' > "$home/state/$t.status"
  out=$(emit "$home" "$t")
  [ "$(field "$out" retry_loop_reported)" = "1" ] || fail "needs-decision keyed report not read as open: $out"
  [ "$(field "$out" retry_band)" = "loop" ] || fail "needs-decision keyed report not read as loop: $out"
  printf 'resolved [key=retry-loop]: captain picked an approach\n' >> "$home/state/$t.status"
  out=$(emit "$home" "$t")
  [ "$(field "$out" retry_band)" = "ok" ] || fail "resolved line did not clear needs-decision loop: $out"
  pass "fm-retry-pressure.sh: an open needs-decision retry-loop key reads as loop"
}
test_needs_decision_keyed_report_reads_loop

test_thresholds_file_without_trailing_newline_applies() {
  local home out t=nonl-task
  home=$(mk_home nonl)
  printf 'relaunch=1' > "$home/config/retry-thresholds"
  delegation_row "$t" > "$home/data/llm-usage/firstmate.jsonl"
  out=$(emit "$home" "$t")
  [ "$(field "$out" relaunch_ceiling)" = "1" ] || fail "unterminated last line not parsed: $out"
  [ "$(field "$out" retry_band)" = "halt" ] || fail "unterminated ceiling not applied: $out"
  printf 'relaunch=zero' > "$home/config/retry-thresholds"
  if emit "$home" "$t" >/dev/null 2>&1; then
    fail "malformed unterminated last line did not fail loudly"
  fi
  rm -f "$home/config/retry-thresholds"
  mkdir -p "$home/config/retry-thresholds"
  if emit "$home" "$t" >/dev/null 2>&1; then
    fail "a directory config file did not fail loudly"
  fi
  pass "fm-retry-pressure.sh: config parsing matches the sibling helper's contract"
}
test_thresholds_file_without_trailing_newline_applies

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

test_directory_overrides_are_honored() {
  local home out t=ovr-task
  home=$(mk_home ovr)
  mkdir -p "$home/alt-state" "$home/alt-data/llm-usage"
  { delegation_row "$t"; delegation_row "$t"; delegation_row "$t"; } \
    >> "$home/alt-data/llm-usage/firstmate.jsonl"
  printf 'blocked [key=retry-loop]: 2 fix no-ops, HEAD unmoved\n' > "$home/alt-state/$t.status"
  out=$(FM_STATE_OVERRIDE="$home/alt-state" FM_DATA_OVERRIDE="$home/alt-data" emit "$home" "$t")
  [ "$(field "$out" relaunches)" = "3" ] || fail "FM_DATA_OVERRIDE telemetry not read: $out"
  [ "$(field "$out" retry_loop_reported)" = "1" ] || fail "FM_STATE_OVERRIDE status not read: $out"
  [ "$(field "$out" retry_band)" = "halt" ] || fail "override evidence did not reach halt: $out"
  pass "fm-retry-pressure.sh: FM_STATE_OVERRIDE/FM_DATA_OVERRIDE resolve like the writers"
}
test_directory_overrides_are_honored

test_config_override_is_honored_for_thresholds() {
  local home out t=cfg-ovr-task
  home=$(mk_home cfgovr)
  mkdir -p "$home/alt-config"
  printf 'relaunch=1\nrounds=7\n' > "$home/alt-config/retry-thresholds"
  printf 'relaunch=9\n' > "$home/config/retry-thresholds"
  { delegation_row "$t"; delegation_row "$t"; } >> "$home/data/llm-usage/firstmate.jsonl"
  out=$(FM_CONFIG_OVERRIDE="$home/alt-config" emit "$home" "$t")
  [ "$(field "$out" relaunch_ceiling)" = "1" ] || fail "FM_CONFIG_OVERRIDE thresholds not read: $out"
  [ "$(field "$out" round_ceiling)" = "7" ] || fail "FM_CONFIG_OVERRIDE rounds not read: $out"
  [ "$(field "$out" retry_band)" = "halt" ] || fail "override ceiling did not reach halt: $out"
  pass "fm-retry-pressure.sh: FM_CONFIG_OVERRIDE resolves the thresholds file like the config writer"
}
test_config_override_is_honored_for_thresholds

test_review_counts_survive_runs_and_duplicate_reports() {
  local home out t=reviews
  home=$(mk_home reviews)
  cat > "$home/state/$t.status" <<'EOF'
working [at=1]: review_rounds: beta=1 run=nm-old
working [at=2]: review_rounds: alpha=2 run=nm-old
working [at=3]: review_rounds: alpha=2 run=nm-old
done [at=4]: implementation ready
working [at=5]: review_rounds: alpha=1 run=nm-new
EOF
  out=$(emit "$home" "$t")
  [ "$(field "$out" review_rounds)" = "alpha=2,beta=1" ] || fail "counts reset or duplicated: $out"
  [ "$(field "$out" review_cap_reached)" = "0" ] || fail "distinct reviewers were summed: $out"
  printf 'working: review_rounds: alpha=3 run=nm-new\nresolved [key=review-cap]: delivered\n' >> "$home/state/$t.status"
  out=$(emit "$home" "$t")
  [ "$(field "$out" review_rounds)" = "alpha=3,beta=1" ] || fail "cumulative count missing: $out"
  [ "$(field "$out" review_cap_reached)" = "1" ] || fail "cap not flagged at 3: $out"
  [ "$(field "$out" retry_band)" = "ok" ] || fail "review cap changed general band: $out"
  printf 'working: review_rounds: beta=4 run=nm-followup\n' >> "$home/state/$t.status"
  out=$(emit "$home" "$t")
  [ "$(field "$out" review_cap_reached)" = "1" ] || fail "count above cap not flagged: $out"
  pass "fm-retry-pressure.sh: cumulative per-reviewer counts survive runs, duplicates, and resolved reports"
}
test_review_counts_survive_runs_and_duplicate_reports

test_review_reports_require_valid_count_and_run_id() {
  local home out t=legacy-reviews
  home=$(mk_home legacy-reviews)
  cat > "$home/state/$t.status" <<'EOF'
working: review_rounds: alpha=3
working: review_rounds: alpha=3 run=
working: review_rounds: alpha=-3 run=nm-one
working: review_rounds: alpha=3oops run=nm-one
working: review_rounds: alpha=03 run=nm-one
working: review_rounds: alpha=3.5 run=nm-one
EOF
  out=$(emit "$home" "$t")
  [ "$(field "$out" review_rounds)" = "none" ] || fail "invalid report counted: $out"
  [ "$(field "$out" review_cap_reached)" = "0" ] || fail "legacy evidence flagged cap: $out"
  printf 'blocked [key=retry-loop]: legacy round ceiling reached\n' >> "$home/state/$t.status"
  out=$(emit "$home" "$t")
  [ "$(field "$out" retry_band)" = "loop" ] || fail "legacy fallback band lost: $out"
  mkdir -p "$home/alt-state"
  printf 'working: review_rounds: reviewer-1.v2=3 run=nm-carried\n' > "$home/alt-state/$t.status"
  out=$(FM_STATE_OVERRIDE="$home/alt-state" emit "$home" "$t")
  [ "$(field "$out" review_rounds)" = "reviewer-1.v2=3" ] || fail "override/carried counts lost: $out"
  [ "$(field "$out" review_cap_reached)" = "1" ] || fail "carried cap lost: $out"
  out=$(FM_STATE_OVERRIDE="$home/alt-state" emit "$home" unrelated-task)
  [ "$(field "$out" review_rounds)" = "none" ] || fail "other task's counts leaked: $out"
  pass "fm-retry-pressure.sh: missing run ids and malformed counts retain general bands; carried counts honor task and state override"
}
test_review_reports_require_valid_count_and_run_id

test_retry_thresholds_is_inheritable_config() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-config-inherit-lib.sh"
  case " $FM_INHERITABLE_CONFIG " in
    *" retry-thresholds "*) ;;
    *) fail "config/retry-thresholds must be in FM_INHERITABLE_CONFIG so secondmate homes inherit the thresholds" ;;
  esac
  pass "fm-retry-pressure.sh: config/retry-thresholds is inherited by secondmate homes"
}
test_retry_thresholds_is_inheritable_config
