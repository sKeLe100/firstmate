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

# Set <path>'s mtime to <epoch>.<nanos> portably. GNU touch -d accepts a
# fractional epoch, BSD touch cannot express sub-second times at all, so the
# portable paths go through python/perl utime. Returns non-zero when no
# mechanism on this host can set a sub-second mtime.
set_mtime_ns() {  # <path> <epoch-seconds> <nanoseconds>
  local path=$1 sec=$2 ns=$3
  if touch -d "@$sec.$(printf '%09d' "$ns")" "$path" 2>/dev/null; then
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; t=int(sys.argv[2])*10**9+int(sys.argv[3]); os.utime(sys.argv[1], ns=(t,t))' \
      "$path" "$sec" "$ns" 2>/dev/null && return 0
  fi
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=utime -e 'my $t=$ARGV[1]+$ARGV[2]/1e9; utime $t,$t,$ARGV[0] or exit 1' \
      "$path" "$sec" "$ns" 2>/dev/null && return 0
  fi
  return 1
}

mtime_seconds() {  # <path>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
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
    FM_PROCEVENT_SIGNAL_DEFER_GRACE="${FM_PROCEVENT_SIGNAL_DEFER_GRACE:-300}" \
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
  local dir state out1 out2 out3 pid
  dir=$(make_case procevent-dedup); state="$dir/state"
  out1="$dir/watch1.out"; out2="$dir/watch2.out"; out3="$dir/watch3.out"

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

  # The supervisor acknowledges the generation it drained. That proves it
  # consumed a wake naming this task while this status content was already on
  # disk, so the change is now settled - still no second record, and no wake.
  pe_case "$dir" handled delivery-src 1 >/dev/null \
    || fail "the captured generation could not be acknowledged"
  watch_bg "$dir" "$out3" 1
  pid=$!
  sleep 3
  is_live_non_zombie "$pid" \
    || { wait "$pid" 2>/dev/null || true; fail "the watcher woke for a settled signal: $(cat "$out3")"; }
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -F 'signal:' "$out3" >/dev/null \
    && fail "the acknowledged event was re-reported as a signal wake: $(cat "$out3")"
  [ "$(queue_kind_count "$state" signal)" -eq 0 ] \
    || fail "a duplicate signal record was enqueued after acknowledgement: $(cat "$state/.wake-queue")"

  pass "one event enqueues once: its status signal never becomes a second wake"
}

# --- Test 1b: a routine status line is never absorbed - only the signal
# annotation would ever present it, so no-loss outweighs the duplicate ---

test_routine_status_line_is_never_absorbed() {
  local dir state out1 out2
  dir=$(make_case procevent-routine); state="$dir/state"
  out1="$dir/watch1.out"; out2="$dir/watch2.out"

  # "done:" is not an OPEN DECISION and is not an unread surface, so the drain
  # presents it only through a signal row's annotation.
  printf 'done: pushed the branch, awaiting review\n' > "$state/delivery-src.status"
  seed_captured_procevent_result "$dir" delivery-src \
    || fail "the fixture captured no process-event result"

  watch_bg "$dir" "$out1"
  wait_for_exit "$!" 150 || fail "the watcher never surfaced the queued process-event result"
  pe_case "$dir" handled delivery-src 1 >/dev/null \
    || fail "the captured generation could not be acknowledged"

  watch_bg "$dir" "$out2" 1
  wait_for_exit "$!" 150 \
    || fail "a routine status line was absorbed under process-event coverage: $(cat "$out2")"
  grep -F "signal: $state/delivery-src.status" "$out2" >/dev/null \
    || fail "the routine status line lost its only delivery channel: $(cat "$out2")"
  [ "$(queue_kind_count "$state" signal)" -eq 1 ] \
    || fail "the routine status line was not enqueued: $(cat "$state/.wake-queue")"

  pass "a routine status line keeps its signal wake rather than being silently absorbed"
}

# --- Test 1c: a routine line appended BESIDE a still-open decision from an
# earlier turn is judged on the newly appended span, not on the whole file ---

test_routine_line_beside_an_open_decision_is_never_absorbed() {
  local dir state out0 out1 out2
  dir=$(make_case procevent-open-decision); state="$dir/state"
  out0="$dir/watch0.out"; out1="$dir/watch1.out"; out2="$dir/watch2.out"

  # An earlier turn opened a decision and was delivered on its own cycle, so
  # its marker is current. OPEN DECISIONS keeps reprinting that line on every
  # later drain.
  printf 'needs-decision: [key=api-shape] pick REST or RPC\n' > "$state/delivery-src.status"
  watch_bg "$dir" "$out0"
  wait_for_exit "$!" 150 || fail "the watcher never delivered the opening decision: $(cat "$out0")"

  # The crewmate now appends a routine line. The still-open decision above is
  # NOT evidence that this line will be presented anywhere.
  printf 'done: pushed the branch, awaiting review\n' >> "$state/delivery-src.status"
  # That first wake was delivered; start the process-event capture from an
  # empty queue so the fixture waits for its OWN queued result.
  : > "$state/.wake-queue"
  seed_captured_procevent_result "$dir" delivery-src \
    || fail "the fixture captured no process-event result"

  watch_bg "$dir" "$out1" 1
  wait_for_exit "$!" 150 || fail "the watcher never surfaced the queued process-event result"
  pe_case "$dir" handled delivery-src 1 >/dev/null \
    || fail "the captured generation could not be acknowledged"

  watch_bg "$dir" "$out2" 1
  wait_for_exit "$!" 150 \
    || fail "a routine line beside an open decision was absorbed: $(cat "$out2")"
  grep -F "signal: $state/delivery-src.status" "$out2" >/dev/null \
    || fail "the appended done: line lost its only delivery channel: $(cat "$out2")"
  [ "$(queue_kind_count "$state" signal)" -ge 1 ] \
    || fail "the appended done: line was not enqueued: $(cat "$state/.wake-queue")"

  pass "a routine line beside a still-open decision keeps its own signal wake"
}

