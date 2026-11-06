#!/usr/bin/env bash
# Portable behavior tests for bin/fm-pc02-test-offload.sh's readiness/fallback
# decision logic: bin/fm-test-run.sh's --pc02-if-idle flag execs into this
# script, so every path here must fall back to a local run, or wait under its
# bound before doing so, rather than hang or silently change what got tested. The real successful-remote-execution
# path runs through fake SSH/rsync with real shell execution and kernel
# locks here; tests/fm-pc02-test-offload-live-e2e.test.sh separately exercises
# the actual PC02 host when explicitly enabled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pc02-test-offload.sh"
# The nested fm-test-run.sh records its environment before the fixture runs;
# its bounded tool and browser probes can exceed 30s on a loaded host.
REMOTE_SUITE_START_TRIES=1800  # 0.1s per try, up to 180s
TMP_ROOT=$(fm_test_tmproot fm-pc02-test-offload)
mkdir -p "$TMP_ROOT/empty-state"
# The offload's pre-claim capacity floors are exercised by their own cases
# below; every other case disables the floors and points the PC02 tmp root at
# this sandbox so a fake host can never read the real /tmp that concurrent test
# lanes may be using.
export FM_PC02_OFFLOAD_TMP_ROOT="$TMP_ROOT/pc02-tmp"
mkdir -p "$FM_PC02_OFFLOAD_TMP_ROOT"
export FM_PC02_OFFLOAD_MEM_MIN_FREE_MB=0
export FM_PC02_OFFLOAD_TMP_MIN_FREE_MB=0
export FM_PC02_OFFLOAD_DISK_MIN_FREE_MB=0
export XDG_CONFIG_HOME="$TMP_ROOT/xdg"

# A wrapper browser execs this fixture, so the resolved-executable oracle is
# a plain file name rather than a host-specific /bin/true resolution.
WRAPPER_TARGET_NAME=chrome-wrapper-target-fixture
WRAPPER_TARGET="$TMP_ROOT/browser-target/$WRAPPER_TARGET_NAME"
mkdir -p "${WRAPPER_TARGET%/*}"
printf '#!/usr/bin/env bash\necho "Chrome Headless Shell 1228.0"\n' > "$WRAPPER_TARGET"
chmod +x "$WRAPPER_TARGET"

install_cache_chrome() {  # <home> <wrapper>
  local path="$1/.cache/ms-playwright/chromium_headless_shell-1228/chrome-headless-shell-linux64/chrome-headless-shell"
  mkdir -p "$(dirname "$path")"
  if [ "$2" = wrapper ]; then
    printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$WRAPPER_TARGET" > "$path"
  else
    printf '#!/usr/bin/env bash\necho "Chrome Headless Shell 1228.0"\n' > "$path"
  fi
  chmod +x "$path"
  printf '%s' "$path"
}

# Every case sees the same deterministic ldd, so browser dependency parity
# never depends on the runner's real libraries or fixture-script shapes.
mkdir -p "$TMP_ROOT/fake-ldd-bin"
cat > "$TMP_ROOT/fake-ldd-bin/ldd" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_LDD_LOG:-}" ]; then printf '%s\n' "$1" >> "$FM_FAKE_LDD_LOG"; fi
target=${1##*/}
if [[ "${FM_FAKE_LDD_MODE:-same}" = wrapper* ]] && [ "$target" = chrome-headless-shell ]; then
  echo 'not a dynamic executable' >&2
  exit 1
fi
case "${FM_FAKE_LDD_MODE:-same}" in
  local-hang) exec sleep 60 ;;
  different|wrapper-different) printf 'libm.so.6 => /fake/lib/libm.so.6 (0x0)\n' ;;
  not-found) printf 'libasound.so.2 => not found\n' ;;
  *) printf 'libc.so.6 => /fake/lib/libc.so.6 (0x0)\n' ;;
esac
SH
chmod +x "$TMP_ROOT/fake-ldd-bin/ldd"
export PATH="$TMP_ROOT/fake-ldd-bin:$PATH"
# The parity probe refuses a tool whose version neither host can establish, so
# give every probed tool this runner lacks (CI has no herdr, for example) the
# same stub version on both fake hosts; installed tools keep their real
# version, which both fake hosts also share.
for tool in git bash python3 jq node shellcheck actionlint ruby chromium herdr pi tmux; do
  command -v "$tool" >/dev/null 2>&1 && continue
  printf '#!/usr/bin/env bash\necho "%s fixture 0.0.0"\n' "$tool" > "$TMP_ROOT/fake-ldd-bin/$tool"
  chmod +x "$TMP_ROOT/fake-ldd-bin/$tool"
done

# The parity gate compares the browser each side selects, so PC01 runs from a
# controlled home whose cached browser matches the one fake_pc02 installs;
# the runner's ambient browser never decides a case.
export HOME="$TMP_ROOT/pc01-default-home"
install_cache_chrome "$HOME" direct >/dev/null

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

test_immediate_fallbacks_do_not_wait_for_the_bound() {
  local probe n fakebin out status
  n=0
  for probe in 'personal-use:on' 'missing:jq'; do
    n=$((n + 1))
    fakebin=$(fm_fakebin "$TMP_ROOT/immediate-no-wait-$n")
    printf '%s\nresource:cpu=99 gpu=0\nthreads:8\n' "$probe" > "$fakebin/probe.txt"
    cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
cat "$(dirname "$0")/probe.txt"
exit 0
SH
    chmod +x "$fakebin/ssh"
    out=$(PATH="$fakebin:$PATH" \
      FM_PC02_OFFLOAD_SLOT_WAIT_SECS=600 timeout 60 "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
    status=$?
    expect_code 0 "$status" "a '$probe' probe must fall back at once, not wait out the bound (status $status): $out"
    assert_not_contains "$out" "waiting up to" "a '$probe' fallback waited instead of routing local at once: $out"
    case "$probe" in
      personal-use:on) assert_contains "$out" "PC02 personal-use switch is on" \
        "the personal-use switch was not the immediate fallback reason: $out" ;;
      missing:jq) assert_contains "$out" "PC02 missing required tool(s): jq" \
        "the missing tool was not the immediate fallback reason: $out" ;;
    esac
  done
  pass "personal use and a missing tool route local at once even while a busy host would otherwise wait"
}

