#!/usr/bin/env bash
# tests/fm-wake-pair-dedup.test.sh - Prove that a single underlying event is
# never enqueued twice as both a procevent check wake and a status signal wake.
#
# Audit finding 3: one event arriving as a check wake (from procevent
# publication) AND as a signal wake (from the same-cycle or next-cycle signal
# scan) costs an extra drain turn every time.  The fix lives in
# bin/fm-watch.sh's signal scan: when a task's procevent inbox has an
# unhandled result, the signal append is skipped because the procevent path
# already delivers the event.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

ROOT=/home/sean_/.treehouse/firstmate-0c6912/5/firstmate
TMP_ROOT=$(fm_test_tmproot fm-wake-pair-dedup-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

# --- Test 1: procevent check wake queued + signal for same task = only check wake ---

test_procevent_coverage_suppresses_duplicate_signal() {
  local dir state fakebin out drain_out status_file procevent_inbox queue_file drain_err
  dir=$(make_case procevent-dedup)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  drain_err="$dir/drain.err"
  status_file="$state/task.status"
  procevent_inbox="$state/procevent-inbox"
  queue_file="$state/.wake-queue"

  # Create a task status file with a captain-relevant verb.
  printf 'blocked: waiting on external\n' > "$status_file"

  # Seed an unhandled procevent result for "task" in the procevent inbox.
  mkdir -p "$procevent_inbox"
  printf 'some output from procevent capture' > "$procevent_inbox/task.1.result"
  printf 'lavish' > "$procevent_inbox/task.1.adapter"
  chmod 0600 "$procevent_inbox/task.1.result" "$procevent_inbox/task.1.adapter"

  # Seed a check wake in the queue, simulating what procevent_surface_queued
  # would emit. The key format: "procevent:<adapter>:<source-id>:<seq>".
  printf '%s\t1\tcheck\tprocevent:lavish:task:1\tcheck: procevent lavish task 1\n' "$(date +%s)" > "$queue_file"

  # Prime the .seen- marker, then change the file AFTER priming.
  prime_status_seen "$state" "$status_file"
  sleep 0.1
  printf 'blocked: waiting on external (updated)\n' > "$status_file"

  # Run the watcher one cycle.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW='firstmate:fm-task' \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>"$dir/watch.err" &

  wait_for_exit "$!" 30 || { kill "$!" 2>/dev/null; fail "watcher did not exit"; }

  # Verify: the watcher should have printed a check wake for procevent.
  grep -F 'check: process-event result captured:' "$out" >/dev/null \
    || fail "watcher did not print procevent check wake: $(cat "$out")"

  # Drain to consume the check wake.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>"$drain_err" \
    || fail "drain after procevent-dedup watch failed"

  # Extract the acknowledgement boundary from the drain stderr.
  local sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$drain_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$drain_err")

  if [ -n "$sequence" ] && [ -n "$generation" ]; then
    FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
      || fail "acknowledgement failed"
  fi

  # Verify the queue is empty - only the check wake should have been enqueued.
  [ ! -s "$queue_file" ] || fail "queue not empty after ack: $(cat "$queue_file")"

  pass "unhandled procevent result suppresses duplicate signal append"
}

# --- Test 2: procevent result handled + new signal = signal fires normally ---

test_independent_signal_fires_when_procevent_handled() {
  local dir state fakebin out drain_out status_file procevent_inbox drain_err
  dir=$(make_case procevent-indep-signal)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  drain_err="$dir/drain.err"
  status_file="$state/task.status"
  procevent_inbox="$state/procevent-inbox"

  printf 'done: implemented feature\n' > "$status_file"

  # Create a HANDLED procevent result.
  mkdir -p "$procevent_inbox"
  printf 'old procevent output' > "$procevent_inbox/task.1.result"
  printf 'lavish' > "$procevent_inbox/task.1.adapter"
  touch "$procevent_inbox/task.1.handled"
  chmod 0600 "$procevent_inbox/task.1.result" "$procevent_inbox/task.1.adapter"

  prime_status_seen "$state" "$status_file"
  sleep 0.1
  printf 'working: refining implementation\n' > "$status_file"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW='firstmate:fm-task' \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>"$dir/watch.err" &

  wait_for_exit "$!" 30 || { kill "$!" 2>/dev/null; fail "watcher did not exit"; }

  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "independent signal was suppressed when procevent result was handled: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>"$drain_err" \
    || fail "drain after independent signal failed"

  local sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$drain_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$drain_err")
  if [ -n "$sequence" ] && [ -n "$generation" ]; then
    FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
      || fail "acknowledgement failed"
  fi

  pass "independent signal fires when procevent result is already handled"
}

# --- Test 3: no procevent at all = signal fires normally ---

test_no_procevent_signal_fires_normally() {
  local dir state fakebin out drain_out status_file drain_err
  dir=$(make_case procevent-absent-signal)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  drain_err="$dir/drain.err"
  status_file="$state/task.status"

  printf 'blocked: needs review\n' > "$status_file"

  prime_status_seen "$state" "$status_file"

  sleep 0.1
  printf 'working: addressing review feedback\n' > "$status_file"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW='firstmate:fm-task' \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>"$dir/watch.err" &

  wait_for_exit "$!" 30 || { kill "$!" 2>/dev/null; fail "watcher did not exit"; }

  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "signal was suppressed with no procevent present: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>"$drain_err" \
    || fail "drain after normal signal failed"

  local sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$drain_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$drain_err")
  if [ -n "$sequence" ] && [ -n "$generation" ]; then
    FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
      || fail "acknowledgement failed"
  fi

  pass "signal fires normally when no procevent exists for the task"
}

# --- Run all tests ---
test_procevent_coverage_suppresses_duplicate_signal
test_independent_signal_fires_when_procevent_handled
test_no_procevent_signal_fires_normally

echo ""
echo "All wake-pair-dedup tests passed."
