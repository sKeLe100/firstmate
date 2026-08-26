#!/usr/bin/env bash
# tests/fm-wake-pair-dedup.test.sh - Prove that a single underlying event is
# never enqueued twice as both a process-event check wake and a status signal
# wake, and that generation-bound coverage never swallows a distinct event.
#
# Audit finding 3: a captured process-event result woke firstmate as a check
# wake, and the same crewmate's status write then woke it AGAIN as a signal on
# the following cycle - two queue records, two drain turns, one event. The fix
# lives in bin/fm-watch.sh's signal scan: a status change already delivered by
# an outstanding, already-surfaced process-event generation is not appended
# again, and with nothing appended the cycle does not wake at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot fm-wake-pair-dedup-tests)

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

# Run the process-event runner against a case home (same seam the watcher
# triage suite uses: a case-local claim root, and no inherited FM_ROOT).
pe_case() {  # <dir> <command>...
  local dir=$1
  shift
  (unset FM_ROOT_OVERRIDE
   FM_PROCEVENT_CLAIM_ROOT="$dir/claims" FM_HOME="$dir" "$ROOT/bin/fm-procevent.sh" "$@")
}

# Capture one real process-event result for <source-id> into <dir>'s home and
# retire the source, leaving exactly one durably captured, unhandled, queued
# result.
seed_captured_procevent_result() {  # <dir> <source-id>
  local dir=$1 id=$2 i=0
  pe_case "$dir" register lavish "$id" -- \
    /bin/sh -c 'printf "session:\n  file: /a.html\n  status: waiting\n"' >/dev/null || return 1
  pe_case "$dir" reconcile >/dev/null || return 1
  while [ "$i" -lt 100 ]; do
    [ -s "$dir/state/.wake-queue" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  pe_case "$dir" retire "$id" >/dev/null || return 1
  [ -s "$dir/state/.wake-queue" ]
}

# Start the watcher against a case home, scoped by FM_HOME so the per-cycle
# process-event reconcile resolves the same state. Follow-up cycles run as a
# handling successor (the production seam for "a predecessor already delivered
# a wake"), so restarting the watcher between cycles does not report the
# unrelated rearm-resurface recovery wake and mask the signal decision.
watch_bg() {  # <dir> <out> [successor]
  local dir=$1 out=$2 successor=${3:-0}
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_WATCH_HANDLING_SUCCESSOR="$successor" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2>"$dir/watch.err" &
}

# Count durable queue records of <kind> currently on the queue.
queue_kind_count() {  # <state> <kind>
  local state=$1 kind=$2
  [ -s "$state/.wake-queue" ] || { echo 0; return; }
  awk -F'\t' -v k="$kind" '$3 == k { n++ } END { print n + 0 }' "$state/.wake-queue"
}

# --- Test 1: the reported duplicate pair - one event, one wake ---

test_procevent_generation_absorbs_its_own_status_signal() {
  local dir state out1 out2 pid
  dir=$(make_case procevent-dedup); state="$dir/state"
  out1="$dir/watch1.out"; out2="$dir/watch2.out"

  # The crewmate's status write comes first, then its process-event result is
  # captured - one event, both surfaces.
  printf 'blocked: waiting on lavish review\n' > "$state/delivery-src.status"
  seed_captured_procevent_result "$dir" delivery-src \
    || fail "the fixture captured no process-event result"

  # Cycle 1: the queued check wake is surfaced and the watcher exits. The
  # status change is still unseen - its .seen marker was never primed.
  watch_bg "$dir" "$out1"
  wait_for_exit "$!" 150 || fail "the watcher never surfaced the queued process-event result"
  grep -F "procevent:delivery-src:1" "$out1" >/dev/null \
    || fail "cycle 1 did not surface the process-event check wake: $(cat "$out1")"
  [ "$(queue_kind_count "$state" check)" -ge 1 ] \
    || fail "the process-event check record was not enqueued: $(cat "$state/.wake-queue")"

  # Cycle 2: the signal scan sees the same event's status change. Before the
  # fix it appended a second record and woke again; now it must do neither.
  watch_bg "$dir" "$out2" 1
  pid=$!
  sleep 3
  is_live_non_zombie "$pid" \
    || { wait "$pid" 2>/dev/null || true; fail "the watcher woke for a covered signal: $(cat "$out2")"; }
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  grep -F 'signal:' "$out2" >/dev/null \
    && fail "a duplicate signal wake was reported for the covered event: $(cat "$out2")"
  [ "$(queue_kind_count "$state" signal)" -eq 0 ] \
    || fail "a duplicate signal record was enqueued: $(cat "$state/.wake-queue")"
  [ "$(queue_kind_count "$state" check)" -ge 1 ] \
    || fail "the process-event check record did not survive: $(cat "$state/.wake-queue")"

  pass "one event enqueues once: the covered status signal is absorbed and no wake fires"
}

# --- Test 2: a genuinely distinct later status change is never coalesced ---

test_distinct_status_change_after_procevent_still_wakes() {
  local dir state out1 out2 drain_out drain_err
  dir=$(make_case procevent-distinct); state="$dir/state"
  out1="$dir/watch1.out"; out2="$dir/watch2.out"
  drain_out="$dir/drain.out"; drain_err="$dir/drain.err"

  printf 'working: driving the lavish session\n' > "$state/delivery-src.status"
  seed_captured_procevent_result "$dir" delivery-src \
    || fail "the fixture captured no process-event result"

  watch_bg "$dir" "$out1"
  wait_for_exit "$!" 150 || fail "the watcher never surfaced the queued process-event result"
  grep -F "procevent:delivery-src:1" "$out1" >/dev/null \
    || fail "cycle 1 did not surface the process-event check wake: $(cat "$out1")"

  # The result stays unhandled, but the crewmate now reports a NEW, distinct
  # event strictly after that capture. It must still be delivered.
  sleep 1.1
  printf 'blocked: need a decision\n' > "$state/delivery-src.status"

  watch_bg "$dir" "$out2" 1
  wait_for_exit "$!" 150 \
    || fail "a distinct status change after an unhandled process-event result was swallowed: $(cat "$out2")"
  grep -F "signal: $state/delivery-src.status" "$out2" >/dev/null \
    || fail "the distinct blocked event did not wake as a signal: $(cat "$out2")"
  [ "$(queue_kind_count "$state" signal)" -eq 1 ] \
    || fail "the distinct blocked event was not enqueued: $(cat "$state/.wake-queue")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>"$drain_err" \
    || fail "drain after the distinct signal failed"
  grep -F 'delivery-src.status' "$drain_out" >/dev/null \
    || fail "the distinct blocked event was not delivered to the drain: $(cat "$drain_out")"
  ack_drain_err "$state" "$drain_err" || fail "acknowledgement failed"

  pass "a distinct status change after an unhandled process-event result is never coalesced"
}

# --- Test 3: an acknowledged generation stops covering later signals ---

test_handled_generation_stops_covering_signals() {
  local dir state out1 out2
  dir=$(make_case procevent-handled); state="$dir/state"
  out1="$dir/watch1.out"; out2="$dir/watch2.out"

  printf 'blocked: waiting on lavish review\n' > "$state/delivery-src.status"
  seed_captured_procevent_result "$dir" delivery-src \
    || fail "the fixture captured no process-event result"

  watch_bg "$dir" "$out1"
  wait_for_exit "$!" 150 || fail "the watcher never surfaced the queued process-event result"

  # The supervisor acknowledges the generation: it no longer stands in for any
  # undelivered status change.
  pe_case "$dir" handled delivery-src 1 >/dev/null \
    || fail "the captured generation could not be acknowledged"

  watch_bg "$dir" "$out2" 1
  wait_for_exit "$!" 150 \
    || fail "the status signal was suppressed after its generation was handled: $(cat "$out2")"
  grep -F "signal: $state/delivery-src.status" "$out2" >/dev/null \
    || fail "the status signal did not wake once the generation was handled: $(cat "$out2")"

  pass "an acknowledged process-event generation no longer covers a status signal"
}

# --- Test 4: no process-event at all - the signal path is untouched ---

test_signal_without_any_procevent_wakes_normally() {
  local dir state out
  dir=$(make_case procevent-absent); state="$dir/state"; out="$dir/watch.out"

  printf 'blocked: needs review\n' > "$state/plain.status"

  watch_bg "$dir" "$out"
  wait_for_exit "$!" 150 || fail "the watcher never surfaced a plain status signal: $(cat "$out")"
  grep -F "signal: $state/plain.status" "$out" >/dev/null \
    || fail "a signal was suppressed with no process-event present: $(cat "$out")"
  [ "$(queue_kind_count "$state" signal)" -eq 1 ] \
    || fail "the plain signal was not enqueued: $(cat "$state/.wake-queue")"

  pass "a status signal with no process-event coverage wakes normally"
}

test_procevent_generation_absorbs_its_own_status_signal
test_distinct_status_change_after_procevent_still_wakes
test_handled_generation_stops_covering_signals
test_signal_without_any_procevent_wakes_normally

echo ""
echo "All wake-pair-dedup tests passed."
