#!/usr/bin/env bash
# Portable behavior tests for bin/fm-pc02-test-offload.sh's readiness/fallback
# decision logic: bin/fm-test-run.sh's --pc02-if-idle flag execs into this
# script, so every path here must fall back to a local run rather than hang
# or silently change what got tested. The real successful-remote-execution
# path runs through fake SSH/rsync with real shell execution and kernel
# locks here; tests/fm-pc02-test-offload-live-e2e.test.sh separately exercises
# the actual PC02 host when explicitly enabled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pc02-test-offload.sh"
TMP_ROOT=$(fm_test_tmproot fm-pc02-test-offload)
mkdir -p "$TMP_ROOT/empty-state"
export XDG_CONFIG_HOME="$TMP_ROOT/xdg"
export FM_PC02_OFFLOAD_LLAMASWAP_URL=http://127.0.0.1:9
export FM_PC02_OFFLOAD_RESOURCE_CHECK_PS1="$TMP_ROOT/no-such-resource-check.ps1"

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

test_missing_supervising_home_falls_back_to_local() {
  local out status
  out=$(PATH="/nonexistent-so-ssh-is-absent:$PATH" FM_HOME="$TMP_ROOT/no-supervising-home" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "a missing supervising home must still run locally: $out"
  assert_contains "$out" "state directory is unavailable or unreadable" \
    "missing-home fallback did not preserve the fail-closed lane result: $out"
  assert_contains "$out" "PC02 lane check reported" "missing-home fallback did not explain the local route: $out"
  pass "a missing supervising home refuses the lane probe and falls back locally"
}

test_supervising_home_is_passed_to_lane_probe() {
  local home fakebin out status
  home="$TMP_ROOT/supervising-home"
  mkdir -p "$home/state"
  fakebin=$(fm_fakebin "$TMP_ROOT/supervising-home-tools")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
case "$*" in *fm-pc02-test-slot-*) echo claimed; read -r command; exit 0 ;; esac
printf 'resource:cpu=1 gpu=0\n'
exit 0
SH
  cat > "$fakebin/rsync" <<'SH'
#!/usr/bin/env bash
exit 11
SH
  chmod +x "$fakebin/ssh" "$fakebin/rsync"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "a readable supervising home should permit the remaining offload checks: $out"
  assert_contains "$out" "rsync to PC02 failed or timed out" \
    "the lane probe did not read the supplied supervising home before continuing: $out"
  pass "the offload probe scans the supplied supervising home before checking PC02"
}

test_unreachable_host_falls_back_to_local() {
  local fakebin out status
  fakebin=$(fm_fakebin "$TMP_ROOT/unreachable")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
case "$*" in *fm-pc02-test-slot-*) echo claimed; read -r command; exit 0 ;; esac
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
case "$*" in *fm-pc02-test-slot-*) echo claimed; read -r command; exit 0 ;; esac
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
case "$*" in *fm-pc02-test-slot-*) echo claimed; read -r command; exit 0 ;; esac
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
case "$*" in *fm-pc02-test-slot-*) echo claimed; read -r command; exit 0 ;; esac
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
case "$*" in *fm-pc02-test-slot-*) echo claimed; read -r command; exit 0 ;; esac
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
case "$*" in *fm-pc02-test-slot-*) echo claimed; read -r command; exit 0 ;; esac
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
case "$*" in *fm-pc02-test-slot-*) echo claimed; read -r command; exit 0 ;; esac
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
case "$*" in *fm-pc02-test-slot-*) echo claimed; read -r command; exit 0 ;; esac
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
case "$*" in *fm-pc02-test-slot-*) echo claimed; read -r command; exit 0 ;; esac
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
case "$*" in *fm-pc02-test-slot-*) echo claimed; read -r command; exit 0 ;; esac
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
case "$*" in *fm-pc02-test-slot-*) echo claimed; read -r command; exit 0 ;; esac
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

# fake_pc02 <dir> builds a fakebin whose ssh and rsync treat <dir>/home as
# PC02's home: the readiness probe reports an idle, tool-ready host, and every
# other remote command (mkdir, retarget, HEAD check, the real test run, and
# cleanup) really runs there, so the remote wrapper and its cleanup execute
# for real. fd 9 is the ssh channel itself, letting a fixture leave a
# straggler that holds the channel open the way a real one does.
fake_pc02() {
  local dir=$1 fakebin real_rsync
  real_rsync=$(command -v rsync)
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/home"
  cat > "$fakebin/ssh" <<SH
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
shift
case "\$*" in
  *personal-use*)
    probe_out=\$(HOME="$dir/home" bash -c "\$*" 2>&1)
    printf '%s\\n' "\${probe_out//resource:script-missing/resource:cpu=1 gpu=0}"
    exit 0
    ;;