# --- Test 2: a genuinely distinct later status change is never coalesced ---

test_distinct_status_change_after_procevent_still_wakes() {
  local dir state out1 out2 drain_out drain_err marker marker_s
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

  # The crewmate now reports a NEW, distinct event immediately after that wake
  # was delivered - inside the same epoch second, so only a sub-second ordering
  # test can tell it apart from the change the wake carried. It must still be
  # delivered on its own.
  printf 'blocked: need a decision\n' > "$state/delivery-src.status"

  # The fixture is only meaningful if whole-second mtimes cannot separate the
  # two writes; that is the boundary a coarse comparison silently absorbs. Pin
  # the status write a millisecond after the delivery, inside its second, so
  # the case is exercised on every run rather than whenever timing obliges.
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -n "$marker" ] || fail "the surfaced process-event marker was not written"
  marker_s=$(mtime_seconds "$marker")
  if set_mtime_ns "$marker" "$marker_s" 200000000 \
     && set_mtime_ns "$state/delivery-src.status" "$marker_s" 201000000; then
    [ "$(mtime_seconds "$state/delivery-src.status")" = "$marker_s" ] \
      && [ "$(mtime_seconds "$marker")" = "$marker_s" ] \
      || fail "fixture did not land both writes in one epoch second"
  fi

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

  pass "a status change written after the check wake, in the same second, is never coalesced"
}

# --- Test 3: deferral never loses a signal - the markers do not advance ---

test_deferred_signal_is_delivered_when_no_acknowledgement_arrives() {
  local dir state out1 out2 out3 pid
  dir=$(make_case procevent-defer-bound); state="$dir/state"
  out1="$dir/watch1.out"; out2="$dir/watch2.out"; out3="$dir/watch3.out"

  printf 'blocked: need a decision\n' > "$state/delivery-src.status"
  seed_captured_procevent_result "$dir" delivery-src \
    || fail "the fixture captured no process-event result"

  watch_bg "$dir" "$out1"
  wait_for_exit "$!" 150 || fail "the watcher never surfaced the queued process-event result"

  # The generation is never acknowledged, so the watcher can never prove the
  # status change was delivered. Deferral must leave the .seen marker alone:
  # once the bounded deferral lapses, the signal is delivered in full.
  watch_bg "$dir" "$out2" 1
  pid=$!
  sleep 2
  is_live_non_zombie "$pid" || { wait "$pid" 2>/dev/null || true; fail "the watcher did not defer: $(cat "$out2")"; }
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  FM_PROCEVENT_SIGNAL_DEFER_GRACE=0 watch_bg "$dir" "$out3" 1
  wait_for_exit "$!" 150 \
    || fail "a signal deferred behind an unacknowledged generation was lost: $(cat "$out3")"
  grep -F "signal: $state/delivery-src.status" "$out3" >/dev/null \
    || fail "the deferred signal was never delivered: $(cat "$out3")"
  [ "$(queue_kind_count "$state" signal)" -eq 1 ] \
    || fail "the deferred signal was not enqueued: $(cat "$state/.wake-queue")"

  pass "a signal deferred behind an unacknowledged generation is delayed, never dropped"
}

# --- Test 3b: a deferred signal co-pending with a benign one keeps its marker ---

