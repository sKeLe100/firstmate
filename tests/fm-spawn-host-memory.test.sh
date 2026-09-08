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
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *pane_current_command*) printf '%s\n' "${FM_FAKE_PANE_CMD:-firstmate}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) printf '%s' "${FM_FAKE_WINDOWS:-}"; exit 0 ;;
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
  assert_contains "$out" "host memory floor" "the refusal must name the floor: $out"
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
  assert_contains "$out" "host memory floor not enforced" \
    "the unmeasurable reading must be disclosed, not silent: $out"
  [ -f "$HOME_DIR/state/$id.meta" ] \
    || fail "the launch that proceeded published no task record: $out"
  pass "fm-spawn.sh: an unmeasurable host-memory reading is disclosed and the launch proceeds"
}
test_unmeasurable_reading_allows_the_launch

printf '# all fm-spawn-host-memory tests passed\n'

test_relaunch_is_not_refused_by_the_floor() {
  local rec id out meminfo
  id=hostmem-relaunch
  rec=$(make_case relaunch "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  meminfo="$CASE_DIR/meminfo-low"
  printf 'MemTotal:       14000000 kB\nMemAvailable:     524288 kB\n' > "$meminfo"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' PATH="$FAKEBIN_DIR:$PATH" \
    FM_MEMINFO_OVERRIDE="$meminfo" \
    "$SPAWN" "$id" --relaunch 2>&1)
  assert_not_contains "$out" "host memory floor" \
    "a relaunch replaces an agent that still holds its memory, so the floor must not refuse it: $out"
  pass "fm-spawn.sh: the host-memory floor does not refuse a --relaunch"
}
test_relaunch_is_not_refused_by_the_floor
