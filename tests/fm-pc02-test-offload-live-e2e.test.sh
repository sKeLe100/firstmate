#!/usr/bin/env bash
# Opt-in live guard for bin/fm-pc02-test-offload.sh's real remote path: that
# ssh actually reaches PC02, that the reconstructed git mirror (working tree
# plus this worktree's per-worktree git-dir plus the shared object/ref store,
# retargeted onto the mirror) resolves to the exact same HEAD, that a real
# fm-test-run.sh invocation executes there, and that its exit code and a
# --json artifact come back to PC01 unchanged. tests/fm-pc02-test-offload.test.sh
# is the portable regression for the decision logic (fake ssh, no network);
# this is the harness-and-host-gated counterpart for the mechanism a stub
# cannot prove. Run it after any change to the sync/retarget/execution steps
# and before trusting that PC02 offload still works end to end.
#
# Skips (never fails) when PC02 itself is asleep, busy, or unreachable at
# test time: that is a legitimate operational state, not a broken guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PC02_OFFLOAD_LIVE_E2E ssh rsync

SCRIPT="$ROOT/bin/fm-pc02-test-offload.sh"
TMP_ROOT=$(fm_test_tmproot fm-pc02-test-offload-live)

if ! timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 pc02 true >/dev/null 2>&1; then
  echo "skip: live: pc02 unreachable right now"
  exit 0
fi
if [ "$("$ROOT/bin/fm-autonomous-pc02-lane.sh" 2>/dev/null)" != free ]; then
  echo "skip: live: PC02 LLM lane is occupied right now"
  exit 0
fi

test_offloads_a_real_run_and_returns_its_exit_code_and_json_unchanged() {
  local out status json
  json="$TMP_ROOT/offload.json"
  out=$("$SCRIPT" tests/fm-pc02-fair-order.test.sh --json "$json" 2>&1)
  status=$?
  expect_code 0 "$status" "a passing script offloaded to a ready PC02 must exit 0: $out"
  assert_contains "$out" "PC02 idle and ready; running tests remotely" \
    "a ready PC02 did not report running remotely: $out"
  assert_contains "$out" "FM_TEST_END" "no remote fm-test-run.sh markers came back: $out"
  [ -s "$json" ] || fail "the --json artifact was not retrieved from PC02: $out"
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$json" \
    || fail "the retrieved --json artifact is not valid JSON"
  pass "a real PC02 offload runs the suite remotely and returns its markers and --json artifact"
}

test_a_failing_remote_script_returns_its_real_exit_code() {
  local fail_script out status
  fail_script="tests/fm-pc02-offload-live-e2e-fixture-fail.test.sh"
  cat > "$ROOT/$fail_script" <<'SH'
#!/usr/bin/env bash
echo "not ok - intentional fixture failure"
exit 1
SH
  chmod +x "$ROOT/$fail_script"
  # A later real offload's --delete rsync removes this from PC02's mirror
  # once it is gone from $ROOT, so cleanup here only needs the local copy.
  out=$("$SCRIPT" "$fail_script" 2>&1)
  status=$?
  rm -f "$ROOT/$fail_script"
  # Cleanup above must land before any assertion below can exit early.
  expect_code 1 "$status" "a failing remote script's exit code must come back unchanged: $out"
  assert_contains "$out" "exit=1" "the remote failure marker did not report exit=1: $out"
  pass "a failing remote-offloaded script returns its real exit code, not a wrapper success"
}

test_orphaned_background_process_times_out_instead_of_hanging() {
  local hang_script out status start end elapsed
  hang_script="tests/fm-pc02-offload-live-e2e-fixture-hang.test.sh"
  cat > "$ROOT/$hang_script" <<'SH'
#!/usr/bin/env bash
# Leaves a child holding stdout open after this script exits, reproducing
# the real hang bin/fm-pc02-test-offload.sh's RUN_TIMEOUT guards against:
# a real --changed run over this repo's own suite left an sshd session with
# no remaining child yet never returned, because some test under it left a
# background process holding the ssh channel's pipe open.
sleep 30 &
disown
echo "ok - fixture exits immediately"
exit 0
SH
  chmod +x "$ROOT/$hang_script"
  start=$(date +%s)
  out=$(FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS=5 "$SCRIPT" "$hang_script" 2>&1)
  status=$?
  end=$(date +%s)
  rm -f "$ROOT/$hang_script"
  elapsed=$((end - start))
  expect_code 124 "$status" "an orphaned background process must time out (124), not hang forever: $out"
  [ "$elapsed" -lt 25 ] || fail "the run took ${elapsed}s despite a 5s RUN_TIMEOUT: $out"
  assert_contains "$out" "exceeded" "the timeout fallback did not explain the run was cut off: $out"
  pass "an orphaned background process on PC02 times out rather than hanging the offload forever"
}

test_offloads_a_real_run_and_returns_its_exit_code_and_json_unchanged
test_a_failing_remote_script_returns_its_real_exit_code
test_orphaned_background_process_times_out_instead_of_hanging

echo "# all fm-pc02-test-offload-live-e2e tests passed"