test_slot_wait_knobs_are_validated() {
  local knob value out status
  for knob in FM_PC02_OFFLOAD_SLOT_WAIT_SECS FM_PC02_OFFLOAD_SLOT_WAIT_INTERVAL_SECS; do
    for value in abc -1; do
      out=$(env "$knob=$value" "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
      status=$?
      expect_code 2 "$status" "$knob=$value must be a configuration error: $out"
      assert_contains "$out" "$knob must be a" "the refusal did not name $knob: $out"
      assert_contains "$out" "got '$value'" "the refusal omitted the rejected value: $out"
      assert_not_contains "$out" "$LOCAL_PROOF_OUT" "$knob=$value still ran the suite: $out"
    done
  done
  out=$(FM_PC02_OFFLOAD_SLOT_WAIT_INTERVAL_SECS=0 "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 2 "$status" "FM_PC02_OFFLOAD_SLOT_WAIT_INTERVAL_SECS=0 must be a configuration error: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_SLOT_WAIT_INTERVAL_SECS must be a positive integer, got '0'" \
    "the interval refusal did not name the rejected zero: $out"
  pass "a malformed slot-wait or slot-wait-interval setting exits 2 and runs no tests"
}

test_unreachable_host_falls_back_to_local() {
  local fakebin out status
  fakebin=$(fm_fakebin "$TMP_ROOT/unreachable")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
echo "ssh: connect to host pc02 port 22: Connection timed out" >&2
exit 255
SH
  chmod +x "$fakebin/ssh"

  out=$(PATH="$fakebin:$PATH" \
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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
printf 'missing:jq\nmissing:shellcheck\nresource:cpu=1 gpu=0\n'
exit 0
SH
  chmod +x "$fakebin/ssh"

  out=$(PATH="$fakebin:$PATH" \
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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
sleep 30
exit 0
SH
  chmod +x "$fakebin/ssh"

  out=$(PATH="$fakebin:$PATH" FM_PC02_OFFLOAD_PROBE_TIMEOUT_SECS=1 \
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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
case "$*" in *fm-pc02-environment-parity-probe*) cmd=${!#}; bash -c "$cmd"; exit $? ;; esac
case "$*" in *fm-pc02-hygiene-probe*) echo 'capacity mem_total_kb=1000000 mem_available_kb=900000 tmp_total_kb=1000000 tmp_used_kb=1000 tmp_free_kb=999000 disk_total_kb=1000000 disk_used_kb=1000 disk_free_kb=999000'; exit 0 ;; esac
# Reachable, idle, and tool-ready for the probe, and a no-op for mkdir and
# any other one-shot remote command; rsync itself is the failure under test.
printf 'resource:cpu=1 gpu=0\nthreads:8\n'
exit 0
SH
  chmod +x "$fakebin/ssh"
  cat > "$fakebin/rsync" <<'SH'
#!/usr/bin/env bash
echo "rsync: fake transfer failure" >&2
exit 11
SH
  chmod +x "$fakebin/rsync"

  out=$(PATH="$fakebin:$PATH" \
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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
printf 'personal-use:on\nresource:cpu=1 gpu=0\n'
exit 0
SH
  chmod +x "$fakebin/ssh"

  out=$(PATH="$fakebin:$PATH" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "the personal-use switch must still run the real suite locally: $out"
  assert_contains "$out" "PC02 personal-use switch is on" "personal-use fallback did not explain why: $out"
  pass "the captain's personal-use switch falls back to a local run"
}

test_unreadable_thread_count_falls_back_to_local() {
  local mode value needle fakebin out status
  for mode in absent empty zero; do
    fakebin=$(fm_fakebin "$TMP_ROOT/thread-count-$mode")
    cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
printf 'resource:cpu=1 gpu=0\n'
[ "${FM_FAKE_THREADS_MODE:-}" = absent ] || printf 'threads:%s\n' "${FM_FAKE_THREADS_VALUE:-}"
exit 0
SH
    chmod +x "$fakebin/ssh"
    value=
    case "$mode" in
      zero) value=0; needle="reported zero threads" ;;
      *) needle="thread count unavailable (got '')" ;;
    esac
    out=$(PATH="$fakebin:$PATH" \
      FM_FAKE_THREADS_MODE="$mode" FM_FAKE_THREADS_VALUE="$value" \
      "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
    status=$?
    expect_code 0 "$status" "an unreadable thread count must still run the real suite locally: $out"
    assert_contains "$out" "running on PC01" \
      "the unreadable-thread-count '$mode' case did not run locally: $out"
    assert_contains "$out" "cannot bound concurrent slot workers" \
      "the local fallback did not explain the missing thread bound: $out"
    assert_contains "$out" "$needle" \
      "the fallback did not name the '$mode' thread count: $out"
  done
  pass "an absent, empty, or zero PC02 thread count routes the run local with a diagnostic"
}

# fake_pc02 <dir> [threads] builds a fakebin whose ssh and rsync treat
# <dir>/home as PC02's home: the readiness probe reports an idle, tool-ready
# host, and every other remote command (mkdir, retarget, HEAD check, the real
# test run, and cleanup) really runs there, so the remote wrapper and its
# cleanup execute for real. fd 9 is the ssh channel itself, letting a fixture
# leave a straggler that holds the channel open the way a real one does. The
# optional thread count pins what the probe reports, independent of the host
# running the test.
fake_pc02() {
  local dir=$1 threads=${2:-16} fakebin real_rsync
  real_rsync=$(command -v rsync)
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/home"
  install_cache_chrome "$dir/home" direct >/dev/null
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
if [ -n "\${FM_FAKE_SSH_NOFILE_HARD:-}" ]; then
  ulimit -S -n "\${FM_FAKE_SSH_NOFILE_SOFT:-\$FM_FAKE_SSH_NOFILE_HARD}" 2>/dev/null || exit 255
  ulimit -H -n "\$FM_FAKE_SSH_NOFILE_HARD" 2>/dev/null || exit 255
fi
case "\$*" in
  *fm-pc02-environment-parity-probe*)
    case "\${FM_FAKE_PARITY_MODE:-}" in
      open-file-limit)
        HOME="$dir/home" bash -c "\$*" 2>&1 | sed "s/^ulimit.open_files=.*/ulimit.open_files=\${FM_FAKE_OPEN_FILES_LIMIT-}/"
        exit 0
        ;;
      version-mismatch)
        HOME="$dir/home" bash -c "\$*" 2>&1 | sed 's/^tool.git=.*/tool.git=fake-PC02-git-version/'
        exit 0
        ;;
      browser-version-mismatch)
        HOME="$dir/home" bash -c "\$*" 2>&1 | sed 's/^chromium.selected_version=.*/chromium.selected_version=Chrome Headless Shell 1229.0/'
        exit 0
        ;;
      chromium-not-found)
        HOME="$dir/home" FM_FAKE_LDD_MODE=not-found bash -c "\$*"
        exit \$?
        ;;
      dependency-mismatch)
        HOME="$dir/home" FM_FAKE_LDD_MODE=different bash -c "\$*"
        exit \$?
        ;;
      wrapper-dependency-mismatch)
        HOME="$dir/home" FM_FAKE_LDD_MODE=wrapper-different bash -c "\$*"
        exit \$?
        ;;
      local-browser-dependency-hang)
        HOME="$dir/home" FM_FAKE_LDD_MODE=same bash -c "\$*"
        exit \$?
        ;;
    esac
    ;;
esac
case "\$*" in
  *personal-use*)
    probe_out=\$(HOME="$dir/home" bash -c "\$*" 2>&1)
    probe_out=\${probe_out//resource:script-missing/resource:cpu=1 gpu=0}
    printf '%s\\n' "\$probe_out" | sed "s/^threads:.*/threads:$threads/"
    [ -z "\${FM_FAKE_PROBE_EXTRA:-}" ] || printf '%s\\n' "\$FM_FAKE_PROBE_EXTRA"
    exit 0
    ;;
esac
cd "$dir/home" || exit 255
if [ -n "\${FM_FAKE_SSH_DETACH:-}" ]; then
  case "\$*" in
    *'rm -rf'*) exit 255 ;;
    *fm-pc02-test-slot-*.lock*)
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
echo "auto_jobs=\${FM_TEST_RUN_AUTO_JOBS_MAX:-unset} remote=\${FM_PC02_OFFLOAD_REMOTE:-unset} argv=\$*"
RUNNER
fi
if [ -n "\${FM_FAKE_CAPTURE_COMPUTE:-}" ] && [ -d "\${args[\${#args[@]}-1]}/bin" ]; then
  cat > "\${args[\${#args[@]}-1]}/bin/fm-test-compute.sh" <<'COMPUTE'
#!/usr/bin/env bash
echo "compute_argv=\$*"
exit "\${FM_FAKE_CAPTURE_COMPUTE_EXIT:-0}"
COMPUTE
fi
SH
  chmod +x "$fakebin/ssh" "$fakebin/rsync"
  printf '%s\n' "$fakebin"
}

remote_runs_left() {  # <fake pc02 dir>
  find "$1/home/.fm-pc02-test-offload" -mindepth 1 -maxdepth 1 -name 'run-*' 2>/dev/null | wc -l | tr -d ' '
}

test_live_pc02_model_worker_does_not_block_offload() {
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  local dir fakebin home out status
  dir="$TMP_ROOT/live-model-worker"
  fakebin=$(fake_pc02 "$dir")
  printf '#!/usr/bin/env bash\necho "ok - live worker fixture"\n' > "$dir/green.test.sh"
  chmod +x "$dir/green.test.sh"
  # Reproduces the 2026-11-04 occurrences: a live PC02 model worker's meta
  # existed while PC02 had a free test slot and the run still stayed on PC01.
  home="$dir/lane-home"
  mkdir -p "$home/state"
  printf 'model=pc02-llamaswap/qwen3.6-35b-a3b-dispatch\nbackend=herdr\ntarget=faketask:0\n' \
    > "$home/state/faketask.meta"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$dir/green.test.sh" 2>&1)
  status=$?
  expect_code 0 "$status" "a live PC02 model worker must not stop the offload: $out"
  assert_contains "$out" "running tests remotely" "the live model worker still pushed the run off PC02: $out"
  assert_not_contains "$out" "running on PC01" "the live model worker still forced the local fallback: $out"
  assert_not_contains "$out" "lane check" "the offload still consulted the model lane: $out"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "the finished remote run left its mirror behind"
  pass "a live PC02 model worker is not test-offload occupancy and the run takes PC02"
}

test_loaded_llama_swap_and_busy_probe_do_not_block_offload() {
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  local dir fakebin home out status fixture
  dir="$TMP_ROOT/loaded-swap-busy"
  fakebin=$(fake_pc02 "$dir")
  for fixture in one two three; do
    printf '#!/usr/bin/env bash\necho "ok - %s fixture"\n' "$fixture" > "$dir/$fixture.test.sh"
    chmod +x "$dir/$fixture.test.sh"
  done
  home="$dir/lane-home"
  mkdir -p "$home/state"
  printf 'model=pc02-llamaswap/qwen3.6-35b-a3b-dispatch\nbackend=herdr\ntarget=faketask:0\n' \
    > "$home/state/faketask.meta"
  # The retired automatic gates' exact readings: a loaded llama-swap and a
  # host that looks CPU- and GPU-busy, alongside the live Qwen worker.
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    FM_FAKE_PROBE_EXTRA=$'llama-swap-running:1\nresource:cpu=99 gpu=95' \
    "$SCRIPT" "$dir/one.test.sh" "$dir/two.test.sh" "$dir/three.test.sh" 2>&1)
  status=$?
  expect_code 0 "$status" "a loaded llama-swap and busy host probe must not stop the offload: $out"
  assert_contains "$out" "running tests remotely" "the retired automatic gates still forced PC01: $out"
  assert_not_contains "$out" "running on PC01" "the retired automatic gates still forced the local fallback: $out"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "the finished remote run left its mirror behind"
  pass "a loaded llama-swap and busy CPU/GPU readings do not stop a multi-script offload"
}

