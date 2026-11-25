#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's host-memory guard, the caller side of
# bin/fm-host-memory.sh (the reporter's own contract lives in
# tests/fm-host-memory.test.sh). Only a proven low reading may refuse a launch:
# a reading that cannot be taken at all - no /proc/meminfo on macOS, a malformed
# floor - is disclosed uncertainty, not evidence of memory pressure, so the
# launch proceeds. FM_MEMINFO_OVERRIDE supplies the fixture the guard reads.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-host-memory)

make_case() {  # <name> <task-id>
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
window_state=${BASH_SOURCE[0]}.window
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *pane_current_command*) printf '%s\n' "${FM_FAKE_PANE_CMD:-firstmate}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ -z "${FM_FAKE_WINDOWS:-}" ] || printf '%s\n' "$FM_FAKE_WINDOWS"
    [ ! -f "$window_state" ] || cat "$window_state"
    exit 0 ;;
  new-window)
    previous=
    for arg in "$@"; do
      [ "$previous" != -n ] || printf '%s\n' "$arg" > "$window_state"
      previous=$arg
    done
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nbrief for %s\n\n## Firstmate spec\nExercise the host-memory guard.\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {  # <home> <proj> <wt> <fakebin> <id> <meminfo>
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 meminfo=$6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' PATH="$fakebin:$PATH" \
    FM_MEMINFO_OVERRIDE="$meminfo" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1
}

