#!/usr/bin/env bash
# End-user demo: one crewmate event (status write + captured process-event
# result). Show what lands on firstmate's durable wake queue, and how many
# drain turns the captain's supervisor must spend to consume it.
set -u
ROOT=$1; LABEL=$2
. "$ROOT/tests/lib.sh"; . "$ROOT/tests/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot dedup-demo-$LABEL)
WATCH="$ROOT/bin/fm-watch.sh"; DRAIN="$ROOT/bin/fm-wake-drain.sh"
pe_case() { local d=$1; shift; (unset FM_ROOT_OVERRIDE; FM_PROCEVENT_CLAIM_ROOT="$d/claims" FM_HOME="$d" "$ROOT/bin/fm-procevent.sh" "$@"); }
watch_bg() { local d=$1 o=$2 s=${3:-0}
  PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_PROCEVENT_CLAIM_ROOT="$d/claims" \
    FM_CREW_STATE_BIN="$d/fakebin/fm-crew-state.sh" FM_WATCH_HANDLING_SUCCESSOR="$s" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$o" 2>"$d/watch.err" & }
dir=$(make_case demo); state="$dir/state"
printf 'blocked: waiting on lavish review\n' > "$state/delivery-src.status"
pe_case "$dir" register lavish delivery-src -- /bin/sh -c 'printf "session:\n  file: /a.html\n  status: waiting\n"' >/dev/null
pe_case "$dir" reconcile >/dev/null
i=0; while [ $i -lt 100 ]; do [ -s "$state/.wake-queue" ] && break; sleep 0.1; i=$((i+1)); done
pe_case "$dir" retire delivery-src >/dev/null

echo "### $LABEL"
echo "--- crewmate reports one event ---"
echo "\$ cat state/delivery-src.status"; cat "$state/delivery-src.status"
watch_bg "$dir" "$dir/w1.out"; wait_for_exit "$!" 150 >/dev/null 2>&1
echo "--- watcher cycle 1: process-event result captured -> wake ---"; cat "$dir/w1.out"
echo "--- supervisor DRAIN TURN 1 (woken by cycle 1) ---"
FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/d1.out" 2>"$dir/d1.err"; sed 's/^/    | /' "$dir/d1.out"
ack_drain_err "$state" "$dir/d1.err" >/dev/null 2>&1 || true
pe_case "$dir" handled delivery-src 1 >/dev/null 2>&1 || true

watch_bg "$dir" "$dir/w2.out" 1; pid=$!; sleep 4; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
echo "--- watcher cycle 2: signal scan sees the SAME event's status change ---"
if [ -s "$dir/w2.out" ]; then cat "$dir/w2.out"; else echo "(no second wake emitted)"; fi
echo "--- durable wake queue after both cycles ---"
if [ -s "$state/.wake-queue" ]; then awk -F'\t' '{print "  kind="$3"  reason="$4}' "$state/.wake-queue"; else echo "  (empty)"; fi
echo "--- supervisor DRAIN TURN 2 (only needed if cycle 2 woke again) ---"
if [ -s "$state/.wake-queue" ]; then
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/d2.out" 2>"$dir/d2.err"; sed 's/^/    | /' "$dir/d2.out"
  ack_drain_err "$state" "$dir/d2.err" >/dev/null 2>&1 || true
  echo "DRAIN TURNS SPENT ON ONE EVENT: 2"
else
  echo "    (nothing queued - no second turn spent)"
  echo "DRAIN TURNS SPENT ON ONE EVENT: 1"
fi
