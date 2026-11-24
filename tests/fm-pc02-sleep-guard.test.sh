#!/usr/bin/env bash
# Behavior tests for bin/fm-pc02-sleep-guard.sh: each keep-awake signal must
# make the predicate busy, an idle host must read free, and stale or
# gen-mismatched worker records must not hold PC02 awake.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pc02-sleep-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-pc02-sleep-guard)
HOME_DIR="$TMP_ROOT/home"
MATE_HOME="$TMP_ROOT/mate"
mkdir -p "$HOME_DIR" "$MATE_HOME/state/parent-route"
fakebin=$(fm_fakebin "$TMP_ROOT/fake")

export FM_PC02_GUARD_HOME="$HOME_DIR"
export FM_PC02_GUARD_MATE_HOME="$MATE_HOME"
export FM_PC02_GUARD_LLAMA_SWAP_URL='http://llama.invalid:8080'
export FM_PC02_GUARD_BEL_HEALTH_URL='http://bel.invalid/health'
export FM_PC02_GUARD_TASKLIST="$TMP_ROOT/tasklist.exe"
export FM_PC02_GUARD_FORGEJO_UNIT='forgejo-runner.service'

export FM_TEST_RUNNER_WORKER="$TMP_ROOT/runner-worker"
export FM_TEST_FORGEJO_CHILD="$TMP_ROOT/forgejo-child"
export FM_TEST_TASKLIST_FILE="$TMP_ROOT/tasklist.txt"
export FM_TEST_RUNNING="$TMP_ROOT/llama-running"

cat >"$fakebin/pgrep" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -x)
    [ -e "$FM_TEST_RUNNER_WORKER" ]
    exit $?
    ;;
  -P)
    [ -e "$FM_TEST_FORGEJO_CHILD" ]
    exit $?
    ;;
esac
exit 1
SH

cat >"$fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
# --user show -p MainPID --value <unit>
for arg in "$@"; do
  case "$arg" in --value) printf '4242\n'; exit 0 ;; esac
done
printf '4242\n'
SH

cat >"$fakebin/curl" <<'SH'
#!/usr/bin/env bash
url=
for arg in "$@"; do
  case "$arg" in http://*|https://*) url=$arg ;; esac
done
case "$url" in
  */running)
    if [ -e "$FM_TEST_RUNNING" ]; then
      printf '{"running":[{"model":"qwen"}]}\n'
    else
      printf '{"running":[]}\n'
    fi
    exit 0
    ;;
esac
exit 22
SH

