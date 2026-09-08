#!/usr/bin/env bash
# tests/fm-watch-retry-band.test.sh - the heartbeat's retry-pressure reader in
# bin/fm-watch.sh. Split out of tests/fm-watch-triage.test.sh, which already sits
# at the per-file runtime cap: each of these cases drives a real fm-watch.sh
# subprocess, and appending them to that file pushed it past the cap.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-retry-band-tests)

size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }

# Signature a primed .seen-* marker must hold so the per-poll signal scan does
# not fire on a pre-existing status (mirrors fm-watch.sh's stat_sig exactly).
seen_sig() {
  local reported size ident
  reported=$(status_observed_signature "$1")
  size=$(size_of "$1")
  ident=$(_fm_open_decisions_file_ident "$1")
  printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
}

# Wait until <pid>'s watcher has completed a whole poll cycle, or exited first.
# The liveness beacon is touched at the TOP of every poll, so this drops any
# stale beacon, waits for a fresh one, then waits for it to advance; the cycle
# in between is what the caller's assertions describe.
wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# --- retry-band surfacing at the heartbeat ----------------------------------
# The context band already reaches supervision through this watcher; retry
# pressure was specified as a heartbeat duty in AGENTS.md with no reader in the
# tree, so a task past its relaunch ceiling stayed invisible until someone ran
# bin/fm-retry-pressure.sh by hand. FM_RETRY_PRESSURE_BIN points at a canned
# reader so these cases pin the surfacing contract, not the helper's own band
# derivation (that lives in tests/fm-retry-pressure.test.sh).

fake_retry_pressure() {  # <fakebin> <band> [<relaunches>]
  local fakebin=$1 band=$2 count=${3:-7}
  cat > "$fakebin/fm-retry-pressure.sh" <<FAKE
#!/usr/bin/env bash
printf 'relaunches=$count retry_loop_reported=0 relaunch_ceiling=3 round_ceiling=4 retry_band=$band task=%s\n' "\$1"
FAKE
  chmod +x "$fakebin/fm-retry-pressure.sh"
}

test_heartbeat_names_a_halt_band_task() {
  local dir state fakebin out sig pid
  dir=$(make_case retry-halt); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  # A fleet whose status logs hold nothing captain-relevant: without the retry
  # read this heartbeat is absorbed as no-change, which is exactly how two
  # halt-band tasks sat unheld on 2026-09-08.
  printf 'working: routine progress\n' > "$state/grinder.status"
  printf 'backend=tmux\n' > "$state/grinder.meta"
  sig=$(seen_sig "$state/grinder.status"); printf '%s' "$sig" > "$state/.seen-grinder_status"
  fake_retry_pressure "$fakebin" halt 7
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_RETRY_PRESSURE_EVERY_POLL=1 \
    FM_RETRY_PRESSURE_BIN="$fakebin/fm-retry-pressure.sh" "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "a halt-band task did not surface at the heartbeat: $(cat "$out")"
  assert_contains "$(cat "$out")" "retry halt: grinder" \
    "the heartbeat wake reason must name the halt-band task"
  assert_grep "retry halt: grinder" "$state/.wake-queue" \
    "the durable wake record must carry the halt-band task too"
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" \
    || fail "the emitted wake reason left the reason grammar every consumer parses: $(cat "$out")"
  pass "a halt-band task makes an otherwise-quiet heartbeat actionable and is named in the reason"
}
test_heartbeat_names_a_halt_band_task

test_halt_is_not_suppressed_while_its_wake_sits_queued() {
  local dir state fakebin out pid
  dir=$(make_case retry-halt-queued); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  printf 'working: routine progress\n' > "$state/grinder.status"
  printf 'backend=tmux\n' > "$state/grinder.meta"
  printf '%s' "$(seen_sig "$state/grinder.status")" > "$state/.seen-grinder_status"
  fake_retry_pressure "$fakebin" halt 7
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_RETRY_PRESSURE_EVERY_POLL=1 \
    FM_RETRY_PRESSURE_BIN="$fakebin/fm-retry-pressure.sh" "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "a halt-band task did not surface at the heartbeat: $(cat "$out")"
  assert_grep "retry halt: grinder" "$state/.wake-queue" \
    "the halt-bearing wake must still be queued for this case"
  assert_absent "$state/.retry-halt-surfaced-grinder" \
    "the halt must not count as surfaced while its wake sits queued undrained"
  pass "a queued-but-undrained halt is not yet recorded as surfaced"
}
test_halt_is_not_suppressed_while_its_wake_sits_queued