test_deferred_signal_survives_a_benign_cycle() {
  local dir state out1 out2 out3 pid
  dir=$(make_case procevent-defer-benign); state="$dir/state"
  out1="$dir/watch1.out"; out2="$dir/watch2.out"; out3="$dir/watch3.out"

  # Informational lines only: every appended line is one the drain's unread
  # surface presents, so the change is coverable (hence deferrable), and no
  # captain verb appears anywhere - which is what lets the cycle below take the
  # benign-absorb branch.
  printf 'note: drafting the API shape\nnote: still drafting\n' \
    > "$state/delivery-src.status"
  seed_captured_procevent_result "$dir" delivery-src \
    || fail "the fixture captured no process-event result"

  watch_bg "$dir" "$out1"
  wait_for_exit "$!" 150 || fail "the watcher never surfaced the queued process-event result"

  # A second, unrelated change lands in the same cycle. With every crew provably
  # working and no captain verb anywhere, the cycle absorbs as benign - and must
  # still not advance the DEFERRED file's .seen marker.
  printf 'x\n' > "$state/crewb.turn-ended"
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$dir" "$out2" 1
  pid=$!
  sleep 3
  is_live_non_zombie "$pid" \
    || { wait "$pid" 2>/dev/null || true; fail "the benign cycle woke: $(cat "$out2")"; }
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  unset FM_FAKE_CREW_STATE

  # The generation is still unacknowledged. Once the deferral bound lapses and
  # the crew is no longer provably working, the deferred change must still be
  # visible to the signal scan - i.e. its marker never moved during the benign
  # cycle - and must be delivered in full.
  FM_PROCEVENT_SIGNAL_DEFER_GRACE=0 watch_bg "$dir" "$out3" 1
  wait_for_exit "$!" 150 \
    || fail "a signal deferred across a benign cycle was lost: $(cat "$out3")"
  grep -F "$state/delivery-src.status" "$out3" >/dev/null \
    || fail "the deferred signal did not survive the benign cycle: $(cat "$out3")"
  [ "$(queue_kind_count "$state" signal)" -ge 1 ] \
    || fail "the deferred signal was not enqueued: $(cat "$state/.wake-queue")"

  pass "a deferred signal keeps its marker when a benign signal shares the cycle"
}

# --- Test 3c: a deferred signal is not surfaced early by the benign branch's
# status-commit-error fallback ---

# When the benign absorb branch cannot commit a status file's seen marker it
# fails toward waking and enqueues the batch. That fallback must still respect
# the deferral: a signal held behind an unacknowledged process-event generation
# has decided nothing yet, so it must not ride the fallback out early.
test_commit_error_fallback_does_not_surface_a_deferred_signal() {
  local dir state out1 out2 records wakes
  dir=$(make_case procevent-defer-commit-error); state="$dir/state"
  out1="$dir/watch1.out"; out2="$dir/watch2.out"

  printf 'note: drafting the API shape\nnote: still drafting\n' \
    > "$state/delivery-src.status"
  seed_captured_procevent_result "$dir" delivery-src \
    || fail "the fixture captured no process-event result"

  watch_bg "$dir" "$out1"
  wait_for_exit "$!" 150 || fail "the watcher never surfaced the queued process-event result"

  # A second, unrelated status log lands in the same cycle with no captain verb,
  # so the crew-working cycle takes the benign absorb branch. Its seen marker is
  # a directory, so the marker commit cannot succeed and the branch falls back
  # to enqueuing the batch.
  printf 'note: unrelated bookkeeping\n' > "$state/othersrc.status"
  mkdir -p "$state/.seen-othersrc_status" \
    || fail "could not stage the unwritable seen marker"

  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$dir" "$out2" 1
  wait_for_exit "$!" 200 \
    || { unset FM_FAKE_CREW_STATE; fail "the commit-error fallback never woke: $(cat "$out2")"; }
  unset FM_FAKE_CREW_STATE

  grep -F "othersrc.status" "$state/.wake-queue" >/dev/null \
    || fail "the uncommittable status file was not enqueued by the fallback: $(cat "$state/.wake-queue")"
  ! grep -F "delivery-src.status" "$state/.wake-queue" >/dev/null \
    || fail "the commit-error fallback surfaced a deferred signal early: $(cat "$state/.wake-queue")"

  # $pending concatenates the pre- and post-grace scans, so a status file whose
  # seen marker can never be committed appears in it twice on every cycle that
  # takes this fallback. Each such cycle wakes exactly once, so its queue cost
  # must be exactly one record: fm_wake_append assigns a fresh seq per call and
  # never dedups, so a second record per cycle costs the supervisor an extra
  # drain turn on a change it already handled. Comparing records against the
  # watcher's own printed wakes keeps this exact however many cycles ran.
  records=$(awk -F'\t' '$3 == "signal" && $4 == "othersrc.status" { n++ } END { print n + 0 }' \
    "$state/.wake-queue")
  wakes=$(grep -c "signal:.*othersrc\.status" "$out2" || true)
  [ "$wakes" -ge 1 ] || fail "the fallback never printed a signal wake: $(cat "$out2")"
  [ "$records" -eq "$wakes" ] \
    || fail "the commit-error fallback enqueued $records records for $wakes wakes: $(cat "$state/.wake-queue")"

  pass "the benign branch's commit-error fallback leaves a deferred signal deferred and enqueues once"
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
test_routine_status_line_is_never_absorbed
test_routine_line_beside_an_open_decision_is_never_absorbed
test_distinct_status_change_after_procevent_still_wakes
test_deferred_signal_is_delivered_when_no_acknowledgement_arrives
test_deferred_signal_survives_a_benign_cycle
test_commit_error_fallback_does_not_surface_a_deferred_signal
test_signal_without_any_procevent_wakes_normally

echo ""
echo "All wake-pair-dedup tests passed."
