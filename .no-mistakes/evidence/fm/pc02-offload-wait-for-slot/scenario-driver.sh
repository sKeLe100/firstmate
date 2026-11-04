#!/usr/bin/env bash
# Drives bin/fm-pc02-test-offload.sh (the real product) against a fixture PC02
# whose ssh/rsync fake only the network host: the readiness probe, the kernel
# slot locks, the mirror sync and the remote suite all run for real on this
# machine. Each scenario prints PASS/FAIL plus the CLI transcript it observed.
set -u

cd {run-worktree} || exit 1
# shellcheck source=tests/lib.sh
. tests/lib.sh

SCRIPT="$ROOT/bin/fm-pc02-test-offload.sh"
EVID=~/.no-mistakes/evidence/01M6JDG4RG6GSVKW5NXT3HJXC0
TMP_ROOT=$(fm_test_tmproot fm-pc02-scenarios)
mkdir -p "$TMP_ROOT/empty-state" "$TMP_ROOT/xdg" "$TMP_ROOT/fake-tools" "$TMP_ROOT/fake-ldd-bin"
export XDG_CONFIG_HOME="$TMP_ROOT/xdg"
export FM_PC02_OFFLOAD_LLAMASWAP_URL=http://127.0.0.1:9
export FM_PC02_OFFLOAD_RESOURCE_CHECK_PS1="$TMP_ROOT/no-such-resource-check.ps1"

install_cache_chrome() {  # <home>
  local path="$1/.cache/ms-playwright/chromium_headless_shell-1228/chrome-headless-shell-linux64/chrome-headless-shell"
  mkdir -p "$(dirname "$path")"
  printf '#!/usr/bin/env bash\necho "Chrome Headless Shell 1228.0"\n' > "$path"
  chmod +x "$path"
}
# A controlled PC01 home so the environment-parity probe compares like with
# like against the fixture PC02 home.
export HOME="$TMP_ROOT/pc01-home"
mkdir -p "$HOME"
install_cache_chrome "$HOME"
for tool in git bash python3 jq node shellcheck actionlint ruby chromium herdr pi tmux perl; do
  command -v "$tool" >/dev/null 2>&1 && continue
  printf '#!/usr/bin/env bash\necho "%s fixture 0.0.0"\n' "$tool" > "$TMP_ROOT/fake-tools/$tool"
  chmod +x "$TMP_ROOT/fake-tools/$tool"