test_drained_halt_becomes_suppressed() {
  local dir state fakebin out pid
  dir=$(make_case retry-halt-drained); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  printf 'working: routine progress\n' > "$state/grinder.status"
  printf 'backend=tmux\n' > "$state/grinder.meta"
  printf '%s' "$(seen_sig "$state/grinder.status")" > "$state/.seen-grinder_status"
  fake_retry_pressure "$fakebin" halt 7
  # The durable state a prior heartbeat leaves behind: the reading was enqueued
  # and the queue has since been drained, so the halt has actually reached the
  # supervisor and may now be suppressed.
  printf 'grinder\t7\n' > "$state/.retry-halt-pending"
  : > "$state/.wake-queue"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_RETRY_PRESSURE_EVERY_POLL=1 \
    FM_RETRY_PRESSURE_BIN="$fakebin/fm-retry-pressure.sh" "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a delivered halt reading re-fired instead of being suppressed: $(cat "$out")"
  fi
  assert_not_contains "$(cat "$out")" "retry halt" \
    "a delivered halt reading must not re-fire on the next heartbeat"
  [ "$(cat "$state/.retry-halt-surfaced-grinder" 2>/dev/null)" = 7 ] \
    || fail "the delivered halt reading was never recorded as surfaced"
  reap "$pid"
  pass "a halt is suppressed once the wake carrying it has been drained"
}
test_drained_halt_becomes_suppressed

test_heartbeat_halt_surfaces_once_per_reading() {
  local dir state fakebin out pid
  dir=$(make_case retry-halt-once); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  printf 'working: routine progress\n' > "$state/grinder.status"
  printf 'backend=tmux\n' > "$state/grinder.meta"
  printf '%s' "$(seen_sig "$state/grinder.status")" > "$state/.seen-grinder_status"
  fake_retry_pressure "$fakebin" halt 7
  # Pre-record the same reading the watcher is about to take: an unchanged halt
  # must not re-fire, or every heartbeat becomes a duplicate of the last one.
  printf '7\n' > "$state/.retry-halt-surfaced-grinder"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_RETRY_PRESSURE_EVERY_POLL=1 \
    FM_RETRY_PRESSURE_BIN="$fakebin/fm-retry-pressure.sh" "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for an already-surfaced halt reading: $(cat "$out")"
  fi
  assert_not_contains "$(cat "$out")" "retry halt" \
    "an already-surfaced halt reading must not re-fire on the next heartbeat"
  reap "$pid"
  pass "an unchanged halt reading stays silent; only a new reading re-surfaces"
}
test_heartbeat_halt_surfaces_once_per_reading

test_heartbeat_ok_band_still_absorbs() {
  local dir state fakebin out pid
  dir=$(make_case retry-ok); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  printf 'working: routine progress\n' > "$state/steady.status"
  printf 'backend=tmux\n' > "$state/steady.meta"
  printf '%s' "$(seen_sig "$state/steady.status")" > "$state/.seen-steady_status"
  fake_retry_pressure "$fakebin" ok 1
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_RETRY_PRESSURE_EVERY_POLL=1 \
    FM_RETRY_PRESSURE_BIN="$fakebin/fm-retry-pressure.sh" "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "an ok retry band made a quiet heartbeat actionable: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "ok-band heartbeat printed a wake reason: $(cat "$out")"
  assert_absent "$state/.retry-halt-surfaced-steady" \
    "an ok band must leave no halt marker behind"
  reap "$pid"
  pass "a non-halt retry band leaves the no-change heartbeat absorbed as before"
}
test_heartbeat_ok_band_still_absorbs

printf '# all fm-watch-retry-band tests passed\n'