test_remote_run_returns_suite_exit_code_despite_straggler() {
  local dir fakebin fixture out status held
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  dir="$TMP_ROOT/remote-straggler"
  fakebin=$(fake_pc02 "$dir")
  fixture="$dir/straggler-fail.test.sh"
  cat > "$fixture" <<SH
#!/usr/bin/env bash
if { true >&9; } 2>/dev/null; then
  date +%s > $(printf '%q' "$dir/straggler-started")
  sleep 30 >&9 2>&1 &
fi
echo "not ok - intentional fixture failure"
exit 1
SH
  chmod +x "$fixture"

  out=$(PATH="$fakebin:$PATH" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$fixture" 2>&1)
  status=$?
  expect_code 1 "$status" "a failing remote suite's exit code must come back unchanged: $out"
  assert_contains "$out" "PC02 idle and ready; running tests remotely" "the run never went remote: $out"
  assert_contains "$out" "exit=1" "the remote fm-test-run.sh markers did not come back: $out"
  # Mirror sync runs before the suite and can take as long as the host is
  # loaded, so the channel hold is measured from the moment the suite's last
  # script leaves its straggler; a surviving straggler then adds its full
  # sleep, while a killed one returns within a second or two of the suite.
  [ -s "$dir/straggler-started" ] || fail "the fixture never recorded leaving its straggler: $out"
  held=$(( $(date +%s) - $(cat "$dir/straggler-started") ))
  [ "$held" -lt 25 ] || fail "a straggler holding the channel kept the run open ${held}s after the suite finished: $out"
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
  out=$(PATH="$fakebin:$PATH" \
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

test_remote_lint_runs_local_lint_and_propagates_exit() {
  local dir fakebin out status
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  dir="$TMP_ROOT/remote-lint"
  fakebin=$(fake_pc02 "$dir")
  out=$(PATH="$fakebin:$PATH" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash FM_FAKE_CAPTURE_COMPUTE=1 \
    FM_FAKE_CAPTURE_COMPUTE_EXIT=7 "$SCRIPT" --lint-partitions 2>&1)
  status=$?
  expect_code 7 "$status" "remote lint must return its own exit code unchanged: $out"
  assert_contains "$out" "PC02 idle and ready; running lint remotely" "the lint run never went remote: $out"
  assert_contains "$out" "compute_argv=local-lint" "remote lint did not invoke the local-lint mode: $out"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "remote lint left a mirror behind: $out"
  pass "remote lint mode invokes local-lint and returns its exit code"
}

test_lint_local_fallback_runs_changed_file_lint() {
  local dir out status
  dir="$TMP_ROOT/lint-local-fallback"
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-pc02-test-offload.sh" "$ROOT/bin/fm-primary-scope-lib.sh" "$ROOT/bin/fm-pc02-hygiene-lib.sh" "$dir/bin/"
  cat > "$dir/bin/fm-lint.sh" <<'LINT'
#!/usr/bin/env bash
printf 'changed-file-lint argv=%s\n' "$*"
exit "${LINT_RC:-0}"
LINT
  cat > "$dir/bin/fm-test-compute.sh" <<'COMPUTE'
#!/usr/bin/env bash
printf 'canonical-lint %s\n' "$*"
exit 0
COMPUTE
  chmod +x "$dir/bin/"*.sh
  out=$(FM_PC02_OFFLOAD_DISABLE=1 LINT_RC=9 "$dir/bin/fm-pc02-test-offload.sh" --lint-partitions 2>&1)
  status=$?
  expect_code 9 "$status" "PC01 lint fallback must return bin/fm-lint.sh's status: $out"
  assert_contains "$out" "changed-file-lint argv=" "PC01 lint fallback did not run bin/fm-lint.sh without arguments: $out"
  [[ "$out" != *'argv=--partition'* ]] || fail "PC01 lint fallback passed canonical partition arguments: $out"
  [[ "$out" != *'canonical-lint'* ]] || fail "PC01 lint fallback ran the canonical local-lint mode: $out"
  pass "PC01 lint fallback runs the changed-file lint instead of canonical partitions"
}

test_remote_invocation_inherits_fm_test_run_scheduler() {
  local dir fakebin out status
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  dir="$TMP_ROOT/remote-bounds"
  fakebin=$(fake_pc02 "$dir")
  cat > "$dir/bounded.test.sh" <<SH
#!/usr/bin/env bash
exec 7> "$dir/serial.lock"
flock -n 7 || { echo 'not ok - concurrent remote tests'; exit 1; }
sleep 1
echo 'ok - serial fixture'
SH
  chmod +x "$dir/bounded.test.sh"
  cp "$dir/bounded.test.sh" "$dir/second.test.sh"
  out=$(PATH="$fakebin:$PATH" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$dir/bounded.test.sh" "$dir/second.test.sh" --per-script-timeout-secs 0 2>&1)
  status=$?
  expect_code 0 "$status" "unproven scripts must stay serial under the inherited scheduler: $out"
  assert_contains "$out" "running tests remotely" "serial test ran locally: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^ok - serial fixture$')" -eq 2 ] \
    || fail "both fixture scripts should have run: $out"
  # FM_TEST_HOST_LOAD is printed only by fm-test-run.sh's own auto scheduler,
  # so its presence proves no --jobs was forced onto the remote invocation;
  # these unproven fixtures are then kept serial by that scheduler.
  assert_contains "$out" "FM_TEST_HOST_LOAD" \
    "the remote run did not use fm-test-run.sh's own scheduler: $out"
  assert_contains "$out" "jobs=1" \
    "unproven scripts must be scheduled serially: $out"
  pass "an offloaded run keeps fm-test-run.sh's own scheduler and per-script bound"
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

  out=$(PATH="$fakebin:$PATH" \
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
  local dir fakebin out status jobs threads cap
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  dir="$TMP_ROOT/remote-jobs-bounds"
  threads=10
  fakebin=$(fake_pc02 "$dir" "$threads")
  # The fake host pins its own thread count, independent of this runner's
  # nproc, so a wrapper reading the local host instead cannot pass.
  cap=$((threads / 2))
  [ "$cap" -ge 1 ] || cap=1
  # Use a private remote runner stand-in to observe argv/environment at the
  # transfer boundary. The real scheduler's isolation policy has separate tests.
  export FM_FAKE_CAPTURE_RUNNER=1
  for jobs in default override split equals cap-split cap-equals below; do
    local -a args=()
    case "$jobs" in
      split) args=(--jobs 4) ;;
      equals) args=(--jobs=3) ;;
      cap-split) args=(--jobs 9999) ;;
      cap-equals) args=(--jobs=9999) ;;
      below) args=(--jobs 1) ;;
    esac
    out=$(PATH="$fakebin:$PATH" \
      FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash FM_PC02_OFFLOAD_JOBS="$([ "$jobs" = override ] && echo 6 || echo 8)" \
      "$SCRIPT" --all "${args[@]+"${args[@]}"}" 2>&1)
    status=$?
    expect_code 0 "$status" "remote jobs fixture failed: $out"
    case "$jobs" in
      default) assert_contains "$out" 'auto_jobs=8' "missing default: $out" ;;
      override) assert_contains "$out" 'auto_jobs=6' "missing override: $out" ;;
      split) assert_contains "$out" 'argv=--all --jobs 4' "split jobs lost: $out" ;;
      equals) assert_contains "$out" 'argv=--all --jobs=3' "equals jobs lost: $out" ;;
      cap-split)
        assert_contains "$out" "argv=--all --jobs $cap" "an explicit split --jobs was not capped: $out"
        assert_contains "$out" "capping --jobs 9999 to $cap" "the cap was not explained: $out"
        ;;
      cap-equals)
        assert_contains "$out" "argv=--all --jobs=$cap" "an explicit equals --jobs was not capped: $out"
        ;;
      below)
        assert_contains "$out" 'argv=--all --jobs 1' "a below-cap caller value was not preserved: $out"
        assert_not_contains "$out" 'capping --jobs' "a below-cap caller value was capped: $out"
        ;;
    esac
    assert_contains "$out" '--per-script-timeout-secs 3000' "default script cap changed: $out"
    assert_contains "$out" 'remote=1' "remote suite did not carry the offload admission marker: $out"
  done
  # One slot may use the whole machine: the cap is the remote thread count.
  out=$(PATH="$fakebin:$PATH" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash FM_PC02_OFFLOAD_SLOTS=1 \
    "$SCRIPT" --all --jobs 9999 2>&1)
  status=$?
  expect_code 0 "$status" "single-slot jobs fixture failed: $out"
  assert_contains "$out" "argv=--all --jobs $threads" \
    "one slot did not get the whole host's thread count: $out"
  # Without an explicit --jobs or FM_PC02_OFFLOAD_JOBS, the default auto
  # ceiling is capped per slot too: 16 PC02 threads / 3 slots => 5.
  local default_dir="$TMP_ROOT/remote-jobs-default-cap"
  local default_fakebin
  default_fakebin=$(fake_pc02 "$default_dir" 16)
  out=$(PATH="$default_fakebin:$PATH" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash FM_PC02_OFFLOAD_SLOTS=3 \
    env -u FM_PC02_OFFLOAD_JOBS "$SCRIPT" --all 2>&1)
  status=$?
  expect_code 0 "$status" "default jobs cap fixture failed: $out"
  assert_contains "$out" 'auto_jobs=5' \
    "the default auto ceiling was not capped per slot: $out"
  unset FM_FAKE_CAPTURE_RUNNER
  printf '#!/usr/bin/env bash\nsleep 60\n' > "$dir/timeout.test.sh"
  chmod +x "$dir/timeout.test.sh"
  out=$(PATH="$fakebin:$PATH" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash FM_PC02_OFFLOAD_SCRIPT_TIMEOUT_SECS=1 \
    "$SCRIPT" "$dir/timeout.test.sh" --per-script-timeout-secs 0 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "remote script cap did not bound an unlimited caller: $out"
  assert_contains "$out" "per_script_timeout_secs=1" "script timeout override was lost: $out"
  assert_contains "$out" "exit=124" "script cap did not time out its fixture: $out"
  pass "remote jobs preserve both caller forms, default to eight, and allow environment overrides with a script cap"
}

