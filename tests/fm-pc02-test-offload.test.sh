#!/usr/bin/env bash
# Portable behavior tests for bin/fm-pc02-test-offload.sh's readiness/fallback
# decision logic: bin/fm-test-run.sh's --pc02-if-idle flag execs into this
# script, so every path here must fall back to a local run rather than hang
# or silently change what got tested. The real successful-remote-execution
# path needs a genuine PC02 host and lives in the opt-in
# tests/fm-pc02-test-offload-live-e2e.test.sh instead; a fake ssh here proves
# the decision logic only.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pc02-test-offload.sh"
TMP_ROOT=$(fm_test_tmproot fm-pc02-test-offload)
mkdir -p "$TMP_ROOT/empty-state"

# --list-families is real, fast, deterministic, and independent of cwd
# state, so it doubles as proof that a fallback path actually reached the
# real fm-test-run.sh with the forwarded arguments intact.
LOCAL_PROOF_ARGS=(--list-families)
LOCAL_PROOF_OUT=$("$ROOT/bin/fm-test-run.sh" --list-families)

test_disable_env_var_skips_every_pc02_check() {
  local out status
  out=$(PATH="/nonexistent-so-ssh-and-rsync-are-absent:$PATH" FM_PC02_OFFLOAD_DISABLE=1 \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "a disabled offload must still run the real suite locally: $out"
  assert_contains "$out" "offload disabled" "disabled-offload run did not explain why it stayed local: $out"
  [ "$(printf '%s\n' "$out" | tail -n +2)" = "$LOCAL_PROOF_OUT" ] \
    || fail "disabled offload did not forward the arguments unchanged to fm-test-run.sh: $out"
  pass "FM_PC02_OFFLOAD_DISABLE=1 always runs locally without touching ssh or rsync"
}

test_lane_occupied_falls_back_to_local() {
  local home out status
  home="$TMP_ROOT/lane-occupied"
  mkdir -p "$home/state"
  {
    printf 'model=pc02-llamaswap/qwen3.8-27b-dispatch\n'
    printf 'backend=tmux\n'
    printf 'target=faketask:0\n'
  } > "$home/state/faketask.meta"

  out=$(PATH="/nonexistent-so-ssh-is-absent:$PATH" FM_STATE_OVERRIDE="$home/state" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "an occupied lane must still run the real suite locally: $out"
  assert_contains "$out" "PC02 lane check reported 'occupied: faketask'" \
    "occupied-lane fallback did not name the holding task: $out"
  pass "a live PC02 LLM lane falls back to a local run without touching ssh"
}

test_unreachable_host_falls_back_to_local() {
  local fakebin out status
  fakebin=$(fm_fakebin "$TMP_ROOT/unreachable")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
echo "ssh: connect to host pc02 port 22: Connection timed out" >&2
exit 255
SH
  chmod +x "$fakebin/ssh"

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "an unreachable host must still run the real suite locally: $out"
  assert_contains "$out" "PC02 unreachable" "unreachable-host fallback did not explain why: $out"
  pass "an unreachable PC02 falls back to a local run"
}

test_missing_required_tool_falls_back_to_local() {
  local fakebin out status
  fakebin=$(fm_fakebin "$TMP_ROOT/missing-tool")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf 'missing:jq\nmissing:shellcheck\nresource:cpu=1 gpu=0\n'
exit 0
SH
  chmod +x "$fakebin/ssh"

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "a tool-short PC02 must still run the real suite locally: $out"
  assert_contains "$out" "PC02 missing required tool(s): jq shellcheck" \
    "missing-tool fallback did not name the missing tools: $out"
  pass "PC02 missing a required tool falls back to a local run rather than a thinner remote run"
}

test_slow_probe_times_out_and_falls_back() {
  local fakebin out status
  fakebin=$(fm_fakebin "$TMP_ROOT/slow-probe")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
sleep 30
exit 0
SH
  chmod +x "$fakebin/ssh"

  out=$(PATH="$fakebin:$PATH" FM_PC02_OFFLOAD_PROBE_TIMEOUT_SECS=1 \
    FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "a stuck probe must still run the real suite locally: $out"
  assert_contains "$out" "PC02 unreachable" "a timed-out probe did not report unreachable: $out"
  pass "a stuck or slow probe times out and falls back rather than hanging"
}

test_rsync_failure_falls_back_to_local() {
  local fakebin out status
  fakebin=$(fm_fakebin "$TMP_ROOT/rsync-fails")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
# Reachable, idle, and tool-ready for the probe, and a no-op for mkdir and
# any other one-shot remote command; rsync itself is the failure under test.
printf 'resource:cpu=1 gpu=0\n'
exit 0
SH
  chmod +x "$fakebin/ssh"
  cat > "$fakebin/rsync" <<'SH'
#!/usr/bin/env bash
echo "rsync: fake transfer failure" >&2
exit 11
SH
  chmod +x "$fakebin/rsync"

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "a failed sync must still run the real suite locally: $out"
  assert_contains "$out" "rsync to PC02 failed or timed out" "rsync failure fallback did not explain why: $out"
  pass "a failed rsync to PC02 falls back to a local run"
}

test_personal_use_switch_falls_back_to_local() {
  local fakebin out status
  fakebin=$(fm_fakebin "$TMP_ROOT/personal-use")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf 'personal-use:on\nresource:cpu=1 gpu=0\n'
exit 0
SH
  chmod +x "$fakebin/ssh"

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "the personal-use switch must still run the real suite locally: $out"
  assert_contains "$out" "PC02 personal-use switch is on" "personal-use fallback did not explain why: $out"
  pass "the captain's personal-use switch falls back to a local run"
}

test_llama_swap_loaded_model_falls_back_to_local() {
  local fakebin out status
  fakebin=$(fm_fakebin "$TMP_ROOT/llama-swap-live")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf 'llama-swap-running:1\nresource:cpu=1 gpu=0\n'
exit 0
SH
  chmod +x "$fakebin/ssh"

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "a llama-swap with a loaded model must still run the real suite locally: $out"
  assert_contains "$out" "PC02 llama-swap has 1 model(s) loaded" \
    "llama-swap fallback did not explain why: $out"
  pass "llama-swap holding a loaded model for any live session falls back to a local run"
}

test_idle_llama_swap_does_not_block_offload() {
  local fakebin out status
  fakebin=$(fm_fakebin "$TMP_ROOT/llama-swap-idle")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf 'llama-swap-running:0\nresource:cpu=1 gpu=0\n'
exit 0
SH
  chmod +x "$fakebin/ssh"
  cat > "$fakebin/rsync" <<'SH'
#!/usr/bin/env bash
exit 11
SH
  chmod +x "$fakebin/rsync"

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "the rsync-failure fallback must still run the real suite locally: $out"
  assert_contains "$out" "rsync to PC02 failed or timed out" \
    "an idle llama-swap with no loaded model stopped the offload before the sync: $out"
  pass "a healthy llama-swap with no loaded model does not block offloading"
}

test_unclear_llama_swap_answer_falls_back_to_local() {
  local fakebin out status
  fakebin=$(fm_fakebin "$TMP_ROOT/llama-swap-unclear")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf 'llama-swap-running:\nresource:cpu=1 gpu=0\n'
exit 0
SH
  chmod +x "$fakebin/ssh"

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "an unclear llama-swap answer must still run the real suite locally: $out"
  assert_contains "$out" "PC02 llama-swap running-model check unclear" \
    "unclear llama-swap fallback did not explain why: $out"
  pass "an unparseable llama-swap /running answer defaults to a local run"
}

test_high_cpu_falls_back_to_local() {
  local fakebin out status
  fakebin=$(fm_fakebin "$TMP_ROOT/cpu-busy")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf 'resource:cpu=97.5 gpu=0\n'
exit 0
SH
  chmod +x "$fakebin/ssh"

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "a busy CPU must still run the real suite locally: $out"
  assert_contains "$out" "PC02 host CPU busy (97.5% >= 50%)" "CPU-busy fallback did not explain why: $out"
  pass "a Windows-wide CPU utilization over the threshold falls back to a local run"
}

test_high_gpu_falls_back_to_local() {
  local fakebin out status
  fakebin=$(fm_fakebin "$TMP_ROOT/gpu-busy")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf 'resource:cpu=1 gpu=42\n'
exit 0
SH
  chmod +x "$fakebin/ssh"

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "a busy GPU must still run the real suite locally: $out"
  assert_contains "$out" "PC02 host GPU busy (42% >= 5%)" "GPU-busy fallback did not explain why: $out"
  pass "a Windows GPU-engine utilization over the threshold falls back to a local run"
}

test_unclear_resource_check_falls_back_to_local() {
  local fakebin out status
  fakebin=$(fm_fakebin "$TMP_ROOT/resource-unclear")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf 'resource:script-missing\n'
exit 0
SH
  chmod +x "$fakebin/ssh"

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "an unclear resource read must still run the real suite locally: $out"
  assert_contains "$out" "PC02 resource check unclear" "unclear-resource fallback did not explain why: $out"
  pass "an unparseable or missing resource read defaults to a local run rather than an idle guess"
}

test_help_prints_the_whole_documented_contract() {
  local out status
  out=$("$SCRIPT" --help 2>&1)
  status=$?
  expect_code 0 "$status" "--help must exit 0: $out"
  assert_contains "$out" "fm-pc02-test-offload.sh <fm-test-run.sh args...>" "--help omitted the usage line: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_DISABLE=1" "--help omitted the disable override: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_PERSONAL_USE_FLAG" "--help omitted the personal-use switch override: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_CPU_BUSY_PCT" "--help omitted the CPU busy threshold: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_GPU_BUSY_PCT" "--help omitted the GPU busy threshold: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS" "--help omitted the run-timeout override: $out"
  case "$out" in
    *"set -u"*) fail "--help spilled past the header block into script code: $out" ;;
  esac
  pass "--help prints the whole documented contract"
}

test_pc02_if_idle_flag_forwards_through_fm_test_run() {
  local out status
  out=$(FM_PC02_OFFLOAD_DISABLE=1 "$ROOT/bin/fm-test-run.sh" --pc02-if-idle "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "fm-test-run.sh --pc02-if-idle must still succeed locally: $out"
  [ "$(printf '%s\n' "$out" | tail -n +2)" = "$LOCAL_PROOF_OUT" ] \
    || fail "fm-test-run.sh --pc02-if-idle changed the forwarded selection's output: $out"
  pass "fm-test-run.sh --pc02-if-idle strips the flag and forwards every other argument unchanged"
}

test_help_prints_the_whole_documented_contract
test_disable_env_var_skips_every_pc02_check
test_lane_occupied_falls_back_to_local
test_unreachable_host_falls_back_to_local
test_missing_required_tool_falls_back_to_local
test_slow_probe_times_out_and_falls_back
test_rsync_failure_falls_back_to_local
test_personal_use_switch_falls_back_to_local
test_llama_swap_loaded_model_falls_back_to_local
test_idle_llama_swap_does_not_block_offload
test_unclear_llama_swap_answer_falls_back_to_local
test_high_cpu_falls_back_to_local
test_high_gpu_falls_back_to_local
test_unclear_resource_check_falls_back_to_local
test_pc02_if_idle_flag_forwards_through_fm_test_run

echo "# all fm-pc02-test-offload tests passed"
