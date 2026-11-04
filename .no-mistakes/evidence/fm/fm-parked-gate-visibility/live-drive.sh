#!/usr/bin/env bash
# Live drive for the STALLED WAITS change (fm/fm-parked-gate-visibility).
#
# Runs the REAL bin/fm-wake-drain.sh (the one writer of the session-start digest
# and the supervision heartbeat's status presentation) over a disposable lab
# home, with the REAL bin/fm-crew-state.sh per-ship read. The no-mistakes CLI is
# emulated at its own boundary from the recorded real capture
# tests/captures/no-mistakes-v1.70.1/parked.toon, which is a v1.70.1 run parked
# at its Test gate with one ask-user finding - the exact incident shape in the
# intent.
#
# Every case builds a fresh lab under $TMPDIR and removes it before returning.
set -u

ROOT={run-worktree}
EVID=~/.no-mistakes/evidence/01M6H2WHM16JSBVW7S5TWN5YFF
LIB=/tmp/fm-drive-lib.sh
NOW=$(date +%s)
FAILED=0

. "$LIB"

pass() { printf 'PASS  %s\n' "$*"; }
bad() { FAILED=$((FAILED + 1)); printf 'FAIL  %s\n' "$*"; }

# A capture variant derived from the real recorded parked-gate TOON: the same
# run, steps, gate, and findings shape with the pipeline's own awaiting_agent
# duration (and, where a case needs it, the finding's action column) changed.
capture_variant() {  # <name> <awaiting_agent-value> <action>
  local out="$1/variant-$2-$3.toon"
  sed -e "s|^  awaiting_agent:.*|  awaiting_agent: $2|" \
      -e "s|test-1,warning,\"\",ask-user,|test-1,warning,\"\",$3,|" \
      "$CAPTURE" > "$out"
  printf '%s\n' "$out"
}

begin_case() {  # <name>
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  new_lab
  printf '\n=== CASE: %s (lab %s)\n' "$1" "$LAB"
}

end_case() {
  rm -rf -- "$LAB"
  LAB=
}

crew_state_of() {  # <id>
  PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" \
    "$ROOT/bin/fm-crew-state.sh" "$1"
}

# ---------------------------------------------------------------------------
# 1. The incident shape: a crewmate-owned gate parked 1h08m with findings and
#    no needs-decision, aged from a real zero-padded pipeline duration.
# ---------------------------------------------------------------------------
begin_case "gate owed by the crewmate, parked 1h08m0s, no needs-decision"
cap=$(capture_variant "$LAB" "parked 1h08m0s" auto-fix)
mkship feat-gate fm/feat-gate "working [at=$((NOW - 5000))]: validating"
mark_run feat-gate "$cap"
state_line=$(crew_state_of feat-gate)
printf 'crew-state: %s\n' "$state_line"
case "$state_line" in
  *"gate awaiting agent for 1h08m0s"*) pass "the real crew-state read mints the 1h08m0s age component" ;;
  *) bad "crew-state did not mint the parked age component: $state_line" ;;
esac
run_drain "$EVID/case1-gate-crewmate.drain.out"; rc=$?
printf 'drain exit: %s\n' "$rc"
cat "$EVID/case1-gate-crewmate.drain.out"
[ "$rc" -eq 0 ] || bad "the drain exited $rc"
grep -F 'STALLED WAITS (waiting on firstmate past 1h00m with nothing on OPEN DECISIONS):' "$EVID/case1-gate-crewmate.drain.out" >/dev/null \
  && pass "the drain printed the STALLED WAITS section" \
  || bad "no STALLED WAITS section on a 1h08m crewmate gate"
grep -F 'feat-gate: parked at test: 1 finding(s) has waited 1h08m on the crewmate with no needs-decision open' "$EVID/case1-gate-crewmate.drain.out" >/dev/null \
  && pass "the gate is reported with its age, its findings, and the crewmate as owner" \
  || bad "the crewmate gate line was missing or wrong"
grep -F 'PROCESS CENSUS' "$EVID/case1-gate-crewmate.drain.out" >/dev/null \
  && bad "a process census printed while this host's load5 is low" \
  || pass "no process census line at ordinary load"
end_case

# ---------------------------------------------------------------------------
# 2. The human-owed gate: the pipeline's own ask-user finding, parked 2d14h
#    (the recorded capture verbatim). The clearing owner is firstmate.
# ---------------------------------------------------------------------------
begin_case "human-owed gate, parked 2d14h, no needs-decision"
mkship feat-gate fm/feat-gate "working [at=$((NOW - 5000))]: validating"
mark_run feat-gate "$CAPTURE"
state_line=$(crew_state_of feat-gate)
printf 'crew-state: %s\n' "$state_line"
case "$state_line" in
  *"ask-user: authority decision"*) pass "the real capture's ask-user finding mints the human-decision component" ;;
  *) bad "the human-decision component was missing: $state_line" ;;