test_shared_browser_resolver_prefers_chromium_to_google_chrome() {
  local dir found
  dir="$TMP_ROOT/browser-selection-order"
  mkdir -p "$dir/home" "$dir/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/chromium"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/google-chrome"
  chmod +x "$dir/bin/chromium" "$dir/bin/google-chrome"
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  found=$("$BASH" -c 'PATH="$1"; HOME="$2"; . "$3/bin/fm-test-chrome.sh"; find_chrome' \
    bash "$dir/bin" "$dir/home" "$ROOT") \
    || fail "the shared browser resolver found no PATH browser"
  [ "$found" = "$dir/bin/chromium" ] \
    || fail "the shared resolver selected $found instead of Chromium"
  pass "the shared suite and parity resolver prefers Chromium over Google Chrome"
}

test_environment_parity_match_allows_offload() {
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  local dir fakebin out status local_home
  dir="$TMP_ROOT/parity-match"
  fakebin=$(fake_pc02 "$dir")
  local_home="$dir/pc01-home"
  install_cache_chrome "$local_home" direct >/dev/null
  install_cache_chrome "$dir/home" direct >/dev/null
  printf '#!/usr/bin/env bash\necho "ok - parity match"\n' > "$dir/parity.test.sh"
  chmod +x "$dir/parity.test.sh"
  out=$(PATH="$fakebin:$PATH" HOME="$local_home" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash "$SCRIPT" "$dir/parity.test.sh" 2>&1)
  status=$?
  expect_code 0 "$status" "matching PC01/PC02 test surfaces should permit offload: $out"
  assert_contains "$out" "running tests remotely" "matching parity did not proceed remotely: $out"
  assert_contains "$out" "claimed PC02 slot 1 of 2" "default slot count was not two: $out"
  pass "matching PC01 and PC02 parity admits the default two-slot offload"
}

test_environment_open_file_capacity() {
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  local remote_limit dir fakebin local_home out status
  for remote_limit in 512 256 128 unlimited invalid ''; do
    dir="$TMP_ROOT/parity-open-files-${remote_limit:-missing}"
    fakebin=$(fake_pc02 "$dir")
    local_home="$dir/pc01-home"
    install_cache_chrome "$local_home" direct >/dev/null
    install_cache_chrome "$dir/home" direct >/dev/null
    printf '#!/usr/bin/env bash\necho "ok - open-file capacity"\n' > "$dir/capacity.test.sh"
    chmod +x "$dir/capacity.test.sh"
    out=$(
      ulimit -S -n 256 || exit 1
      PATH="$fakebin:$PATH" HOME="$local_home" \
        FM_FAKE_PARITY_MODE=open-file-limit FM_FAKE_OPEN_FILES_LIMIT="$remote_limit" \
        FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash "$SCRIPT" "$dir/capacity.test.sh" 2>&1
    )
    status=$?
    expect_code 0 "$status" "open-file capacity case '$remote_limit' failed: $out"
    case "$remote_limit" in
      512|256|unlimited)
        assert_contains "$out" "running tests remotely" "sufficient PC02 limit '$remote_limit' did not offload: $out"
        assert_not_contains "$out" "running on PC01" "sufficient PC02 limit '$remote_limit' fell back: $out"
        ;;
      *)
        assert_contains "$out" "ulimit.open_files below PC01 or invalid" "insufficient/invalid PC02 limit lacked a diagnostic: $out"
        assert_contains "$out" "PC01='256', PC02='$remote_limit'" "limit diagnostic omitted the compared values: $out"
        assert_contains "$out" "running on PC01" "insufficient/invalid PC02 limit did not fall back: $out"
        assert_not_contains "$out" "running tests remotely" "insufficient/invalid PC02 limit offloaded: $out"
        ;;
    esac
  done
  pass "PC02 open-file capacity accepts higher/equal limits and refuses lower or invalid limits"
}

test_raised_open_file_limit_admits_and_reaches_remote_run() {
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  local dir fakebin local_home out status hard
  hard=$(ulimit -Hn)
  case "$hard" in
    unlimited) ;;
    ''|*[!0-9]*) pass "skip: cannot read the host hard open-file limit"; return ;;
    *) [ "$hard" -ge 1024 ] || { pass "skip: host hard open-file limit is below 1024"; return; } ;;
  esac
  dir="$TMP_ROOT/remote-open-files-raised"
  fakebin=$(fake_pc02 "$dir")
  local_home="$dir/pc01-home"
  install_cache_chrome "$local_home" direct >/dev/null
  cat > "$dir/nofile.test.sh" <<'SH'
#!/usr/bin/env bash
echo "suite_soft_nofile=$(ulimit -Sn)"
SH
  chmod +x "$dir/nofile.test.sh"
  out=$(
    ulimit -S -n 1024 || exit 1
    PATH="$fakebin:$PATH" HOME="$local_home" \
      FM_FAKE_SSH_NOFILE_SOFT=512 FM_FAKE_SSH_NOFILE_HARD=1024 \
      FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash "$SCRIPT" "$dir/nofile.test.sh" 2>&1
  )
  status=$?
  expect_code 0 "$status" "a low soft open-file limit on PC02 must not block the raised run: $out"
  assert_contains "$out" "running tests remotely" \
    "the raised PC02 soft open-file limit did not satisfy the parity rule: $out"
  assert_contains "$out" "suite_soft_nofile=1024" \
    "the remote suite did not inherit PC02's hard open-file limit: $out"

  out=$(
    ulimit -S -n 1024 || exit 1
    PATH="$fakebin:$PATH" HOME="$local_home" \
      FM_FAKE_SSH_NOFILE_SOFT=256 FM_FAKE_SSH_NOFILE_HARD=512 \
      FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash "$SCRIPT" "$dir/nofile.test.sh" 2>&1
  )
  status=$?
  expect_code 0 "$status" "a hard limit below PC01's must still run locally: $out"
  assert_contains "$out" "ulimit.open_files below PC01 or invalid" \
    "raising PC02's soft limit must not admit a hard limit below PC01's: $out"
  assert_contains "$out" "running on PC01" \
    "an insufficient PC02 hard limit did not route the suite locally: $out"
  pass "offload raises PC02's soft open-file limit to its hard limit without loosening the parity rule"
}

