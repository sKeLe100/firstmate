#!/usr/bin/env bash
# Behavior tests for fm-watch.sh's quota_loop_hold_check: the one live caller
# of bin/fm-classify-lib.sh's status_provider_quota_loop classifier. A `hold`
# verdict must interrupt and captain-hold the task exactly once per genuinely
# new quota-exhaustion streak, never twice for the same unchanged status file,
# and - critically - it must still fire for a SECOND, fully independent
# back-to-back loop that occurs after the task recovered from the first one,
# even though the windowed streak count (bin/fm-classify-lib.sh
# status_quota_exhaustion_count) resets to the same value both times.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-quota-loop-hold)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects"

export FM_HOME="$HOME_DIR"
export FM_STATE_OVERRIDE="$HOME_DIR/state"
export FM_DATA_OVERRIDE="$HOME_DIR/data"
export FM_CONFIG_OVERRIDE="$HOME_DIR/config"
export FM_PROJECTS_OVERRIDE="$HOME_DIR/projects"

# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

WAKES_LOG="$TMP_ROOT/wakes.log"
: > "$WAKES_LOG"
fm_wake_append() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$WAKES_LOG"; }
wake() { printf 'woke:%s\n' "$1" >> "$WAKES_LOG"; }
# fm-control.sh/fm-captain-hold.sh are best-effort side effects
# (quota_loop_hold_check swallows their failures); there is no real task
# endpoint in this hermetic test, so let them fail silently as designed.

wake_count() { grep -c '^woke:' "$WAKES_LOG" 2>/dev/null || true; }

test_first_loop_fires_once_then_dedupes() {
  local task=quota-hold-t1 statusf
  statusf="$STATE/$task.status"
  : > "$WAKES_LOG"
  printf 'working: hit RESOURCE_EXHAUSTED\n' > "$statusf"
  printf 'working: Quota exceeded again\n' >> "$statusf"

  quota_loop_hold_check "$task"
  [ "$(wake_count)" = 1 ] || fail "a genuine back-to-back quota loop must interrupt and hold exactly once, got $(wake_count) wakes"
  [ -f "$STATE/.quota-hold-$task" ] || fail "a fired hold must persist its dedup marker"

  quota_loop_hold_check "$task"
  [ "$(wake_count)" = 1 ] || fail "re-polling the same unchanged status file must not re-fire the hold, got $(wake_count) wakes"
  pass "fm-watch.sh: a quota loop interrupts and holds once, then dedupes on the unchanged status file"
}

test_second_independent_loop_after_recovery_still_fires() {
  local task=quota-hold-t2 statusf
  statusf="$STATE/$task.status"
  : > "$WAKES_LOG"
  printf 'working: hit RESOURCE_EXHAUSTED\n' > "$statusf"
  printf 'working: Quota exceeded again\n' >> "$statusf"
  quota_loop_hold_check "$task"
  [ "$(wake_count)" = 1 ] || fail "the first back-to-back loop must fire, got $(wake_count) wakes"

  # The task recovers: a non-exhaustion status line resets the windowed streak
  # (bin/fm-classify-lib.sh status_quota_exhaustion_count) back to 0, and the
  # task does real, unrelated work for a while.
  printf 'working: resumed and made real progress\n' >> "$statusf"
  printf 'done: unrelated work finished\n' >> "$statusf"
  quota_loop_hold_check "$task"
  [ "$(wake_count)" = 1 ] || fail "a recovered task doing real work must not re-fire the hold, got $(wake_count) wakes"

  # A second, fully independent back-to-back loop reaches the SAME windowed
  # streak count (2) as the first one. It must still fire: the marker must key
  # off status-file growth, not the windowed count, or this silently vanishes.
  printf 'working: hit RESOURCE_EXHAUSTED once more\n' >> "$statusf"
  printf 'working: quota exceeded yet again\n' >> "$statusf"
  quota_loop_hold_check "$task"
  [ "$(wake_count)" = 2 ] || fail "a second, independent back-to-back quota loop reaching the same streak count must still interrupt and hold, got $(wake_count) wakes"
  pass "fm-watch.sh: a second independent quota loop after recovery still interrupts and holds"
}

test_first_loop_fires_once_then_dedupes
test_second_independent_loop_after_recovery_still_fires

echo "# all fm-watch-quota-loop-hold tests passed"
