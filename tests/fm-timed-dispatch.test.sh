#!/usr/bin/env bash
# Behavior tests for bin/fm-timed-dispatch.sh.
#
# Every scenario runs the helper's public commands against real process-event
# runners and real clock conditions; nothing asserts implementation-source
# bytes. The suite proves the durable arm/fire/restart path, the clock boundary
# under a fake now, quota-reset resolution through a fake quota-axi, refusal of
# an unusable reading, and the list/cancel lifecycle.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-timed-dispatch-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
mkdir -p "$FM_PROCEVENT_CLAIM_ROOT"

td() { FM_HOME="$1" "$ROOT/bin/fm-timed-dispatch.sh" "${@:2}"; }
pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }

new_home() { mkdir -p "$1/state"; fm_test_track_procevent_home "$1"; }

wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

first_result() {  # <home> <source-id>
  local g
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] || continue
    printf '%s\n' "$g"
    return 0
  done
  return 1
}

wait_for_result() {  # <home> <source-id> [tries]
  local n=${3:-150}
  for _ in $(seq 1 "$n"); do
    first_result "$1" "$2" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

wait_for_file() {  # <file> [tries]
  local n=${2:-150}
  for _ in $(seq 1 "$n"); do [ -e "$1" ] && return 0; sleep 0.1; done
  return 1
}

count_results() {  # <home> <source-id>
  local g n=0
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] || continue
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

record_value() {  # <record> <key>
  awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1"
}

# --- arm, gate the clock, fire once, and wake naming the task ---------------
H="$TMP_ROOT/h-clock"; new_home "$H"
TASK=clock-task
NOW=$(date +%s)
TARGET=$((NOW + 2))
out=$(td "$H" arm "$TASK" --at "@$TARGET" --interval 0.1 --grace 0)
assert_contains "$out" "armed: when-dispatch-$TASK" "arm reports the canonical source id naming the task"
assert_present "$H/state/when/when-dispatch-$TASK.spec" "arm writes the when spec"
assert_present "$H/state/timed-dispatch/dispatch-$TASK.record" "arm writes the durable dispatch record"
assert_contains "$(record_value "$H/state/timed-dispatch/dispatch-$TASK.record" kind)" at "the record marks a clock target"
assert_contains "$(td "$H" list)" "task=$TASK" "list names the armed task"
assert_contains "$(td "$H" list)" "state=armed" "list reports the live watch as armed"

if FM_TIMED_DISPATCH_NOW=$((TARGET - 1)) td "$H" _condition "$TARGET"; then
  fail "the clock condition held before its target"
fi
FM_TIMED_DISPATCH_NOW="$TARGET" td "$H" _condition "$TARGET" \
  || fail "the clock condition did not hold at its target"

pe "$H" reconcile >/dev/null
wait_for_result "$H" "when-dispatch-$TASK" || fail "the armed clock wake never captured an outcome"
RESULT=$(first_result "$H" "when-dispatch-$TASK")
assert_grep 'status: fired' "$RESULT" "the outcome records a fired wake"
assert_grep "wake to dispatch $TASK" "$RESULT" "the outcome message names the task"
pe "$H" reconcile >/dev/null
assert_contains "$(wake_payloads "$H")" "procevent when when-dispatch-$TASK 1" \
  "the check wake names the task through the source id"
for _ in $(seq 1 100); do
  [ ! -e "$H/state/procevent/when-dispatch-$TASK.source" ] && break
  sleep 0.1
done
assert_absent "$H/state/procevent/when-dispatch-$TASK.source" "a fired watch retires its registration"
assert_contains "$(pe "$H" handled "when-dispatch-$TASK" 1)" "handled: when-dispatch-$TASK 1" \
  "the outcome acknowledges through the generic channel"
assert_contains "$(td "$H" list)" "state=fired" "list reports the terminal watch as fired"
pass "an armed clock wake gates on its target, fires once, and the wake names the task"

# --- a firstmate restart restarts the watch and still fires exactly once ----
H="$TMP_ROOT/h-restart"; new_home "$H"
TASK=restart-task
TARGET=$(( $(date +%s) + 5 ))
td "$H" arm "$TASK" --at "$TARGET" --interval 0.5 --grace 0 >/dev/null
pe "$H" reconcile >/dev/null
CLAIM="$FM_PROCEVENT_CLAIM_ROOT/when-dispatch-$TASK.claim"
wait_for_file "$CLAIM" || fail "the restart watch never claimed its runner"
RUNNER=$(sed -n '2p' "$CLAIM" 2>/dev/null)
[ -n "$RUNNER" ] || fail "the claim recorded no runner pid"
kill -0 "$RUNNER" 2>/dev/null || fail "the restart watch runner was not live before the restart"
kill "$RUNNER" 2>/dev/null || true
for _ in $(seq 1 60); do kill -0 "$RUNNER" 2>/dev/null || break; sleep 0.1; done
kill -0 "$RUNNER" 2>/dev/null && fail "the restart watch runner did not stop"
pe "$H" reconcile >/dev/null
wait_for_result "$H" "when-dispatch-$TASK" || fail "the restarted watch never fired after its target"
RESULT=$(first_result "$H" "when-dispatch-$TASK")
assert_grep 'status: fired' "$RESULT" "the restarted watch fired cleanly"
assert_contains "$(count_results "$H" "when-dispatch-$TASK")" 1 "the restart produced exactly one outcome"
pass "a firstmate restart restarts the armed watch and it still fires exactly once"

# --- a quota account resolves its own window reset and fires ---------------
H="$TMP_ROOT/h-quota"; new_home "$H"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN" "$TMP_ROOT/acct-two"
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf 'cfg=%s args=%s\n' "${CLAUDE_CONFIG_DIR-unset}" "$*" >> "$FAKE_QUOTA_READS"
cat "$FAKE_QUOTA_FIXTURE"
SH
chmod +x "$FAKEBIN/quota-axi"
TASK=quota-task
TARGET=$(( $(date +%s) + 3 ))
RESET_ISO=$(jq -rn --argjson e "$TARGET" '$e|todateiso8601')
jq -n --arg ts "$RESET_ISO" '{schemaVersion:5,providers:[{provider:"claude",state:{status:"fresh"},windows:[{id:"five_hour",kind:"session",resetsAt:$ts,percentRemaining:5},{id:"seven_day",kind:"weekly",resetsAt:"2026-12-01T00:00:00Z"}],quotaSemantics:{status:"known",effectiveAvailability:[]}}]}' \
  > "$TMP_ROOT/quota-fresh.json"
out=$(PATH="$FAKEBIN:$PATH" FAKE_QUOTA_READS="$TMP_ROOT/quota-reads" \
  FAKE_QUOTA_FIXTURE="$TMP_ROOT/quota-fresh.json" \
  td "$H" arm "$TASK" --account "$TMP_ROOT/acct-two" --window five_hour --interval 0.1 --grace 0)
assert_contains "$out" "armed: when-dispatch-$TASK" "a quota arm succeeds"
assert_grep "cfg=$TMP_ROOT/acct-two args=--provider claude --profile-only --json" \
  "$TMP_ROOT/quota-reads" "the account's own root and isolated read are used"
assert_contains "$(record_value "$H/state/timed-dispatch/dispatch-$TASK.record" kind)" quota \
  "the record marks a quota target"
assert_contains "$(record_value "$H/state/timed-dispatch/dispatch-$TASK.record" target_epoch)" "$TARGET" \
  "the quota window's reset epoch is recorded"
pe "$H" reconcile >/dev/null
wait_for_result "$H" "when-dispatch-$TASK" || fail "the quota wake never fired after its reset"
RESULT=$(first_result "$H" "when-dispatch-$TASK")
assert_grep "wake to dispatch $TASK" "$RESULT" "the quota outcome names the task"
assert_grep "five_hour reset at $RESET_ISO" "$RESULT" "the quota outcome names the resolved window reset"
pass "a quota account resolves its own window reset and wakes naming the task"

# --- an unusable quota reading is refused with nothing left armed ----------
H="$TMP_ROOT/h-quota-bad"; new_home "$H"
jq -n '{schemaVersion:5,providers:[{provider:"claude",state:{status:"unavailable",error:"Claude profile credentials missing"},windows:[],quotaSemantics:{status:"unknown",effectiveAvailability:[]},notSetUp:true}]}' \
  > "$TMP_ROOT/quota-bad.json"
if out=$(PATH="$FAKEBIN:$PATH" FAKE_QUOTA_READS="$TMP_ROOT/quota-reads-bad" \
  FAKE_QUOTA_FIXTURE="$TMP_ROOT/quota-bad.json" \
  td "$H" arm bad-quota --account "$TMP_ROOT/acct-two" 2>&1); then
  fail "an unavailable quota reading must refuse the arm: $out"
fi
assert_contains "$out" "unavailable" "the refusal names the unavailable reading"
assert_absent "$H/state/when/when-dispatch-bad-quota.spec" "a refused quota arm leaves no spec"
assert_absent "$H/state/timed-dispatch/dispatch-bad-quota.record" "a refused quota arm leaves no record"
if out=$(PATH="$FAKEBIN:$PATH" FAKE_QUOTA_READS="$TMP_ROOT/quota-reads-bad" \
  FAKE_QUOTA_FIXTURE="$TMP_ROOT/quota-fresh.json" \
  td "$H" arm bad-window --account "$TMP_ROOT/acct-two" --window no_such_window 2>&1); then
  fail "an unknown quota window must refuse the arm: $out"
fi
assert_contains "$out" "no no_such_window reset" "the refusal names the missing window"
assert_absent "$H/state/timed-dispatch/dispatch-bad-window.record" "a missing-window arm leaves no record"
pass "an unusable quota reading is refused and leaves nothing armed"

# --- bad clock targets and a past target are refused ----------------------
H="$TMP_ROOT/h-bad-at"; new_home "$H"
if out=$(td "$H" arm past-task --at "@1" 2>&1); then fail "a past target must be refused: $out"; fi
assert_contains "$out" "not in the future" "the refusal explains the target already passed"
if out=$(td "$H" arm offset-task --at "2026-11-21T15:09:00-05:00" 2>&1); then
  fail "a non-UTC offset must be refused: $out"
fi
assert_contains "$out" "UTC ISO-8601" "the refusal asks for a UTC time"
assert_absent "$H/state/timed-dispatch/dispatch-past-task.record" "no record is written for a refused clock target"
pass "bad and past clock targets are refused before anything is armed"

# --- list, cancel, duplicate refusal, and the --name override --------------
H="$TMP_ROOT/h-lifecycle"; new_home "$H"
NOW=$(date +%s)
TARGET=$((NOW + 3600))
out=$(td "$H" arm lifecycle-task --at "$TARGET" --grace 5)
assert_contains "$out" "armed: when-dispatch-lifecycle-task" "the lifecycle arm succeeds"
assert_contains "$(record_value "$H/state/timed-dispatch/dispatch-lifecycle-task.record" fire_epoch)" "$((TARGET + 5))" \
  "the record applies the grace to the fire time"
if out=$(td "$H" arm lifecycle-task --at "$TARGET" 2>&1); then fail "a duplicate arm must be refused: $out"; fi
assert_contains "$out" "already armed" "the duplicate refusal names the existing arm"
assert_contains "$(td "$H" list)" "task=lifecycle-task" "list shows the armed task"
assert_contains "$(td "$H" cancel lifecycle-task)" "cancelled: when-dispatch-lifecycle-task" "cancel retires the watch"
assert_absent "$H/state/when/when-dispatch-lifecycle-task.spec" "cancel removes the spec"
assert_absent "$H/state/procevent/when-dispatch-lifecycle-task.source" "cancel drops the registration"
assert_absent "$H/state/timed-dispatch/dispatch-lifecycle-task.record" "cancel removes the record"
assert_contains "$(td "$H" list)" "timed-dispatch: none" "list reports nothing armed after cancel"

LONG=$(printf 'a%.0s' $(seq 1 55))
if out=$(td "$H" arm "$LONG" --at "$TARGET" 2>&1); then fail "an over-long default name must be refused: $out"; fi
assert_contains "$out" "too long to name the wake" "the refusal suggests the --name override"
out=$(td "$H" arm "$LONG" --name short-demo --at "$TARGET")
assert_contains "$out" "armed: when-short-demo" "the --name override arms a short watch name"
assert_contains "$out" "task: $LONG" "the task id still appears in the arm outcome"
assert_contains "$out" "cancel --name short-demo" "the cancel hint uses --name for an overridden watch"
assert_contains "$(td "$H" cancel --name short-demo)" "cancelled: when-short-demo" "cancel by name works"
pass "list, cancel, duplicate refusal, grace, and the --name override all behave"

printf 'all fm-timed-dispatch tests passed\n'
