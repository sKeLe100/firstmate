#!/usr/bin/env bash
# tests/fm-watch-triage-lib.sh - shared helpers for the cases of the always-on wake
# triage built into bin/fm-watch.sh and the shared classifier
# (bin/fm-classify-lib.sh). The watcher absorbs the benign majority of wakes in
# bash and exits ONLY on an actionable wake, so firstmate's LLM re-arms once per
# actionable event instead of once per wake. The cases cover the classifier
# predicates as pure functions, then drive a real fm-watch.sh subprocess to
# assert the behavioral contract: provably-working no-verb wakes absorbed (no
# exit, no queue entry, suppressor advanced, beacon fresh), stopped-crew no-verb
# wakes surfaced (queue + exit), provably-working stale panes
# absorbed-then-escalated past the threshold, terminal-looking stale status lines
# overridden by an active run, the heartbeat backstop fail-safe, and afk
# coherence (no double-triage while the away-mode daemon owns supervision).
#
# Sourced, never run: this file sources the four tests/fm-watch-triage-*-part.sh
# case files at its end, and tests/fm-watch-triage.test.sh and
# tests/fm-watch-triage-waits.test.sh each run part of those cases, so neither
# script approaches the per-script runtime bound on its own.
#
# Daemon-side classification/injection lives in fm-daemon.test.sh; watcher/lock
# liveness in fm-watcher-lock.test.sh; the durable-queue safety matrix in
# fm-wake-queue.test.sh; the heartbeat's retry-band reader in
# fm-watch-retry-band.test.sh (split out to keep this file under the
# per-file runtime cap).
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-triage-tests)

ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

# Common watcher knobs: tight poll/grace, no check or heartbeat cadence unless a
# test overrides them, so a test only exercises the path it targets. FM_CREW_STATE_BIN
# points at the case's hermetic fake fm-crew-state.sh (installed by make_case) so the
# absorb-only-when-provably-working triage reads a canned verdict; a test fixes that
# verdict via FM_FAKE_CREW_STATE in its environment before calling watch_bg.
watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$@" "$WATCH" > "$out" &
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if it died.
# Only for an absence window whose case passes more easily under load, never as
# proof that a watcher reached a poll: wait_poll_cycle below owns that.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

# Wait until <pid>'s watcher has completed a whole poll cycle, or exited first.
# A fixed wait_live budget only proves the process is still ALIVE: fm-watch.sh
# does bounded startup work (the recovery-marker snapshot, lock acquisition)
# before its first stale scan, so on a loaded
# machine a short fixed budget can reap a round before the cycle it asserts on
# ever ran - and then every "no wake, no marker" assertion passes vacuously
# while every "marker written" assertion fails spuriously.
# The liveness beacon is touched at the TOP of every poll, so this drops any
# beacon left by an earlier round, waits for THIS watcher to write a fresh one
# (some poll's top), then waits for that one to advance (the next poll's top) -
# and the whole cycle in between is what the caller's assertions describe.
# 0 if the watcher is still alive after a completed cycle, 1 if it exited.
# Every positive wait in these cases is a ceiling, not a schedule: it returns as
# soon as its event lands, and a budget that runs out is stretched once by host
# load (fm_test_load_scaled_ticks in tests/wake-helpers.sh) before it counts as a
# failure, so contention alone cannot turn a slow poll into a spurious one.
wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first='' now i=0 scaled=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  while :; do
    if [ "$i" -ge "$limit" ]; then
      [ "$scaled" -eq 0 ] || return 1
      scaled=1
      limit=$(fm_test_load_scaled_ticks "$limit")
      [ "$i" -lt "$limit" ] || return 1
    fi
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -z "$first" ]; then
      first=$now
    elif [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
}

