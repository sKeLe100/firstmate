#!/usr/bin/env bash
# Behavioral coverage for bin/fm-underused-capacity.sh: fixture resource
# snapshots drive the lane verdicts through the script's public interface, with
# the pool's free slots and the queue's dispatchable count supplied as fixtures.
# Covers an idle fleet, a saturated pool, quota-tight and stale lanes, an empty
# queue, the uncapped default, threshold precedence, and a broken source.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-underused-capacity.sh"
TMP_ROOT=$(fm_test_tmproot fm-underused-capacity)

fail() { echo "FAIL: $*" >&2; exit 1; }

make_dir() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/config"
  printf '%s\n' "$d"
}

write_resource() {  # <dir> <json-body>
  printf '%s\n' "$2" > "$1/resource.json"
}

write_queue() {  # <dir> <dispatchable>
  printf 'count: 3\ndispatchable: %s\n' "$2" > "$1/queue.txt"
}

write_capacity() {  # <dir> <line>
  printf '%s\n' "$2" > "$1/capacity.txt"
}

run_report() {  # <dir>
  local d=$1
  FM_HOME="$d" "$SCRIPT" \
    --resource-json "$d/resource.json" \
    --queue-output "$d/queue.txt" \
    --capacity-line "$(cat "$d/capacity.txt")"
}

# A fixture with four lanes: claude#1 has headroom but its weekly window is
# ahead of pace (overspending) and one live worker; claude#2 has headroom with
# its weekly window behind pace (unused reserve); opencode-go's rolling window
# has headroom with its weekly window behind pace;
# codex's five-hour window is nearly spent.
lane_fixture() {
  cat <<'EOF'
{"schema":"fm-resource-snapshot.v1","generated":"2026-11-22T00:00:00Z","quota":[
{"lane":"claude#1","account":"/home/u/.claude","window":"five_hour","pct_remaining":71,"pace":"behind","state":"fresh"},
{"lane":"claude#1","account":"/home/u/.claude","window":"seven_day","pct_remaining":30,"pace":"ahead","state":"fresh"},
{"lane":"claude#2","account":"/home/u/.claude-secondary","window":"five_hour","pct_remaining":83,"pace":"behind","state":"fresh"},
{"lane":"claude#2","account":"/home/u/.claude-secondary","window":"seven_day","pct_remaining":46,"pace":"behind","state":"fresh"},
{"lane":"opencode-go","account":"-","window":"rolling","pct_remaining":99,"pace":"behind","state":"fresh"},
{"lane":"opencode-go","account":"-","window":"weekly","pct_remaining":86,"pace":"behind","state":"fresh"},
{"lane":"codex","account":"-","window":"five_hour","pct_remaining":10,"pace":"ahead","state":"fresh"},
{"lane":"codex","account":"-","window":"window:720h","pct_remaining":0,"pace":"ahead","state":"fresh"}],
"workers":[
{"spend_lane":"claude#1","stage":"working"},
{"spend_lane":"claude#2","stage":"parked"},
{"spend_lane":"opencode-go","stage":"done"},
{"spend_lane":"codex","stage":"failed"}]}
EOF
}

# 1. Idle capacity is reported only for lanes whose weekly window is not
#    ahead of pace (the 2026-11-22 claude#2 and opencode-go case), with the pool's free slots, the dispatchable count, and that
#    lane's own live worker count.
d=$(make_dir idle)
lane_fixture > "$d/resource.json"
write_queue "$d" 3
write_capacity "$d" 'capacity: free_lanes=2 reason=ok lanes=1 target=3 secondmates=0 load1=0.1 cores=8 mem_free_pct=70 disk_free_mb=100000'
out=$(run_report "$d")
assert_equals "idle capacity: claude#2 83%, 2 free slots, 3 dispatchable, live=1
idle capacity: opencode-go 99%, 2 free slots, 3 dispatchable, live=0" "$out" \
  "idle report should name the behind-pace lanes and skip ahead-of-pace claude#1"