cat >"$fakebin/ping" <<'SH'
#!/usr/bin/env bash
echo "ping must never be used" >&2
exit 99
SH
chmod +x "$fakebin"/*
cat >"$FM_PC02_GUARD_TASKLIST" <<'SH'
#!/usr/bin/env bash
cat "$FM_TEST_TASKLIST_FILE" 2>/dev/null || exit 1
SH
chmod +x "$FM_PC02_GUARD_TASKLIST"
printf 'INFO: No tasks are running which match the specified criteria.\n' >"$FM_TEST_TASKLIST_FILE"
reset_signals() {
  rm -f "$FM_TEST_RUNNER_WORKER" "$FM_TEST_FORGEJO_CHILD" "$FM_TEST_RUNNING" \
    "$FM_TEST_TASKLIST_FILE" "$HOME_DIR/.fm-pc02-personal-use" \
    "$MATE_HOME"/state/*.busy-state "$MATE_HOME"/state/*.busy-gen \
    "$MATE_HOME"/state/parent-route/*.busy-state "$MATE_HOME"/state/parent-route/*.busy-gen
  printf 'INFO: No tasks are running which match the specified criteria.\n' >"$FM_TEST_TASKLIST_FILE"
}

verdict() {
  PATH="$fakebin:$PATH" bash "$SCRIPT" status
}

reset_signals
[ "$(verdict)" = free ] || fail "an idle host must read free: $(verdict)"
pass "idle host reads free"

: >"$HOME_DIR/.fm-pc02-personal-use"
[ "$(verdict)" = "busy personal-use" ] || fail "personal use must read busy: $(verdict)"
reset_signals
pass "personal use holds PC02 awake"

lock="$HOME_DIR/.fm-pc02-test-slot-1.lock"
: >"$lock"
(
  exec 9>"$lock"
  flock -n 9 || exit 1
  : >"$TMP_ROOT/lock-held"
  sleep 10
) &
lock_pid=$!
for _ in $(seq 1 50); do
  [ -e "$TMP_ROOT/lock-held" ] && break
  sleep 0.1
done
[ -e "$TMP_ROOT/lock-held" ] || fail "could not hold the test slot lock"
[ "$(verdict)" = "busy test-slot" ] || fail "a held offload slot must read busy: $(verdict)"
kill "$lock_pid" 2>/dev/null || true
wait "$lock_pid" 2>/dev/null || true
rm -f "$TMP_ROOT/lock-held" "$lock"
pass "a held test-offload slot holds PC02 awake"

: >"$FM_TEST_RUNNER_WORKER"
[ "$(verdict)" = "busy github-runner" ] || fail "a GitHub runner job must read busy: $(verdict)"
reset_signals
pass "a GitHub runner job holds PC02 awake"

: >"$FM_TEST_FORGEJO_CHILD"
[ "$(verdict)" = "busy forgejo-runner" ] || fail "a Forgejo runner job must read busy: $(verdict)"
reset_signals
pass "a Forgejo runner job holds PC02 awake"

: >"$FM_TEST_RUNNING"
[ "$(verdict)" = "busy llama-swap" ] || fail "a running llama-swap model must read busy: $(verdict)"
reset_signals
printf 'llama-server.exe    1000 Console  1  10,000 K\n' >"$FM_TEST_TASKLIST_FILE"
[ "$(verdict)" = "busy llama-swap" ] || fail "a Windows llama-server must read busy: $(verdict)"
reset_signals
pass "a loaded llama-swap model holds PC02 awake"

now=$(date +%s)
record="$MATE_HOME/state/parent-route/pc02-mate.busy-state"
printf 'v1 gen=gtest seq=2 state=busy source=claude-hook event=prompt ts=%s\n' "$now" >"$record"
printf 'gtest\n' >"$MATE_HOME/state/parent-route/pc02-mate.busy-gen"
[ "$(verdict)" = "busy worker" ] || fail "a busy secondmate turn must read busy: $(verdict)"
pass "a busy secondmate turn holds PC02 awake"

printf 'v1 gen=gtest seq=3 state=idle source=claude-hook event=stop ts=%s\n' "$now" >"$record"
[ "$(verdict)" = free ] || fail "an idle secondmate turn must read free: $(verdict)"
pass "an idle secondmate turn does not hold PC02 awake"

printf 'v1 gen=gtest seq=2 state=busy source=claude-hook event=prompt ts=%s\n' "$now" >"$record"
printf 'gother\n' >"$MATE_HOME/state/parent-route/pc02-mate.busy-gen"
[ "$(verdict)" = free ] || fail "a gen-mismatched busy record must be ignored: $(verdict)"
pass "a stale incarnation record is ignored"

printf 'v1 gen=gtest seq=2 state=busy source=claude-hook event=prompt ts=%s\n' "$((now - 20000))" >"$record"
printf 'gtest\n' >"$MATE_HOME/state/parent-route/pc02-mate.busy-gen"
[ "$(verdict)" = free ] || fail "a stale busy record must be ignored: $(verdict)"
reset_signals
pass "an over-age busy record is ignored"

: >"$HOME_DIR/.fm-pc02-personal-use"
: >"$FM_TEST_RUNNER_WORKER"
combined=$(verdict)
case "$combined" in
  'busy '*personal-use*runner*) ;;
  *) fail "combined signals must name every reason: $combined" ;;
esac
reset_signals
pass "combined signals name every active reason"

echo "# all fm-pc02-sleep-guard tests passed"
