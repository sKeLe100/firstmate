#!/usr/bin/env bash
# Unit tests for fm-watch.sh's pc02-staleness-cadence: the opencode+pc02
# lane's raised idle floor and the opencode-log loop-step liveness read that
# together keep a working PC02 crew from being misread as wedged
# (data/pc02-followthrough-gap-assessment/report.md).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-pc02-cadence)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects"

export FM_HOME="$HOME_DIR"
export FM_STATE_OVERRIDE="$HOME_DIR/state"
export FM_DATA_OVERRIDE="$HOME_DIR/data"
export FM_CONFIG_OVERRIDE="$HOME_DIR/config"
export FM_PROJECTS_OVERRIDE="$HOME_DIR/projects"
export FM_OPENCODE_LOG="$TMP_ROOT/opencode.log"

# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

# Stub the wedge path's side effects so wedge_timer_check runs hermetically.
WAKES_LOG="$TMP_ROOT/wakes.log"
fm_wake_append() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$WAKES_LOG"; }
wake() { :; }
triage_log() { :; }
crew_worktree_written_since() { return 1; }

write_meta() {  # <task> <harness> <model>
  printf 'window=firstmate:fm-%s\nharness=%s\nkind=ship\nmodel=%s\n' "$1" "$2" "$3" \
    > "$STATE/$1.meta"
}

log_step_at() {  # <iso-timestamp>
  printf 'timestamp=%s level=INFO run=deadbeef message=loop session.id=ses_x step=3\n' "$1" \
    >> "$FM_OPENCODE_LOG"
}

reset_case() {
  : > "$WAKES_LOG"
  rm -f "$FM_OPENCODE_LOG" "$STATE"/.stale-since-* "$STATE"/.wedge-escalations-* "$STATE"/.wedge-backoff-*
}

test_lane_classifier() {
  write_meta pc02-task opencode pc02-llamaswap/qwen3.6-35b-a3b-dispatch
  write_meta cloud-task claude claude-sonnet-5
  pc02_lane_task pc02-task || fail "opencode+pc02 meta should classify as a pc02 lane"
  pc02_lane_task cloud-task && fail "claude meta must not classify as a pc02 lane"
  pc02_lane_task absent-task && fail "missing meta must not classify as a pc02 lane"
  pass "pc02_lane_task classifies by harness=opencode plus pc02-llamaswap/* model"
}

test_idle_floor_holds_escalation_below_600s() {
  reset_case
  write_meta pc02-task opencode pc02-llamaswap/qwen3.6-35b-a3b-dispatch
  since_file="$STATE/.stale-since-x1"
  esc_file="$STATE/.wedge-escalations-x1"
  echo "$(( $(date +%s) - 300 ))" > "$since_file"
  wedge_timer_check win1 "$since_file" test "$esc_file" pc02-task
  [ ! -s "$WAKES_LOG" ] || fail "300s idle must stay under the 600s pc02 floor: $(cat "$WAKES_LOG")"
  pass "a pc02 lane idle 300s does not escalate despite the 240s default threshold"
}

test_fresh_loop_step_resets_timer_instead_of_escalating() {
  reset_case
  write_meta pc02-task opencode pc02-llamaswap/qwen3.6-35b-a3b-dispatch
  since_file="$STATE/.stale-since-x2"
  esc_file="$STATE/.wedge-escalations-x2"
  echo "$(( $(date +%s) - 700 ))" > "$since_file"
  log_step_at "$(date -u -d '-60 seconds' +%Y-%m-%dT%H:%M:%S.000Z)"
  wedge_timer_check win2 "$since_file" test "$esc_file" pc02-task
  [ ! -s "$WAKES_LOG" ] || fail "a fresh loop step must absorb, not escalate: $(cat "$WAKES_LOG")"
  [ -s "$since_file" ] || fail "absorb must restart the quiet-spell timer"
  [ "$(( $(date +%s) - $(cat "$since_file") ))" -lt 60 ] || fail "restarted timer should be recent"
  pass "a loop step newer than the quiet spell restarts the timer without escalation"
}

test_stale_log_escalates_past_floor() {
  reset_case
  write_meta pc02-task opencode pc02-llamaswap/qwen3.6-35b-a3b-dispatch
  since_file="$STATE/.stale-since-x3"
  esc_file="$STATE/.wedge-escalations-x3"
  echo "$(( $(date +%s) - 700 ))" > "$since_file"
  log_step_at "$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%S.000Z)"
  wedge_timer_check win3 "$since_file" test "$esc_file" pc02-task
  grep -q "possible wedge" "$WAKES_LOG" || fail "700s idle with only stale loop steps must escalate"
  pass "a pc02 lane past the floor with no fresh loop step still escalates"
}

test_non_pc02_lane_keeps_default_threshold() {
  reset_case
  write_meta cloud-task claude claude-sonnet-5
  since_file="$STATE/.stale-since-x4"
  esc_file="$STATE/.wedge-escalations-x4"
  echo "$(( $(date +%s) - 300 ))" > "$since_file"
  wedge_timer_check win4 "$since_file" test "$esc_file" cloud-task
  grep -q "possible wedge" "$WAKES_LOG" || fail "a non-pc02 lane idle 300s must escalate at the 240s default"
  pass "non-pc02 lanes keep the default escalation threshold"
}

test_lane_classifier
test_idle_floor_holds_escalation_below_600s
test_fresh_loop_step_resets_timer_instead_of_escalating
test_stale_log_escalates_past_floor
test_non_pc02_lane_keeps_default_threshold

echo "# all fm-watch-pc02-cadence tests passed"