esac
cd "$dir/home" || exit 255
if [ -n "\${FM_FAKE_SSH_DETACH:-}" ]; then
  case "\$*" in
    *'rm -rf'*) exit 255 ;;
    *fm-pc02-test-slot-*)
      mkdir -p "$dir/relay"
      rm -f "$dir/relay/in"; mkfifo "$dir/relay/in"
      cat <&0 > "$dir/relay/in" &
      catpid=\$!
      HOME="$dir/home" bash -c "\$*" < "$dir/relay/in" &
      trap 'kill "\$catpid" 2>/dev/null; exit 143' TERM
      while :; do sleep 0.1; done
      ;;
  esac
fi
exec 9>&1
printf '%s\n' "\$*" >> "$dir/ssh.log"
# The source worktree may contain normal read-only hook directories.
# Restore fixture permissions on cleanup, including signal/failed-run paths.
case "\$*" in *'rm -rf'*) chmod -R u+w "$dir/home/.fm-pc02-test-offload" 2>/dev/null || true ;; esac
HOME="$dir/home" exec bash -c "\$*"
SH
  cat > "$fakebin/rsync" <<SH
#!/usr/bin/env bash
args=(--exclude=/state --exclude=/data --exclude=/config --exclude=/projects)
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -e) shift 2; continue ;;
    pc02:/*) args+=("\${1#pc02:}") ;;
    pc02:*) args+=("$dir/home/\${1#pc02:}") ;;
    *) args+=("\$1") ;;
  esac
  shift
done
"$real_rsync" "\${args[@]}" || exit \$?
if [ -n "\${FM_FAKE_CAPTURE_RUNNER:-}" ] && [ -d "\${args[\${#args[@]}-1]}/bin" ]; then
  cat > "\${args[\${#args[@]}-1]}/bin/fm-test-run.sh" <<'RUNNER'
#!/usr/bin/env bash
echo "auto_jobs=\${FM_TEST_RUN_AUTO_JOBS_MAX:-unset} argv=\$*"
RUNNER
fi
SH
  chmod +x "$fakebin/ssh" "$fakebin/rsync"
  printf '%s\n' "$fakebin"
}

remote_runs_left() {  # <fake pc02 dir>
  find "$1/home/.fm-pc02-test-offload" -mindepth 1 -maxdepth 1 -name 'run-*' 2>/dev/null | wc -l | tr -d ' '
}

test_remote_run_returns_suite_exit_code_despite_straggler() {
  local dir fakebin fixture out status start elapsed
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  dir="$TMP_ROOT/remote-straggler"
  fakebin=$(fake_pc02 "$dir")
  fixture="$dir/straggler-fail.test.sh"
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
if { true >&9; } 2>/dev/null; then sleep 30 >&9 2>&1 & fi
echo "not ok - intentional fixture failure"
exit 1
SH
  chmod +x "$fixture"

  start=$(date +%s)
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$fixture" 2>&1)
  status=$?
  elapsed=$(( $(date +%s) - start ))
  expect_code 1 "$status" "a failing remote suite's exit code must come back unchanged: $out"
  assert_contains "$out" "PC02 idle and ready; running tests remotely" "the run never went remote: $out"
  assert_contains "$out" "exit=1" "the remote fm-test-run.sh markers did not come back: $out"
  [ "$elapsed" -lt 25 ] || fail "a straggler holding the channel kept the run open ${elapsed}s: $out"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "the per-run PC02 mirror was left behind: $out"
  flock -n "$dir/home/.fm-pc02-test-slot-1.lock" true || fail "failure retained the host claim"
  pass "a remote run returns the suite's own exit code promptly despite a straggler and removes its mirror"
}

test_remote_run_passes_through_green_suite_and_json() {
  local dir fakebin out status json_rel
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  dir="$TMP_ROOT/remote-green"
  fakebin=$(fake_pc02 "$dir")
  printf '#!/usr/bin/env bash\necho "ok - fixture"\n' > "$dir/green.test.sh"
  chmod +x "$dir/green.test.sh"
  json_rel=".fm-pc02-offload-test-$$.json"
  rm -f "$ROOT/$json_rel"
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$dir/green.test.sh" --json "$json_rel" 2>&1)
  status=$?
  mv "$ROOT/$json_rel" "$dir/out.json" 2>/dev/null
  expect_code 0 "$status" "a passing remote suite must exit 0: $out"
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$dir/out.json" \
    || fail "the relative --json artifact was not pulled back from the PC02 mirror as valid JSON: $out"
  assert_contains "$out" 'FM_TEST_ENV_RECORD v=1' "the fake PC02 shell did not emit its own environment record: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^FM_TEST_ENV_RECORD v=1$')" -eq 1 ] \
    || fail "the fake PC02 path should emit one environment record: $out"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "the per-run PC02 mirror was left behind: $out"
  pass "a green remote run exits 0, returns its --json artifact, and removes its mirror"
}

test_remote_run_uses_7200_second_default_timeout() {
  local dir fakebin real_timeout out status
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  dir="$TMP_ROOT/default-run-timeout"
  fakebin=$(fake_pc02 "$dir")
  real_timeout=$(command -v timeout)
  cat > "$fakebin/timeout" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "--kill-after=10" ]; then
  printf '%s\\n' "\${2:-}" >> "\$FM_TEST_OFFLOAD_TIMEOUT_CAPTURE"
fi
exec "$real_timeout" "\$@"
SH
  chmod +x "$fakebin/timeout"
  printf '#!/usr/bin/env bash\necho "ok - default timeout fixture"\n' > "$dir/green.test.sh"
  chmod +x "$dir/green.test.sh"

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash FM_TEST_OFFLOAD_TIMEOUT_CAPTURE="$dir/timeout.log" \
    env -u FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS "$SCRIPT" "$dir/green.test.sh" 2>&1)
  status=$?
  expect_code 0 "$status" "default-timeout remote fixture failed: $out"
  assert_contains "$out" "PC02 idle and ready; running tests remotely" "the run never went remote: $out"
  [ "$(cat "$dir/timeout.log")" = 7200 ] \
    || fail "remote timeout executable did not receive the independent 7200-second default: $(cat "$dir/timeout.log" 2>/dev/null)"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "default-timeout fixture left a mirror behind"
  pass "a remote suite passes the 7200-second default to its timeout executable"
}

test_remote_jobs_and_script_bound() {
  local dir fakebin out status jobs
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  dir="$TMP_ROOT/remote-bounds"
  fakebin=$(fake_pc02 "$dir")
  # Use a private remote runner stand-in to observe argv/environment at the
  # transfer boundary. The real scheduler's isolation policy has separate tests.
  export FM_FAKE_CAPTURE_RUNNER=1
  for jobs in default override split equals; do
    local -a args=()
    case "$jobs" in
      split) args=(--jobs 4) ;;
      equals) args=(--jobs=3) ;;
    esac
    out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
      FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash FM_PC02_OFFLOAD_JOBS="$([ "$jobs" = override ] && echo 6 || echo 8)" \
      "$SCRIPT" --all "${args[@]+"${args[@]}"}" 2>&1)
    status=$?
    expect_code 0 "$status" "remote jobs fixture failed: $out"
    case "$jobs" in
      default) assert_contains "$out" 'auto_jobs=8' "missing default: $out" ;;
      override) assert_contains "$out" 'auto_jobs=6' "missing override: $out" ;;
      split) assert_contains "$out" 'argv=--all --jobs 4' "split jobs lost: $out" ;;
      equals) assert_contains "$out" 'argv=--all --jobs=3' "equals jobs lost: $out" ;;
    esac
    assert_contains "$out" '--per-script-timeout-secs 3000' "default script cap changed: $out"
  done
  unset FM_FAKE_CAPTURE_RUNNER
  printf '#!/usr/bin/env bash\nsleep 60\n' > "$dir/timeout.test.sh"
  chmod +x "$dir/timeout.test.sh"
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash FM_PC02_OFFLOAD_SCRIPT_TIMEOUT_SECS=1 \
    "$SCRIPT" "$dir/timeout.test.sh" --per-script-timeout-secs 0 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "remote script cap did not bound an unlimited caller: $out"
  assert_contains "$out" "per_script_timeout_secs=1" "script timeout override was lost: $out"
  assert_contains "$out" "exit=124" "script cap did not time out its fixture: $out"
  pass "remote jobs preserve both caller forms, default to eight, and allow environment overrides with a script cap"
}

test_active_remote_suite_falls_back_locally() {
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  local dir fakebin out status owner _
  dir="$TMP_ROOT/remote-active"
  fakebin=$(fake_pc02 "$dir")
  # shellcheck disable=SC2016 # Positional parameter belongs to the lock holder.
  flock "$dir/home/.fm-pc02-test-slot-1.lock" bash -c 'touch "$1"; sleep 60' bash "$dir/locked" &
  owner=$!
  for _ in $(seq 1 300); do [ -f "$dir/locked" ] && break; sleep 0.1; done
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash FM_PC02_OFFLOAD_SLOTS=1 "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  pkill -P "$owner" 2>/dev/null || true
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true
  expect_code 0 "$status" "an occupied PC02 must run locally: $out"
  assert_contains "$out" "PC02 test slot busy" "active suite was not detected: $out"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "an occupied host received a new remote run"
  pass "an active PC02 test slot routes a second suite to PC01"
}

test_decoy_host_suite_does_not_affect_remote_probe() {
  local dir fakebin decoy_pid out status
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  dir="$TMP_ROOT/remote-decoy-host-suite"
  fakebin=$(fake_pc02 "$dir")
  printf '#!/usr/bin/env bash\necho "ok - hermetic fixture"\n' > "$dir/green.test.sh"
  chmod +x "$dir/green.test.sh"
  bash -c 'exec -a fm-test-run.sh sleep 30' &
  decoy_pid=$!
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$dir/green.test.sh" 2>&1)
  status=$?
  kill "$decoy_pid" 2>/dev/null || true
  wait "$decoy_pid" 2>/dev/null || true
  expect_code 0 "$status" "a decoy process name must not block a PC02 claim: $out"
  assert_contains "$out" "PC02 idle and ready; running tests remotely" \
    "a process merely mentioning fm-test-run.sh blocked a free host slot: $out"
  pass "a process merely mentioning fm-test-run.sh does not block a free host slot"
}

test_term_mid_remote_run_removes_mirror_and_kills_suite() {
  local dir fakebin fixture pid status _
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  dir="$TMP_ROOT/remote-term"
  fakebin=$(fake_pc02 "$dir")
  fixture="$dir/hang.test.sh"
  cat > "$fixture" <<SH
#!/usr/bin/env bash
echo "\$\$" > "$dir/suite-pid"
touch "$dir/suite-started"
sleep 60
SH
  chmod +x "$fixture"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$fixture" > "$dir/out.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 300); do
    [ -f "$dir/suite-started" ] && break
    sleep 0.1
  done
  [ -f "$dir/suite-started" ] || { kill "$pid" 2>/dev/null; fail "the remote suite never started: $(cat "$dir/out.log")"; }
  kill -TERM "$pid"
  wait "$pid"
  status=$?
  expect_code 143 "$status" "a TERM mid-run must exit 143: $(cat "$dir/out.log")"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "TERM mid-run left the per-run PC02 mirror behind: $(cat "$dir/out.log")"
  for _ in $(seq 1 30); do
    kill -0 "$(cat "$dir/suite-pid")" 2>/dev/null || break
    sleep 0.1
  done
  ! kill -0 "$(cat "$dir/suite-pid")" 2>/dev/null || fail "TERM mid-run left the remote suite running"
  flock -n "$dir/home/.fm-pc02-test-slot-1.lock" true || fail "TERM retained the host claim"
  pass "TERM during a remote run kills the remote suite and removes its mirror"
}

test_term_with_transport_ignoring_eof_stops_suite_and_frees_slot() {
  local dir fakebin fixture pid status start elapsed _
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  dir="$TMP_ROOT/remote-term-detach"
  fakebin=$(fake_pc02 "$dir")
  fixture="$dir/hang.test.sh"
  cat > "$fixture" <<SH
#!/usr/bin/env bash
echo "\$\$" > "$dir/suite-pid"
touch "$dir/suite-started"
sleep 60
SH
  chmod +x "$fixture"

  PATH="$fakebin:$PATH" FM_FAKE_SSH_DETACH=1 FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$fixture" > "$dir/out.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 300); do
    [ -f "$dir/suite-started" ] && break
    sleep 0.1
  done
  [ -f "$dir/suite-started" ] || { kill "$pid" 2>/dev/null; fail "the remote suite never started: $(cat "$dir/out.log")"; }
  flock -n "$dir/home/.fm-pc02-test-slot-1.lock" true && fail "the host slot was not held during the run"
  start=$SECONDS
  kill -TERM "$pid"
  wait "$pid"
  status=$?
  elapsed=$((SECONDS - start))
  expect_code 143 "$status" "a TERM mid-run must exit 143: $(cat "$dir/out.log")"
  [ "$elapsed" -le 20 ] || fail "TERM cleanup was not bounded (${elapsed}s)"
  for _ in $(seq 1 50); do
    kill -0 "$(cat "$dir/suite-pid")" 2>/dev/null || break
    sleep 0.1
  done
  ! kill -0 "$(cat "$dir/suite-pid")" 2>/dev/null || fail "dropping the transport left the remote suite running"
  flock -n "$dir/home/.fm-pc02-test-slot-1.lock" true || fail "the slot stayed held after the suite ended"
  pass "TERM with a transport that ignores stdin EOF still stops the remote suite and frees the slot"
}

test_sigkill_of_driver_stops_remote_suite_and_frees_slot() {
  local dir fakebin fixture pid _
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  dir="$TMP_ROOT/remote-kill"
  fakebin=$(fake_pc02 "$dir")
  fixture="$dir/hang.test.sh"
  cat > "$fixture" <<SH
#!/usr/bin/env bash
echo "\$\$" > "$dir/suite-pid"
touch "$dir/suite-started"
sleep 60
SH
  chmod +x "$fixture"

  PATH="$fakebin:$PATH" FM_FAKE_SSH_DETACH=1 FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$fixture" > "$dir/out.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 300); do
    [ -f "$dir/suite-started" ] && break
    sleep 0.1
  done
  [ -f "$dir/suite-started" ] || { kill "$pid" 2>/dev/null; fail "the remote suite never started: $(cat "$dir/out.log")"; }
  kill -KILL "$pid"
  wait "$pid" 2>/dev/null
  for _ in $(seq 1 100); do
    kill -0 "$(cat "$dir/suite-pid")" 2>/dev/null || break
    sleep 0.1
  done
  ! kill -0 "$(cat "$dir/suite-pid")" 2>/dev/null || fail "SIGKILL of the driver left the remote suite running"
  flock -n "$dir/home/.fm-pc02-test-slot-1.lock" true || fail "the slot stayed held after the suite ended"
  pkill -TERM -f "$dir/home" 2>/dev/null || true
  pass "abrupt loss of the driver stops the remote suite and frees the slot"
}

test_bare_common_store_needs_machine_file_unless_state_override() {
  local dir fakebin wt out status
  dir="$TMP_ROOT/bare-common"
  fakebin=$(fm_fakebin "$dir/tools")
  mkdir -p "$dir/seed" "$dir/config"
  git -C "$dir/seed" init -q . || fail "could not init seed repo"
  git -C "$dir/seed" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m seed || fail "could not seed commit"
  git clone -q --bare "$dir/seed" "$dir/gate.git" || fail "could not create bare store"
  git -C "$dir/gate.git" worktree add -q --detach "$dir/wt" HEAD || fail "could not add gate-style worktree"
  wt="$dir/wt"
  cp -R "$ROOT/bin" "$wt/bin"
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
case "$*" in *fm-pc02-test-slot-*) echo claimed; read -r command; exit 0 ;; esac
printf 'resource:cpu=1 gpu=0\n'
SH
  printf '#!/usr/bin/env bash\nexit 11\n' > "$fakebin/rsync"
  chmod +x "$fakebin/ssh" "$fakebin/rsync"

  out=$(env -u FM_HOME -u FM_STATE_OVERRIDE PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$dir/config" \
    "$wt/bin/fm-pc02-test-offload.sh" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  expect_code 0 "$?" "a bare common store without a machine file must run locally: $out"
  assert_contains "$out" "common git store does not identify a primary clone" "bare store was not refused: $out"
  assert_contains "$out" "$dir/config/firstmate/test-offload-home" "diagnostic did not name the resolved machine file: $out"
  assert_contains "$out" "one absolute operational-home path followed by a newline" "diagnostic did not say what to put in the file: $out"

  out=$(env -u FM_HOME PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$dir/config" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    "$wt/bin/fm-pc02-test-offload.sh" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  expect_code 0 "$?" "FM_STATE_OVERRIDE in a bare common store must run: $out"
  assert_contains "$out" "rsync to PC02 failed" "FM_STATE_OVERRIDE did not bypass git-common-dir discovery: $out"
  pass "a gate-style bare common store needs the machine file, while FM_STATE_OVERRIDE bypasses discovery"
}

test_machine_home_config_without_fm_home() {
  local dir fakebin out status config
  dir="$TMP_ROOT/machine-home"
  fakebin=$(fm_fakebin "$dir")
  config="$dir/config"
  mkdir -p "$config/firstmate" "$dir/supervisor/state"
  printf '%s\n' "$dir/supervisor" > "$config/firstmate/test-offload-home"
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
case "$*" in *fm-pc02-test-slot-*) echo claimed; read -r command; exit 0 ;; esac
printf 'resource:cpu=1 gpu=0\n'
SH
  printf '#!/usr/bin/env bash\nexit 11\n' > "$fakebin/rsync"
  chmod +x "$fakebin/ssh" "$fakebin/rsync"
  out=$(env -u FM_HOME -u FM_STATE_OVERRIDE PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$config" \
    "$ROOT/bin/fm-test-run.sh" --pc02-if-idle "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "unset FM_HOME with machine configuration must run: $out"
  assert_contains "$out" 'rsync to PC02 failed' "configured home did not reach transfer: $out"
  printf '%s\n' "$dir/missing-home" > "$config/firstmate/test-offload-home"
  out=$(env -u FM_HOME -u FM_STATE_OVERRIDE PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$config" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  expect_code 0 "$?" "unavailable configured home must fall back: $out"
  assert_contains "$out" 'state directory is unavailable or unreadable' "unavailable configured home was skipped: $out"
  rm "$config/firstmate/test-offload-home"
  mkdir "$config/firstmate/test-offload-home"
  out=$(env -u FM_HOME -u FM_STATE_OVERRIDE PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$config" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  expect_code 0 "$?" "unreadable home configuration must fall back: $out"
  assert_contains "$out" 'configuration unavailable or invalid' "unreadable configuration was skipped: $out"
  rmdir "$config/firstmate/test-offload-home"
  ln -s "$dir/missing-config" "$config/firstmate/test-offload-home"
  out=$(env -u FM_HOME -u FM_STATE_OVERRIDE PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$config" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  expect_code 0 "$?" "dangling configured-home pointer must fall back: $out"
  assert_contains "$out" 'configuration unavailable or invalid' "dangling configuration was skipped: $out"
  pass "machine configuration resolves an unset FM_HOME and fails closed when unreadable"
}

test_primary_clone_home_without_environment_or_config() {
  local dir fakebin source out
  dir="$TMP_ROOT/primary-home"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/clone/bin" "$dir/clone/state"
  git init -q "$dir/clone"
  for source in "$ROOT"/bin/*.sh; do
    ln -s "$source" "$dir/clone/bin/$(basename "$source")"
  done
  # Keep this entrypoint in the fixture so its ROOT is the fixture clone.
  rm "$dir/clone/bin/fm-pc02-test-offload.sh"
  cp "$SCRIPT" "$dir/clone/bin/fm-pc02-test-offload.sh"
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
case "$*" in *fm-pc02-test-slot-*) echo claimed; read -r command; exit 0 ;; esac
printf 'resource:cpu=1 gpu=0\n'
SH
  printf '#!/usr/bin/env bash\nexit 11\n' > "$fakebin/rsync"
  chmod +x "$fakebin/ssh" "$fakebin/rsync"
  out=$(env -u FM_HOME -u FM_STATE_OVERRIDE PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$dir/no-config" \
    "$dir/clone/bin/fm-pc02-test-offload.sh" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  expect_code 0 "$?" "primary clone discovery must run without FM_HOME: $out"
  assert_contains "$out" 'rsync to PC02 failed' "primary clone's state did not reach transfer: $out"
  pass "primary clone discovery resolves the home without environment or machine configuration"
}

test_concurrent_offloads_admit_two_runs() {
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  local dir fakebin first second third a b c _ losers
  dir="$TMP_ROOT/concurrent"
  fakebin=$(fake_pc02 "$dir")
  cat > "$dir/claimant.test.sh" <<SH
#!/usr/bin/env bash
if { true >&9; } 2>/dev/null; then
  echo started >> "$dir/started"
  for _ in \$(seq 1 300); do [ -f "$dir/release" ] && exit 0; sleep 0.1; done
  exit 1
fi
echo 'ok - local loser'
SH
  chmod +x "$dir/claimant.test.sh"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$dir/claimant.test.sh" > "$dir/first.log" 2>&1 &
  first=$!
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$dir/claimant.test.sh" > "$dir/second.log" 2>&1 &
  second=$!
  for _ in $(seq 1 300); do
    [ -f "$dir/started" ] && [ "$(wc -l < "$dir/started")" -eq 2 ] && break
    sleep 0.1
  done
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$dir/claimant.test.sh" > "$dir/third.log" 2>&1 &
  third=$!
  losers=0
  for _ in $(seq 1 300); do
    if [ -f "$dir/started" ] && grep -q 'test slot busy' "$dir/third.log"; then losers=1; break; fi
    sleep 0.1
  done
  touch "$dir/release"
  wait "$first"; a=$?
  wait "$second"; b=$?
  wait "$third"; c=$?
  expect_code 0 "$a" "first claimant failed: $(cat "$dir/first.log")"
  expect_code 0 "$b" "second claimant failed: $(cat "$dir/second.log")"
  expect_code 0 "$c" "third claimant failed: $(cat "$dir/third.log")"
  [ "$losers" = 1 ] || fail "third claimant did not fall back while both slots were held"
  [ "$(wc -l < "$dir/started" | tr -d ' ')" = 2 ] || fail "expected exactly two remote claimants"
  flock -n "$dir/home/.fm-pc02-test-slot-1.lock" true || fail "winner retained claim"
  flock -n "$dir/home/.fm-pc02-test-slot-2.lock" true || fail "second winner retained claim"
  [ -f "$dir/home/.fm-pc02-test-slot-1.lock" ] && [ -f "$dir/home/.fm-pc02-test-slot-2.lock" ] || fail "lock files were unlinked"
  pass "two concurrent remote suites overlap and a third falls back locally"
}

test_dead_owner_and_timeout_release_claim() {
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  local dir fakebin owner _ out status
  dir="$TMP_ROOT/dead-owner"
  fakebin=$(fake_pc02 "$dir")
  # shellcheck disable=SC2016 # Evaluated by the real lock owner.
  flock -F "$dir/home/.fm-pc02-test-slot-1.lock" bash -c 'touch "$1"; exec sleep 60' bash "$dir/held" &
  owner=$!
  for _ in $(seq 1 300); do [ -f "$dir/held" ] && break; sleep 0.1; done
  [ -f "$dir/held" ] || fail "stale-claim fixture did not acquire its lock"
  kill -KILL "$owner"
  wait "$owner" 2>/dev/null || true
  [ -f "$dir/home/.fm-pc02-test-slot-1.lock" ] || fail "dead owner did not leave a lock file"
  printf '#!/usr/bin/env bash\nsleep 60\n' > "$dir/timeout.test.sh"
  chmod +x "$dir/timeout.test.sh"
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS=2 "$SCRIPT" "$dir/timeout.test.sh" 2>&1)
  status=$?
  expect_code 124 "$status" "dead owner's slot must be reclaimed and suite timeout preserved: $out"
  assert_contains "$out" 'running tests remotely' "dead lock file blocked the run: $out"
  flock -n "$dir/home/.fm-pc02-test-slot-1.lock" true || fail "timeout retained host claim"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "timeout left a mirror behind"
  pass "a dead owner's claim is reclaimed and the next run releases it on timeout"
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
test_missing_supervising_home_falls_back_to_local
test_supervising_home_is_passed_to_lane_probe
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
test_remote_run_returns_suite_exit_code_despite_straggler
test_remote_run_passes_through_green_suite_and_json
test_remote_run_uses_7200_second_default_timeout
test_remote_jobs_and_script_bound
test_active_remote_suite_falls_back_locally
test_decoy_host_suite_does_not_affect_remote_probe
test_term_mid_remote_run_removes_mirror_and_kills_suite
test_term_with_transport_ignoring_eof_stops_suite_and_frees_slot
test_sigkill_of_driver_stops_remote_suite_and_frees_slot
test_bare_common_store_needs_machine_file_unless_state_override
test_machine_home_config_without_fm_home
test_primary_clone_home_without_environment_or_config
test_concurrent_offloads_admit_two_runs
test_dead_owner_and_timeout_release_claim

echo "# all fm-pc02-test-offload tests passed"