done
# A deterministic ldd so the browser-dependency parity comparison sees the same
# libraries on both fixture hosts instead of this runner's real C library.
cat > "$TMP_ROOT/fake-ldd-bin/ldd" <<'SH'
#!/usr/bin/env bash
target=${1##*/}
if [[ "${FM_FAKE_LDD_MODE:-same}" = wrapper* ]] && [ "$target" = chrome-headless-shell ]; then
  echo 'not a dynamic executable' >&2
  exit 1
fi
printf 'libc.so.6 => /fake/lib/libc.so.6 (0x0)\n'
SH
chmod +x "$TMP_ROOT/fake-ldd-bin/ldd"
export PATH="$TMP_ROOT/fake-ldd-bin:$TMP_ROOT/fake-tools:$PATH"

LOCAL_PROOF_ARGS=(--list-families)
LOCAL_PROOF_OUT=$("$ROOT/bin/fm-test-run.sh" --list-families 2>&1)

# Reuse the repository's own fixture-PC02 builder (its ssh/rsync fake the host;
# everything else is real) instead of re-deriving that harness.
eval "$(sed -n '/^fake_pc02() {/,/^}/p' tests/fm-pc02-test-offload.test.sh)"
eval "$(sed -n '/^remote_runs_left() {/,/^}/p' tests/fm-pc02-test-offload.test.sh)"

SCEN=
RC=0
ok() { printf '  PASS: %s\n' "$1"; }
bad() {
  printf '  FAIL: %s\n' "$1"
  RC=1
}
has() { if printf '%s\n' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 :: transcript never showed [$2]"; fi; }
hasnt() { if printf '%s\n' "$1" | grep -qF -- "$2"; then bad "$3 :: transcript showed [$2]"; else ok "$3"; fi; }
eq() { if [ "$1" = "$2" ]; then ok "$3 ($1)"; else bad "$3 :: got [$1] want [$2]"; fi; }
expect_ok() { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2 :: exit $1"; fi; }
raw() { printf '%s\n' "$2" > "$EVID/raw-$SCEN-$1.log"; }

hold_slot() {  # <dir> <slot> -> echoes the holding pid
  local dir=$1 slot=$2 marker pid _
  marker="$dir/held-$slot"
  # shellcheck disable=SC2016 # Positional parameter belongs to the lock holder.
  flock "$dir/home/.fm-pc02-test-slot-$slot.lock" bash -c 'touch "$1"; sleep 600' bash "$marker" \
    >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 300); do [ -f "$marker" ] && break; sleep 0.1; done
  [ -f "$marker" ] || { echo "hold_slot $slot failed" >&2; return 1; }
  printf '%s\n' "$pid"
}
release_slot() {  # <pid...>
  local pid
  for pid in "$@"; do
    [ -n "$pid" ] || continue
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}
wait_for_line() {  # <file> <needle> <tries>
  local _ out=$1 needle=$2 tries=$3
  for _ in $(seq 1 "$tries"); do
    grep -qF -- "$needle" "$out" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}
six_slot_config() {  # <dir> -> echoes an XDG config dir holding the 6-slot file
  local cfg="$1/config"
  mkdir -p "$cfg/firstmate"
  printf '6\n' > "$cfg/firstmate/pc02-offload-slots"
  printf '%s\n' "$cfg"
}

# ---------------------------------------------------------------- scenario a
# Intent: a busy PC02 is waited on instead of being skipped, so the run lands
# on PC02 (not PC01), with the six slots the operator asked for.
scenario_a_busy_pc02_waited_on_then_runs_on_pc02() {
  local dir fakebin cfg slot pid out pids=() runpid tries=0
  dir="$TMP_ROOT/a-busy-six"
  cfg=$(six_slot_config "$dir")
  fakebin=$(fake_pc02 "$dir" 16)
  cat > "$dir/green.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - the waiter ran this suite on PC02"
SH
  chmod +x "$dir/green.test.sh"
  for slot in 1 2 3 4 5 6; do
    pid=$(hold_slot "$dir" "$slot") || return 1
    pids+=("$pid")
  done
  PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$cfg" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash FM_PC02_OFFLOAD_SLOT_WAIT_SECS=120 \
    FM_PC02_OFFLOAD_SLOT_WAIT_INTERVAL_SECS=1 FM_PC02_OFFLOAD_GATE_RECHECK_SECS=1 \
    "$SCRIPT" "$dir/green.test.sh" > "$dir/out.log" 2>&1 &
  runpid=$!
  if wait_for_line "$dir/out.log" "all 6 PC02 test slots are busy; waiting up to" 900; then
    ok "with all six slots held the run waits instead of falling back at once"
    release_slot "${pids[2]}"
    ok "freed one slot (slot 3) while the run was waiting"
  else
    bad "the all-slots-busy wait was never announced"
  fi
  while kill -0 "$runpid" 2>/dev/null && [ "$tries" -lt 900 ]; do
    sleep 0.2
    tries=$((tries + 1))
  done
  if kill -0 "$runpid" 2>/dev/null; then
    kill "$runpid" 2>/dev/null
    bad "the waiting run never finished"
  fi
  wait "$runpid" 2>/dev/null
  release_slot "${pids[@]}"
  out=$(cat "$dir/out.log")
  raw transcript "$out"

  has "$out" "all 6 PC02 test slots are busy; waiting up to 120s for a free slot" \
    "the six-slot host is reported busy and the wait is bounded"
  has "$out" "claimed PC02 slot 3 of 6" "the waiter took the freed slot and names the six-slot host"
  has "$out" "running tests remotely" "the waited run executed on PC02"
  has "$out" "the waiter ran this suite on PC02" "PC02 really ran the selected suite"
  hasnt "$out" "running on PC01" "the run never fell back to PC01 while a slot could free"
  eq "$(remote_runs_left "$dir")" 0 "the remote mirror was cleaned up"
}

# ---------------------------------------------------------------- scenario b
# Intent: six slots, and their per-slot worker ceiling at 16 threads.
scenario_b_six_slots_run_concurrently_with_two_workers_each() {
  local dir fakebin cfg i out status pids=() started_count held_count
  dir="$TMP_ROOT/b-six-concurrent"
  cfg=$(six_slot_config "$dir")
  fakebin=$(fake_pc02 "$dir" 16)
  cat > "$dir/claimant.test.sh" <<SH
#!/usr/bin/env bash
if { true >&9; } 2>/dev/null; then
  echo started >> "$dir/started"
  for _ in \$(seq 1 600); do [ -f "$dir/release" ] && exit 0; sleep 0.1; done
  exit 1
fi
echo 'ok - local fallback'
SH
  chmod +x "$dir/claimant.test.sh"
  for i in 1 2 3 4 5 6; do
    PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$cfg" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
      FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
      "$SCRIPT" "$dir/claimant.test.sh" > "$dir/claimant-$i.log" 2>&1 &
    pids+=("$!")
  done
  for _ in $(seq 1 900); do
    [ -s "$dir/started" ] && [ "$(wc -l < "$dir/started" | tr -d ' ')" -ge 6 ] && break
    sleep 0.1
  done
  started_count=$(wc -l < "$dir/started" 2>/dev/null | tr -d ' ')
  eq "${started_count:-0}" 6 "six concurrent offloads each reached PC02"
  held_count=0
  for i in 1 2 3 4 5 6; do
    if ! flock -n "$dir/home/.fm-pc02-test-slot-$i.lock" true; then held_count=$((held_count + 1)); fi
  done
  eq "$held_count" 6 "all six slot locks were held at once, so six runs really fit"
  out=$(PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$cfg" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash FM_PC02_OFFLOAD_SLOT_WAIT_SECS=0 \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  raw seventh-run "$out"
  expect_ok "$status" "the seventh run against six busy slots still ran the real suite locally"
  has "$out" "all 6 PC02 test slots are busy; running locally" \
    "the seventh run names all six busy slots"
  touch "$dir/release"
  for i in "${pids[@]}"; do wait "$i" 2>/dev/null; done
  for i in 1 2 3 4 5 6; do raw "claimant-$i" "$(cat "$dir/claimant-$i.log")"; done
  # The per-slot worker ceiling: 16 threads / 6 slots = 2 workers per run.
  export FM_FAKE_CAPTURE_RUNNER=1
  out=$(PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$cfg" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash "$SCRIPT" --all 2>&1)
  status=$?
  unset FM_FAKE_CAPTURE_RUNNER
  raw worker-cap "$out"
  expect_ok "$status" "a --all run under the six-slot setting completed"
  has "$out" "auto_jobs=2" "each of the six slots is capped at floor(16/6)=2 workers"
}

# ---------------------------------------------------------------- scenario c
# Adversarial: if no slot frees within the bound, the run must still finish by
# running the real suite locally rather than hanging or failing.
scenario_c_expired_bound_still_runs_the_real_suite_locally() {
  local dir fakebin cfg slot pid out status started ended pids=()
  dir="$TMP_ROOT/c-bound-expiry"
  cfg=$(six_slot_config "$dir")
  fakebin=$(fake_pc02 "$dir" 16)
  for slot in 1 2 3 4 5 6; do
    pid=$(hold_slot "$dir" "$slot") || return 1
    pids+=("$pid")
  done
  started=$(date +%s)
  out=$(PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$cfg" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash FM_PC02_OFFLOAD_SLOT_WAIT_SECS=4 \
    FM_PC02_OFFLOAD_SLOT_WAIT_INTERVAL_SECS=1 timeout 300 \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  ended=$(date +%s)
  release_slot "${pids[@]}"
  raw transcript "$out"
  expect_ok "$status" "an exhausted slot wait still exits 0 through the real local suite"
  has "$out" "all 6 PC02 test slots are busy; waiting up to 4s for a free slot" \
    "the run announced the bounded wait"
  has "$out" "all 6 PC02 test slots stayed busy through the 4s wait bound; running locally" \
    "the fallback names the wait it actually spent"
  eq "$(printf '%s\n' "$out" | grep -v '^fm-pc02-test-offload: ')" "$LOCAL_PROOF_OUT" \
    "the fallback ran the real local suite with the forwarded arguments unchanged"
  if [ "$((ended - started))" -ge 4 ]; then
    ok "the run waited out its bound ($((ended - started))s)"
  else
    bad "the run fell back after only $((ended - started))s, before its 4s bound"
  fi
  eq "$(remote_runs_left "$dir")" 0 "a fully busy PC02 received no new remote run"
}

# ---------------------------------------------------------------- scenario d
# Adversarial: the states waiting cannot fix must route to PC01 at once even
# while a long bound is configured.
scenario_d_unfixable_states_do_not_wait() {
  local n probe fakebin out status started ended
  n=0
  for probe in 'personal-use:on' 'missing:jq' 'resource:script-missing' 'unreachable'; do
    n=$((n + 1))
    fakebin=$(fm_fakebin "$TMP_ROOT/d-$n")
    case "$probe" in
      unreachable)
        cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
echo "ssh: connect to host pc02 port 22: Connection timed out" >&2
exit 255
SH
        ;;
      *)
        case "$probe" in
          resource:script-missing) printf '%s\nthreads:16\n' "$probe" > "$fakebin/probe.txt" ;;
          *) printf '%s\nresource:cpu=1 gpu=0\nthreads:16\n' "$probe" > "$fakebin/probe.txt" ;;
        esac
        cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
case "$*" in *fm-pc02-test-slot-*.lock*) echo 'claimed 1 of 2'; read -r command; exit 0 ;; esac
case "$*" in *fm-pc02-environment-parity-probe*) cmd=${!#}; bash -c "$cmd"; exit $? ;; esac
cat "$(dirname "$0")/probe.txt"
exit 0
SH
        ;;
    esac
    chmod +x "$fakebin/ssh"
    started=$(date +%s)
    out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
      FM_PC02_OFFLOAD_SLOT_WAIT_SECS=600 timeout 60 "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
    status=$?
    ended=$(date +%s)
    raw "$(printf '%s' "$probe" | tr ':' '-')" "$out"
    expect_ok "$status" "[$probe] still ran the real suite locally"
    hasnt "$out" "waiting up to" "[$probe] routed local without waiting under a 600s bound"
    hasnt "$out" "PC02 is free again" "[$probe] did not wait for PC02 to clear"
    if [ "$((ended - started))" -lt 30 ]; then
      ok "[$probe] returned at once ($((ended - started))s)"
    else
      bad "[$probe] spent $((ended - started))s before falling back"
    fi
    case "$probe" in
      personal-use:on) has "$out" "PC02 personal-use switch is on" "the personal-use switch is the reason" ;;
      missing:jq) has "$out" "PC02 missing required tool(s): jq" "the missing tool is the reason" ;;
      resource:script-missing)
        has "$out" "the resource-check script is missing at $FM_PC02_OFFLOAD_RESOURCE_CHECK_PS1" \
          "the missing resource-check script names the path that is missing"
        ;;
      unreachable) has "$out" "PC02 unreachable" "the unreachable host is the reason" ;;
    esac
  done
}

