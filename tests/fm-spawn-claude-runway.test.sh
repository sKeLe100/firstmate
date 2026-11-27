#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's Claude five-hour runway admission, the
# caller side of bin/fm-dispatch-quota-cap.sh (that script's own contract lives
# in tests/fm-dispatch-quota-cap.test.sh). A fresh Claude ship or scout whose
# bound account is projected to exhaust before its reset, or is under 40% with a
# live lane on that account, is deferred with exit 75 and leaves its backlog
# item queued, exactly like the project-capacity refusal. The gate reads the
# fixture supplied in FM_DISPATCH_QUOTA_JSON, so no test reaches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-claude-runway)

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
  printf '# Task\n## Captain'"'"'s intent\nbrief for %s\n\n## Firstmate spec\nExercise the runway gate.\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {  # <home> <proj> <wt> <fakebin> <id> <quota> [extra spawn args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 quota=$6
  shift 6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' PATH="$fakebin:$PATH" \
    FM_DISPATCH_QUOTA_JSON="$quota" \
    FM_MEMINFO_OVERRIDE="$home/meminfo" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off "$@" 2>&1
}

write_meminfo() {  # <file>
  printf 'MemTotal:       14000000 kB\nMemAvailable:    8388608 kB\n' > "$1"
}

quota_fixture() {  # <file> <five_pct> <hours> <projected_hours|empty> [projection_confidence]
  python3 - "$1" "$2" "$3" "${4:-}" "${5:-}" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
f, pct, hours, projected, confidence = sys.argv[1:]
gen = datetime(2026, 9, 14, 12, 0, tzinfo=timezone.utc)
resets = gen + timedelta(hours=float(hours))
pace = {"status": "behind", "burnMultiple": 0.4}
if projected:
    pace["projectedExhaustedAt"] = (
        gen + timedelta(hours=float(projected))
    ).isoformat().replace("+00:00", "Z")
if confidence:
    pace["projectionConfidence"] = confidence
json.dump({
    "generatedAt": gen.isoformat().replace("+00:00", "Z"),
    "schemaVersion": 5,
    "providers": [
        {"provider": "claude", "windows": [
            {"id": "five_hour", "kind": "session", "resetsAt": resets.isoformat(),
             "percentRemaining": float(pct), "pace": pace},
            {"id": "seven_day", "kind": "weekly", "percentRemaining": 80,
             "pace": {"status": "behind", "burnMultiple": 0.4}},
        ]},
        {"provider": "codex", "windows": [
            {"id": "window:720h", "kind": "unknown", "percentRemaining": 50,
             "pace": {"status": "behind", "burnMultiple": 1.0}},
        ]},
    ],
}, open(f, "w"))
PY
}

quota_fresh_fixture() {  # <file>
  python3 - "$1" <<'PY'
import json, sys
from datetime import datetime, timezone
gen = datetime(2026, 9, 14, 12, 0, tzinfo=timezone.utc)
stamp = gen.isoformat().replace("+00:00", "Z")
# A five_hour window whose countdown has not started: no resetsAt, zero
# usage, unknown pace - exactly what quota-axi publishes on a fresh account.
json.dump({
    "generatedAt": stamp,
    "schemaVersion": 5,
    "providers": [
        {"provider": "claude", "state": {"status": "fresh"}, "windows": [
            {"id": "five_hour", "kind": "session", "percentUsed": 0,
             "percentRemaining": 100,
             "pace": {"status": "unknown", "reason": "missing_cycle"}},
            {"id": "seven_day", "kind": "weekly",
             "resetsAt": "2026-09-18T12:00:00Z", "percentRemaining": 80,
             "pace": {"status": "behind", "burnMultiple": 0.4}},
        ]},
    ],
}, open(sys.argv[1], "w"))
PY
}

write_live_lane() {  # <home> <task-id>
  cat > "$1/state/$2.meta" <<META
window=firstmate:fm-$2
endpoint_task_id=$2
harness=claude
kind=ship
backend=tmux
META
}

