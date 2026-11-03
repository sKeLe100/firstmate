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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
case "$*" in
  *fm-pc02-environment-parity-probe*)
    cmd=${!#}
    bash -c "$cmd"
    exit $?
    ;;
esac
printf 'resource:cpu=1 gpu=0\nthreads:8\n'
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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
case "$*" in *fm-pc02-environment-parity-probe*) cmd=${!#}; bash -c "$cmd"; exit $? ;; esac
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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
case "$*" in *fm-pc02-environment-parity-probe*) cmd=${!#}; bash -c "$cmd"; exit $? ;; esac
printf 'llama-swap-running:0\nresource:cpu=1 gpu=0\nthreads:8\n'
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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
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
    out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
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
# The source worktree may contain normal read-only hook directories.
# Restore fixture permissions on cleanup, including signal/failed-run paths.
case "\$*" in *'rm -rf'*) chmod -R u+w "$dir/home/.fm-pc02-test-offload" 2>/dev/null || true ;; esac
HOME="$dir/home" exec bash -c "\$*"
SH
  cat > "$dir/fake-lint.sh" <<'LINT'
#!/usr/bin/env bash
echo "lint CI=${CI:-unset} argv=$*"
telemetry=
prev=
for a in "$@"; do
  [ "$prev" != "--telemetry" ] || telemetry=$a
  case "$a" in --telemetry=*) telemetry=${a#--telemetry=} ;; esac
  prev=$a
done
if [ -n "$telemetry" ]; then
  printf 'format\tfm-lint-telemetry-v1\n' > "$telemetry" || exit 3
  printf 'root\tbin/fm-lint.sh\n' > "${telemetry%.tsv}.roots.tsv" || exit 3
fi
exit "${FM_FAKE_LINT_EXIT:-0}"
LINT
  chmod +x "$dir/fake-lint.sh"
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
if [ -n "\${FM_FAKE_CAPTURE_LINT:-}" ] && [ -d "\${args[\${#args[@]}-1]}/bin" ]; then
  cp "$dir/fake-lint.sh" "\${args[\${#args[@]}-1]}/bin/fm-lint.sh"
  chmod +x "\${args[\${#args[@]}-1]}/bin/fm-lint.sh"
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
  [ "$elapsed" -lt 35 ] || fail "a straggler holding the channel kept the run open ${elapsed}s: $out"
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
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
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
  done
  # One slot may use the whole machine: the cap is the remote thread count.
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
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
  out=$(PATH="$default_fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash FM_PC02_OFFLOAD_SLOTS=3 \
    env -u FM_PC02_OFFLOAD_JOBS "$SCRIPT" --all 2>&1)
  status=$?
  expect_code 0 "$status" "default jobs cap fixture failed: $out"
  assert_contains "$out" 'auto_jobs=5' \
    "the default auto ceiling was not capped per slot: $out"
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
  out=$(PATH="$fakebin:$PATH" HOME="$local_home" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
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
      PATH="$fakebin:$PATH" HOME="$local_home" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
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
    PATH="$fakebin:$PATH" HOME="$local_home" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
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
    PATH="$fakebin:$PATH" HOME="$local_home" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
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
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
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
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
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
  out=$(PATH="$hangbin:$fakebin:$PATH" HOME="$local_home" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
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
  out=$(PATH="$fakebin:$PATH" HOME="$local_home" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
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
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
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
  out=$(PATH="$fakebin:$PATH" HOME="$local_home" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
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
  out=$(PATH="$fakebin:$PATH" HOME="$local_home" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
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
  out=$(PATH="$fakebin:$PATH" HOME="$local_home" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
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
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
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
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  release_slot "$first" "$second"
  expect_code 0 "$status" "a fully occupied PC02 must run locally: $out"
  assert_contains "$out" "all 2 PC02 test slots are busy; running locally" \
    "the all-slots-busy fallback was not logged clearly: $out"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "a fully occupied host received a new remote run"
  pass "both busy PC02 slots route the next suite to PC01 with a clear log"
}

test_malformed_slot_count_is_a_configuration_error() {
  local dir fakebin out status value
  dir="$TMP_ROOT/slots-invalid"
  fakebin=$(fake_pc02 "$dir")
  for value in 0 abc 17; do
    out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
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
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_SLOTS=1 FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  release_slot "$first"
  expect_code 0 "$status" "FM_PC02_OFFLOAD_SLOTS=1 must keep the single-slot fallback: $out"
  assert_contains "$out" "all 1 PC02 test slots are busy" "the single-slot fallback did not name its limit: $out"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "the single busy slot received a new remote run"
  pass "FM_PC02_OFFLOAD_SLOTS=1 keeps the original single-slot fallback"
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
  for _ in $(seq 1 50); do
    flock -n "$dir/home/.fm-pc02-test-slot-1.lock" true && break
    sleep 0.1
  done
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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
case "$*" in *fm-pc02-environment-parity-probe*) cmd=${!#}; bash -c "$cmd"; exit $? ;; esac
printf 'resource:cpu=1 gpu=0\nthreads:8\n'
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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
case "$*" in *fm-pc02-environment-parity-probe*) cmd=${!#}; bash -c "$cmd"; exit $? ;; esac
printf 'resource:cpu=1 gpu=0\nthreads:8\n'
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
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
case "$*" in *fm-pc02-environment-parity-probe*) cmd=${!#}; bash -c "$cmd"; exit $? ;; esac
printf 'resource:cpu=1 gpu=0\nthreads:8\n'
SH
  printf '#!/usr/bin/env bash\nexit 11\n' > "$fakebin/rsync"
  chmod +x "$fakebin/ssh" "$fakebin/rsync"
  out=$(env -u FM_HOME -u FM_STATE_OVERRIDE PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$dir/no-config" \
    "$dir/clone/bin/fm-pc02-test-offload.sh" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  expect_code 0 "$?" "primary clone discovery must run without FM_HOME: $out"
  assert_contains "$out" 'rsync to PC02 failed' "primary clone's state did not reach transfer: $out"
  pass "primary clone discovery resolves the home without environment or machine configuration"
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
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "$dir/claimant.test.sh" > "$dir/first.log" 2>&1 &
  first=$!
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
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
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
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
    FM_PC02_OFFLOAD_SLOTS=1 FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS=2 "$SCRIPT" "$dir/timeout.test.sh" 2>&1)
  status=$?
  expect_code 124 "$status" "dead owner's slot must be reclaimed and suite timeout preserved: $out"
  assert_contains "$out" 'running tests remotely' "dead lock file blocked the run: $out"
  flock -n "$dir/home/.fm-pc02-test-slot-1.lock" true || fail "timeout retained host claim"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "timeout left a mirror behind"
  pass "a dead owner's claim is reclaimed and the next run releases it on timeout"
}

test_lint_mode_falls_back_locally_with_forwarded_args() {
  local out direct status
  out=$(PATH="/nonexistent-so-ssh-and-rsync-are-absent:$PATH" FM_PC02_OFFLOAD_DISABLE=1 \
    "$SCRIPT" --lint --list-files 2>&1)
  status=$?
  direct=$("$ROOT/bin/fm-lint.sh" --list-files 2>&1)
  expect_code 0 "$status" "a disabled lint offload must still run the real lint locally: $out"
  assert_contains "$out" "offload disabled" "disabled lint offload did not explain why it stayed local: $out"
  assert_contains "$out" "running lint on PC01" "disabled lint offload did not name its local command: $out"
  [ "$(printf '%s\n' "$out" | tail -n +2)" = "$direct" ] \
    || fail "--lint did not forward its arguments unchanged to fm-lint.sh: $out"
  pass "--lint falls back to the real local lint with its arguments intact"
}

test_remote_lint_forwards_partition_and_returns_exit_code() {
  local dir fakebin out status
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "skip: remote fixture needs rsync and flock"; return
  fi
  dir="$TMP_ROOT/remote-lint"
  fakebin=$(fake_pc02 "$dir")
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash FM_FAKE_CAPTURE_LINT=1 FM_FAKE_LINT_EXIT=7 \
    "$SCRIPT" --lint --partition 2of4 --telemetry "$dir/lint.tsv" 2>&1)
  status=$?
  expect_code 7 "$status" "a remote lint's exit code must come back unchanged: $out"
  assert_contains "$out" "PC02 idle and ready; running lint remotely" "the lint run never went remote: $out"
  assert_contains "$out" "lint CI=true argv=--partition 2of4 --telemetry .fm-pc02-telemetry/lint.tsv" \
    "the remote lint did not force the full canonical selection with a PC02-side telemetry path: $out"
  case "$out" in
    *"--telemetry $dir/lint.tsv"*) fail "the PC01 telemetry path reached PC02 unchanged: $out" ;;
  esac
  [ "$(cat "$dir/lint.tsv" 2>/dev/null)" = "$(printf 'format\tfm-lint-telemetry-v1')" ] \
    || fail "the remote lint's telemetry snapshot did not arrive at the caller's path: $out"
  [ "$(cat "$dir/lint.roots.tsv" 2>/dev/null)" = "$(printf 'root\tbin/fm-lint.sh')" ] \
    || fail "the remote lint's roots sidecar did not arrive at the caller's path: $out"
  [ "$(remote_runs_left "$dir")" = 0 ] || fail "the per-run PC02 mirror was left behind after lint: $out"
  flock -n "$dir/home/.fm-pc02-test-slot-1.lock" true || fail "lint retained the host claim"
  pass "a remote lint forwards partition arguments, returns its exit code, and returns both telemetry files"
}

test_canonical_lint_without_arguments_forwards_none() {
  local dir fakebin clone source out status
  dir="$TMP_ROOT/lint-no-args"
  clone="$dir/clone"
  mkdir -p "$clone/bin"
  for source in "$ROOT"/bin/*.sh; do
    ln -s "$source" "$clone/bin/$(basename "$source")"
  done
  rm "$clone/bin/fm-pc02-test-offload.sh" "$clone/bin/fm-lint.sh"
  cp "$SCRIPT" "$clone/bin/fm-pc02-test-offload.sh"
  cat > "$clone/bin/fm-lint.sh" <<'SH'
#!/usr/bin/env bash
printf 'local-lint argc=%s argv=%s\n' "$#" "$*"
exit 9
SH
  chmod +x "$clone/bin/fm-lint.sh"
  out=$(FM_PC02_OFFLOAD_DISABLE=1 "$clone/bin/fm-pc02-test-offload.sh" --lint 2>&1)
  status=$?
  expect_code 9 "$status" "a canonical --lint fallback must return fm-lint's own exit code: $out"
  assert_contains "$out" "local-lint argc=0 argv=" \
    "the canonical --lint fallback did not invoke fm-lint with zero arguments: $out"
  if ! command -v rsync >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    pass "a canonical no-argument --lint offload forwards no arguments locally (remote fixture skipped)"; return
  fi
  fakebin=$(fake_pc02 "$dir")
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash FM_FAKE_CAPTURE_LINT=1 "$SCRIPT" --lint 2>&1)
  status=$?
  expect_code 0 "$status" "the canonical no-argument --lint offload must run remotely: $out"
  assert_contains "$out" "PC02 idle and ready; running lint remotely" "canonical --lint never went remote: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^lint CI=true argv=$')" = 1 ] \
    || fail "the remote canonical lint did not receive exactly zero forwarded arguments: $out"
  pass "a canonical no-argument --lint offload runs remotely with no forwarded arguments"
}

test_missing_perl_falls_back_to_local() {
  local dir fakebin tools tool out status
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

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  expect_code 0 "$status" "a PC02 without perl must still run the real suite locally: $out"
  case "$out" in
    *"PC02 missing required tool(s):"*perl*) : ;;
    *) fail "a PC02 missing perl, which the canonical lint hard-requires, was admitted: $out" ;;
  esac
  pass "PC02 missing perl falls back to a local run instead of failing the remote lint"
}

test_help_prints_the_whole_documented_contract() {
  local out status
  out=$("$SCRIPT" --help 2>&1)
  status=$?
  expect_code 0 "$status" "--help must exit 0: $out"
  assert_contains "$out" "fm-pc02-test-offload.sh <fm-test-run.sh args...>" "--help omitted the usage line: $out"
  assert_contains "$out" "fm-pc02-test-offload.sh --lint [fm-lint.sh args...]" "--help omitted the lint usage line: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_DISABLE=1" "--help omitted the disable override: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_PERSONAL_USE_FLAG" "--help omitted the personal-use switch override: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_CPU_BUSY_PCT" "--help omitted the CPU busy threshold: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_GPU_BUSY_PCT" "--help omitted the GPU busy threshold: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS" "--help omitted the run-timeout override: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_SLOTS" "--help omitted the concurrent-slot override: $out"
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
test_unreadable_thread_count_falls_back_to_local
test_pc02_if_idle_flag_forwards_through_fm_test_run
test_missing_perl_falls_back_to_local
test_lint_mode_falls_back_locally_with_forwarded_args
test_canonical_lint_without_arguments_forwards_none
test_remote_lint_forwards_partition_and_returns_exit_code
test_remote_run_returns_suite_exit_code_despite_straggler
test_remote_run_passes_through_green_suite_and_json
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
test_all_slots_busy_falls_back_locally
test_malformed_slot_count_is_a_configuration_error
test_single_slot_mode_keeps_the_old_fallback
test_decoy_host_suite_does_not_affect_remote_probe
test_term_mid_remote_run_removes_mirror_and_kills_suite
test_term_with_transport_ignoring_eof_stops_suite_and_frees_slot
test_sigkill_of_driver_stops_remote_suite_and_frees_slot
test_bare_common_store_needs_machine_file_unless_state_override
test_machine_home_config_without_fm_home
test_primary_clone_home_without_environment_or_config
test_two_concurrent_offloads_take_both_slots
test_dead_owner_and_timeout_release_claim

echo "# all fm-pc02-test-offload tests passed"