esac
run_drain "$EVID/case2-gate-ask-user.drain.out"; rc=$?
printf 'drain exit: %s\n' "$rc"
cat "$EVID/case2-gate-ask-user.drain.out"
[ "$rc" -eq 0 ] || bad "the drain exited $rc"
grep -F 'feat-gate: parked at test: 1 finding(s) has waited 2d14h on firstmate (ask-user: authority decision) with no needs-decision open' "$EVID/case2-gate-ask-user.drain.out" >/dev/null \
  && pass "the multi-day (2d14h) human-owed gate is aged and names firstmate's ask-user decision" \
  || bad "the human-owed gate line was missing or wrong"
grep -F 'feat-gate:' "$EVID/case2-gate-ask-user.drain.out" | grep -F 'on the crewmate' >/dev/null \
  && bad "the human-owed gate named the crewmate instead of firstmate" \
  || pass "the human-owed gate is not mislabelled as waiting on the crewmate"
end_case

# ---------------------------------------------------------------------------
# 3. Guard: an open needs-decision on the same gate is not silence. It belongs
#    to OPEN DECISIONS and must not be printed twice as a stall.
# ---------------------------------------------------------------------------
begin_case "gate parked 2d14h WITH an open needs-decision"
mkship feat-gate fm/feat-gate \
  "working [at=$((NOW - 5000))]: validating" \
  'needs-decision [key=nm-01RUN-test]: ask-user findings=test-1 file=/tmp/nm-01RUN-findings.txt'
mark_run feat-gate "$CAPTURE"
run_drain "$EVID/case3-gate-with-open-decision.drain.out"; rc=$?
printf 'drain exit: %s\n' "$rc"
cat "$EVID/case3-gate-with-open-decision.drain.out"
[ "$rc" -eq 0 ] || bad "the drain exited $rc"
grep -F 'STALLED WAITS' "$EVID/case3-gate-with-open-decision.drain.out" >/dev/null \
  && bad "an answered-elsewhere gate still printed a STALLED WAITS section" \
  || pass "no STALLED WAITS section while the gate's decision is open"
grep -F 'OPEN DECISIONS' "$EVID/case3-gate-with-open-decision.drain.out" >/dev/null \
  && pass "the open needs-decision is presented by OPEN DECISIONS instead" \
  || bad "the open needs-decision vanished from the digest"
end_case

# ---------------------------------------------------------------------------
# 4. The second incident shape: an idle declared go-wait paused 2h15m.
# ---------------------------------------------------------------------------
begin_case "declared go-wait idle 2h15m"
mkship go-wait fm/feat-gowait \
  "working [at=$((NOW - 9000))]: validating" \
  "paused [at=$((NOW - 8100))]: ready for test slot; waiting for firstmate go before no-mistakes"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" go-wait)
"$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" go-wait idle --gen "$gen" --source claude-hook --event stop
state_line=$(crew_state_of go-wait)
printf 'crew-state: %s\n' "$state_line"
case "$state_line" in
  state:\ paused*) pass "the real crew-state reads the ship as paused from its status log" ;;
  *) bad "crew-state did not read the idle ship as paused: $state_line" ;;
esac
run_drain "$EVID/case4-go-wait.drain.out"; rc=$?
printf 'drain exit: %s\n' "$rc"
cat "$EVID/case4-go-wait.drain.out"
[ "$rc" -eq 0 ] || bad "the drain exited $rc"
grep -F 'go-wait: paused 2h15m waiting on firstmate: ready for test slot; waiting for firstmate go before no-mistakes' "$EVID/case4-go-wait.drain.out" >/dev/null \
  && pass "the idle go-wait is flagged with its age and what it waits on" \
  || bad "the idle go-wait line was missing or wrong"
end_case

# ---------------------------------------------------------------------------
# 5. Guards: fresh gate, fresh go-wait, quota-held pause, captain-held pause -
#    none of these is a silent firstmate stall.
# ---------------------------------------------------------------------------
begin_case "guards: fresh gate 10m, fresh go-wait 5m, quota pause 2h15m, captain wait 2h15m"
fresh_cap=$(capture_variant "$LAB" "parked 10m0s" auto-fix)
mkship fresh-gate fm/feat-freshgate "working [at=$((NOW - 700))]: validating"
mark_run fresh-gate "$fresh_cap"
mkship fresh-go fm/feat-freshgo \
  "paused [at=$((NOW - 300))]: waiting for firstmate go before no-mistakes"
mkship quota-held fm/feat-quota \
  "paused [at=$((NOW - 8100))]: held for Claude quota; resumes on firstmate steer"
mkship captain-wait fm/feat-captain \
  "paused [at=$((NOW - 8100))]: waiting for the captain decision on the API shape"
for id in fresh-go quota-held captain-wait; do
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" "$id" idle --gen "$gen" --source claude-hook --event stop
  printf 'crew-state %s: %s\n' "$id" "$(crew_state_of "$id")"