test_low_reading_refuses_the_launch() {
  local rec id out status meminfo
  id=hostmem-low
  rec=$(make_case low "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  meminfo="$CASE_DIR/meminfo-low"
  # 512 MiB available, well under the built-in 3072 MiB floor.
  printf 'MemTotal:       14000000 kB\nMemAvailable:     524288 kB\n' > "$meminfo"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$meminfo")
  status=$?
  expect_code 1 "$status" "a spawn under the memory floor must refuse: $out"
  assert_contains "$out" "host memory low" "the refusal must name the low host memory: $out"
  assert_contains "$out" "3072MiB" "the refusal must name the floor it failed: $out"
  assert_contains "$out" "or lower config/host-memory-floor" \
    "a floor refusal must point at the floor config that governs it: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no task record"
  pass "fm-spawn.sh: a proven low host-memory reading refuses the launch"
}
test_low_reading_refuses_the_launch

test_unmeasurable_reading_allows_the_launch() {
  local rec id out status meminfo
  id=hostmem-unmeasurable
  rec=$(make_case unmeasurable "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  meminfo="$CASE_DIR/meminfo-absent"
  # No such file: the shape of a host with no /proc/meminfo at all (macOS).
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$meminfo")
  status=$?
  expect_code 0 "$status" "an unmeasurable host reading must not block the launch: $out"
  assert_contains "$out" "host memory reading not enforced" \
    "the unmeasurable reading must be disclosed, not silent: $out"
  [ -f "$HOME_DIR/state/$id.meta" ] \
    || fail "the launch that proceeded published no task record: $out"
  pass "fm-spawn.sh: an unmeasurable host-memory reading is disclosed and the launch proceeds"
}
test_unmeasurable_reading_allows_the_launch

write_live_session() {  # <home> <task-id>
  cat > "$1/state/$2.meta" <<META
window=firstmate:fm-$2
endpoint_task_id=$2
harness=claude
kind=ship
backend=tmux
META
}

test_mostly_used_swap_refuses_the_launch() {
  local rec id out status meminfo
  id=hostmem-swap-high
  rec=$(make_case swap-high "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  meminfo="$CASE_DIR/meminfo-swap-high"
  # Plenty of RAM, but 97% of swap is already in use: the floor alone would
  # admit this launch, which is the shape of the PC01 WSL OOM crash.
  printf 'MemTotal:       14000000 kB\nMemAvailable:    8388608 kB\nSwapTotal:       4000000 kB\nSwapFree:         100000 kB\n' > "$meminfo"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$meminfo")
  status=$?
  expect_code 1 "$status" "a mostly used swap must refuse the launch: $out"
  assert_contains "$out" "swap 97% used" "the refusal must name the measured swap percentage: $out"
  assert_contains "$out" "90%" "the refusal must name the swap bound: $out"
  assert_not_contains "$out" "or lower config/host-memory-floor" \
    "a swap-only refusal must not advise lowering the floor, which cannot clear it: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "a swap-refused spawn must publish no task record"
  pass "fm-spawn.sh: a mostly used swap refuses the launch"
}
test_mostly_used_swap_refuses_the_launch

test_low_floor_and_swap_refusal_names_both_causes() {
  local rec id out status meminfo
  id=hostmem-both-low
  rec=$(make_case both-low "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  meminfo="$CASE_DIR/meminfo-both-low"
  # 512 MiB available under the 3072 MiB floor and 97% of swap in use: lowering
  # the floor clears only one of the two causes.
  printf 'MemTotal:       14000000 kB\nMemAvailable:     524288 kB\nSwapTotal:       4000000 kB\nSwapFree:         100000 kB\n' > "$meminfo"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$meminfo")
  status=$?
  expect_code 1 "$status" "low memory with mostly used swap must refuse the launch: $out"
  assert_contains "$out" "swap 97% used" "the refusal must name the swap cause: $out"
  assert_not_contains "$out" "or lower config/host-memory-floor" \
    "the refusal must not suggest the floor alone clears a refusal swap also drives: $out"
  assert_contains "$out" "alone cannot clear" \
    "the refusal must say lowering the floor alone is not enough: $out"
  pass "fm-spawn.sh: a floor-and-swap refusal does not offer the floor as the whole remedy"
}
test_low_floor_and_swap_refusal_names_both_causes

test_swap_below_the_limit_allows_the_launch() {
  local rec id out status meminfo
  id=hostmem-swap-ok
  rec=$(make_case swap-ok "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  meminfo="$CASE_DIR/meminfo-swap-ok"
  # 25% of swap in use, well below the 90% admission bound.
  printf 'MemTotal:       14000000 kB\nMemAvailable:    8388608 kB\nSwapTotal:       4000000 kB\nSwapFree:        3000000 kB\n' > "$meminfo"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$meminfo")
  status=$?
  expect_code 0 "$status" "swap below the bound must not block the launch: $out"
  [ -f "$HOME_DIR/state/$id.meta" ] \
    || fail "the launch under a healthy swap reading published no task record: $out"
  pass "fm-spawn.sh: swap below the admission bound allows the launch"
}
test_swap_below_the_limit_allows_the_launch

test_unassessed_swap_is_disclosed_and_allows_the_launch() {
  local rec id out status meminfo
  id=hostmem-swap-unassessed
  rec=$(make_case swap-unassessed "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  meminfo="$CASE_DIR/meminfo-swap-unassessed"
  # Swap is reported but its free figure is missing: the launch proceeds on
  # the healthy RAM reading, and the unassessed swap must still reach stderr.
  printf 'MemTotal:       14000000 kB\nMemAvailable:    8388608 kB\nSwapTotal:       4000000 kB\n' > "$meminfo"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$meminfo")
  status=$?
  expect_code 0 "$status" "an unassessed swap must not block the launch: $out"
  assert_contains "$out" "swap not assessed" \
    "the unassessed swap must be disclosed on the launch path, not swallowed: $out"
  [ -f "$HOME_DIR/state/$id.meta" ] \
    || fail "the launch with unassessed swap published no task record: $out"
  pass "fm-spawn.sh: an unassessed swap is disclosed and the launch proceeds"
}
test_unassessed_swap_is_disclosed_and_allows_the_launch

test_parked_sessions_are_counted_through_memavailable() {
  local rec id out status meminfo
  id=hostmem-parked
  rec=$(make_case parked "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  meminfo="$CASE_DIR/meminfo-parked"
  # Three idle parked sessions are already live, and MemAvailable has their
  # resident memory deducted by the kernel. At 3500 MiB the reading is above the
  # 3072 MiB floor, so this launch must proceed: subtracting a fixed reserve per
  # parked session again would count the same memory twice and refuse work the
  # host can carry.
  printf 'MemTotal:       14000000 kB\nMemAvailable:    3584000 kB\n' > "$meminfo"
  write_live_session "$HOME_DIR" other-1
  write_live_session "$HOME_DIR" other-2
  write_live_session "$HOME_DIR" other-3
  out=$(FM_FAKE_WINDOWS=$'fm-other-1\nfm-other-2\nfm-other-3' FM_FAKE_PANE_CMD=claude \
    run_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$meminfo")
  status=$?
  expect_code 0 "$status" "parked sessions are counted through MemAvailable, not subtracted twice: $out"
  [ -f "$HOME_DIR/state/$id.meta" ] \
    || fail "the launch above the floor published no task record: $out"
  pass "fm-spawn.sh: idle parked sessions count through MemAvailable without a second subtraction"
}
test_parked_sessions_are_counted_through_memavailable

test_relaunch_is_not_refused_by_the_floor() {
  local rec id out meminfo
  id=hostmem-relaunch
  rec=$(make_case relaunch "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  meminfo="$CASE_DIR/meminfo-low"
  # Low memory and a mostly used swap together: without the --relaunch
  # exemption the guard would refuse on the first check it reaches.
  printf 'MemTotal:       14000000 kB\nMemAvailable:     524288 kB\nSwapTotal:       4000000 kB\nSwapFree:         100000 kB\n' > "$meminfo"
  # The task record and agent-free endpoint --relaunch requires; without them
  # the run aborts long before the guard and the case would pin nothing.
  cat > "$HOME_DIR/state/$id.meta" <<META
window=firstmate:fm-$id
endpoint_task_id=$id
harness=claude
kind=ship
backend=tmux
project=$PROJ_DIR
worktree=$WT_DIR
META
  printf 'working: relaunch fixture\n' > "$HOME_DIR/state/$id.status"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_FAKE_WINDOWS="fm-$id" FM_FAKE_PANE_CMD=bash \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' PATH="$FAKEBIN_DIR:$PATH" \
    FM_MEMINFO_OVERRIDE="$meminfo" \
    "$SPAWN" "$id" --relaunch 2>&1)
  assert_not_contains "$out" "needs an existing task record" \
    "the fixture must reach the guard, not abort on a missing task record: $out"
  assert_not_contains "$out" "endpoint reads" \
    "the fixture must reach the guard, not abort on a live endpoint: $out"
  assert_not_contains "$out" "refusing to launch task" \
    "a relaunch replaces an agent that still holds its memory, so the floor must not refuse it: $out"
  pass "fm-spawn.sh: the host-memory floor does not refuse a --relaunch"
}
test_relaunch_is_not_refused_by_the_floor

spawn_scope_case() {  # <name> <id> <systemd-mode>: runs a spawn; sets OUT and LAUNCH_TEXT
  local rec id=$2 mode=$3 meminfo bin
  rec=$(make_case "$1" "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  meminfo="$CASE_DIR/meminfo-ok"
  printf 'MemTotal:       22000000 kB\nMemAvailable:   16000000 kB\n' > "$meminfo"
  bin="$CASE_DIR/sysd"
  mkdir -p "$bin"
  cat > "$bin/systemd-run" <<SH
#!/usr/bin/env bash
[ "$mode" != fail ] || exit 1
max=
for a in "\$@"; do case "\$a" in MemoryMax=*M) max=\${a#MemoryMax=}; max=\${max%M} ;; esac; done
echo \$(( max * 1048576 ))
SH
  chmod +x "$bin/systemd-run"
  rm -rf /tmp/fm-"$id"+*
  OUT=$(FM_SYSTEMD_RUN="$bin/systemd-run" run_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$meminfo")
  LAUNCH_TEXT=$(cat /tmp/fm-"$id"+*/launch.*.sh 2>/dev/null)
  rm -rf /tmp/fm-"$id"+*
}

test_launch_runs_inside_a_memory_scope() {
  spawn_scope_case scope-ok hostmem-scope-ok ok
  assert_contains "$LAUNCH_TEXT" "systemd-run --user --scope" "the worker launch is wrapped in a user scope: $OUT"
  assert_contains "$LAUNCH_TEXT" "MemoryMax=6144M" "the scope carries the memory ceiling"
  assert_not_contains "$OUT" "WITHOUT a per-worker memory scope" "a working scope is not reported as missing"
  pass "fm-spawn.sh: a ship or scout launch runs inside a per-worker memory scope"
}
test_launch_runs_inside_a_memory_scope

test_scoped_launch_falls_back_when_the_pane_has_no_user_bus() {
  spawn_scope_case scope-nobus hostmem-scope-nobus ok
  local nobus ldir rc=0
  # Run the emitted launch where no user bus exists: the original command (a
  # stub harness) must still run, with the loud warning, and the scope never.
  nobus=$(mktemp -d)
  mkdir -p "$nobus/bin"
  printf '#!/bin/sh\necho ORIGINAL-LAUNCH-RAN\n' > "$nobus/bin/claude"
  chmod +x "$nobus/bin/claude"
  printf '%s\n' "$LAUNCH_TEXT" > "$nobus/launch.sh"
  # The launch refers to its (already cleaned-up) private staging directory.
  ldir=$(printf '%s' "$LAUNCH_TEXT" | grep -o '/tmp/fm-hostmem-scope-nobus+[0-9a-f]*' | head -1)
  [ -z "$ldir" ] || mkdir -p "$ldir"
  OUT2=$(env -i PATH="$nobus/bin:/usr/bin:/bin" HOME="$nobus" XDG_RUNTIME_DIR="$nobus" /bin/sh "$nobus/launch.sh" 2>&1) || rc=$?
  rm -rf "$nobus" /tmp/fm-hostmem-scope-nobus+*
  assert_contains "$OUT2" "ORIGINAL-LAUNCH-RAN" "the original launch runs without a user bus: $OUT2"
  assert_contains "$OUT2" "launching WITHOUT a per-worker memory scope" "a pane without a user bus says so"
  assert_not_contains "$OUT2" "Failed to connect to user scope bus" "the scoped branch is not attempted without a bus"
  pass "fm-spawn.sh: a scoped launch runs the original command when the pane has no user bus"
}
test_scoped_launch_falls_back_when_the_pane_has_no_user_bus

test_launch_without_scope_is_loud() {
  spawn_scope_case scope-none hostmem-scope-none fail
  assert_contains "$OUT" "WITHOUT a per-worker memory scope" "the missing scope is disclosed, never silent: $OUT"
  assert_not_contains "$LAUNCH_TEXT" "systemd-run" "the launch proceeds unwrapped when no scope can be proven"
  [ -f "$HOME_DIR/state/hostmem-scope-none.meta" ] || fail "the launch must still proceed: $OUT"
  pass "fm-spawn.sh: with no usable scope the launch proceeds and says so"
}
test_launch_without_scope_is_loud

test_brief_installing_in_the_worktree_is_refused() {
  local rec id=hostmem-brief-install out status meminfo
  rec=$(make_case brief-install "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  meminfo="$CASE_DIR/meminfo-ok"
  printf 'MemTotal:       22000000 kB\nMemAvailable:   16000000 kB\n' > "$meminfo"
  printf '# Task\n## Captain'"'"'s intent\nRun npm install inside the working copy and profile it.\n' > "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$meminfo")
  status=$?
  expect_code 1 "$status" "a brief that installs into the worktree must refuse the spawn: $out"
  assert_contains "$out" "fm-scratch/<task-id>" "the refusal points at the scratch location: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn publishes no task record"
  pass "fm-spawn.sh: a brief naming an install inside the working copy is refused"
}
test_brief_installing_in_the_worktree_is_refused

printf '# all fm-spawn-host-memory tests passed\n'