# ---------------------------------------------------------------- scenario e
# A caller that declares a wall budget gets the whole of it for the run: the
# pinned Test entry point must not spend it waiting on PC02.
scenario_e_caller_wall_budget_skips_the_wait_on_the_pinned_entry_path() {
  local dir fakebin cfg slot pid out status started ended pids=() first_family
  dir="$TMP_ROOT/e-wall-budget"
  cfg=$(six_slot_config "$dir")
  fakebin=$(fake_pc02 "$dir" 16)
  for slot in 1 2 3 4 5 6; do
    pid=$(hold_slot "$dir" "$slot") || return 1
    pids+=("$pid")
  done
  first_family=$(printf '%s\n' "$LOCAL_PROOF_OUT" | head -n 1)
  started=$(date +%s)
  out=$(PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$cfg" FM_STATE_OVERRIDE="$TMP_ROOT/empty-state" \
    FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash timeout 300 \
    "$ROOT/bin/fm-test-run.sh" --pc02-if-idle --max-wall-ms 600000 "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  ended=$(date +%s)
  release_slot "${pids[@]}"
  raw transcript "$out"
  expect_ok "$status" "the budgeted pinned-entry run completed through the real local suite"
  has "$out" "all 6 PC02 test slots are busy; running locally" \
    "a declared wall budget turns the busy-slot wait into the immediate PC01 fallback"
  hasnt "$out" "waiting up to" "the declared wall budget was not spent waiting on PC02"
  has "$out" "$first_family" "the forwarded selection still produced its real output"
  if [ "$((ended - started))" -lt 60 ]; then
    ok "the budgeted run returned in $((ended - started))s"
  else
    bad "the budgeted run spent $((ended - started))s"
  fi
}

# ---------------------------------------------------------------- scenario f
# A transient load gate (a live LLM lane) is waited on, then PC02 is used.
scenario_f_load_gate_waits_then_uses_pc02() {
  local dir fakebin home out status freer
  dir="$TMP_ROOT/f-load-gate"
  fakebin=$(fake_pc02 "$dir" 16)
  printf '#!/usr/bin/env bash\necho "ok - gate cleared"\n' > "$dir/green.test.sh"
  chmod +x "$dir/green.test.sh"
  home="$dir/lane-home"
  mkdir -p "$home/state"
  printf 'model=pc02-llamaswap/qwen3.8-27b-dispatch\nbackend=tmux\ntarget=faketask:0\n' > "$home/state/faketask.meta"
  ( sleep 3; rm -f "$home/state/faketask.meta" ) &
  freer=$!
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$home/state" FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    FM_PC02_OFFLOAD_SLOT_WAIT_SECS=60 FM_PC02_OFFLOAD_GATE_RECHECK_SECS=1 \
    "$SCRIPT" "$dir/green.test.sh" 2>&1)
  status=$?
  wait "$freer" 2>/dev/null || true
  raw transcript "$out"
  expect_ok "$status" "a run that waited for the lane to clear still completed"
  has "$out" "PC02 lane check reported 'occupied: faketask'; waiting up to" \
    "the live lane is waited on under the bound instead of an immediate PC01 fallback"
  has "$out" "PC02 is free again after" "the cleared gate was announced"
  has "$out" "running tests remotely" "the run took PC02 once the lane freed"
  hasnt "$out" "running on PC01" "the waiting run did not fall back to PC01"
  local wait_line free_line remote_line
  wait_line=$(printf '%s\n' "$out" | grep -nF "waiting up to" | head -n 1 | cut -d: -f1)
  free_line=$(printf '%s\n' "$out" | grep -nF "PC02 is free again" | head -n 1 | cut -d: -f1)
  remote_line=$(printf '%s\n' "$out" | grep -nF "running tests remotely" | head -n 1 | cut -d: -f1)
  if [ -n "$wait_line" ] && [ -n "$free_line" ] && [ -n "$remote_line" ] \
    && [ "$wait_line" -lt "$free_line" ] && [ "$free_line" -lt "$remote_line" ]; then
    ok "nothing reached PC02 until after the lane cleared (wait@$wait_line < free@$free_line < remote@$remote_line)"
  else
    bad "the run reached PC02 outside the wait/clear/run order (wait@$wait_line free@$free_line remote@$remote_line)"
  fi
  eq "$(remote_runs_left "$dir")" 0 "the remote mirror was cleaned up"
}

# ---------------------------------------------------------------- scenario g
# Adversarial: a gate that never clears must fall back on time.
scenario_g_load_gate_that_never_clears_falls_back_on_time() {
  local dir fakebin home out status started ended
  dir="$TMP_ROOT/g-gate-stuck"
  fakebin=$(fake_pc02 "$dir" 16)
  home="$dir/lane-home"
  mkdir -p "$home/state"
  printf 'model=pc02-llamaswap/qwen3.8-27b-dispatch\nbackend=tmux\ntarget=faketask:0\n' > "$home/state/faketask.meta"
  started=$(date +%s)
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$home/state" FM_PC02_OFFLOAD_REQUIRED_TOOLS=bash \
    FM_PC02_OFFLOAD_SLOT_WAIT_SECS=3 FM_PC02_OFFLOAD_GATE_RECHECK_SECS=1 timeout 300 \
    "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  ended=$(date +%s)
  raw transcript "$out"
  expect_ok "$status" "a lane that never clears still exits 0 through the real local suite"
  has "$out" "PC02 lane check reported 'occupied: faketask' and still so after the 3s wait bound; running on PC01" \
    "the expired gate logged its reason and the PC01 fallback"
  eq "$(printf '%s\n' "$out" | grep -v '^fm-pc02-test-offload: ')" "$LOCAL_PROOF_OUT" \
    "the expired gate ran the real local suite with the forwarded arguments unchanged"
  if [ "$((ended - started))" -ge 3 ]; then
    ok "the gate wait lasted $((ended - started))s, at least its 3s bound"
  else
    bad "the gate fell back before waiting out its bound ($((ended - started))s)"
  fi
  eq "$(remote_runs_left "$dir")" 0 "a lane that never cleared never reached PC02"
}

# ---------------------------------------------------------------- scenario h
# The new knobs are configuration: a malformed value must refuse loudly and run
# nothing, and --help must describe each knob exactly once.
scenario_h_configuration_errors_and_help() {
  local knob value out status count
  for knob in FM_PC02_OFFLOAD_SLOT_WAIT_SECS FM_PC02_OFFLOAD_SLOT_WAIT_INTERVAL_SECS; do
    for value in abc -1; do
      out=$(env "$knob=$value" "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
      status=$?
      eq "$status" 2 "$knob=$value is a configuration error"
      has "$out" "$knob must be a" "the refusal names $knob"
      has "$out" "got '$value'" "the refusal names the rejected value"
      hasnt "$out" "pure-contract-unit" "$knob=$value ran no suite"
    done
  done
  out=$(FM_PC02_OFFLOAD_SLOT_WAIT_INTERVAL_SECS=0 "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
  status=$?
  eq "$status" 2 "a zero slot-wait interval is a configuration error"
  has "$out" "FM_PC02_OFFLOAD_SLOT_WAIT_INTERVAL_SECS must be a positive integer, got '0'" \
    "the zero interval is rejected with its value"
  for value in 0 abc; do
    out=$(FM_PC02_OFFLOAD_GATE_RECHECK_SECS="$value" "$SCRIPT" "${LOCAL_PROOF_ARGS[@]}" 2>&1)
    status=$?
    eq "$status" 2 "a gate-recheck value of '$value' is a configuration error"
    has "$out" "FM_PC02_OFFLOAD_GATE_RECHECK_SECS must be a positive integer, got '$value'" \
      "the gate-recheck refusal names the rejected value '$value'"
  done
  out=$("$SCRIPT" --help 2>&1)
  status=$?
  raw help "$out"
  eq "$status" 0 "--help exits 0"
  has "$out" "FM_PC02_OFFLOAD_SLOT_WAIT_SECS" "--help documents the shared wait bound"
  has "$out" "FM_PC02_OFFLOAD_SLOT_WAIT_INTERVAL_SECS" "--help documents the slot poll interval"
  has "$out" "FM_PC02_OFFLOAD_GATE_RECHECK_SECS" "--help documents the gate re-check interval"
  count=$(printf '%s\n' "$out" | grep -c 'non-negative')
  eq "$count" 0 "--help makes no non-negative range claim that the code rejects"
  local gate_doc interval_doc
  gate_doc=$(printf '%s\n' "$out" | grep -A4 'FM_PC02_OFFLOAD_GATE_RECHECK_SECS' | tr '\n' ' ')
  interval_doc=$(printf '%s\n' "$out" | grep -A4 'FM_PC02_OFFLOAD_SLOT_WAIT_INTERVAL_SECS' | tr '\n' ' ')
  has "$gate_doc" "positive" "--help documents the gate re-check value as positive"
  hasnt "$gate_doc" "non-negative" "--help does not contradict the gate re-check's positive range"
  has "$interval_doc" "positive" "--help documents the slot poll interval as positive"
}

run() {  # <name> <function>
  local name=$1 fn=$2
  SCEN=$name
  printf '== scenario %s\n' "$name"
  RC=0
  "$fn"
  if [ "$RC" -eq 0 ]; then
    printf 'SCENARIO %s: PASS\n' "$name"
  else
    printf 'SCENARIO %s: FAIL\n' "$name"
  fi
}

only=${1:-all}
for s in a_busy_pc02_waited_on_then_runs_on_pc02 \
  b_six_slots_run_concurrently_with_two_workers_each \
  c_expired_bound_still_runs_the_real_suite_locally \
  d_unfixable_states_do_not_wait \
  e_caller_wall_budget_skips_the_wait_on_the_pinned_entry_path \
  f_load_gate_waits_then_uses_pc02 \
  g_load_gate_that_never_clears_falls_back_on_time \
  h_configuration_errors_and_help; do
  case "$only" in all | "${s%%_*}") run "$s" "scenario_$s" ;; esac
done
rm -rf "$TMP_ROOT"
exit 0