# 2. A saturated pool (free_lanes=0) prints nothing and exits 0.
d=$(make_dir saturated)
lane_fixture > "$d/resource.json"
write_queue "$d" 3
write_capacity "$d" 'capacity: free_lanes=0 reason=full lanes=3 target=3 secondmates=0 load1=4.0 cores=4 mem_free_pct=40 disk_free_mb=100000'
out=$(run_report "$d")
assert_equals "" "$out" "saturated pool must stay silent"

# 3. Quota-tight and stale readings never read as idle capacity.
d=$(make_dir quota-tight)
cat > "$d/resource.json" <<'EOF'
{"schema":"fm-resource-snapshot.v1","quota":[
{"lane":"claude#1","window":"five_hour","pct_remaining":20,"pace":"ahead","state":"fresh"},
{"lane":"claude#1","window":"seven_day","pct_remaining":80,"pace":"ahead","state":"fresh"},
{"lane":"claude#2","window":"five_hour","pct_remaining":90,"pace":"ahead","state":"stale"},
{"lane":"claude#2","window":"seven_day","pct_remaining":80,"pace":"ahead","state":"fresh"}],
"workers":[]}
EOF
write_queue "$d" 2
write_capacity "$d" 'capacity: free_lanes=1 reason=ok lanes=2 target=3'
out=$(run_report "$d")
assert_equals "" "$out" "tight or stale five-hour windows must not report idle capacity"

# 4. An empty dispatchable queue prints nothing even with headroom and free
#    slots.
d=$(make_dir empty-queue)
lane_fixture > "$d/resource.json"
write_queue "$d" 0
write_capacity "$d" 'capacity: free_lanes=2 reason=ok lanes=1 target=3'
out=$(run_report "$d")
assert_equals "" "$out" "an empty dispatchable queue must stay silent"

# 5. No lane cap (free_lanes=unknown, reason=no-target) counts as free slots
#    and is reported as uncapped rather than invented as a number.
d=$(make_dir uncapped)
lane_fixture > "$d/resource.json"
write_queue "$d" 4
write_capacity "$d" 'capacity: free_lanes=unknown reason=no-target lanes=1 target=none'
out=$(run_report "$d")
assert_equals "idle capacity: claude#2 83%, uncapped free slots, 4 dispatchable, live=1
idle capacity: opencode-go 99%, uncapped free slots, 4 dispatchable, live=0" "$out" \
  "a home without a lane cap should report uncapped free slots"

# 6. Threshold precedence: the flag wins over the environment, and a config
#    file supplies the default when neither is set.
d=$(make_dir threshold)
lane_fixture > "$d/resource.json"
write_queue "$d" 2
write_capacity "$d" 'capacity: free_lanes=2 reason=ok lanes=1 target=3'
out=$(FM_UNDERUSED_FIVE_HOUR_MIN=60 run_report "$d")
assert_contains "$out" "claude#2 83%" "threshold 60 from the environment should report claude#2"
printf '90\n' > "$d/config/underused-capacity-threshold"
out=$(run_report "$d")
assert_equals "idle capacity: opencode-go 99%, 2 free slots, 2 dispatchable, live=0" "$out" \
  "config threshold 90 should silence the 83% lane only"
out=$(FM_HOME="$d" "$SCRIPT" --resource-json "$d/resource.json" --queue-output "$d/queue.txt" \
  --capacity-line "$(cat "$d/capacity.txt")" --threshold 80)
assert_contains "$out" "claude#2 83%" "--threshold should override the config file"

# 7. A source that cannot answer fails loudly instead of claiming nothing is
#    idle.
d=$(make_dir broken)
lane_fixture > "$d/resource.json"
write_capacity "$d" 'capacity: free_lanes=2 reason=ok lanes=1 target=3'
printf 'count: 2\n' > "$d/queue.txt"
out=$(run_report "$d" 2>&1)
rc=$?
assert_equals "1" "$rc" "a queue snapshot without a dispatchable count must exit 1"
assert_contains "$out" "no dispatchable count" "the failure should name the missing count"

echo "fm-underused-capacity.test.sh: ok"