test_tight_account_with_a_live_lane_is_deferred() {
  local rec id out status quota
  id=runway-defer
  rec=$(make_case defer "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  write_meminfo "$HOME_DIR/meminfo"
  write_live_lane "$HOME_DIR" other-lane
  quota="$CASE_DIR/quota-tight.json"
  quota_fixture "$quota" 30 4 ''
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$quota")
  status=$?
  expect_code 75 "$status" "a second lane on a below-40% account must defer: $out"
  assert_contains "$out" "deferred: Claude account ordinary has no headroom" \
    "the deferral must name the tight Claude account: $out"
  assert_contains "$out" "30% left" "the deferral must carry the reason: $out"
  assert_contains "$out" "backlog item stays queued" \
    "the deferral must say the item stays queued: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "a deferred spawn must publish no task record"
  pass "fm-spawn.sh: a Claude lane beyond the account's runway cap is deferred with exit 75"
}
test_tight_account_with_a_live_lane_is_deferred

test_tight_account_with_no_live_lane_admits_one() {
  local rec id out status quota
  id=runway-admit
  rec=$(make_case admit "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  write_meminfo "$HOME_DIR/meminfo"
  quota="$CASE_DIR/quota-tight.json"
  quota_fixture "$quota" 30 4 ''
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$quota")
  status=$?
  expect_code 0 "$status" "the first lane on a below-40% account must launch: $out"
  [ -f "$HOME_DIR/state/$id.meta" ] \
    || fail "the admitted launch published no task record: $out"
  pass "fm-spawn.sh: the first Claude lane on a below-40% account is admitted"
}
test_tight_account_with_no_live_lane_admits_one

test_projected_exhaustion_defers_even_at_high_remaining() {
  local rec id out status quota
  id=runway-projected
  rec=$(make_case projected "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  write_meminfo "$HOME_DIR/meminfo"
  quota="$CASE_DIR/quota-projected.json"
  # 89% left, the 2026-11-19 reading, but exhaustion is projected an hour
  # before the reset: the old percent ladder would have admitted this.
  quota_fixture "$quota" 89 4 3
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$quota")
  status=$?
  expect_code 75 "$status" "projected exhaustion before reset must defer even at 89% left: $out"
  assert_contains "$out" "est. exhaustion" \
    "the deferral must label the projection as an estimate: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "a deferred spawn must publish no task record"
  pass "fm-spawn.sh: projected exhaustion before the reset defers a new Claude lane"
}
test_projected_exhaustion_defers_even_at_high_remaining

test_on_pace_projection_keeps_the_spawn_admitted() {
  local rec id out status quota
  id=runway-on-pace
  rec=$(make_case on-pace "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  write_meminfo "$HOME_DIR/meminfo"
  quota="$CASE_DIR/quota-on-pace.json"
  # 89% left with exhaustion projected at the reset itself: spend on pace must
  # ride out the window, so the lane is admitted.
  quota_fixture "$quota" 89 4 4.05 established
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$quota")
  status=$?
  expect_code 0 "$status" "an on-pace projection must admit the lane: $out"
  [ -f "$HOME_DIR/state/$id.meta" ] || fail "the admitted lane published no task record: $out"
  pass "fm-spawn.sh: an on-pace projection keeps the base cap"
}
test_on_pace_projection_keeps_the_spawn_admitted

test_early_projection_keeps_the_spawn_admitted() {
  local rec id out status quota
  id=runway-early
  rec=$(make_case early "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  write_meminfo "$HOME_DIR/meminfo"
  quota="$CASE_DIR/quota-early.json"
  # An early projection swings by hours and is never used as a verdict.
  quota_fixture "$quota" 89 4 1 early
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$quota")
  status=$?
  expect_code 0 "$status" "an early projection must admit the lane: $out"
  [ -f "$HOME_DIR/state/$id.meta" ] || fail "the admitted lane published no task record: $out"
  pass "fm-spawn.sh: an early projection keeps the base cap"
}
test_early_projection_keeps_the_spawn_admitted

test_unstarted_five_hour_window_still_spawns() {
  local rec id out status quota
  id=runway-unstarted
  rec=$(make_case unstarted "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  write_meminfo "$HOME_DIR/meminfo"
  quota="$CASE_DIR/quota-unstarted.json"
  # A completely fresh account: the five-hour countdown has not started, so
  # the report is 100% with no reset. That is headroom, not an unreadable
  # reading, and must not defer the launch.
  quota_fresh_fixture "$quota"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$quota")
  status=$?
  expect_code 0 "$status" "an unstarted five-hour window must admit the lane: $out"
  [ -f "$HOME_DIR/state/$id.meta" ] || fail "the admitted lane published no task record: $out"
  pass "fm-spawn.sh: a fresh account whose five-hour window has not started is admitted"
}
test_unstarted_five_hour_window_still_spawns

test_projected_exhaustion_over_pace_approval_admits() {
  local rec id out status quota meta
  id=runway-over-pace
  rec=$(make_case over-pace "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  write_meminfo "$HOME_DIR/meminfo"
  quota="$CASE_DIR/quota-projected.json"
  # Same projected-exhaustion reading that defers without the flag: 89% left
  # but exhaustion an hour before the reset.
  quota_fixture "$quota" 89 4 3
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$quota" \
    --over-pace "captain approved going over pace for this dispatch")
  status=$?
  expect_code 0 "$status" "the captain's over-pace approval must admit the lane: $out"
  assert_contains "$out" "runway gate overridden" \
    "the override must print one line naming the runway gate: $out"
  meta="$HOME_DIR/state/$id.meta"
  [ -f "$meta" ] || fail "the admitted lane published no task record: $out"
  grep -qxF 'over_pace=captain approved going over pace for this dispatch' "$meta" \
    || fail "the task record must carry the approval text: $(cat "$meta")"
  grep -q '^over_pace_at=' "$meta" \
    || fail "the task record must carry the approval timestamp: $(cat "$meta")"
  pass "fm-spawn.sh: a projected-exhaustion deferral is overridden by --over-pace and recorded"
}
test_projected_exhaustion_over_pace_approval_admits

test_over_pace_empty_reason_is_refused() {
  local rec id out status quota
  id=runway-over-pace-empty
  rec=$(make_case over-pace-empty "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  write_meminfo "$HOME_DIR/meminfo"
  quota="$CASE_DIR/quota-projected.json"
  quota_fixture "$quota" 89 4 3
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$quota" \
    --over-pace "")
  status=$?
  expect_code 1 "$status" "an empty --over-pace reason must refuse: $out"
  assert_contains "$out" "requires the captain's approval words" \
    "the refusal must name the missing approval words: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no task record"
  pass "fm-spawn.sh: an empty --over-pace reason is refused"
}
test_over_pace_empty_reason_is_refused

test_over_pace_does_not_bypass_orchestrator_lane_cap() {
  local rec id out status quota orch meta
  id=runway-orch-second
  rec=$(make_case orch-cap "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF2
$rec
EOF2
  write_meminfo "$HOME_DIR/meminfo"
  orch="$CASE_DIR/orch-claude"
  mkdir -p "$orch"
  printf '%s\n' "$orch" > "$HOME_DIR/config/claude-accounts"
  printf '%s\n' "$orch" > "$HOME_DIR/config/claude-orchestrator-account"
  fm_fake_exit0 "$FAKEBIN_DIR" claude
  # One live worker already sits beside the orchestrator on that account.
  meta="$HOME_DIR/state/other-lane.meta"
  {
    echo "harness=claude"
    echo "kind=ship"
    echo "account=$orch"
  } > "$meta"
  quota="$CASE_DIR/quota-projected.json"
  quota_fixture "$quota" 89 4 3
  # Even with the captain's over-pace approval, the orchestrator account still
  # admits at most one worker beside the orchestrator.
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$quota" \
    --account "$orch" --over-pace "captain approved going over pace")
  status=$?
  expect_code 75 "$status" "the orchestrator lane cap must still defer a second worker: $out"
  assert_contains "$out" "is the orchestrator account and admits at most 1 worker" \
    "the deferral must name the orchestrator lane cap: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "a deferred spawn must publish no task record"
  pass "fm-spawn.sh: --over-pace does not bypass the orchestrator lane cap"
}
test_over_pace_does_not_bypass_orchestrator_lane_cap

printf '# all fm-spawn-claude-runway tests passed\n'