done
run_drain "$EVID/case5-guards.drain.out"; rc=$?
printf 'drain exit: %s\n' "$rc"
cat "$EVID/case5-guards.drain.out"
[ "$rc" -eq 0 ] || bad "the drain exited $rc"
if grep -F 'STALLED WAITS' "$EVID/case5-guards.drain.out" >/dev/null; then
  bad "a guard case reached STALLED WAITS: $(grep -F 'STALLED WAITS' "$EVID/case5-guards.drain.out")"
else
  pass "no ship is flagged: under an hour, external quota, and captain-held waits stay out"
fi
for id in fresh-gate fresh-go quota-held captain-wait; do
  grep -F "$id:" "$EVID/case5-guards.drain.out" >/dev/null \
    && bad "$id was named in the digest as waiting" \
    || pass "$id is not flagged"
done
end_case

# ---------------------------------------------------------------------------
# 6. A large fleet stays under the bounded read fan-out and still judges every
#    ship: 10 parked gates at a concurrency bound of 3.
# ---------------------------------------------------------------------------
begin_case "10 parked gates at a read-concurrency bound of 3"
cap2=$(capture_variant "$LAB" "parked 2h00m0s" auto-fix)
for i in 1 2 3 4 5 6 7 8 9 10; do
  mkship "gate-$i" "fm/feat-gate-$i" "working [at=$((NOW - 5000))]: validating"
  mark_run "gate-$i" "$cap2"
done
mkdir -p "$LAB/count"
printf '0\n' > "$LAB/count/live"
printf '0\n' > "$LAB/count/peak"
started=$(date +%s)
run_drain "$EVID/case6-concurrency.drain.out" \
  FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=3 FM_SHIM_COUNT_DIR="$LAB/count" FM_SHIM_DELAY=0.4; rc=$?
printf 'drain exit: %s in %ss\n' "$rc" "$(( $(date +%s) - started ))"
cat "$EVID/case6-concurrency.drain.out"
[ "$rc" -eq 0 ] || bad "the drain exited $rc"
peak=$(cat "$LAB/count/peak")
printf 'peak concurrent no-mistakes reads: %s\n' "$peak"
[ "$peak" -le 3 ] \
  && pass "the per-ship reads never exceeded the configured bound of 3 (peak $peak)" \
  || bad "the drain ran $peak reads at once with a bound of 3"
count=$(grep -c ' has waited 2h00m on the crewmate with no needs-decision open' "$EVID/case6-concurrency.drain.out")
[ "$count" -eq 10 ] \
  && pass "all 10 parked gates were still judged under the bound" \
  || bad "only $count of 10 parked gates were judged"
end_case

# ---------------------------------------------------------------------------
# 7. The digest a captain actually reads: the real bin/fm-session-start.sh runs
#    the real drain and prints its sections verbatim, so both incident shapes
#    reach the session-start digest. The heartbeat path runs this same drain
#    (the watcher wake tells the primary to run it first), so the digest proof
#    covers the presentation both surfaces share.
# ---------------------------------------------------------------------------
begin_case "session-start digest carries both incident shapes"
mkship feat-gate fm/feat-gate "working [at=$((NOW - 5000))]: validating"
mark_run feat-gate "$CAPTURE"
mkship go-wait fm/feat-gowait \
  "working [at=$((NOW - 9000))]: validating" \
  "paused [at=$((NOW - 8100))]: ready for test slot; waiting for firstmate go before no-mistakes"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" go-wait)
"$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" go-wait idle --gen "$gen" --source claude-hook --event stop
timeout 240 env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE \
  PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB" FM_BOOTSTRAP_NETWORK=0 \
  "$ROOT/bin/fm-session-start.sh" > "$EVID/case7-session-start-digest.out" 2> "$EVID/case7-session-start-digest.err"
rc=$?
printf 'session-start exit: %s\n' "$rc"
[ "$rc" -eq 0 ] || bad "fm-session-start.sh exited $rc"
sed -n '/^STALLED WAITS/,/^$/p' "$EVID/case7-session-start-digest.out"
grep -F 'feat-gate: parked at test: 1 finding(s) has waited 2d14h on firstmate (ask-user: authority decision) with no needs-decision open' "$EVID/case7-session-start-digest.out" >/dev/null \
  && pass "the session-start digest carries the human-owed parked gate" \
  || bad "the digest did not carry the human-owed parked gate"
grep -F 'go-wait: paused 2h15m waiting on firstmate: ready for test slot; waiting for firstmate go before no-mistakes' "$EVID/case7-session-start-digest.out" >/dev/null \
  && pass "the session-start digest carries the idle declared go-wait" \
  || bad "the digest did not carry the idle declared go-wait"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -f -- "$LAB" >/dev/null 2>&1 || break
  sleep 1
done
pgrep -f -- "$LAB" >/dev/null 2>&1 \
  && bad "session-start left a process behind for this lab" \
  || pass "session-start exited with no process left behind"
end_case

printf '\n'
if [ "$FAILED" -eq 0 ]; then
  printf 'RESULT: all live drives passed\n'
else
  printf 'RESULT: %s live drive assertion(s) failed\n' "$FAILED"
fi
exit "$FAILED"