# Every wait_for_exit budget in this file is 100 ticks (10s) before load
# scaling, not because any watcher takes that long to decide, but because
# fm-watch.sh does bounded startup work before its first poll: a tighter budget
# reaps the process while it is still starting and reports a spurious "did not
# surface" failure. A generous budget can only remove that false negative - a
# watcher that never exits still fails the assertion when the budget runs out.
wait_numeric_file() {
  local file=$1 limit=${2:-30} i=0 scaled=0 value
  while :; do
    if [ "$i" -ge "$limit" ]; then
      [ "$scaled" -eq 0 ] || return 1
      scaled=1
      limit=$(fm_test_load_scaled_ticks "$limit")
      [ "$i" -lt "$limit" ] || return 1
    fi
    value=$(cat "$file" 2>/dev/null || true)
    case "$value" in
      ''|*[!0-9]*) ;;
      *) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
}

# The evidence a wake-count assertion needs when it fails: the durable queue rows
# and the watcher's own absorb/surface decisions, so a failure on a host nobody
# can rerun at will still says which poll queued the unexpected row and why.
wake_evidence() {  # <state>
  printf '\nwake queue:\n%s\ntriage log tail:\n%s' \
    "$(cat "$1/.wake-queue" 2>/dev/null)" "$(tail -n 20 "$1/.watch-triage.log" 2>/dev/null)"
}

# Portable mtime in epoch seconds. Platform-detected, never the `stat -f || stat -c`
# fallback (which writes a partial filesystem dump on Linux; see fm-watch.sh).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Set <file>'s mtime to exactly <epoch> seconds, for aging a busy-turn marker by
# a precise amount (touch -t takes a local-time stamp, not an epoch, on both
# platforms, so convert via BSD `date -r` or GNU `date -d @`).
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

# Signature a primed .seen-* marker must hold so the per-poll signal scan does not
# fire on a pre-existing status (mirrors fm-watch.sh's stat_sig exactly).
seen_sig() {
  local reported size ident
  case "$1" in
    *.status)
      reported=$(status_observed_signature "$1")
      size=$(size_of "$1")
      ident=$(_fm_open_decisions_file_ident "$1")
      printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
      ;;
    *)
      if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
      ;;
  esac
}

# Prime <file>'s .seen-* suppressor to its CURRENT signature, so the per-poll
# no-verb signal scan (which watches every *.turn-ended for a size:mtime change)
# treats a just-created or just-backdated turn-ended marker as already seen.
# Busy-turn-age fixtures create/backdate turn-ended directly (there is no real
# harness touching it), so without this the marker's own first sighting would
# fire an unrelated "signal:" wake and mask the busy-turn-age assertion under
# test. Call again after any further touch/set_mtime on the same file.
prime_turnend_seen() {  # <file>
  local f=$1 base
  base=$(basename "$f" | tr '.' '_')
  printf '%s' "$(seen_sig "$f")" > "$(dirname "$f")/.seen-$base"
}

record_pi_busy() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source pi-ext --event agent-start
}

# Stop an owned watcher. TERM must end it through its EXIT cleanup, so one still
# alive after the file's standard 100-tick budget fails the case here, with the
# process evidence wait_for_exit prints, instead of an unbounded wait hanging
# the whole suite until the CI job timeout.
reap() {
  local rc
  kill "$1" 2>/dev/null || true
  wait_for_exit "$1" 100
  rc=$?
  [ "$rc" -ne 124 ] || fail "watcher pid $1 did not exit within 10s of TERM"
}

# The cases themselves, split by subject so no single file outgrows the test-size
# ceiling. Every part is sourced before any case runs, so a case may call a helper
# defined beside the cases of another part.
# shellcheck source=tests/fm-watch-triage-signals-part.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-watch-triage-signals-part.sh"
# shellcheck source=tests/fm-watch-triage-stale-part.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-watch-triage-stale-part.sh"
# shellcheck source=tests/fm-watch-triage-wedge-part.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-watch-triage-wedge-part.sh"
# shellcheck source=tests/fm-watch-triage-away-part.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-watch-triage-away-part.sh"