test_environment_version_mismatch_falls_back_with_field() {
  local dir fakebin out status
  dir="$TMP_ROOT/parity-version-mismatch"
  fakebin=$(fake_pc02 "$dir")
  out=$(PATH="$fakebin:$PATH" \
    FM_FAKE_PARITY_MODE=version-mismatch FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "a version mismatch must run locally: $out"
  assert_contains "$out" "tool.git" "the fallback diagnostic did not name the mismatching tool: $out"
  assert_contains "$out" "fake-PC02-git-version" "the fallback diagnostic omitted PC02's value: $out"
  assert_contains "$out" "running on PC01" "a mismatched host was not routed locally: $out"
  pass "a PC02 tool-version mismatch names the surface and runs locally"
}

test_hung_local_browser_dependency_probe_falls_back() {
  local dir fakebin out status start elapsed
  dir="$TMP_ROOT/parity-browser-probe-timeout"
  fakebin=$(fake_pc02 "$dir")
  start=$SECONDS
  out=$(PATH="$fakebin:$PATH" \
    FM_FAKE_LDD_MODE=local-hang FM_FAKE_PARITY_MODE=local-browser-dependency-hang \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  elapsed=$((SECONDS - start))
  expect_code 0 "$status" "a timed-out local browser probe must still run the suite locally: $out"
  [ "$elapsed" -lt 20 ] || fail "the local browser dependency probe exceeded its bound (${elapsed}s): $out"
  assert_contains "$out" "browser dependency probe timed out running ldd" \
    "the fallback did not clearly identify the timed-out dependency probe: $out"
  assert_contains "$out" "running on PC01" "a browser-probe timeout did not select the local run: $out"
  assert_not_contains "$out" "running tests remotely" "a browser-probe timeout ran the remote suite: $out"
  if grep -F 'fm-pc02-test-slot-' "$dir/ssh.log" >/dev/null 2>&1; then
    fail "a browser-probe timeout claimed a remote slot: $(cat "$dir/ssh.log")"
  fi
  pass "a hanging local browser dependency probe times out and routes locally"
}

test_term_ignoring_parity_probes_are_killed_and_route_locally() {
  local dir fakebin hangbin local_home out status start elapsed browser
  dir="$TMP_ROOT/parity-probe-kill"
  fakebin=$(fake_pc02 "$dir")
  local_home="$dir/pc01-home"
  browser=$(install_cache_chrome "$local_home" direct)
  hangbin="$dir/hangbin"
  mkdir -p "$hangbin"
  cat > "$hangbin/herdr" <<SH
#!/usr/bin/env bash
if [ "\${HOME:-}" = "$dir/home" ]; then echo 'herdr fixture 0.0.0'; exit 0; fi
trap '' TERM INT
exec sleep 120
SH
  chmod +x "$hangbin/herdr"
  cat > "$browser" <<'SH'
#!/usr/bin/env bash
trap '' TERM INT
exec sleep 120
SH
  chmod +x "$browser"
  start=$SECONDS
  out=$(PATH="$hangbin:$fakebin:$PATH" HOME="$local_home" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  elapsed=$((SECONDS - start))
  expect_code 0 "$status" "a TERM-ignoring parity probe must still route the run locally: $out"
  [ "$elapsed" -lt 50 ] \
    || fail "TERM-ignoring version probes outlived their 15-second deadline (${elapsed}s): $out"
  assert_contains "$out" "tool.herdr version could not be established" \
    "a stalled tool version probe was not recorded as unestablished: $out"
  assert_contains "$out" "chromium.selected_version version could not be established" \
    "a stalled browser version probe was not recorded as unestablished: $out"
  assert_contains "$out" "running on PC01" "stalled version probes did not route the run locally: $out"
  pass "TERM-ignoring tool and browser version probes are killed at their deadline"
}

test_selected_cached_browser_version_mismatch_falls_back() {
  local dir fakebin out status local_home
  dir="$TMP_ROOT/parity-browser-version-mismatch"
  fakebin=$(fake_pc02 "$dir")
  local_home="$dir/pc01-home"
  install_cache_chrome "$local_home" direct >/dev/null
  install_cache_chrome "$dir/home" direct >/dev/null
  out=$(PATH="$fakebin:$PATH" HOME="$local_home" \
    FM_FAKE_PARITY_MODE=browser-version-mismatch FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "a selected headless-shell version mismatch must run locally: $out"
  assert_contains "$out" "chromium.selected_version" "the fallback did not name the selected browser version: $out"
  assert_contains "$out" "Chrome Headless Shell 1229.0" "the fallback omitted PC02's selected browser version: $out"
  assert_contains "$out" "running on PC01" "different cached browser versions were not routed locally: $out"
  pass "a cached headless-shell version mismatch names the surface and runs locally"
}

test_chromium_missing_library_falls_back_with_field() {
  local dir fakebin out status
  dir="$TMP_ROOT/parity-chromium-missing-library"
  fakebin=$(fake_pc02 "$dir")
  out=$(PATH="$fakebin:$PATH" \
    FM_FAKE_PARITY_MODE=chromium-not-found FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "an unresolved PC02 Chromium library must run locally: $out"
  assert_contains "$out" "PC02 Chromium at" "the fallback diagnostic did not name the host and browser path: $out"
  assert_contains "$out" "UNRESOLVED:libasound.so.2" "the fallback diagnostic omitted the unresolved soname: $out"
  assert_contains "$out" "running on PC01" "an unresolved Chromium library was not routed locally: $out"
  pass "a PC02 Chromium library failure names the library and runs locally"
}

test_chromium_dependency_soname_difference_falls_back() {
  local dir fakebin out status local_home
  dir="$TMP_ROOT/parity-chromium-different-dependencies"
  fakebin=$(fake_pc02 "$dir")
  local_home="$dir/pc01-home"
  install_cache_chrome "$local_home" direct >/dev/null
  install_cache_chrome "$dir/home" direct >/dev/null
  out=$(PATH="$fakebin:$PATH" HOME="$local_home" \
    FM_FAKE_PARITY_MODE=dependency-mismatch FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "different Chromium soname sets must run locally: $out"
  assert_contains "$out" "chromium.dependencies" "the fallback diagnostic did not identify the dependency set: $out"
  assert_contains "$out" "libm.so.6" "the fallback diagnostic omitted the differing soname: $out"
  assert_contains "$out" "running on PC01" "different Chromium dependencies were not routed locally: $out"
  pass "different resolved Chromium sonames route locally with the named difference"
}

test_chromium_wrapper_resolution_does_not_false_fallback() {
  local dir fakebin out status local_home
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  dir="$TMP_ROOT/parity-chromium-wrapper"
  fakebin=$(fake_pc02 "$dir")
  local_home="$dir/pc01-home"
  install_cache_chrome "$local_home" wrapper >/dev/null
  install_cache_chrome "$dir/home" wrapper >/dev/null
  printf '#!/usr/bin/env bash\necho "ok - wrapper"\n' > "$dir/wrapper.test.sh"
  chmod +x "$dir/wrapper.test.sh"
  out=$(PATH="$fakebin:$PATH" HOME="$local_home" \
    FM_FAKE_LDD_MODE=wrapper FM_FAKE_LDD_LOG="$dir/ldd.log" FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$dir/wrapper.test.sh" 2>&1)
  status=$?
  expect_code 0 "$status" "a wrapper that resolves to a dynamic browser must permit offload: $out"
  assert_contains "$out" "running tests remotely" "the wrapper browser caused a false local fallback: $out"
  [ "$(grep -Fc "$WRAPPER_TARGET_NAME" "$dir/ldd.log")" -eq 2 ] \
    || fail "the fake ldd did not inspect the wrapper's resolved executable on both hosts: $(cat "$dir/ldd.log")"
  pass "a launcher browser resolves to its executable without a false fallback"
}

test_chromium_wrapper_compares_resolved_sonames() {
  local dir fakebin out status local_home
  dir="$TMP_ROOT/parity-chromium-wrapper-dependencies"
  fakebin=$(fake_pc02 "$dir")
  local_home="$dir/pc01-home"
  install_cache_chrome "$local_home" wrapper >/dev/null
  install_cache_chrome "$dir/home" wrapper >/dev/null
  out=$(PATH="$fakebin:$PATH" HOME="$local_home" \
    FM_FAKE_LDD_MODE=wrapper FM_FAKE_LDD_LOG="$dir/ldd.log" \
    FM_FAKE_PARITY_MODE=wrapper-dependency-mismatch FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "different resolved wrapper sonames must run locally: $out"
  assert_contains "$out" "chromium.dependencies" "the wrapper dependency mismatch was not compared: $out"
  assert_contains "$out" "libc.so.6" "the wrapper's PC01 soname was omitted: $out"
  assert_contains "$out" "libm.so.6" "the wrapper's PC02 soname was omitted: $out"
  [ "$(grep -Fc "$WRAPPER_TARGET_NAME" "$dir/ldd.log")" -eq 2 ] \
    || fail "the fake ldd did not inspect each wrapper's resolved executable: $(cat "$dir/ldd.log")"
  pass "wrapper parity compares sonames from the resolved executable on both hosts"
}

# Start a fixture that holds one PC02 slot for the lifetime of the case.
hold_slot() {  # <dir> <slot> <marker>
  local dir=$1 slot=$2 marker=$3 _
  # shellcheck disable=SC2016 # Positional parameter belongs to the lock holder.
  flock "$dir/home/.fm-pc02-test-slot-$slot.lock" bash -c 'touch "$1"; sleep 60' bash "$marker" &
  HOLD_SLOT_PID=$!
  for _ in $(seq 1 300); do [ -f "$marker" ] && break; sleep 0.1; done
  [ -f "$marker" ] || fail "slot-$slot fixture did not acquire its lock"
}

release_slot() {  # <pid...>
  local pid
  for pid in "$@"; do
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}

test_one_of_two_busy_slots_still_runs_remotely() {
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  local dir fakebin out status first
  dir="$TMP_ROOT/remote-one-of-two"
  fakebin=$(fake_pc02 "$dir")
  printf '#!/usr/bin/env bash\necho "ok - second slot"\n' > "$dir/green.test.sh"
  chmod +x "$dir/green.test.sh"
  hold_slot "$dir" 1 "$dir/slot-1-held"
  first=$HOLD_SLOT_PID
  out=$(PATH="$fakebin:$PATH" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash "$SCRIPT" "$dir/green.test.sh" 2>&1)
  status=$?
  release_slot "$first"
  expect_code 0 "$status" "one busy of two slots must still run remotely: $out"
  assert_contains "$out" "claimed PC02 slot 2 of 2" "the run did not take the free second slot: $out"
  assert_contains "$out" "running tests remotely" "the second slot did not run remotely: $out"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "the second-slot run left its mirror behind"
  pass "one busy of two PC02 slots still runs the next suite remotely"
}

test_all_slots_busy_falls_back_locally() {
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  local dir fakebin out status first second
  dir="$TMP_ROOT/remote-all-busy"
  fakebin=$(fake_pc02 "$dir")
  hold_slot "$dir" 1 "$dir/slot-1-held"
  first=$HOLD_SLOT_PID
  hold_slot "$dir" 2 "$dir/slot-2-held"
  second=$HOLD_SLOT_PID
  out=$(PATH="$fakebin:$PATH" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash FM_PC02_OFFLOAD_SLOT_WAIT_SECS=2 \
    FM_PC02_OFFLOAD_SLOT_WAIT_INTERVAL_SECS=1 \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  release_slot "$first" "$second"
  expect_code 0 "$status" "a fully occupied PC02 must run locally after its bounded wait: $out"
  assert_contains "$out" "all 2 PC02 test slots are busy; waiting up to 2s for a free slot" \
    "the bounded slot wait was not announced: $out"
  assert_contains "$out" "all 2 PC02 test slots stayed busy through the 2s wait bound; running locally" \
    "the timeout fallback was not logged clearly: $out"
  [ "$(printf '%s\n' "$out" | grep -v '^fm-pc02-test-offload: ')" = "$LOCAL_PROOF_OUT" ] \
    || fail "the timeout fallback did not run the real local suite: $out"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "a fully occupied host received a new remote run"
  pass "busy PC02 slots are waited on up to the bound, then the suite runs locally"
}

test_malformed_slot_count_is_a_configuration_error() {
  local dir fakebin out status value
  dir="$TMP_ROOT/slots-invalid"
  fakebin=$(fake_pc02 "$dir")
  for value in 0 abc 17; do
    out=$(PATH="$fakebin:$PATH" \
      FM_PC02_OFFLOAD_SLOTS="$value" "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
    status=$?
    expect_code 2 "$status" "FM_PC02_OFFLOAD_SLOTS=$value must be a configuration error: $out"
    case "$value" in
      abc) assert_contains "$out" "must be a positive integer" \
        "the refusal did not ask for an integer: $out" ;;
      *) assert_contains "$out" "must be between 1 and 16" \
        "the refusal did not state the accepted range: $out" ;;
    esac
    assert_contains "$out" "FM_PC02_OFFLOAD_SLOTS" \
      "the refusal did not name the rejected setting: $out"
    assert_contains "$out" "got '$value'" "the refusal omitted the rejected slot count: $out"
    assert_not_contains "$out" "running tests remotely" \
      "FM_PC02_OFFLOAD_SLOTS=$value still ran the suite remotely: $out"
    assert_not_contains "$out" "$LOCAL_PROOF_OUT" \
      "FM_PC02_OFFLOAD_SLOTS=$value still ran the suite: $out"
  done
  [ ! -e "$dir/ssh.log" ] || fail "a malformed slot count still reached PC02: $(cat "$dir/ssh.log")"
  pass "a malformed FM_PC02_OFFLOAD_SLOTS exits 2 and runs no tests"
}

test_single_slot_mode_keeps_the_old_fallback() {
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  local dir fakebin out status first
  dir="$TMP_ROOT/remote-single-slot"
  fakebin=$(fake_pc02 "$dir")
  hold_slot "$dir" 1 "$dir/slot-1-held"
  first=$HOLD_SLOT_PID
  out=$(PATH="$fakebin:$PATH" \
    FM_PC02_OFFLOAD_SLOTS=1 FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    FM_PC02_OFFLOAD_SLOT_WAIT_SECS=0 \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  release_slot "$first"
  expect_code 0 "$status" "FM_PC02_OFFLOAD_SLOTS=1 with wait 0 must keep the single-slot fallback: $out"
  assert_contains "$out" "all 1 PC02 test slots are busy; running locally" \
    "the single-slot fallback did not name its limit: $out"
  assert_not_contains "$out" "waiting up to" "a zero wait still announced a wait: $out"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "the single busy slot received a new remote run"
  pass "FM_PC02_OFFLOAD_SLOTS=1 with a zero wait keeps the immediate single-slot fallback"
}

test_default_wait_bound_is_ten_minutes() {
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: slot-wait default case needs rsync and flock"; return
  fi
  local dir fakebin out pid first second _
  dir="$TMP_ROOT/default-wait-bound"
  fakebin=$(fake_pc02 "$dir")
  hold_slot "$dir" 1 "$dir/slot-1-held"
  first=$HOLD_SLOT_PID
  hold_slot "$dir" 2 "$dir/slot-2-held"
  second=$HOLD_SLOT_PID
  PATH="$fakebin:$PATH" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" > "$dir/out.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 600); do
    grep -q "waiting up to 600s for a free slot" "$dir/out.log" 2>/dev/null && break
    sleep 0.1
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  release_slot "$first" "$second"
  out=$(cat "$dir/out.log")
  assert_contains "$out" "all 2 PC02 test slots are busy; waiting up to 600s for a free slot" \
    "the default wait bound is not the expected ten minutes: $out"
  pass "an occupied PC02 waits at most the 600s default bound"
}

test_caller_wall_budget_skips_the_pc02_wait() {
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: slot-wait budget case needs rsync and flock"; return
  fi
  local dir fakebin first second out status
  dir="$TMP_ROOT/wall-budget-slots"
  fakebin=$(fake_pc02 "$dir")
  hold_slot "$dir" 1 "$dir/slot-1-held"
  first=$HOLD_SLOT_PID
  hold_slot "$dir" 2 "$dir/slot-2-held"
  second=$HOLD_SLOT_PID
  out=$(PATH="$fakebin:$PATH" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" --max-wall-ms 600000 "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  release_slot "$first" "$second"
  expect_code 0 "$status" "a fully busy PC02 with a caller wall budget must run locally at once: $out"
  assert_contains "$out" "all 2 PC02 test slots are busy; running locally" \
    "the budgeted slot wait did not fall back at once: $out"
  assert_not_contains "$out" "waiting up to" "a caller wall budget still waited for a free slot: $out"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "a budgeted busy-slot run still reached PC02"
  pass "a caller wall budget clamps the slot wait to zero"
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
  out=$(PATH="$fakebin:$PATH" \
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

  PATH="$fakebin:$PATH" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$fixture" > "$dir/out.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 "$REMOTE_SUITE_START_TRIES"); do
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

  PATH="$fakebin:$PATH" FM_FAKE_SSH_DETACH=1 \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$fixture" > "$dir/out.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 "$REMOTE_SUITE_START_TRIES"); do
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

  PATH="$fakebin:$PATH" FM_FAKE_SSH_DETACH=1 \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$fixture" > "$dir/out.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 "$REMOTE_SUITE_START_TRIES"); do
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
  for _ in $(seq 1 50); do
    flock -n "$dir/home/.fm-pc02-test-slot-1.lock" true && break
    sleep 0.1
  done
  flock -n "$dir/home/.fm-pc02-test-slot-1.lock" true || fail "the slot stayed held after the suite ended"
  pkill -TERM -f "$dir/home" 2>/dev/null || true
  pass "abrupt loss of the driver stops the remote suite and frees the slot"
}

test_two_concurrent_offloads_take_both_slots() {
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  local dir fakebin first second a b c _ out
  dir="$TMP_ROOT/concurrent"
  fakebin=$(fake_pc02 "$dir")
  cat > "$dir/claimant.test.sh" <<SH
#!/usr/bin/env bash
if { true >&9; } 2>/dev/null; then
  echo started >> "$dir/started"
  for _ in \$(seq 1 300); do [ -f "$dir/release" ] && exit 0; sleep 0.1; done
  exit 1
fi
echo 'ok - local fallback'
SH
  chmod +x "$dir/claimant.test.sh"
  PATH="$fakebin:$PATH" FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$dir/claimant.test.sh" > "$dir/first.log" 2>&1 &
  first=$!
  PATH="$fakebin:$PATH" FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$dir/claimant.test.sh" > "$dir/second.log" 2>&1 &
  second=$!
  for _ in $(seq 1 300); do
    [ -s "$dir/started" ] || { sleep 0.1; continue; }
    [ "$(wc -l < "$dir/started" | tr -d ' ')" = 2 ] && break
    sleep 0.1
  done
  { [ -s "$dir/started" ] && [ "$(wc -l < "$dir/started" | tr -d ' ')" = 2 ]; } \
    || fail "two concurrent offloads did not both take a slot: $(cat "$dir/first.log" "$dir/second.log" 2>/dev/null)"
  flock -n "$dir/home/.fm-pc02-test-slot-1.lock" true && fail "slot 1 was free while two claimants ran"
  flock -n "$dir/home/.fm-pc02-test-slot-2.lock" true && fail "slot 2 was free while two claimants ran"
  # Both slots held: a third suite must fall back locally and say so.
  out=$(PATH="$fakebin:$PATH" FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    FM_PC02_OFFLOAD_SLOT_WAIT_SECS=0 "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  c=$?
  expect_code 0 "$c" "a third suite against two busy slots must run locally: $out"
  assert_contains "$out" "all 2 PC02 test slots are busy; running locally" \
    "the third suite did not name both busy slots: $out"
  touch "$dir/release"
  wait "$first"; a=$?
  wait "$second"; b=$?
  expect_code 0 "$a" "first claimant failed: $(cat "$dir/first.log")"
  expect_code 0 "$b" "second claimant failed: $(cat "$dir/second.log")"
  [ "$(wc -l < "$dir/started" | tr -d ' ')" = 2 ] || fail "more than two claimants ran remotely"
  flock -n "$dir/home/.fm-pc02-test-slot-1.lock" true || fail "winner retained slot 1"
  flock -n "$dir/home/.fm-pc02-test-slot-2.lock" true || fail "winner retained slot 2"
  pass "two concurrent offloads take both PC02 slots and a third falls back locally"
}

test_busy_slots_wait_for_a_free_slot() {
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  local dir fakebin out status first second pid _
  dir="$TMP_ROOT/remote-busy-wait"
  fakebin=$(fake_pc02 "$dir")
  printf '#!/usr/bin/env bash\necho "ok - waited slot"\n' > "$dir/green.test.sh"
  chmod +x "$dir/green.test.sh"
  hold_slot "$dir" 1 "$dir/slot-1-held"
  first=$HOLD_SLOT_PID
  hold_slot "$dir" 2 "$dir/slot-2-held"
  second=$HOLD_SLOT_PID
  PATH="$fakebin:$PATH" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    FM_PC02_OFFLOAD_SLOT_WAIT_SECS=60 FM_PC02_OFFLOAD_SLOT_WAIT_INTERVAL_SECS=1 \
    "$SCRIPT" "$dir/green.test.sh" > "$dir/out.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 600); do
    grep -q "waiting up to 60s" "$dir/out.log" 2>/dev/null && break
    sleep 0.1
  done
  if ! grep -q "waiting up to 60s" "$dir/out.log" 2>/dev/null; then
    release_slot "$first" "$second"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "a busy PC02 never announced its slot wait: $(cat "$dir/out.log")"
  fi
  release_slot "$first"
  for _ in $(seq 1 300); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  wait "$pid"
  status=$?
  release_slot "$second"
  out=$(cat "$dir/out.log")
  expect_code 0 "$status" "waiting for a slot did not run the suite remotely: $out"
  assert_contains "$out" "claimed PC02 slot" "the waiter never took the freed slot: $out"
  assert_contains "$out" "running tests remotely" "the waiter did not run remotely after the slot freed: $out"
  assert_not_contains "$out" "running locally" "the waiter fell back locally instead of taking the freed slot: $out"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "the waited run left its mirror behind"
  pass "a fully busy PC02 is waited on and the run takes the first slot that frees"
}

test_slot_file_and_env_precedence() {
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  local dir fakebin config slots_file out status
  dir="$TMP_ROOT/slot-file"
  fakebin=$(fake_pc02 "$dir" 16)
  config="$dir/config"
  mkdir -p "$config/firstmate"
  slots_file="$config/firstmate/pc02-offload-slots"
  export FM_FAKE_CAPTURE_RUNNER=1
  printf '4\n' > "$slots_file"
  out=$(PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$config" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash env -u FM_PC02_OFFLOAD_SLOTS "$SCRIPT" --all 2>&1)
  status=$?
  expect_code 0 "$status" "a machine slot file of 4 must run: $out"
  assert_contains "$out" 'auto_jobs=4' \
    "the machine slot file did not drive the per-slot worker cap (16/4=4): $out"
  # The same file is read again for the next run: no daemon restart needed.
  printf '2\n' > "$slots_file"
  out=$(PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$config" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash env -u FM_PC02_OFFLOAD_SLOTS "$SCRIPT" --all 2>&1)
  status=$?
  expect_code 0 "$status" "the changed machine slot file must apply to the next run: $out"
  assert_contains "$out" 'auto_jobs=8' \
    "the slot file was not re-read for the next run (16/2=8): $out"
  # A value written without its trailing newline (printf 6 > file) is still read.
  printf '6' > "$slots_file"
  out=$(PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$config" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash env -u FM_PC02_OFFLOAD_SLOTS "$SCRIPT" --all 2>&1)
  status=$?
  expect_code 0 "$status" "a slot file without a trailing newline must still apply: $out"
  assert_contains "$out" 'auto_jobs=2' \
    "a slot file without a trailing newline was not read (16/6=2): $out"
  # The environment wins over the file.
  out=$(PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$config" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash FM_PC02_OFFLOAD_SLOTS=4 "$SCRIPT" --all 2>&1)
  status=$?
  expect_code 0 "$status" "an environment slot override must run: $out"
  assert_contains "$out" 'auto_jobs=4' \
    "the environment did not override the machine slot file: $out"
  unset FM_FAKE_CAPTURE_RUNNER

  local bad badfake badconfig value
  bad="$TMP_ROOT/slot-file-invalid"
  badfake=$(fake_pc02 "$bad" 16)
  badconfig="$bad/config"
  mkdir -p "$badconfig/firstmate"
  for value in abc 17 ''; do
    printf '%s\n' "$value" > "$badconfig/firstmate/pc02-offload-slots"
    out=$(PATH="$badfake:$PATH" XDG_CONFIG_HOME="$badconfig" \
      FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash env -u FM_PC02_OFFLOAD_SLOTS "$SCRIPT" --all 2>&1)
    status=$?
    expect_code 2 "$status" "a malformed machine slot file '$value' must be a configuration error: $out"
    assert_contains "$out" "$badconfig/firstmate/pc02-offload-slots" \
      "the refusal did not name the machine slot file: $out"
    assert_contains "$out" "got '$value'" "the refusal omitted the rejected value: $out"
  done
  [ ! -e "$bad/ssh.log" ] || fail "a malformed machine slot file still reached PC02: $(cat "$bad/ssh.log")"
  pass "the machine slot file is read every run, the environment overrides it, and malformed values exit 2"
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
  out=$(PATH="$fakebin:$PATH" FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    FM_PC02_OFFLOAD_SLOTS=1 FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS=2 "$SCRIPT" "$dir/timeout.test.sh" 2>&1)
  status=$?
  expect_code 124 "$status" "dead owner's slot must be reclaimed and suite timeout preserved: $out"
  assert_contains "$out" 'running tests remotely' "dead lock file blocked the run: $out"
  flock -n "$dir/home/.fm-pc02-test-slot-1.lock" true || fail "timeout retained host claim"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "timeout left a mirror behind"
  pass "a dead owner's claim is reclaimed and the next run releases it on timeout"
}

test_missing_perl_falls_back_to_local() {
  local dir fakebin tools tool out status
  if ! command -v rsync >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync"; return
  fi
  dir="$TMP_ROOT/missing-perl"
  fakebin=$(fm_fakebin "$dir")
  tools="$dir/pc02-tools"
  mkdir -p "$tools"
  for tool in git python3 jq node shellcheck actionlint ruby chromium; do
    printf '#!/bin/sh\nexit 0\n' > "$tools/$tool"
    chmod +x "$tools/$tool"
  done
  ln -s "$(command -v bash)" "$tools/bash"
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
  *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;;
  *fm-pc02-environment-parity-probe*) cmd=\${!#}; bash -c "\$cmd"; exit \$? ;;
esac
probe_out=\$(PATH="$tools" "\$BASH" -c "\$*" 2>&1)
printf '%s\\n' "\${probe_out//resource:script-missing/resource:cpu=1 gpu=0}"
exit 0
SH
  chmod +x "$fakebin/ssh"

  out=$(PATH="$fakebin:$PATH" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "a PC02 without perl must still run the real suite locally: $out"
  case "$out" in
    *"PC02 missing required tool(s):"*perl*) : ;;
    *) fail "a PC02 missing perl, which the canonical lint hard-requires, was admitted: $out" ;;
  esac
  pass "PC02 missing perl falls back to a local run instead of failing the remote command"
}

test_preclaim_capacity_floors_route_local_naming_the_resource() {
  local which label dir fakebin out status
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  for which in MEM TMP DISK; do
    case "$which" in
      MEM) label=MemAvailable ;;
      TMP) label="$FM_PC02_OFFLOAD_TMP_ROOT free" ;;
      DISK) label="disk free" ;;
    esac
    dir="$TMP_ROOT/floor-low-$which"
    fakebin=$(fake_pc02 "$dir")
    out=$(env "FM_PC02_OFFLOAD_${which}_MIN_FREE_MB=999999999" \
      PATH="$fakebin:$PATH" \
      FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
      "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
    status=$?
    expect_code 0 "$status" "a $which capacity floor must still run the suite locally: $out"
    assert_contains "$out" "$label" "the $which floor fallback did not name the resource: $out"
    assert_contains "$out" "below the 999999999 MiB floor" "the $which floor fallback did not name the floor: $out"
    [ "$(remote_runs_left "$dir")" = 0 ] || fail "the $which floor still created a PC02 mirror"
  done
  pass "MemAvailable, /tmp free and disk free floors each route local and name the resource"
}

test_preclaim_capacity_never_removes_another_runs_roots() {
  local dir fakebin home base tmp out status
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  dir="$TMP_ROOT/preclaim-untouched"
  fakebin=$(fake_pc02 "$dir")
  home="$dir/home"
  base="$home/.fm-pc02-test-offload"
  tmp="$FM_PC02_OFFLOAD_TMP_ROOT"
  mkdir -p "$base/run-other" "$tmp/fm-test-run.other" "$tmp/fm-fixture-other/read-only"
  printf 'keep\n' > "$base/run-other/file"
  printf 'keep\n' > "$tmp/fm-test-run.other/file"
  printf 'keep\n' > "$tmp/fm-fixture-other/read-only/file"
  chmod 500 "$tmp/fm-fixture-other/read-only"
  printf '%s\n%s\n' "999999" 'linux-starttime=0 cmdline-hex=00' > "$tmp/fm-fixture-other/.fm-test-fixture"
  touch -d '3 hours ago' "$base/run-other" "$tmp/fm-test-run.other" \
    "$tmp/fm-fixture-other/.fm-test-fixture"
  out=$(PATH="$fakebin:$PATH" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "the capacity gate must not change the suite result: $out"
  assert_contains "$out" "running tests remotely" "the run never went remote: $out"
  [ "$(cat "$base/run-other/file" 2>/dev/null)" = keep ] \
    || fail "the pre-claim gate removed another run's offload root"
  [ "$(cat "$tmp/fm-test-run.other/file" 2>/dev/null)" = keep ] \
    || fail "the pre-claim gate removed another run's fm-test-run.* root"
  [ "$(cat "$tmp/fm-fixture-other/read-only/file" 2>/dev/null)" = keep ] \
    || fail "the pre-claim gate removed a marker-bearing fixture root"
  pass "the pre-claim capacity gate reads the host and never removes another run's root"
}

test_remote_run_keeps_its_tmpdir_in_the_mirror_and_cleans_read_only_content() {
  local dir fakebin fixture out status used
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  dir="$TMP_ROOT/run-tmpdir"
  fakebin=$(fake_pc02 "$dir")
  fixture="$dir/records-tmpdir.test.sh"
  cat > "$fixture" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$TMPDIR" > "$dir/tmpdir-used"
mkdir -p "\$TMPDIR/ro"
printf 'x\n' > "\$TMPDIR/ro/file"
chmod 500 "\$TMPDIR/ro"
# A read-only directory in the offload mirror outside the runner's own run
# root, so only the mirror cleanup can reap it.
[ -n "\$FM_TEST_RUN_ROOT" ] || { echo 'fixture: FM_TEST_RUN_ROOT not published' >&2; exit 1; }
mirror_tmp=\$(dirname "\$FM_TEST_RUN_ROOT")
printf '%s\n' "\$mirror_tmp" > "$dir/mirror-tmp-used"
mkdir -p "\$mirror_tmp/offload-ro"
printf 'x\n' > "\$mirror_tmp/offload-ro/file"
chmod 500 "\$mirror_tmp/offload-ro"
printf 'ok - recorded TMPDIR\n'
SH
  chmod +x "$fixture"
  out=$(PATH="$fakebin:$PATH" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash "$SCRIPT" "$fixture" 2>&1)
  status=$?
  expect_code 0 "$status" "the recording fixture must run green remotely: $out"
  assert_contains "$out" "running tests remotely" "the run never went remote: $out"
  used=$(cat "$dir/tmpdir-used" 2>/dev/null || true)
  mirror_tmp=$(cat "$dir/mirror-tmp-used" 2>/dev/null || true)
  case "$mirror_tmp" in
    */.fm-pc02-test-offload/run-*/tmp) : ;;
    *) fail "the remote run did not publish its mirror's temp root: '$mirror_tmp' ($out)" ;;
  esac
  case "$used" in
    "$mirror_tmp"/*) : ;;
    *) fail "the remote run did not place TMPDIR inside its own mirror: '$used' ($out)" ;;
  esac
  [ ! -e "$used" ] || fail "ownership cleanup left the run's read-only TMPDIR content at $used"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "the run left its mirror behind"
  pass "a remote run keeps its TMPDIR inside its mirror, and cleanup removes read-only content there"
}

test_remote_timeout_reaps_mirror_and_run_tmp_root() {
  local dir fakebin fixture out status used _
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  dir="$TMP_ROOT/timeout-reaps"
  fakebin=$(fake_pc02 "$dir")
  fixture="$dir/leaky.test.sh"
  cat > "$fixture" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$TMPDIR" > "$dir/tmpdir-used"
mkdir -p "\$TMPDIR/ro"
printf 'x\n' > "\$TMPDIR/ro/file"
chmod 500 "\$TMPDIR/ro"
# A read-only directory in the offload mirror outside the runner's own run
# root, so only the mirror cleanup can reap it.
[ -n "\$FM_TEST_RUN_ROOT" ] || { echo 'fixture: FM_TEST_RUN_ROOT not published' >&2; exit 1; }
mirror_tmp=\$(dirname "\$FM_TEST_RUN_ROOT")
printf '%s\n' "\$mirror_tmp" > "$dir/mirror-tmp-used"
mkdir -p "\$mirror_tmp/offload-ro"
printf 'x\n' > "\$mirror_tmp/offload-ro/file"
chmod 500 "\$mirror_tmp/offload-ro"
sleep 60
SH
  chmod +x "$fixture"
  out=$(PATH="$fakebin:$PATH" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS=45 \
    "$SCRIPT" "$fixture" 2>&1)
  status=$?
  expect_code 124 "$status" "the run timeout must still fail with 124: $out"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "the timeout left a mirror behind"
  used=$(cat "$dir/tmpdir-used" 2>/dev/null || true)
  if [ -n "$used" ]; then
    mirror_tmp=$(cat "$dir/mirror-tmp-used" 2>/dev/null || true)
    case "$mirror_tmp" in
      */.fm-pc02-test-offload/run-*/tmp) : ;;
      *) fail "the remote run did not publish its mirror's temp root: '$mirror_tmp' ($out)" ;;
    esac
    case "$used" in
      "$mirror_tmp"/*) : ;;
      *) fail "the remote run did not place TMPDIR inside its own mirror: '$used' ($out)" ;;
    esac
    [ ! -e "$used" ] || fail "the run's TMPDIR survived the timeout at $used"
  fi
  pass "a timed-out offload exits 124 and reaps its mirror and run-scoped TMPDIR"
}

test_malformed_hygiene_bound_is_a_configuration_error() {
  local out status setting
  for setting in FM_PC02_OFFLOAD_CLEANUP_TIMEOUT_SECS FM_PC02_OFFLOAD_MEM_MIN_FREE_MB; do
    out=$(env "$setting=abc" "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
    status=$?
    expect_code 2 "$status" "a malformed $setting must exit 2: $out"
    assert_contains "$out" "$setting must be a non-negative integer" \
      "the malformed $setting was not named: $out"
  done
  pass "a malformed capacity bound exits 2 without running the selected command"
}

test_help_prints_the_whole_documented_contract() {
  local out status
  out=$("$SCRIPT" --help 2>&1)
  status=$?
  expect_code 0 "$status" "--help must exit 0: $out"
  assert_contains "$out" "fm-pc02-test-offload.sh <fm-test-run.sh args...>" "--help omitted the usage line: $out"
  assert_contains "$out" "fm-pc02-test-offload.sh --lint-partitions" "--help omitted the lint usage line: $out"
  assert_contains "$out" "changed-file selection" "--help omitted the PC01 changed-file lint fallback: $out"
  assert_contains "$out" "bin/fm-lint.sh's changed-file lint on PC01" "--help omitted the PC01 changed-file lint exit contract: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_DISABLE=1" "--help omitted the disable override: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_PERSONAL_USE_FLAG" "--help omitted the personal-use switch override: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS" "--help omitted the run-timeout override: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_SLOTS" "--help omitted the concurrent-slot override: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_SLOT_WAIT_SECS" "--help omitted the slot-wait override: $out"
  assert_contains "$out" "pc02-offload-slots" "--help omitted the per-machine slot file: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_PARITY_TIMEOUT_SECS" "--help omitted the parity-probe timeout override: $out"
  assert_contains "$out" "integer from 1 to 16" "--help omitted the slot range and integer requirement: $out"
  assert_contains "$out" "exits 2" "--help omitted the configuration-error exit: $out"
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
test_preclaim_capacity_floors_route_local_naming_the_resource
test_preclaim_capacity_never_removes_another_runs_roots
test_remote_run_keeps_its_tmpdir_in_the_mirror_and_cleans_read_only_content
test_remote_timeout_reaps_mirror_and_run_tmp_root
test_malformed_hygiene_bound_is_a_configuration_error
test_disable_env_var_skips_every_pc02_check
test_immediate_fallbacks_do_not_wait_for_the_bound
test_slot_wait_knobs_are_validated
test_unreachable_host_falls_back_to_local
test_missing_required_tool_falls_back_to_local
test_slow_probe_times_out_and_falls_back
test_rsync_failure_falls_back_to_local
test_personal_use_switch_falls_back_to_local
test_unreadable_thread_count_falls_back_to_local
test_pc02_if_idle_flag_forwards_through_fm_test_run
test_missing_perl_falls_back_to_local
test_live_pc02_model_worker_does_not_block_offload
test_loaded_llama_swap_and_busy_probe_do_not_block_offload
test_remote_run_returns_suite_exit_code_despite_straggler
test_remote_run_passes_through_green_suite_and_json
test_remote_lint_runs_local_lint_and_propagates_exit
test_lint_local_fallback_runs_changed_file_lint
test_remote_invocation_inherits_fm_test_run_scheduler
test_remote_run_uses_7200_second_default_timeout
test_remote_jobs_and_script_bound
test_environment_parity_match_allows_offload
test_environment_open_file_capacity
test_raised_open_file_limit_admits_and_reaches_remote_run
test_environment_version_mismatch_falls_back_with_field
test_hung_local_browser_dependency_probe_falls_back
test_term_ignoring_parity_probes_are_killed_and_route_locally
test_selected_cached_browser_version_mismatch_falls_back
test_shared_browser_resolver_prefers_chromium_to_google_chrome
test_chromium_missing_library_falls_back_with_field
test_chromium_dependency_soname_difference_falls_back
test_chromium_wrapper_resolution_does_not_false_fallback
test_chromium_wrapper_compares_resolved_sonames
test_one_of_two_busy_slots_still_runs_remotely
test_busy_slots_wait_for_a_free_slot
test_all_slots_busy_falls_back_locally
test_slot_file_and_env_precedence
test_malformed_slot_count_is_a_configuration_error
test_single_slot_mode_keeps_the_old_fallback
test_default_wait_bound_is_ten_minutes
test_caller_wall_budget_skips_the_pc02_wait
test_decoy_host_suite_does_not_affect_remote_probe
test_term_mid_remote_run_removes_mirror_and_kills_suite
test_term_with_transport_ignoring_eof_stops_suite_and_frees_slot
test_sigkill_of_driver_stops_remote_suite_and_frees_slot
test_two_concurrent_offloads_take_both_slots
test_dead_owner_and_timeout_release_claim

echo "# all fm-pc02-test-offload tests passed"
