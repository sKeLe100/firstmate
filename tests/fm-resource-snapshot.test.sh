#!/usr/bin/env bash
# Behavioral coverage for bin/fm-resource-snapshot.sh: deterministic fixture
# rendering of every section, failure isolation, row caps, read-only behavior,
# and an opt-in live reconciliation against the raw readers on both hosts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-resource-snapshot)
SNAP="$ROOT/bin/fm-resource-snapshot.sh"
NOW=1795123200

write_json() {  # <path> <body>
  printf '%s\n' "$2" > "$1"
}

make_home() {  # <name> <quota-mode: fresh|failed|rate-limited>
  local name=$1 quota=$2 home fb
  home="$TMP_ROOT/$name/home"
  fb="$TMP_ROOT/$name/bin"
  mkdir -p "$home/state" "$home/data/account-roles" "$home/config" "$fb"

  cat > "$home/state/alpha.meta" <<EOF
endpoint_task_id=alpha
kind=ship
harness=claude
model=claude-sonnet-5-5
account=/home/test/.claude-secondary
worktree=$TMP_ROOT/$name/nowhere
spawn_gen=s$((NOW - 7200)).1.1
pr=https://example.invalid/pr/1
herdr_pane_id=wA:p1
EOF
  cat > "$home/state/beta.meta" <<EOF
endpoint_task_id=beta
kind=scout
harness=opencode
model=opencode-go/deepseek-v4.1-flash
worktree=$TMP_ROOT/$name/nowhere
spawn_gen=s$((NOW - 60)).1.1
herdr_pane_id=wA:p2
EOF
  cat > "$home/state/gamma.meta" <<EOF
endpoint_task_id=gamma
spawn_gen=not-a-number
EOF

  cat > "$home/data/secondmates.md" <<'EOF'
- pc02-mate - fixture mate (host: pc02; root: /home/test/fork; home: /home/test/mate; scope: fixture; projects: ; added 2026-11-01)
EOF

  cat > "$home/config/claude-roles" <<'EOF'
orchestrator=/home/test/.claude
workers=/home/test/.claude-secondary
EOF

  cat > "$fb/collie" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"rows":[{"paneId":"wA:p1","lastActiveAt":1795122900000},{"paneId":"wB:p1","lastActiveAt":1795122000000}]}'
EOF

  case "$quota" in
    failed)
      cat > "$fb/quota-axi" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
      ;;
    rate-limited)
      cat > "$fb/quota-axi" <<'EOF'
#!/usr/bin/env bash
cat "${FAKE_QUOTA_RATE_LIMITED:?}"
EOF
      ;;
    *)
      cat > "$fb/quota-axi" <<'EOF'
#!/usr/bin/env bash
cat "${FAKE_QUOTA_JSON:?}"
EOF
      ;;
  esac
  chmod +x "$fb/collie" "$fb/quota-axi"
  printf '%s|%s\n' "$home" "$fb"
}

write_fixtures() {  # <name>
  local name=$1 dir=$TMP_ROOT/$1
  write_json "$dir/quota.json" '{
    "schemaVersion": 6,
    "generatedAt": "2026-11-20T00:00:00Z",
    "providers": [
      {"provider":"claude","plan":"pro","accountLocator":{"path":"/home/test/.claude"},"accountKey":"a",
       "state":{"status":"fresh","stale":false},
       "windows":[{"id":"five_hour","percentRemaining":71,"resetsAt":"2026-11-20T06:00:00Z","pace":{"status":"behind"}},
                  {"id":"seven_day","percentRemaining":8,"resetsAt":"2026-11-23T00:00:00Z","pace":{"status":"ahead"}}]},
      {"provider":"claude","plan":"pro","accountLocator":{"path":"/home/test/.claude-secondary"},"accountKey":"b",
       "state":{"status":"fresh","stale":false},
       "windows":[{"id":"five_hour","percentRemaining":83,"resetsAt":"2026-11-20T08:00:00Z","pace":{"status":"behind"}},
                  {"id":"seven_day","percentRemaining":46,"resetsAt":"2026-11-23T00:00:00Z","pace":{"status":"behind"}}]},
      {"provider":"opencode-go","plan":"OpenCode Go","accountKey":"default",
       "state":{"status":"fresh","stale":false},
       "windows":[{"id":"rolling","percentRemaining":99,"resetsAt":"2026-11-20T09:00:00Z","pace":{"status":"behind"}},
                  {"id":"weekly","percentRemaining":86,"resetsAt":"2026-11-23T00:00:00Z","pace":{"status":"behind"}},
                  {"id":"monthly","percentRemaining":93,"resetsAt":"2026-12-16T00:00:00Z","pace":{"status":"behind"}}]},
      {"provider":"codex","plan":"free","accountKey":"default",
       "state":{"status":"fresh","stale":false},
       "windows":[{"id":"window:720h","percentRemaining":0,"resetsAt":"2026-12-06T00:00:00Z","pace":{"status":"ahead"}}]}
    ]}'
  write_json "$dir/quota-rate-limited.json" '{
    "schemaVersion": 6,
    "generatedAt": "2026-11-20T00:00:00Z",
    "providers": [
      {"provider":"claude","plan":"pro","accountLocator":{"path":"/home/test/.claude"},"accountKey":"a",
       "state":{"status":"rate_limited","stale":false,"error":"rate limited","retryAfter":"2026-11-20T00:02:00Z"},
       "windows":[]}
    ]}'
  write_json "$dir/hosts.json" '{
    "hosts":[
      {"machine":"PC01","load1":0.5,"cores":16,"mem_free_pct":80,"disk_free_gb":850.0,"disk_path":"/home/test","uptime":1000,"read_utc":"2026-11-20T00:00:00Z"}
    ],
    "drives":[
      {"machine":"PC01","mount":"/","total_gb":1000.0,"free_gb":850.0,"pct_used":15,"read_utc":"2026-11-20T00:00:00Z"},
      {"machine":"PC01","mount":"C:","total_gb":500.0,"free_gb":88.0,"pct_used":82,"read_utc":"2026-11-20T00:00:00Z"}
    ]}'
  write_json "$dir/drive-health.json" '{
    "drive_health":[
      {"machine":"PC01","disk":"/dev/pd0","model":"ST8000DM004-2CX188","smart":"PASSED","reallocated":"0","pending":"0","uncorrectable":"0","temp_c":"31","power_on_hours":"14711","media_errors":"-","reason":"-","read_utc":"2026-11-20T00:00:00Z"},
      {"machine":"PC02","disk":"/dev/sdc","model":"Force MP510","smart":"PASSED","reallocated":"-","pending":"-","uncorrectable":"-","temp_c":"45","power_on_hours":"14682","nvme_used_pct":"13","media_errors":"0","reason":"-","read_utc":"2026-11-20T00:00:00Z"},
      {"machine":"PC02","disk":"/dev/sdb","model":"WDC WD140EFGX-68B0GN0","smart":"FAILED","reallocated":"8","pending":"2","uncorrectable":"1","temp_c":"41","power_on_hours":"7100","media_errors":"-","reason":"SMART self-assessment FAILED","read_utc":"2026-11-20T00:00:00Z"}
    ]}'
  write_json "$dir/herdr-pc01.json" '{
    "sessions":[{"name":"default","status":"running"}],
    "workspaces":[{"workspace_id":"wA","label":"└ alpha · p:x"},{"workspace_id":"wZ","label":"firstmate"}],
    "panes":[
      {"pane_id":"wA:p1","tab_id":"wA:t1","workspace_id":"wA","agent":"claude","agent_status":"working","cwd":"/home/test/wt","foreground_cwd":"/home/test/wt","terminal_title_stripped":"Alpha"},
      {"pane_id":"wZ:p9","tab_id":"wZ:t1","workspace_id":"wZ","agent_status":"unknown","cwd":"/home/test/relay","foreground_cwd":"/home/test/relay","terminal_title_stripped":"Relay"},
      {"pane_id":"wZ:p2","tab_id":"wZ:t1","workspace_id":"wZ","agent":"opencode","agent_status":"unknown","cwd":"/home/test","foreground_cwd":"/home/test","terminal_title_stripped":"Unknown agent"}
    ]}'
  write_json "$dir/herdr-pc02.json" '{
    "sessions":[{"name":"fm-remote","status":"running"}],
    "workspaces":[{"workspace_id":"wB","label":"└ beta · p:y"}],
    "panes":[
      {"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB","agent":"opencode","agent_status":"idle","cwd":"/home/test/mate","foreground_cwd":"/home/test/mate","terminal_title_stripped":"Beta"}
    ]}'
  write_json "$dir/remote.json" '{
    "hosts":[{"machine":"PC02","load1":1.5,"cores":16,"mem_free_pct":75,"disk_free_gb":900.0,"disk_path":"/home/test/mate","uptime":2000,"read_utc":"2026-11-20T00:00:00Z"}],
    "drives":[{"machine":"PC02","mount":"C:","total_gb":900.0,"free_gb":23.0,"pct_used":97,"read_utc":"2026-11-20T00:00:00Z"},
{"machine":"PC02","mount":"B1","total_gb":100.0,"free_gb":19.9,"pct_used":50,"read_utc":"2026-11-20T00:00:00Z"},
{"machine":"PC02","mount":"B2","total_gb":100.0,"free_gb":20.0,"pct_used":50,"read_utc":"2026-11-20T00:00:00Z"},
{"machine":"PC02","mount":"B3","total_gb":100.0,"free_gb":39.9,"pct_used":50,"read_utc":"2026-11-20T00:00:00Z"},
{"machine":"PC02","mount":"B4","total_gb":100.0,"free_gb":40.0,"pct_used":50,"read_utc":"2026-11-20T00:00:00Z"}],
    "sessions":[{"name":"fm-remote","status":"running"}],
    "workers":[
      {"home_lane":"pc02-mate","task":"delta","kind":"ship","model":"opencode-go/deepseek-v4.1-flash","spend_lane":"opencode-go","stage":"state: working · source: pane","age":"5m","last_active":"2026-11-20T00:00:00Z","ctx_band":"n/a","pr":"-","read_utc":"2026-11-20T00:00:00Z"},
      {"home_lane":"pc02-mate","task":"epsilon","kind":"ship","model":"claude-haiku-5-5","spend_lane":"claude#2","stage":"state: done · source: status-log","age":"1h","last_active":"-","ctx_band":"ok(10%)","pr":"-","read_utc":"2026-11-20T00:00:00Z"}
    ],
    "android":[
      {"avd":"pt_pixel8pro","serial":"emulator-5554","state":"device","boot_completed":"1","detail":"running emulator","read_utc":"2026-11-20T00:00:00Z"}
    ],
    "mate_account":"/home/test/.claude-secondary"
  }'
  write_json "$dir/roles.json" '[
    {"role":"orchestrator","where":"PC01","account":"/home/test/.claude","evidence":"fixture","read_utc":"2026-11-20T00:00:00Z"},
    {"role":"supervision","where":"PC01","account":"inherited","evidence":"enabled engine=claude model=sonnet","read_utc":"2026-11-20T00:00:00Z"},
    {"role":"worker-lane:opencode-go","where":"PC01,PC02","account":"-","evidence":"2 worker(s) on opencode-go","read_utc":"2026-11-20T00:00:00Z"}
  ]'
  write_json "$dir/testing.json" '{
    "testing":[
      {"machine":"PC01","item":"pc01-test-slot","state":"free","detail":"no holder recorded","read_utc":"2026-11-20T00:00:00Z"},
      {"machine":"PC02","item":"pc02-personal-use","state":"off","detail":"-","read_utc":"2026-11-20T00:00:00Z"}
    ],
    "compute":[
      {"rung":"gitlab","account":"example-group","plan":"free","used":"443 min MTD","allowance":"400 min/mo","reset":"2026-12-01","status":"exhausted","runs":"relay rung","read_utc":"2026-11-20T00:00:00Z"},
      {"rung":"github-storage","account":"example-user","plan":"free","used":"120 GB-h","allowance":"360 GB-h","reset":"month rollover","status":"ok","runs":"-","read_utc":"2026-11-20T00:00:00Z"}
    ]}'
  write_json "$dir/android.json" '{
    "android":[
      {"machine":"PC01","avd":"pt_pixel8pro","serial":"emulator-5554","state":"device","boot_completed":"1","detail":"running emulator","read_utc":"2026-11-20T00:00:00Z"},
      {"machine":"PC02","avd":"-","serial":"-","state":"none","boot_completed":"-","detail":"no AVDs and no running emulators","read_utc":"2026-11-20T00:00:00Z"}
    ]}'
  export FM_RESOURCE_ANDROID_FIXTURE="$dir/android.json"
  write_json "$dir/hosts-pc01.json" '{
    "hosts":[{"machine":"PC01","load1":0.5,"cores":16,"mem_free_pct":80,"disk_free_gb":850.0,"disk_path":"/home/test","uptime":1000,"read_utc":"2026-11-20T00:00:00Z"}],
    "drives":[{"machine":"PC01","mount":"/","total_gb":1000.0,"free_gb":850.0,"pct_used":15,"read_utc":"2026-11-20T00:00:00Z"},
{"machine":"PC01","mount":"B1","total_gb":100.0,"free_gb":19.9,"pct_used":50,"read_utc":"2026-11-20T00:00:00Z"},
{"machine":"PC01","mount":"B2","total_gb":100.0,"free_gb":20.0,"pct_used":50,"read_utc":"2026-11-20T00:00:00Z"},
{"machine":"PC01","mount":"B3","total_gb":100.0,"free_gb":39.9,"pct_used":50,"read_utc":"2026-11-20T00:00:00Z"},
{"machine":"PC01","mount":"B4","total_gb":100.0,"free_gb":40.0,"pct_used":50,"read_utc":"2026-11-20T00:00:00Z"}]
  }'
  write_json "$dir/down.json" '{
    "hosts":[],"drives":[],"sessions":[],"workers":[],"mate_account":"",
    "unavailable":[{"source":"pc02:pc02","reason":"remote host read failed (status 255)","read_utc":"2026-11-20T00:00:00Z"}]
  }'
  write_json "$dir/context.json" '{"alpha":"warn(23.5%)"}'
}

run_snapshot() {  # <home> <fakebin> [args...]
  local home=$1 fb=$2
  shift 2
  env PATH="$fb:$BASE_PATH" FM_HOME="$home" FM_RESOURCE_NOW="$NOW" \
    FM_RESOURCE_HOSTS_JSON="$TMP_ROOT/fixture/hosts.json" \
    FM_RESOURCE_DRIVE_HEALTH_FIXTURE="$TMP_ROOT/fixture/drive-health.json" \
    FM_RESOURCE_HERDR_JSON_PC01="$TMP_ROOT/fixture/herdr-pc01.json" \
    FM_RESOURCE_HERDR_JSON_PC02="$TMP_ROOT/fixture/herdr-pc02.json" \
    FM_RESOURCE_REMOTE_FIXTURE="$TMP_ROOT/fixture/remote.json" \
    FM_RESOURCE_ROLES_FILE="$TMP_ROOT/fixture/roles.json" \
    FM_RESOURCE_TESTING_FIXTURE="$TMP_ROOT/fixture/testing.json" \
    FM_RESOURCE_CONTEXT_FIXTURE="$TMP_ROOT/fixture/context.json" \
    FAKE_QUOTA_JSON="$TMP_ROOT/fixture/quota.json" \
    FAKE_QUOTA_RATE_LIMITED="$TMP_ROOT/fixture/quota-rate-limited.json" \
    "$SNAP" "$@"
}

fixture_home() {
  local rec
  rec=$(make_home fixture fresh)
  HOME_DIR=${rec%%|*}
  FB=${rec#*|}
  write_fixtures fixture
}

HOME_DIR=
FB=

setup_fixture() {
  [ -n "$HOME_DIR" ] && return 0
  fixture_home
}

count_json() {  # <json-file> <jq-path>
  jq -r "($2) | length" "$1"
}

test_every_section_renders_and_agrees() {
  local out rc
  setup_fixture
  out=$(run_snapshot "$HOME_DIR" "$FB" --json 2>&1); rc=$?
  expect_code 0 "$rc" "full fixture render"
  printf '%s\n' "$out" > "$TMP_ROOT/model.json"
  local section
  for section in hosts drives drive_health quota workers panes strays secondmates roles testing android compute unavailable; do
    jq -e "has(\"$section\")" "$TMP_ROOT/model.json" >/dev/null || fail "missing section $section"
  done
  [ "$(count_json "$TMP_ROOT/model.json" '.hosts')" = 2 ] || fail "hosts count"
  [ "$(count_json "$TMP_ROOT/model.json" '.drives')" = 7 ] || fail "drives count"
  [ "$(count_json "$TMP_ROOT/model.json" '.drive_health')" = 3 ] || fail "drive health count: $(jq -c '.drive_health' "$TMP_ROOT/model.json")"
  [ "$(count_json "$TMP_ROOT/model.json" '.quota')" = 8 ] || fail "quota rows: $(jq -c '.quota' "$TMP_ROOT/model.json")"
  [ "$(count_json "$TMP_ROOT/model.json" '.workers')" = 5 ] || fail "workers must union both homes"
  [ "$(count_json "$TMP_ROOT/model.json" '.panes')" = 4 ] || fail "panes count"
  [ "$(count_json "$TMP_ROOT/model.json" '.strays')" = 2 ] || fail "bare + unknown-agent panes are exactly two strays"
  [ "$(count_json "$TMP_ROOT/model.json" '.secondmates')" = 1 ] || fail "secondmates count"
  [ "$(count_json "$TMP_ROOT/model.json" '.roles')" = 3 ] || fail "roles fixture count"
  [ "$(count_json "$TMP_ROOT/model.json" '.testing')" = 2 ] || fail "testing count"
  [ "$(count_json "$TMP_ROOT/model.json" '.android')" = 2 ] || fail "android count"
  jq -e '[.unavailable[] | select(.source | startswith("android"))] | length == 0' \
    "$TMP_ROOT/model.json" >/dev/null || fail "a readable Android probe must leave unavailable"
  [ "$(count_json "$TMP_ROOT/model.json" '.compute')" = 2 ] || fail "compute count"
  jq -e '.drives[] | select(.machine == "PC02" and .mount == "C:") | .free_gb == "23.0" and .warn == "watch"' \
    "$TMP_ROOT/model.json" >/dev/null || fail "PC02 C: must be watch at 23 GB"
  jq -e '.drive_health[] | select(.machine == "PC02" and .disk == "/dev/sdb")
    | .smart == "FAILED" and .reallocated == "8" and .pending == "2"
      and .uncorrectable == "1" and .temp_c == "41" and .reason != "-"' \
    "$TMP_ROOT/model.json" >/dev/null \
    || fail "a failing drive must keep its SMART counts and verdict: $(jq -c '.drive_health' "$TMP_ROOT/model.json")"
  jq -e '.drive_health[] | select(.machine == "PC02" and .disk == "/dev/sdc")
    | .smart == "PASSED" and .nvme_used_pct == "13" and .media_errors == "0" and .reason == "-"' \
    "$TMP_ROOT/model.json" >/dev/null \
    || fail "an NVMe row must carry percentage used and media errors: $(jq -c '.drive_health' "$TMP_ROOT/model.json")"
  jq -e '.quota | map(.lane) | .[0] == "claude#1" and .[2] == "claude#2" and .[4] == "opencode-go" and .[7] == "codex"' \
    "$TMP_ROOT/model.json" >/dev/null || fail "quota lane order must be Claude #1, Claude #2, OpenCode Go, Codex"
  jq -e '.quota[] | select(.lane == "claude#1" and .window == "five_hour")
    | .account == "/home/test/.claude" and .pct_remaining == 71
      and .resets_et != "-" and .reading_utc == "2026-11-20T00:00:00Z"' \
    "$TMP_ROOT/model.json" >/dev/null \
    || fail "a Claude quota row must carry account, percent, reset, and the quota read time: $(jq -c '.quota' "$TMP_ROOT/model.json")"
  jq -e '.workers[] | select(.task == "alpha") | .ctx_band == "warn(23.5%)" and .spend_lane == "claude#2"' \
    "$TMP_ROOT/model.json" >/dev/null || fail "claude context band and lane"
  jq -e '.workers[] | select(.task == "gamma") | .kind == "unknown" and .model == "unknown" and .age == "-"' \
    "$TMP_ROOT/model.json" >/dev/null || fail "missing meta fields must render unknown"
  jq -e '.secondmates[0] | .id == "pc02-mate" and .workers == "2" and .account == "/home/test/.claude-secondary"' \
    "$TMP_ROOT/model.json" >/dev/null || fail "secondmate direct read and worker count: $(jq -c '.secondmates' "$TMP_ROOT/model.json")"

  out=$(run_snapshot "$HOME_DIR" "$FB" 2>&1); rc=$?
  expect_code 0 "$rc" "TOON render"
  assert_contains "$out" 'workers[5]{machine,home_lane,task' "TOON must render the workers table"
  assert_contains "$out" 'unavailable: []' "TOON must render the empty unavailable section"
  pass "every section renders and JSON/TOON share the same model"
}

test_failed_quota_is_labelled_not_zero() {
  local rec home fb out rc
  rec=$(make_home quota-failed failed); home=${rec%%|*}; fb=${rec#*|}
  write_fixtures fixture
  out=$(run_snapshot "$home" "$fb" --json 2>&1); rc=$?
  expect_code 0 "$rc" "failed quota render"
  printf '%s\n' "$out" > "$TMP_ROOT/failed.json"
  [ "$(count_json "$TMP_ROOT/failed.json" '.quota')" = 0 ] || fail "failed quota must not invent rows"
  jq -e '.unavailable[] | select(.source == "quota")' "$TMP_ROOT/failed.json" >/dev/null \
    || fail "failed quota must render an unavailable row"
  [ "$(count_json "$TMP_ROOT/failed.json" '.hosts')" = 2 ] || fail "a failed source must not drop other sections"
  pass "a failed quota read is labelled and never rendered as zero"
}

test_rate_limited_quota_is_not_zero() {
  local rec home fb out rc
  rec=$(make_home quota-limited rate-limited); home=${rec%%|*}; fb=${rec#*|}
  write_fixtures fixture
  out=$(run_snapshot "$home" "$fb" --json 2>&1); rc=$?
  expect_code 0 "$rc" "rate-limited quota render"
  printf '%s\n' "$out" > "$TMP_ROOT/limited.json"
  jq -e '.quota[] | select(.lane == "claude#1") | .state == "rate_limited" and .pct_remaining == null and (.reason | test("retry"))' \
    "$TMP_ROOT/limited.json" >/dev/null || fail "rate-limited quota must keep state, reason, and a null percentage"
  pass "a rate-limited quota read shows state and retry, never 0 percent"
}

test_down_pc02_keeps_pc01() {
  local rec home fb out rc
  rec=$(make_home down fresh); home=${rec%%|*}; fb=${rec#*|}
  write_fixtures fixture
  out=$(env PATH="$fb:$BASE_PATH" FM_HOME="$home" FM_RESOURCE_NOW="$NOW" \
    FM_RESOURCE_HOSTS_JSON="$TMP_ROOT/fixture/hosts-pc01.json" \
    FM_RESOURCE_HERDR_JSON_PC01="$TMP_ROOT/fixture/herdr-pc01.json" \
    FM_RESOURCE_REMOTE_FIXTURE="$TMP_ROOT/fixture/down.json" \
    FM_RESOURCE_ROLES_FILE="$TMP_ROOT/fixture/roles.json" \
    FM_RESOURCE_TESTING_FIXTURE="$TMP_ROOT/fixture/testing.json" \
    FM_RESOURCE_CONTEXT_FIXTURE="$TMP_ROOT/fixture/context.json" \
    FAKE_QUOTA_JSON="$TMP_ROOT/fixture/quota.json" \
    "$SNAP" --json 2>&1); rc=$?
  expect_code 0 "$rc" "down PC02 render"
  printf '%s\n' "$out" > "$TMP_ROOT/down.json"
  jq -e '.unavailable[] | select(.source == "pc02:pc02")' "$TMP_ROOT/down.json" >/dev/null \
    || fail "down PC02 must render an unavailable row"
  [ "$(count_json "$TMP_ROOT/down.json" '.hosts')" = 1 ] || fail "PC01 host must survive a PC02 outage"
  jq -e '.workers | map(select(.machine == "PC01")) | length == 3' "$TMP_ROOT/down.json" >/dev/null \
    || fail "PC01 workers must survive a PC02 outage"
  pass "a down PC02 yields unavailable rows and keeps PC01 complete"
}

test_remote_fixture_alone_supplies_pc02_rows() {
  local rec home fb out rc
  rec=$(make_home remote-only fresh); home=${rec%%|*}; fb=${rec#*|}
  write_fixtures fixture
  out=$(env PATH="$fb:$BASE_PATH" FM_HOME="$home" FM_RESOURCE_NOW="$NOW" \
    FM_RESOURCE_HOSTS_JSON="$TMP_ROOT/fixture/hosts-pc01.json" \
    FM_RESOURCE_HERDR_JSON_PC01="$TMP_ROOT/fixture/herdr-pc01.json" \
    FM_RESOURCE_HERDR_JSON_PC02="$TMP_ROOT/fixture/herdr-pc02.json" \
    FM_RESOURCE_REMOTE_FIXTURE="$TMP_ROOT/fixture/remote.json" \
    FM_RESOURCE_ROLES_FILE="$TMP_ROOT/fixture/roles.json" \
    FM_RESOURCE_TESTING_FIXTURE="$TMP_ROOT/fixture/testing.json" \
    FM_RESOURCE_CONTEXT_FIXTURE="$TMP_ROOT/fixture/context.json" \
    FAKE_QUOTA_JSON="$TMP_ROOT/fixture/quota.json" \
    "$SNAP" --json 2>&1); rc=$?
  expect_code 0 "$rc" "remote-fixture-only render"
  printf '%s\n' "$out" > "$TMP_ROOT/remote-only.json"
  jq -e '.hosts | map(.machine) | sort == ["PC01","PC02"]' "$TMP_ROOT/remote-only.json" >/dev/null \
    || fail "PC02 host must come from the remote fixture alone"
  jq -e '.drives[] | select(.machine == "PC02" and .mount == "C:") | .free_gb == "23.0" and .warn == "watch"' \
    "$TMP_ROOT/remote-only.json" >/dev/null || fail "PC02 C: at 23 GB must render watch from the remote fixture alone"
  jq -e '.panes | map(select(.machine == "PC02")) | length == 1' "$TMP_ROOT/remote-only.json" >/dev/null \
    || fail "PC02 panes must resolve the running session from the remote fixture"
  local m
  for m in PC01 PC02; do
    jq -e --arg m "$m" '[.drives[] | select(.machine == $m and (.mount | startswith("B"))) | .warn] == ["low","watch","watch","ok"]' \
      "$TMP_ROOT/remote-only.json" >/dev/null || fail "$m boundary drives must warn low,watch,watch,ok at 19.9/20/39.9/40 GB: $(jq -c '[.drives[] | select(.mount | startswith("B"))]' "$TMP_ROOT/remote-only.json")"
  done
  pass "the remote fixture alone supplies PC02 hosts, drives, and the running session"
}

test_worker_lane_account_follows_lane_not_role() {
  local rec home fb out rc
  rec=$(make_home lane-account fresh); home=${rec%%|*}; fb=${rec#*|}
  write_fixtures fixture
  cat > "$home/data/account-roles/fm-claude-roles.sh" <<'EOF'
#!/usr/bin/env bash
echo "ok: config/claude-orchestrator-account = /home/test/.claude-secondary"
echo "ok: config/claude-account = /home/test/.claude"
EOF
  cat > "$home/state/delta.meta" <<'EOF'
endpoint_task_id=delta
kind=ship
harness=claude
model=claude-sonnet-5-5
account=/home/test/.claude
spawn_gen=s1.1.1
EOF
  out=$(env PATH="$fb:$BASE_PATH" FM_HOME="$home" FM_RESOURCE_NOW="$NOW" \
    FM_RESOURCE_HOSTS_JSON="$TMP_ROOT/fixture/hosts-pc01.json" \
    FM_RESOURCE_HERDR_JSON_PC01="$TMP_ROOT/fixture/herdr-pc01.json" \
    FM_RESOURCE_REMOTE_FIXTURE="$TMP_ROOT/fixture/down.json" \
    FM_RESOURCE_TESTING_FIXTURE="$TMP_ROOT/fixture/testing.json" \
    FM_RESOURCE_CONTEXT_FIXTURE="$TMP_ROOT/fixture/context.json" \
    FAKE_QUOTA_JSON="$TMP_ROOT/fixture/quota.json" \
    "$SNAP" --json 2>&1); rc=$?
  expect_code 0 "$rc" "live roles render"
  printf '%s\n' "$out" > "$TMP_ROOT/lane-account.json"
  jq -e '[.roles[] | select(.role == "worker-lane:claude#1") | .account] == ["/home/test/.claude"]' "$TMP_ROOT/lane-account.json" >/dev/null \
    || fail "worker-lane:claude#1 must report the .claude account: $(jq -c '.roles' "$TMP_ROOT/lane-account.json")"
  jq -e '[.roles[] | select(.role == "worker-lane:claude#2") | .account] == ["/home/test/.claude-secondary"]' "$TMP_ROOT/lane-account.json" >/dev/null \
    || fail "worker-lane:claude#2 must report the claude-secondary account: $(jq -c '.roles' "$TMP_ROOT/lane-account.json")"
  pass "worker-lane accounts follow the lane classification, not the orchestrator role"
}

test_row_caps_and_omitted() {
  local rec home fb out rc
  rec=$(make_home caps fresh); home=${rec%%|*}; fb=${rec#*|}
  write_fixtures fixture
  out=$(env PATH="$fb:$BASE_PATH" FM_HOME="$home" FM_RESOURCE_NOW="$NOW" \
    FM_RESOURCE_CAP_WORKERS=2 FM_RESOURCE_CAP_PANES=2 FM_RESOURCE_CAP_STRAYS=1 \
    FM_RESOURCE_HOSTS_JSON="$TMP_ROOT/fixture/hosts.json" \
    FM_RESOURCE_HERDR_JSON_PC01="$TMP_ROOT/fixture/herdr-pc01.json" \
    FM_RESOURCE_HERDR_JSON_PC02="$TMP_ROOT/fixture/herdr-pc02.json" \
    FM_RESOURCE_REMOTE_FIXTURE="$TMP_ROOT/fixture/remote.json" \
    FM_RESOURCE_ROLES_FILE="$TMP_ROOT/fixture/roles.json" \
    FM_RESOURCE_TESTING_FIXTURE="$TMP_ROOT/fixture/testing.json" \
    FM_RESOURCE_CONTEXT_FIXTURE="$TMP_ROOT/fixture/context.json" \
    FAKE_QUOTA_JSON="$TMP_ROOT/fixture/quota.json" \
    "$SNAP" --json 2>&1); rc=$?
  expect_code 0 "$rc" "capped render"
  printf '%s\n' "$out" > "$TMP_ROOT/caps.json"
  [ "$(count_json "$TMP_ROOT/caps.json" '.workers')" = 2 ] || fail "worker cap"
  [ "$(count_json "$TMP_ROOT/caps.json" '.panes')" = 2 ] || fail "pane cap"
  [ "$(count_json "$TMP_ROOT/caps.json" '.strays')" = 1 ] || fail "stray cap"
  jq -e '.omitted.workers == 3 and .omitted.panes == 2 and .omitted.strays == 1' \
    "$TMP_ROOT/caps.json" >/dev/null || fail "omitted counts must match the cut rows"
  pass "row caps hold and the omitted counts report the cut rows"
}

test_read_only_leaves_fixture_untouched() {
  local rec home fb before after
  rec=$(make_home readonly fresh); home=${rec%%|*}; fb=${rec#*|}
  write_fixtures fixture
  before=$(find "$home" -type f -printf '%p %s %T@\n' | sort)
  run_snapshot "$home" "$fb" --json >/dev/null 2>&1 || fail "snapshot failed"
  after=$(find "$home" -type f -printf '%p %s %T@\n' | sort)
  [ "$before" = "$after" ] || fail "the snapshot changed files under the fixture home"
  pass "the command creates no file and leaves fixture mtimes unchanged"
}

test_home_only_renders_workers_only() {
  local rec home fb out rc
  rec=$(make_home homeonly fresh); home=${rec%%|*}; fb=${rec#*|}
  write_fixtures fixture
  out=$(env PATH="$fb:$BASE_PATH" FM_HOME="$home" FM_RESOURCE_NOW="$NOW" \
    FM_RESOURCE_CONTEXT_FIXTURE="$TMP_ROOT/fixture/context.json" \
    FAKE_QUOTA_JSON="$TMP_ROOT/fixture/quota.json" \
    "$SNAP" --home-only --json 2>&1); rc=$?
  expect_code 0 "$rc" "home-only render"
  printf '%s\n' "$out" > "$TMP_ROOT/homeonly.json"
  jq -e 'keys_unsorted == ["schema","generated","generated_et","home","budget_exceeded","omitted","workers","unavailable"]' \
    "$TMP_ROOT/homeonly.json" >/dev/null || fail "home-only must expose only its own home fields"
  [ "$(count_json "$TMP_ROOT/homeonly.json" '.workers')" = 3 ] || fail "home-only must read this home only"
  pass "home-only renders just one home's workers for the remote call"
}

test_android_fixture_renders_both_hosts() {
  setup_fixture
  local out rc
  out=$(run_snapshot "$HOME_DIR" "$FB" --json 2>&1); rc=$?
  expect_code 0 "$rc" "android fixture render"
  printf '%s\n' "$out" > "$TMP_ROOT/android-fixture.json"
  [ "$(count_json "$TMP_ROOT/android-fixture.json" '.android')" = 2 ] || fail "android fixture row count"
  jq -e '.android[] | select(.machine == "PC01") | .avd == "pt_pixel8pro" and .serial == "emulator-5554" and .state == "device" and .boot_completed == "1"' \
    "$TMP_ROOT/android-fixture.json" >/dev/null || fail "PC01 Android row: $(jq -c '.android' "$TMP_ROOT/android-fixture.json")"
  jq -e '[.unavailable[] | select(.source | startswith("android"))] | length == 0' \
    "$TMP_ROOT/android-fixture.json" >/dev/null || fail "a readable Android section must not stay unavailable"
  out=$(run_snapshot "$HOME_DIR" "$FB" 2>&1); rc=$?
  expect_code 0 "$rc" "android fixture TOON render"
  assert_contains "$out" 'android[2]{machine,avd,serial,state,boot_completed,detail,read_utc}:' \
    "TOON must render the Android table"
  pass "the Android fixture renders one row per host and clears the unavailable row"
}

test_android_probe_reads_fake_tools() {
  local rec home fb out rc fake
  rec=$(make_home android-probe fresh); home=${rec%%|*}; fb=${rec#*|}
  write_fixtures fixture
  fake="$TMP_ROOT/android-fake"
  mkdir -p "$fake"
  cat > "$fake/adb" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  devices) printf 'List of devices attached\nemulator-5554\tdevice\nemulator-5556\toffline\n\n' ;;
  "-s emulator-5554 emu avd name") printf 'pt_pixel8pro\r\r\nOK\r\r\n' ;;
  "-s emulator-5554 shell getprop sys.boot_completed") printf '1\r\n' ;;
  *) exit 1 ;;
esac
EOF
  cat > "$fake/emulator" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "-list-avds" ] && { printf 'pt_pixel8pro\nother_avd\n'; exit 0; }
exit 1
EOF
  chmod +x "$fake/adb" "$fake/emulator"
  out=$(env PATH="$fb:$BASE_PATH" FM_HOME="$home" FM_RESOURCE_NOW="$NOW" \
    FM_RESOURCE_ANDROID_FIXTURE= FM_RESOURCE_ADB="$fake/adb" FM_RESOURCE_EMULATOR="$fake/emulator" \
    FM_RESOURCE_HOSTS_JSON="$TMP_ROOT/fixture/hosts-pc01.json" \
    FM_RESOURCE_REMOTE_FIXTURE="$TMP_ROOT/fixture/remote.json" \
    FM_RESOURCE_ROLES_FILE="$TMP_ROOT/fixture/roles.json" \
    FM_RESOURCE_TESTING_FIXTURE="$TMP_ROOT/fixture/testing.json" \
    FM_RESOURCE_CONTEXT_FIXTURE="$TMP_ROOT/fixture/context.json" \
    FAKE_QUOTA_JSON="$TMP_ROOT/fixture/quota.json" \
    "$SNAP" --json 2>&1); rc=$?
  expect_code 0 "$rc" "Android probe render"
  printf '%s\n' "$out" > "$TMP_ROOT/android-probe.json"
  jq -e '.android[] | select(.machine == "PC01" and .avd == "pt_pixel8pro")
    | .serial == "emulator-5554" and .state == "device" and .boot_completed == "1"' \
    "$TMP_ROOT/android-probe.json" >/dev/null || fail "running AVD row: $(jq -c '.android' "$TMP_ROOT/android-probe.json")"
  jq -e '[.android[] | select(.machine == "PC01" and .avd == "other_avd") | .state] == ["unknown"]' \
    "$TMP_ROOT/android-probe.json" >/dev/null || fail "a listed AVD must not render stopped while an unnamed offline serial exists"
  jq -e '[.android[] | select(.serial == "emulator-5556") | .state] == ["offline"]' \
    "$TMP_ROOT/android-probe.json" >/dev/null || fail "an offline adb serial must keep its state"
  jq -e '[.unavailable[] | select(.source | startswith("android"))] | length == 0' \
    "$TMP_ROOT/android-probe.json" >/dev/null || fail "a successful Android probe must clear unavailable"
  pass "adb serials, AVD list, and boot_completed come from the bounded probes"
}

run_android_probe() {  # <name> <adb-script-body> <emulator-script-body> -> JSON on stdout
  local name=$1 rec home fb fake
  rec=$(make_home "android-$name" fresh); home=${rec%%|*}; fb=${rec#*|}
  write_fixtures fixture
  fake="$TMP_ROOT/android-fake-$name"
  mkdir -p "$fake"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$fake/adb"
  printf '#!/usr/bin/env bash\n%s\n' "$3" > "$fake/emulator"
  chmod +x "$fake/adb" "$fake/emulator"
  env PATH="$fb:$BASE_PATH" FM_HOME="$home" FM_RESOURCE_NOW="$NOW" \
    FM_RESOURCE_ANDROID_FIXTURE= FM_RESOURCE_ADB="$fake/adb" FM_RESOURCE_EMULATOR="$fake/emulator" \
    FM_RESOURCE_HOSTS_JSON="$TMP_ROOT/fixture/hosts-pc01.json" \
    FM_RESOURCE_REMOTE_FIXTURE="$TMP_ROOT/fixture/remote.json" \
    FM_RESOURCE_ROLES_FILE="$TMP_ROOT/fixture/roles.json" \
    FM_RESOURCE_TESTING_FIXTURE="$TMP_ROOT/fixture/testing.json" \
    FM_RESOURCE_CONTEXT_FIXTURE="$TMP_ROOT/fixture/context.json" \
    FAKE_QUOTA_JSON="$TMP_ROOT/fixture/quota.json" \
    "$SNAP" --json 2>&1
}

test_android_unresolved_name_is_not_stopped() {
  local out
  out=$(run_android_probe unresolved \
    'case "$*" in devices) printf "List of devices attached\nemulator-5554\tdevice\n" ;; *) exit 1 ;; esac' \
    '[ "$*" = "-list-avds" ] && { printf "pt_pixel8pro\n"; exit 0; }; exit 1')
  printf '%s\n' "$out" > "$TMP_ROOT/android-unresolved.json"
  jq -e '[.android[] | select(.machine == "PC01")] | length == 1' \
    "$TMP_ROOT/android-unresolved.json" >/dev/null \
    || fail "an unnamed running emulator must render exactly one row: $(jq -c '.android' "$TMP_ROOT/android-unresolved.json")"
  jq -e '[.android[] | select(.machine == "PC01") | .avd] == ["unknown"]' \
    "$TMP_ROOT/android-unresolved.json" >/dev/null \
    || fail "an unnamed running emulator must render avd unknown, never a stopped listing: $(jq -c '.android' "$TMP_ROOT/android-unresolved.json")"
  jq -e '.android[] | select(.machine == "PC01" and .serial == "emulator-5554")
    | .state == "device" and .boot_completed == "failed" and (.detail | test("unresolved"))' \
    "$TMP_ROOT/android-unresolved.json" >/dev/null || fail "unresolved running emulator row: $(jq -c .android "$TMP_ROOT/android-unresolved.json")"
  pass "an unnamed running emulator renders once as avd unknown, never also as a stopped AVD"
}

test_android_adb_failure_keeps_avd_unknown_not_stopped() {
  local out
  out=$(run_android_probe adb-fail 'exit 1' \
    '[ "$*" = "-list-avds" ] && { printf "pt_pixel8pro\n"; exit 0; }; exit 1')
  printf '%s\n' "$out" > "$TMP_ROOT/android-adb-fail.json"
  jq -e '[.android[] | select(.machine == "PC01" and .avd == "pt_pixel8pro") | .state] == ["unknown"]' \
    "$TMP_ROOT/android-adb-fail.json" >/dev/null \
    || fail "a listed AVD must render unknown, not stopped, when adb fails: $(jq -c '.android' "$TMP_ROOT/android-adb-fail.json")"
  jq -e '.android[] | select(.machine == "PC01" and .avd == "pt_pixel8pro") | (.detail | test("adb"))' \
    "$TMP_ROOT/android-adb-fail.json" >/dev/null \
    || fail "the unknown AVD row must state the adb reason: $(jq -c '.android' "$TMP_ROOT/android-adb-fail.json")"
  jq -e '[.android[] | select(.state == "stopped")] | length == 0' \
    "$TMP_ROOT/android-adb-fail.json" >/dev/null || fail "a failed adb read must never claim a stopped AVD"
  jq -e '[.unavailable[] | select(.source == "android:PC01") | .reason] == ["adb devices failed (status 1)"]' \
    "$TMP_ROOT/android-adb-fail.json" >/dev/null \
    || fail "the failed adb probe must be stated: $(jq -c '.unavailable' "$TMP_ROOT/android-adb-fail.json")"
  pass "a failed adb read renders the AVD unknown with its reason, never stopped"
}

test_android_probe_failures_are_stated_not_zero() {
  local out
  out=$(run_android_probe failing 'exit 1' 'exit 1')
  printf '%s\n' "$out" > "$TMP_ROOT/android-failing.json"
  jq -e '[.android[] | select(.machine == "PC01")] | length == 0' "$TMP_ROOT/android-failing.json" >/dev/null \
    || fail "failing probes must not render a zero-device row"
  jq -e '[.unavailable[] | select(.source == "android:PC01") | .reason] | sort == ["adb devices failed (status 1)","emulator -list-avds failed (status 1)"]' \
    "$TMP_ROOT/android-failing.json" >/dev/null \
    || fail "probe failures must be stated: $(jq -c '.unavailable' "$TMP_ROOT/android-failing.json")"
  pass "failed adb and emulator probes render as stated reasons, never as zero devices"
}

test_android_empty_clean_reads_render_none() {
  local out
  out=$(run_android_probe empty \
    'case "$*" in devices) printf "List of devices attached\n\n" ;; *) exit 1 ;; esac' \
    '[ "$*" = "-list-avds" ] && exit 0; exit 1')
  printf '%s\n' "$out" > "$TMP_ROOT/android-empty.json"
  jq -e '[.android[] | select(.machine == "PC01") | .state] == ["none"]' "$TMP_ROOT/android-empty.json" >/dev/null \
    || fail "clean empty reads must render one none row: $(jq -c '.android' "$TMP_ROOT/android-empty.json")"
  pass "clean empty Android reads render a none row"
}

test_android_boot_completed_variants() {
  local out
  out=$(run_android_probe boot \
    'case "$*" in
  devices) printf "List of devices attached\nemulator-5554\tdevice\nemulator-5556\tdevice\nemulator-5558\tdevice\n" ;;
  "-s emulator-5554 emu avd name") printf "avd_a\nOK\n" ;;
  "-s emulator-5556 emu avd name") printf "avd_b\nOK\n" ;;
  "-s emulator-5558 emu avd name") printf "avd_c\nOK\n" ;;
  "-s emulator-5554 shell getprop sys.boot_completed") printf "0\r\n" ;;
  "-s emulator-5556 shell getprop sys.boot_completed") printf "\r\n" ;;
  *) exit 1 ;;
esac' \
    '[ "$*" = "-list-avds" ] && { printf "avd_a\navd_b\navd_c\n"; exit 0; }; exit 1')
  printf '%s\n' "$out" > "$TMP_ROOT/android-boot.json"
  jq -e '[.android[] | select(.machine == "PC01") | {(.avd): .boot_completed}] | add == {"avd_a":"0","avd_b":"unknown","avd_c":"failed"}' \
    "$TMP_ROOT/android-boot.json" >/dev/null \
    || fail "boot_completed variants: $(jq -c '.android' "$TMP_ROOT/android-boot.json")"
  pass "boot_completed renders 0, unknown for empty, and failed for an unanswered probe"
}

run_pc02_android_live() {  # <name> <ssh-mode: run|fail> <adb-body> <emulator-body> -> JSON
  local name=$1 mode=$2 rec home fb fake
  rec=$(make_home "pc02-android-$name" fresh); home=${rec%%|*}; fb=${rec#*|}
  write_fixtures fixture
  fake="$TMP_ROOT/pc02-android-fake-$name"
  mkdir -p "$fake"
  printf '#!/usr/bin/env bash\n%s\n' "$3" > "$fake/adb"
  printf '#!/usr/bin/env bash\n%s\n' "$4" > "$fake/emulator"
  cat > "$fake/ssh" <<EOF
#!/usr/bin/env bash
script=\$(cat)
case "\$script" in
  *android_probe_host*) [ "$mode" = run ] && { printf '%s\n' "\$script" | bash -s; exit \$?; } ;;
esac
exit 255
EOF
  chmod +x "$fake/adb" "$fake/emulator" "$fake/ssh"
  env PATH="$fake:$fb:$BASE_PATH" FM_HOME="$home" FM_RESOURCE_NOW="$NOW" FM_SSH_BIN="$fake/ssh" \
    FM_RESOURCE_ANDROID_FIXTURE= FM_RESOURCE_ANDROID_ROOTS= FM_RESOURCE_ANDROID_HOME_DIRS= \
    FM_RESOURCE_HOSTS_JSON="$TMP_ROOT/fixture/hosts-pc01.json" \
    FM_RESOURCE_ROLES_FILE="$TMP_ROOT/fixture/roles.json" \
    FM_RESOURCE_TESTING_FIXTURE="$TMP_ROOT/fixture/testing.json" \
    FM_RESOURCE_CONTEXT_FIXTURE="$TMP_ROOT/fixture/context.json" \
    FAKE_QUOTA_JSON="$TMP_ROOT/fixture/quota.json" \
    "$SNAP" --json 2>&1
}

test_android_physical_device_does_not_hide_stopped_avd() {
  local out
  out=$(run_android_probe physical \
    'case "$*" in devices) printf "List of devices attached\nR58M12ABC\tdevice\n" ;; *) exit 1 ;; esac' \
    '[ "$*" = "-list-avds" ] && { printf "pt_pixel8pro\n"; exit 0; }; exit 1')
  printf '%s\n' "$out" > "$TMP_ROOT/android-physical.json"
  jq -e '[.android[] | select(.machine == "PC01" and .avd == "pt_pixel8pro") | .state] == ["stopped"]' \
    "$TMP_ROOT/android-physical.json" >/dev/null \
    || fail "a physical adb device must not hide a stopped AVD: $(jq -c '.android' "$TMP_ROOT/android-physical.json")"
  jq -e '.android[] | select(.machine == "PC01" and .serial == "R58M12ABC")
    | .avd == "-" and .state == "device" and .detail == "adb device"' \
    "$TMP_ROOT/android-physical.json" >/dev/null \
    || fail "a physical adb serial must render as its own row: $(jq -c '.android' "$TMP_ROOT/android-physical.json")"
  jq -e '[.android[] | select(.machine == "PC01" and .state == "unknown")] | length == 0' \
    "$TMP_ROOT/android-physical.json" >/dev/null || fail "a physical device must never turn a listed AVD unknown"
  pass "a non-emulator adb serial leaves a stopped AVD rendered stopped"
}

test_android_probe_timeouts_are_stated() {
  local out
  out=$(run_android_probe timeout 'exit 124' 'exit 124')
  printf '%s\n' "$out" > "$TMP_ROOT/android-timeout.json"
  jq -e '[.android[] | select(.machine == "PC01")] | length == 0' "$TMP_ROOT/android-timeout.json" >/dev/null \
    || fail "timed-out probes must not render a zero-device row"
  jq -e '[.unavailable[] | select(.source == "android:PC01") | .reason] | sort == ["adb devices timed out","emulator -list-avds timed out"]' \
    "$TMP_ROOT/android-timeout.json" >/dev/null \
    || fail "timeouts must be stated: $(jq -c '.unavailable' "$TMP_ROOT/android-timeout.json")"
  pass "timed-out adb and emulator probes render as stated reasons"
}

test_pc02_android_live_read() {
  local out
  out=$(run_pc02_android_live ok run \
    'case "$*" in
  devices) printf "List of devices attached\nemulator-5554\tdevice\n" ;;
  "-s emulator-5554 emu avd name") printf "pt_pixel8pro\nOK\n" ;;
  "-s emulator-5554 shell getprop sys.boot_completed") printf "1\n" ;;
  *) exit 1 ;;
esac' \
    '[ "$*" = "-list-avds" ] && { printf "pt_pixel8pro\nother_avd\n"; exit 0; }; exit 1')
  printf '%s\n' "$out" > "$TMP_ROOT/pc02-android-ok.json"
  jq -e '[.android[] | select(.machine == "PC02") | {(.avd): [.state, .boot_completed]}] | add == {"pt_pixel8pro":["device","1"],"other_avd":["stopped","-"]}' \
    "$TMP_ROOT/pc02-android-ok.json" >/dev/null \
    || fail "PC02 live Android rows: $(jq -c '.android' "$TMP_ROOT/pc02-android-ok.json")"
  pass "the shipped PC02 Android probe returns rows over the ssh boundary"
}

test_pc02_android_live_failure_is_stated() {
  local out
  out=$(run_pc02_android_live down fail 'exit 1' 'exit 1')
  printf '%s\n' "$out" > "$TMP_ROOT/pc02-android-down.json"
  jq -e '[.android[] | select(.machine == "PC02")] | length == 0' "$TMP_ROOT/pc02-android-down.json" >/dev/null \
    || fail "a failed PC02 Android read must not render rows"
  jq -e '[.unavailable[] | select(.reason | test("remote Android read failed"))] | length == 1' \
    "$TMP_ROOT/pc02-android-down.json" >/dev/null \
    || fail "PC02 Android failure must be stated: $(jq -c '.unavailable' "$TMP_ROOT/pc02-android-down.json")"
  pass "a failed PC02 Android read is an unavailable row, never zero devices"
}

run_android_discovery() {  # <name> <env assignments...> -> JSON
  local name=$1
  shift
  local rec home fb
  rec=$(make_home "android-disc-$name" fresh); home=${rec%%|*}; fb=${rec#*|}
  write_fixtures fixture
  env PATH="$fb:$BASE_PATH" FM_HOME="$home" FM_RESOURCE_NOW="$NOW" \
    FM_RESOURCE_ANDROID_FIXTURE= \
    FM_RESOURCE_HOSTS_JSON="$TMP_ROOT/fixture/hosts-pc01.json" \
    FM_RESOURCE_REMOTE_FIXTURE="$TMP_ROOT/fixture/remote.json" \
    FM_RESOURCE_ROLES_FILE="$TMP_ROOT/fixture/roles.json" \
    FM_RESOURCE_TESTING_FIXTURE="$TMP_ROOT/fixture/testing.json" \
    FM_RESOURCE_CONTEXT_FIXTURE="$TMP_ROOT/fixture/context.json" \
    FAKE_QUOTA_JSON="$TMP_ROOT/fixture/quota.json" \
    "$@" "$SNAP" --json 2>&1
}

test_android_discovery_reads_environment_json_and_port() {
  local root fake marker out
  root="$TMP_ROOT/android-root-pc02/Android"
  fake="$TMP_ROOT/android-root-pc02/fake"
  marker="$TMP_ROOT/android-root-pc02/port-5041-seen"
  mkdir -p "$root/Sdk/platform-tools" "$root/Sdk/emulator" "$root/avd/pt_pixel8pro.avd" "$fake"
  cat > "$root/environment.json" <<EOF
{
  "ANDROID_SDK_ROOT": "$root/Sdk",
  "ANDROID_AVD_HOME": "$root/avd",
  "ANDROID_ADB_SERVER_PORT": "5041"
}
EOF
  cat > "$root/Sdk/platform-tools/adb" <<EOF
#!/usr/bin/env bash
case "\$*" in
  devices) printf 'List of devices attached\n\n' ;;
  "-P 5041 devices") : > "$marker"; printf 'List of devices attached\n\n' ;;
  *) exit 1 ;;
esac
EOF
  cat > "$root/Sdk/emulator/emulator" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "-list-avds" ] || exit 1
[ -n "${ANDROID_AVD_HOME:-}" ] && printf 'pt_pixel8pro
'
exit 0
EOF
  chmod +x "$root/Sdk/platform-tools/adb" "$root/Sdk/emulator/emulator"
  out=$(run_android_discovery env-json     FM_RESOURCE_ANDROID_ROOTS="$root" FM_RESOURCE_ANDROID_HOME_DIRS=)
  printf '%s\n' "$out" > "$TMP_ROOT/android-discovery-env.json"
  [ -e "$marker" ] || fail "adb must be read on the environment.json declared port 5041"
  jq -e '[.android[] | select(.machine == "PC01" and .avd == "pt_pixel8pro") | .state] == ["stopped"]'     "$TMP_ROOT/android-discovery-env.json" >/dev/null     || fail "an AVD home from environment.json must render stopped: $(jq -c '.android' "$TMP_ROOT/android-discovery-env.json")"
  jq -e '[.unavailable[] | select(.source | startswith("android"))] | length == 0'     "$TMP_ROOT/android-discovery-env.json" >/dev/null     || fail "a readable environment.json root must not leave unavailable: $(jq -c '.unavailable' "$TMP_ROOT/android-discovery-env.json")"
  pass "an environment.json AVD home and declared adb port 5041 are discovered and read"
}

test_android_discovery_reads_wsl_only_avd_home() {
  local avd fake out
  avd="$TMP_ROOT/android-wsl-home/.android/avd"
  fake="$TMP_ROOT/android-wsl-home/fake"
  mkdir -p "$avd/foo.avd" "$fake"
  printf 'avd.ini.encoding=UTF-8\npath=%s/foo.avd\n' "$avd" > "$avd/foo.ini"
  cat > "$fake/adb" <<'EOF'
#!/usr/bin/env bash
case "$*" in devices) printf 'List of devices attached\n\n' ;; *) exit 1 ;; esac
EOF
  chmod +x "$fake/adb"
  out=$(run_android_discovery wsl-home     FM_RESOURCE_ANDROID_ROOTS= FM_RESOURCE_ANDROID_HOME_DIRS="$avd"     FM_RESOURCE_ADB="$fake/adb" FM_RESOURCE_EMULATOR=)
  printf '%s\n' "$out" > "$TMP_ROOT/android-discovery-wsl.json"
  jq -e '[.android[] | select(.machine == "PC01" and .avd == "foo") | .state] == ["stopped"]'     "$TMP_ROOT/android-discovery-wsl.json" >/dev/null     || fail "a WSL-only AVD home must render its AVD as stopped: $(jq -c '.android' "$TMP_ROOT/android-discovery-wsl.json")"
  pass "a WSL-only ~/.android/avd AVD is discovered without an emulator binary"
}

test_android_discovery_reports_unreadable_root() {
  local root fake out
  root="$TMP_ROOT/android-unreadable/Android"
  fake="$TMP_ROOT/android-unreadable/fake"
  mkdir -p "$root/environment.json" "$fake"
  cat > "$fake/adb" <<'EOF'
#!/usr/bin/env bash
case "$*" in devices) printf 'List of devices attached

' ;; *) exit 1 ;; esac
EOF
  cat > "$fake/emulator" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "-list-avds" ] && exit 0
exit 1
EOF
  chmod +x "$fake/adb" "$fake/emulator"
  out=$(run_android_discovery unreadable     FM_RESOURCE_ANDROID_ROOTS="$root" FM_RESOURCE_ANDROID_HOME_DIRS=     FM_RESOURCE_ADB="$fake/adb" FM_RESOURCE_EMULATOR="$fake/emulator")
  printf '%s\n' "$out" > "$TMP_ROOT/android-discovery-unreadable.json"
  jq -e '[.android[] | select(.machine == "PC01" and .state == "none")] | length == 0'     "$TMP_ROOT/android-discovery-unreadable.json" >/dev/null     || fail "an unreadable known root must never render none: $(jq -c '.android' "$TMP_ROOT/android-discovery-unreadable.json")"
  jq -e '[.unavailable[] | select(.source == "android:PC01") | .reason] | any(test("unreadable"))'     "$TMP_ROOT/android-discovery-unreadable.json" >/dev/null     || fail "an unreadable known root must be stated: $(jq -c '.unavailable' "$TMP_ROOT/android-discovery-unreadable.json")"
  pass "an unreadable known root is reported with its reason, never as none"
}

test_android_missing_tools_is_stated_not_zero() {
  local rec home fb out rc
  rec=$(make_home android-missing fresh); home=${rec%%|*}; fb=${rec#*|}
  write_fixtures fixture
  out=$(env PATH="$fb:$BASE_PATH" FM_HOME="$home" FM_RESOURCE_NOW="$NOW" \
    FM_RESOURCE_ANDROID_FIXTURE= FM_RESOURCE_ADB= FM_RESOURCE_EMULATOR= \
    FM_RESOURCE_HOSTS_JSON="$TMP_ROOT/fixture/hosts-pc01.json" \
    FM_RESOURCE_REMOTE_FIXTURE="$TMP_ROOT/fixture/remote.json" \
    FM_RESOURCE_ROLES_FILE="$TMP_ROOT/fixture/roles.json" \
    FM_RESOURCE_TESTING_FIXTURE="$TMP_ROOT/fixture/testing.json" \
    FM_RESOURCE_CONTEXT_FIXTURE="$TMP_ROOT/fixture/context.json" \
    FAKE_QUOTA_JSON="$TMP_ROOT/fixture/quota.json" \
    "$SNAP" --json 2>&1); rc=$?
  expect_code 0 "$rc" "missing Android tools render"
  printf '%s\n' "$out" > "$TMP_ROOT/android-missing.json"
  jq -e '[.android[] | select(.machine == "PC01")] | length == 0' \
    "$TMP_ROOT/android-missing.json" >/dev/null || fail "missing tools must not render a zero-device row"
  jq -e '[.unavailable[] | select(.source == "android:PC01") | .reason] | sort == ["adb not found","emulator not found"]' \
    "$TMP_ROOT/android-missing.json" >/dev/null || fail "missing tools must be stated: $(jq -c '.unavailable' "$TMP_ROOT/android-missing.json")"
  pass "missing adb and emulator render as stated reasons, never as zero devices"
}

test_live_reconciliation() {
  fm_live_gate opt-in FM_FLEET_LIVE ssh quota-axi herdr glab systemctl
  local live_home=${FM_RESOURCE_LIVE_HOME:-${FM_HOME:-$HOME/firstmate}}
  [ -f "$live_home/data/secondmates.md" ] || fail "live home has no secondmates registry: $live_home"
  local model="$TMP_ROOT/live.json" gen
  "$SNAP" --home "$live_home" --json > "$model" 2>/dev/null || fail "live snapshot failed"
  gen=$(jq -r '.generated' "$model")

  # Worker ids equal the union of both homes' metadata ids.
  local local_ids remote_ids expected actual
  local_ids=$(find "$live_home/state" -maxdepth 1 -name '*.meta' -printf '%f\n' 2>/dev/null \
    | sed 's/\.meta$//' | sort | paste -sd, -)
  local remote_line host remote_home
  remote_line=$(grep -m1 '^- .*(host:' "$live_home/data/secondmates.md" 2>/dev/null)
  host=$(printf '%s' "$remote_line" | sed -n 's/.*(host: \([^;)]*\).*/\1/p')
  remote_home=$(printf '%s' "$remote_line" | sed -n 's/.*; home: \([^;)]*\).*/\1/p')
  remote_ids=''
  if [ -n "$host" ] && [ -n "$remote_home" ]; then
    # shellcheck disable=SC2029 # the validated remote path is intentionally expanded here
    remote_ids=$(ssh "$host" "find '$remote_home/state' -maxdepth 1 -name '*.meta' -printf '%f\\n' 2>/dev/null | sed 's/\\.meta$//' | sort" 2>/dev/null | paste -sd, -)
  fi
  expected=$(printf '%s\n%s\n' "$local_ids" "$remote_ids" | tr ',' '\n' | awk 'NF && !seen[$0]++' | sort | paste -sd, -)
  actual=$(jq -r '[.workers[].task] | unique | sort | join(",")' "$model")
  [ "$expected" = "$actual" ] || fail "worker ids: expected $expected, actual $actual (read $gen)"

  # Each Claude quota percentage equals the raw reader for the same account path.
  local profiles raw_quota
  profiles=$(sed -n 's/^orchestrator=//p;s/^workers=//p' "$live_home/config/claude-roles" 2>/dev/null | paste -sd: -)
  raw_quota=$(QUOTA_AXI_CLAUDE_PROFILES="$profiles" quota-axi --full --json 2>/dev/null)
  printf '%s' "$raw_quota" | jq -e '.providers | type == "array"' >/dev/null || fail "raw quota read failed"
  local path window expected_pct actual_pct actual_state
  while IFS=$'\t' read -r path window expected_pct; do
    [ -n "$path" ] || continue
    actual_pct=$(jq -r --arg p "$path" --arg w "$window" \
      '[.quota[] | select(.account == $p and .window == $w) | .pct_remaining][0] // "missing"' "$model")
    actual_state=$(jq -r --arg p "$path" --arg w "$window" \
      '[.quota[] | select(.account == $p and .window == $w) | .state][0] // "missing"' "$model")
    # The snapshot bounds its read with --max-age, so a reused reading is
    # labelled stale and may sit one percentage point behind the fresh read;
    # only fresh rows must match the raw figure exactly.
    if [ "$actual_state" = stale ]; then
      [ "$actual_pct" != missing ] || fail "stale quota row $path $window has no figure (read $gen)"
    else
      [ "$actual_pct" = "$expected_pct" ] || fail "quota $path $window: expected $expected_pct, actual $actual_pct (read $gen)"
    fi
  done < <(printf '%s' "$raw_quota" | jq -r '.providers[] | select(.provider=="claude") | .accountLocator.path as $p | .windows[] | [$p,.id,(.percentRemaining|tostring)] | @tsv')

  # PC01 drives equal df -Pk.
  local expected_free actual_free
  expected_free=$(df -Pk / 2>/dev/null | awk 'NR == 2 { printf "%.1f", $4 / 1048576 }')
  actual_free=$(jq -r '[.drives[] | select(.machine=="PC01" and .mount=="\/") | .free_gb][0] // "missing"' "$model")
  [ "$actual_free" = "$expected_free" ] || fail "PC01 / free_gb: expected $expected_free, actual $actual_free (read $gen)"

  # PC01 panes equal herdr's own count.
  expected=$(herdr pane list 2>/dev/null | jq -r '.result.panes | length')
  actual=$(jq -r '[.panes[] | select(.machine=="PC01")] | length' "$model")
  [ "$actual" = "$expected" ] || fail "PC01 pane count: expected $expected, actual $actual (read $gen)"

  # Orchestrator role equals fm-claude-roles.sh verify.
  local verify_acct
  verify_acct=$(bash "$live_home/data/account-roles/fm-claude-roles.sh" verify 2>/dev/null \
    | sed -n 's/^ok: *.*claude-orchestrator-account = //p' | head -1)
  if [ -n "$verify_acct" ]; then
    actual=$(jq -r '[.roles[] | select(.role=="orchestrator") | .account][0] // "missing"' "$model")
    [ "$actual" = "$verify_acct" ] || fail "orchestrator account: expected $verify_acct, actual $actual (read $gen)"
  fi

  # PC02 offload slots and personal-use switch equal their raw files.
  if [ -n "$host" ]; then
    local raw_slots raw_personal
    raw_slots=$(ssh "$host" 'slots=2; sf="$HOME/.config/firstmate/pc02-offload-slots"; [ -f "$sf" ] && slots=$(head -1 "$sf"); printf "0/%s" "$slots"' 2>/dev/null)
    actual=$(jq -r '[.testing[] | select(.item=="pc02-offload-slots") | .state][0] // "missing"' "$model")
    # The used count is a live sample and may move between the two reads; the
    # configured slot total and the row's shape must still agree.
    if [ -n "$raw_slots" ]; then
      [ "$actual" != missing ] || fail "PC02 slots row missing (read $gen)"
      [ "${actual##*/}" = "${raw_slots##*/}" ] || fail "PC02 slot total: expected ${raw_slots##*/}, actual ${actual##*/} (read $gen)"
      [ "${actual%%/*}" -le "${actual##*/}" ] 2>/dev/null || fail "PC02 used slots exceed the total: $actual (read $gen)"
    fi
    raw_personal=$(ssh "$host" 'if [ -e "$HOME/.fm-pc02-personal-use" ]; then echo on; else echo off; fi' 2>/dev/null)
    actual=$(jq -r '[.testing[] | select(.item=="pc02-personal-use") | .state][0] // "missing"' "$model")
    [ -z "$raw_personal" ] || [ "$actual" = "$raw_personal" ] || fail "PC02 personal use: expected $raw_personal, actual $actual (read $gen)"
  fi

  # GitLab minutes equal the namespace quota read.
  local gl_used='' gl_ns
  gl_ns=$(awk -F= '$1 == "gitlab_namespace" { print $2; exit }' "$live_home/config/resource-snapshot" 2>/dev/null)
  gl_ns=${FM_RESOURCE_GITLAB_NAMESPACE:-$gl_ns}
  [ -z "$gl_ns" ] || gl_used=$(glab api "namespaces/$gl_ns" 2>/dev/null | jq -r '.ci_minutes_usage.total_minutes_used // empty')
  if [ -n "$gl_used" ]; then
    actual=$(jq -r '[.compute[] | select(.rung=="gitlab") | .used][0] // "missing"' "$model")
    [ "$actual" = "${gl_used} min MTD" ] || fail "gitlab minutes: expected ${gl_used} min MTD, actual $actual (read $gen)"
  fi

  # Forgejo PC01 state equals the user unit.
  expected=$(systemctl --user is-active forgejo.service 2>/dev/null | head -1)
  actual=$(jq -r '[.testing[] | select(.item=="forgejo-pc01") | .state][0] // "missing"' "$model")
  [ "$actual" = "$expected" ] || fail "forgejo state: expected $expected, actual $actual (read $gen)"

  pass "the live snapshot matches the raw readers for workers, quota, drives, panes, roles, GitLab, and Forgejo"
}

test_opencode_worker_gets_a_context_band() {
  setup_fixture
  local store models out
  store="$TMP_ROOT/fixture/opencode-store"
  models="$TMP_ROOT/fixture/opencode-models.json"
  mkdir -p "$store"
  printf '%s\n' '{"opencode-go":{"models":{"deepseek-v4.1-flash":{"limit":{"context":1000000}}}}}' > "$models"
  python3 - "$store/opencode.db" "$TMP_ROOT/fixture/nowhere" <<'PY'
import json, sqlite3, sys
db, wt = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
con.executescript(
    "CREATE TABLE session (id text PRIMARY KEY, directory text, parent_id text,"
    " model text, time_updated integer);"
    "CREATE TABLE message (id text PRIMARY KEY, session_id text,"
    " time_created integer, data text);"
)
con.execute("INSERT INTO session VALUES (?,?,?,?,?)", ("ses_beta", wt, None, None, 1795123200000))
con.execute("INSERT INTO message VALUES (?,?,?,?)", ("m1", "ses_beta", 1, json.dumps(
    {"role": "assistant", "providerID": "opencode-go", "modelID": "deepseek-v4.1-flash",
     "tokens": {"input": 1000, "output": 50, "cache": {"read": 159000, "write": 0}}})))
con.commit()
PY
  out=$(env PATH="$FB:$BASE_PATH" FM_HOME="$HOME_DIR" FM_RESOURCE_NOW="$NOW" \
    FM_RESOURCE_HOSTS_JSON="$TMP_ROOT/fixture/hosts.json" \
    FM_RESOURCE_HERDR_JSON_PC01="$TMP_ROOT/fixture/herdr-pc01.json" \
    FM_RESOURCE_ROLES_FILE="$TMP_ROOT/fixture/roles.json" \
    FM_RESOURCE_TESTING_FIXTURE="$TMP_ROOT/fixture/testing.json" \
    FM_RESOURCE_SKIP_REMOTE=1 \
    FM_OPENCODE_STORE="$store" FM_OPENCODE_MODELS="$models" \
    FAKE_QUOTA_JSON="$TMP_ROOT/fixture/quota.json" \
    "$SNAP" --json 2>&1)
  printf '%s\n' "$out" > "$TMP_ROOT/opencode-context.json"
  jq -e '.workers[] | select(.task == "beta") | .ctx_band == "warn(16.0%)"' \
    "$TMP_ROOT/opencode-context.json" >/dev/null \
    || fail "opencode worker must get its context band: $(jq -c '.workers' "$TMP_ROOT/opencode-context.json")"
  pass "an opencode worker's context band comes from its session store"
}

run_compute_snapshot() {  # <home> <fakebin> [env assignments...]
  local home=$1 fb=$2
  shift 2
  env PATH="$fb:$BASE_PATH" FM_HOME="$home" FM_RESOURCE_NOW="$NOW" \
    FM_RESOURCE_HOSTS_JSON="$TMP_ROOT/fixture/hosts.json" \
    FM_RESOURCE_HERDR_JSON_PC01="$TMP_ROOT/fixture/herdr-pc01.json" \
    FM_RESOURCE_HERDR_JSON_PC02="$TMP_ROOT/fixture/herdr-pc02.json" \
    FM_RESOURCE_ROLES_FILE="$TMP_ROOT/fixture/roles.json" \
    FM_RESOURCE_SKIP_REMOTE=1 \
    FAKE_QUOTA_JSON="$TMP_ROOT/fixture/quota.json" \
    "$@" "$SNAP" --json
}

compute_home() {  # <base> -> "<home>|<fakebin>"
  local base=$1
  mkdir -p "$base/home/state" "$base/home/data" "$base/home/config" "$base/bin"
  printf '%s|%s\n' "$base/home" "$base/bin"
}

test_compute_discovers_github_and_gitlab_from_live_state() {
  setup_fixture
  local base rec home fb code out
  base="$TMP_ROOT/compute-live"
  rec=$(compute_home "$base"); home=${rec%%|*}; fb=${rec#*|}
  code="$base/code"
  mkdir -p "$code"
  git -C "$code" init -q
  git -C "$code" remote add origin https://github.com/acme-org/hello.git
  cat > "$fb/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  'api user --jq .login') printf 'octocat\n' ;;
  *billing/usage*) printf '%s\n' '{"usageItems":[{"product":"actions","sku":"Actions Linux","quantity":42}]}' ;;
  */repos/acme-org/hello/actions/runs*) printf '%s\n' '{"total_count":7}' ;;
  *) exit 1 ;;
esac
STUB
  cat > "$fb/glab" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  'api user') printf '%s\n' '{"username":"acme"}' ;;
  'api namespaces/acme') printf '%s\n' '{"ci_minutes_usage":{"total_minutes_used":12},"plan":"free"}' ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$fb/gh" "$fb/glab"
  printf 'storage_gb_hours\t12\nallowance_gb_hours\t360\npercent\t3\nas_of\t2026-11-20\n' \
    > "$home/state/.actions-storage-check"
  out=$(run_compute_snapshot "$home" "$fb" FM_ROOT_OVERRIDE="$code")
  printf '%s\n' "$out" > "$base/out.json"
  jq -e 'any(.compute[]; .rung=="github-actions" and .account=="octocat" and .used=="42 min MTD")' \
    "$base/out.json" >/dev/null || fail "github identity/repo discovery must read billing: $(jq -c '.compute' "$base/out.json")"
  jq -e 'any(.compute[]; .rung=="github-runs" and .account=="octocat" and .runs=="7 runs/24h")' \
    "$base/out.json" >/dev/null || fail "github run discovery must use the code root origin repo: $(jq -c '.compute' "$base/out.json")"
  jq -e 'any(.compute[]; .rung=="gitlab" and .account=="acme" and .used=="12 min MTD" and .status=="ok")' \
    "$base/out.json" >/dev/null || fail "gitlab namespace discovery must read the glab user: $(jq -c '.compute' "$base/out.json")"
  jq -e '[.unavailable[] | select(.source=="github" or .source=="gitlab")] | length == 0' \
    "$base/out.json" >/dev/null || fail "a discovered provider must not render a not-configured row: $(jq -c '.unavailable' "$base/out.json")"
  pass "github and gitlab identities come from the live gh/glab and the code root origin without a config file"
}

test_compute_discovers_forgejo_from_local_instance() {
  setup_fixture
  local base rec home fb repo ini creds out out2
  base="$TMP_ROOT/compute-forgejo"
  rec=$(compute_home "$base"); home=${rec%%|*}; fb=${rec#*|}
  repo="$base/forgejo-repositories"; ini="$base/app.ini"; creds="$base/forgejo-credentials"
  mkdir -p "$repo/fmadmin/groundwork.git"
  cat > "$ini" <<EOF
[server]
ROOT_URL = http://127.0.0.1:3000/
[repository]
ROOT = $repo
EOF
  printf 'Username: fmadmin\nPassword: secret\n' > "$creds"
  cat > "$fb/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in *is-active*) exit 0 ;; esac
exit 1
STUB
  cat > "$fb/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"/api/v1/version"*) printf '200' ;;
  *"/admin/actions/runners"*) printf '%s\n' '[{"name":"forgejo-pc02","status":"online"}]' ;;
  *"/actions/runs?limit=50"*) printf '%s\n' '{"workflow_runs":[{"status":"waiting"},{"status":"running"},{"status":"completed"}]}' ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$fb/systemctl" "$fb/curl"
  out=$(run_compute_snapshot "$home" "$fb" \
    FM_RESOURCE_FORGEJO_INI="$ini" FM_RESOURCE_FORGEJO_REPO_ROOT="$repo" \
    FM_RESOURCE_FORGEJO_CREDENTIALS="$creds")
  printf '%s\n' "$out" > "$base/out.json"
  jq -e 'any(.compute[]; .rung=="forgejo" and .account=="fmadmin" and .status=="active" and .runs=="2 queued")' \
    "$base/out.json" >/dev/null || fail "forgejo discovery must read the local instance and its one repo: $(jq -c '.compute' "$base/out.json")"
  jq -e 'any(.testing[]; .item=="forgejo-pc01" and .state=="active")' "$base/out.json" >/dev/null \
    || fail "the local Forgejo unit must render without config: $(jq -c '.testing' "$base/out.json")"
  jq -e 'any(.testing[]; .item=="forgejo-runners" and .state=="forgejo-pc02:online")' "$base/out.json" >/dev/null \
    || fail "the registered runner must render from the admin read: $(jq -c '.testing' "$base/out.json")"
  jq -e 'any(.testing[]; .item=="forgejo-queued" and .state=="2")' "$base/out.json" >/dev/null \
    || fail "queued forgejo runs must render: $(jq -c '.testing' "$base/out.json")"
  jq -e '[.unavailable[] | select(.source | startswith("forgejo"))] | length == 0' "$base/out.json" >/dev/null \
    || fail "a fully discovered forgejo must not leave unavailable rows: $(jq -c '.unavailable' "$base/out.json")"

  out2=$(run_compute_snapshot "$home" "$fb" \
    FM_RESOURCE_FORGEJO_INI="$ini" FM_RESOURCE_FORGEJO_REPO_ROOT="$repo" \
    FM_RESOURCE_FORGEJO_CREDENTIALS=)
  printf '%s\n' "$out2" > "$base/out-no-creds.json"
  jq -e 'any(.compute[]; .rung=="forgejo" and .account=="fmadmin" and .status=="active")' \
    "$base/out-no-creds.json" >/dev/null || fail "forgejo must render the fast facts without credentials: $(jq -c '.compute' "$base/out-no-creds.json")"
  jq -e '[.unavailable[] | select(.source=="forgejo:credentials")] | length == 1' \
    "$base/out-no-creds.json" >/dev/null || fail "a missing credential path must be named: $(jq -c '.unavailable' "$base/out-no-creds.json")"
  pass "forgejo url, account and repo come from the local instance without a config file"
}

test_compute_without_identity_says_why() {
  setup_fixture
  local base rec home fb out
  base="$TMP_ROOT/compute-none"
  rec=$(compute_home "$base"); home=${rec%%|*}; fb=${rec#*|}
  mkdir -p "$base/empty-root"
  cat > "$fb/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  cat > "$fb/glab" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$fb/gh" "$fb/glab"
  out=$(run_compute_snapshot "$home" "$fb" \
    FM_ROOT_OVERRIDE="$base/no-such-code-root" \
    FM_RESOURCE_FORGEJO_INI="$base/no-such-app.ini" \
    FM_RESOURCE_FORGEJO_REPO_ROOT="$base/empty-root")
  printf '%s\n' "$out" > "$base/out.json"
  [ "$(jq -r '.compute | length' "$base/out.json")" = 0 ] \
    || fail "no discovered identity must render no compute rows: $(jq -c '.compute' "$base/out.json")"
  jq -e '[.unavailable[] | select(.source=="github" and .reason=="not configured")] | length == 1' \
    "$base/out.json" >/dev/null || fail "an unidentifiable gh must stay not configured: $(jq -c '.unavailable' "$base/out.json")"
  jq -e '[.unavailable[] | select(.source=="gitlab" and .reason=="not configured")] | length == 1' \
    "$base/out.json" >/dev/null || fail "an unidentifiable glab must stay not configured: $(jq -c '.unavailable' "$base/out.json")"
  jq -e '[.unavailable[] | select(.source=="forgejo" and .reason=="not configured")] | length == 1' \
    "$base/out.json" >/dev/null || fail "an undiscoverable forgejo must stay not configured: $(jq -c '.unavailable' "$base/out.json")"
  pass "an undiscoverable provider keeps an honest not-configured row"
}

write_pc01_snapshot() {  # <path> <status> <finished_at> [error]
  local path=$1 status=$2 finished=$3 error=${4:-} sda nvme
  sda=$(cat <<'SDA'
=== START OF READ SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED

Device Model:     ST8000DM004-2CX188
Serial Number:    ZCT2KA1Y
  5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       -       0
  9 Power_On_Hours          0x0032   084   084   000    Old_age   Always       -       14711h+54m+35.898s
194 Temperature_Celsius     0x0022   031   059   000    Old_age   Always       -       31 (0 15 0 0 0)
197 Current_Pending_Sector  0x0012   100   100   000    Old_age   Always       -       0
198 Offline_Uncorrectable   0x0010   100   100   000    Old_age   Offline      -       0
SDA
)
  nvme=$(cat <<'NVME'
=== START OF SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED

Model Number:                       Force MP510
Temperature:                        45 Celsius
Percentage Used:                    13%
Power On Hours:                     14,682
Media and Data Integrity Errors:    0
NVME
)
  jq -n --arg status "$status" --arg finished "$finished" --arg error "$error" \
    --arg sda "$sda" --arg nvme "$nvme" '
    {
      job: "drive-health",
      status: $status,
      error: (if $error == "" then null else $error end),
      started_at: $finished,
      finished_at: $finished,
      disks: [
        {Number: 0, FriendlyName: "ST8000DM004-2CX188", HealthStatus: "Healthy"},
        {Number: 2, FriendlyName: "Force MP510", HealthStatus: "Healthy"}
      ],
      reliability: [
        {disk: "ST8000DM004-2CX188", temperature_c: 31, power_on_hours: 14711},
        {disk: "Force MP510", temperature_c: 45, power_on_hours: 14682, wear: 13}
      ],
      smart: {
        available: true,
        devices: [
          {device: "/dev/pd0", friendly_name: "ST8000DM004-2CX188", exit_code: 0, health: "PASSED", output: $sda},
          {device: "/dev/pd2", friendly_name: "Force MP510", exit_code: 0, health: "PASSED", output: $nvme}
        ]
      }
    }' > "$path"
}

run_pc01_drive_health() {  # <snapshot-file> -> JSON
  local file=$1
  env PATH="$FB:$BASE_PATH" FM_HOME="$HOME_DIR" FM_RESOURCE_NOW="$NOW" \
    FM_RESOURCE_DRIVE_HEALTH_FIXTURE= \
    FM_RESOURCE_HOSTS_JSON="$TMP_ROOT/fixture/hosts-pc01.json" \
    FM_RESOURCE_PC01_DRIVE_HEALTH_FILE="$file" \
    FM_RESOURCE_REMOTE_FIXTURE="$TMP_ROOT/fixture/down.json" \
    FM_RESOURCE_HERDR_JSON_PC01="$TMP_ROOT/fixture/herdr-pc01.json" \
    FM_RESOURCE_ROLES_FILE="$TMP_ROOT/fixture/roles.json" \
    FM_RESOURCE_TESTING_FIXTURE="$TMP_ROOT/fixture/testing.json" \
    FM_RESOURCE_CONTEXT_FIXTURE="$TMP_ROOT/fixture/context.json" \
    FM_RESOURCE_ANDROID_FIXTURE="$TMP_ROOT/fixture/android.json" \
    FAKE_QUOTA_JSON="$TMP_ROOT/fixture/quota.json" \
    "$SNAP" --json 2>&1
}

test_drive_health_pc01_snapshot_reads_smart() {
  setup_fixture
  local f out
  f="$TMP_ROOT/pc01-drive-health.json"
  write_pc01_snapshot "$f" ok 2026-11-19T20:50:00Z
  out=$(run_pc01_drive_health "$f")
  printf '%s\n' "$out" > "$TMP_ROOT/dh-pc01-ok.json"
  jq -e '[.drive_health[] | select(.machine == "PC01")] | length == 2' \
    "$TMP_ROOT/dh-pc01-ok.json" >/dev/null \
    || fail "PC01 snapshot must render one row per smart device: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc01-ok.json")"
  jq -e '.drive_health[] | select(.disk == "/dev/pd0")
    | .model == "ST8000DM004-2CX188" and .smart == "PASSED"
      and .reallocated == "0" and .pending == "0" and .uncorrectable == "0"
      and .temp_c == "31" and .power_on_hours == "14711"
      and .reason == "-" and .read_utc == "2026-11-19T20:50:00Z"' \
    "$TMP_ROOT/dh-pc01-ok.json" >/dev/null \
    || fail "PC01 ATA attributes: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc01-ok.json")"
  jq -e '.drive_health[] | select(.disk == "/dev/pd2")
    | .model == "Force MP510" and .smart == "PASSED"
      and .nvme_used_pct == "13" and .media_errors == "0"
      and .temp_c == "45" and .power_on_hours == "14682"' \
    "$TMP_ROOT/dh-pc01-ok.json" >/dev/null \
    || fail "PC01 NVMe percentage used and media errors: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc01-ok.json")"
  pass "a PC01 snapshot renders per-disk SMART counts, NVMe usage, and its own read time"
}

test_drive_health_pc01_stale_missing_failed_labelled() {
  setup_fixture
  local f out
  f="$TMP_ROOT/pc01-drive-health-stale.json"
  write_pc01_snapshot "$f" ok 2026-11-01T00:00:00Z
  out=$(run_pc01_drive_health "$f")
  printf '%s\n' "$out" > "$TMP_ROOT/dh-pc01-stale.json"
  jq -e '.drive_health[] | .machine == "PC01" and .smart == "stale"
    and .reallocated == "-" and .pending == "-" and .uncorrectable == "-"
    and (.reason | test("old")) and .read_utc == "2026-11-01T00:00:00Z"' \
    "$TMP_ROOT/dh-pc01-stale.json" >/dev/null \
    || fail "a stale snapshot must be labelled stale, not healthy: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc01-stale.json")"

  out=$(run_pc01_drive_health "$TMP_ROOT/pc01-drive-health-absent.json")
  printf '%s\n' "$out" > "$TMP_ROOT/dh-pc01-missing.json"
  jq -e '.drive_health[] | .machine == "PC01" and .smart == "not-set-up"
    and .reallocated == "-" and (.reason | test("not set up"))' \
    "$TMP_ROOT/dh-pc01-missing.json" >/dev/null \
    || fail "a missing snapshot must say not set up: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc01-missing.json")"

  f="$TMP_ROOT/pc01-drive-health-failed.json"
  write_pc01_snapshot "$f" error 2026-11-19T20:50:00Z "Get-Disk failed"
  out=$(run_pc01_drive_health "$f")
  printf '%s\n' "$out" > "$TMP_ROOT/dh-pc01-failed.json"
  jq -e '.drive_health[] | .machine == "PC01" and .smart == "failed"
    and .reallocated == "-" and (.reason | test("status is error"))
    and (.reason | test("Get-Disk failed"))' \
    "$TMP_ROOT/dh-pc01-failed.json" >/dev/null \
    || fail "a failed snapshot must name its error: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc01-failed.json")"
  pass "stale, missing, and failed PC01 snapshots are labelled with reason and read time, never zero or healthy"
}

run_pc02_drive_health() {  # <name> <smartctl-path> [ssh-mode: run|down] -> JSON
  local name=$1 smartctl_path=$2 mode=${3:-run} rec home fb fake
  rec=$(make_home "pc02-dh-$name" fresh); home=${rec%%|*}; fb=${rec#*|}
  write_fixtures fixture
  fake="$TMP_ROOT/pc02-dh-$name"
  mkdir -p "$fake"
  cat > "$fake/sda.txt" <<'SDA'
=== START OF READ SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED

Device Model:     ST8000DM004-2CX188
  5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       -       0
  9 Power_On_Hours          0x0032   084   084   000    Old_age   Always       -       14711h+54m+35.898s
194 Temperature_Celsius     0x0022   031   059   000    Old_age   Always       -       31 (0 15 0 0 0)
197 Current_Pending_Sector  0x0012   100   100   000    Old_age   Always       -       0
198 Offline_Uncorrectable   0x0010   100   100   000    Old_age   Offline      -       0
SDA
  cat > "$fake/nvme.txt" <<'NVME'
=== START OF SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED

Model Number:                       Force MP510
Temperature:                        45 Celsius
Percentage Used:                    13%
Power On Hours:                     14,682
Media and Data Integrity Errors:    0
NVME
  cat > "$fake/ssh" <<SSH
#!/usr/bin/env bash
script=\$(cat)
case "\$script" in
  *fm-drive-health*) [ "$mode" = run ] && { printf '%s\n' "\$script" | bash; exit \$?; } ;;
esac
exit 255
SSH
  chmod +x "$fake/ssh"
  env PATH="$fake:$fb:$BASE_PATH" FM_HOME="$home" FM_RESOURCE_NOW="$NOW" \
    FM_SSH_BIN="$fake/ssh" FM_RESOURCE_PC02_SMARTCTL="$smartctl_path" \
    FM_RESOURCE_DRIVE_HEALTH_FIXTURE= FM_RESOURCE_REMOTE_FIXTURE= \
    FM_RESOURCE_HOSTS_JSON="$TMP_ROOT/fixture/hosts-pc01.json" \
    FM_RESOURCE_HERDR_JSON_PC01="$TMP_ROOT/fixture/herdr-pc01.json" \
    FM_RESOURCE_HERDR_JSON_PC02="$TMP_ROOT/fixture/herdr-pc02.json" \
    FM_RESOURCE_ROLES_FILE="$TMP_ROOT/fixture/roles.json" \
    FM_RESOURCE_TESTING_FIXTURE="$TMP_ROOT/fixture/testing.json" \
    FM_RESOURCE_CONTEXT_FIXTURE="$TMP_ROOT/fixture/context.json" \
    FM_RESOURCE_ANDROID_FIXTURE="$TMP_ROOT/fixture/android.json" \
    SDA_TEXT="$fake/sda.txt" NVME_TEXT="$fake/nvme.txt" \
    FAKE_QUOTA_JSON="$TMP_ROOT/fixture/quota.json" \
    "$SNAP" --json 2>&1
}

test_drive_health_pc02_reads_smartctl() {
  local fake out
  fake="$TMP_ROOT/pc02-dh-tools"
  mkdir -p "$fake"
  cat > "$fake/smartctl" <<'SMART'
#!/usr/bin/env bash
case "$*" in
  *--scan*) printf '/dev/sda -d ata # /dev/sda, ATA device\n/dev/sdc -d nvme # /dev/sdc, NVMe device\n' ;;
  *"/dev/sda"*) cat "$SDA_TEXT" ;;
  *"/dev/sdc"*) cat "$NVME_TEXT" ;;
  *) exit 1 ;;
esac
SMART
  chmod +x "$fake/smartctl"
  out=$(run_pc02_drive_health ok "$fake/smartctl")
  printf '%s\n' "$out" > "$TMP_ROOT/dh-pc02-ok.json"
  jq -e '[.drive_health[] | select(.machine == "PC02")] | length == 2' \
    "$TMP_ROOT/dh-pc02-ok.json" >/dev/null \
    || fail "PC02 smartctl scan must render one row per device: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc02-ok.json")"
  jq -e '.drive_health[] | select(.disk == "/dev/sda")
    | .model == "ST8000DM004-2CX188" and .smart == "PASSED"
      and .reallocated == "0" and .pending == "0" and .uncorrectable == "0"
      and .temp_c == "31" and .power_on_hours == "14711" and .reason == "-"
      and .read_utc == "2026-11-19T21:20:00Z"' \
    "$TMP_ROOT/dh-pc02-ok.json" >/dev/null \
    || fail "PC02 ATA row: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc02-ok.json")"
  jq -e '.drive_health[] | select(.disk == "/dev/sdc")
    | .model == "Force MP510" and .smart == "PASSED"
      and .nvme_used_pct == "13" and .media_errors == "0"' \
    "$TMP_ROOT/dh-pc02-ok.json" >/dev/null \
    || fail "PC02 NVMe row: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc02-ok.json")"
  pass "the shipped PC02 smartctl probe parses ATA and NVMe health over the ssh boundary"
}

test_drive_health_pc02_missing_tool_and_unreachable() {
  local out
  out=$(run_pc02_drive_health missing /nonexistent/smartctl)
  printf '%s\n' "$out" > "$TMP_ROOT/dh-pc02-missing.json"
  jq -e '[.drive_health[] | select(.machine == "PC02")] | length == 1
    and .[0].smart == "missing-tool" and .[0].reallocated == "-"
    and (.[0].reason | test("smartmontools"))' \
    "$TMP_ROOT/dh-pc02-missing.json" >/dev/null \
    || fail "a missing smartctl must be stated, not zero: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc02-missing.json")"

  out=$(run_pc02_drive_health down /nonexistent/smartctl down)
  printf '%s\n' "$out" > "$TMP_ROOT/dh-pc02-down.json"
  jq -e '[.drive_health[] | select(.machine == "PC02")] | length == 1
    and .[0].smart == "unreachable" and .[0].reallocated == "-"
    and (.[0].reason | test("status 255"))' \
    "$TMP_ROOT/dh-pc02-down.json" >/dev/null \
    || fail "an unreachable host must be stated, not zero or healthy: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc02-down.json")"
  pass "missing-tool and unreachable PC02 reads are labelled with reason, never zero or healthy"
}

test_drive_health_pc02_crlf_and_failed_output() {
  local fake out
  fake="$TMP_ROOT/pc02-dh-crlf-tools"
  mkdir -p "$fake"
  cat > "$fake/smartctl" <<'SMART'
#!/usr/bin/env bash
case "$*" in
  *--scan*) printf '/dev/sda -d sat\r\n/dev/sdb -d ata # /dev/sdb, ATA device\r\n/dev/sdc -d ata [SAT]\r\n' ;;
  *"/dev/sda"*) sed 's/$/\r/' "$SDA_TEXT" ;;
  *"/dev/sdb"*) sed 's/PASSED/FAILED!/; s/^\(197.*-       \)0/\1 8/' "$SDA_TEXT" | sed 's/$/\r/'; exit 8 ;;
  *"/dev/sdc"*) printf 'Smartctl open device: /dev/sdc failed\r\n'; exit 2 ;;
  *) exit 1 ;;
esac
SMART
  chmod +x "$fake/smartctl"
  out=$(run_pc02_drive_health crlf "$fake/smartctl")
  printf '%s\n' "$out" > "$TMP_ROOT/dh-pc02-crlf.json"
  jq -e '.drive_health[] | select(.disk == "/dev/sda")
    | .model == "ST8000DM004-2CX188" and .smart == "PASSED" and .reallocated == "0"
      and .power_on_hours == "14711" and .reason == "-"' \
    "$TMP_ROOT/dh-pc02-crlf.json" >/dev/null \
    || fail "CRLF scan line without a comment and CRLF health output must parse: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc02-crlf.json")"
  jq -e '.drive_health[] | select(.disk == "/dev/sdb")
    | (.smart | test("^FAILED")) and (.smart | test("\r") | not) and .pending == "8"' \
    "$TMP_ROOT/dh-pc02-crlf.json" >/dev/null \
    || fail "a FAILED verdict with a non-zero exit must keep its verdict and counts: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc02-crlf.json")"
  jq -e '.drive_health[] | select(.disk == "/dev/sdc")
    | .smart == "failed" and (.reason | test("no health verdict")) and (.reason | test("exit 2"))' \
    "$TMP_ROOT/dh-pc02-crlf.json" >/dev/null \
    || fail "a device with no verdict must be failed, never healthy: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc02-crlf.json")"
  pass "PC02 parses CRLF smartctl.exe output, real FAILED verdicts, and verdict-less devices"
}

test_drive_health_pc01_snapshot_fallbacks_and_failures() {
  setup_fixture
  local f out
  f="$TMP_ROOT/pc01-dh-disks.json"
  write_pc01_snapshot "$TMP_ROOT/pc01-dh-base.json" ok 2026-11-19T20:50:00Z
  jq 'del(.smart.devices)' "$TMP_ROOT/pc01-dh-base.json" > "$f"
  out=$(run_pc01_drive_health "$f")
  printf '%s\n' "$out" > "$TMP_ROOT/dh-pc01-disks.json"
  jq -e '[.drive_health[] | select(.machine == "PC01")] | length == 2
    and all(.[]; .smart == "Healthy" and .reallocated == "-" and (.reason | test("SMART unavailable")))
    and (.[] | select(.disk == "/dev/pd2") | .temp_c == "45" and .nvme_used_pct == "13")' \
    "$TMP_ROOT/dh-pc01-disks.json" >/dev/null \
    || fail "without SMART output, Windows HealthStatus rows must say so: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc01-disks.json")"

  jq 'del(.smart.devices, .disks) | .smart.error = "elevation denied"' "$TMP_ROOT/pc01-dh-base.json" > "$f"
  out=$(run_pc01_drive_health "$f")
  printf '%s\n' "$out" > "$TMP_ROOT/dh-pc01-nodisk.json"
  jq -e '[.drive_health[] | select(.machine == "PC01")] | length == 1
    and .[0].smart == "unavailable" and (.[0].reason | test("no disk data: elevation denied"))' \
    "$TMP_ROOT/dh-pc01-nodisk.json" >/dev/null \
    || fail "a snapshot with no disk data must be unavailable: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc01-nodisk.json")"

  printf '{ not json' > "$f"
  out=$(run_pc01_drive_health "$f")
  printf '%s\n' "$out" > "$TMP_ROOT/dh-pc01-badjson.json"
  jq -e '[.drive_health[] | select(.machine == "PC01")] | length == 1
    and .[0].smart == "failed" and (.[0].reason | test("not valid JSON"))' \
    "$TMP_ROOT/dh-pc01-badjson.json" >/dev/null \
    || fail "invalid JSON must be failed: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc01-badjson.json")"

  jq 'del(.finished_at)' "$TMP_ROOT/pc01-dh-base.json" > "$f"
  out=$(run_pc01_drive_health "$f")
  printf '%s\n' "$out" > "$TMP_ROOT/dh-pc01-nofinish.json"
  jq -e '[.drive_health[] | select(.machine == "PC01")] | length == 1
    and .[0].smart == "failed" and (.[0].reason | test("finished_at"))' \
    "$TMP_ROOT/dh-pc01-nofinish.json" >/dev/null \
    || fail "a missing finished_at must not render healthy: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc01-nofinish.json")"

  jq '.smart.devices[0] |= (.output = "" | .health = null | .exit_code = 5)' "$TMP_ROOT/pc01-dh-base.json" > "$f"
  out=$(run_pc01_drive_health "$f")
  printf '%s\n' "$out" > "$TMP_ROOT/dh-pc01-noverdict.json"
  jq -e '.drive_health[] | select(.disk == "/dev/pd0")
    | .smart == "failed" and (.reason | test("no health verdict \\(exit 5\\)"))' \
    "$TMP_ROOT/dh-pc01-noverdict.json" >/dev/null \
    || fail "a device without a verdict must be failed: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc01-noverdict.json")"

  jq '.smart.devices[0] |= (.health = "FAILED!" | .exit_code = 8)' "$TMP_ROOT/pc01-dh-base.json" > "$f"
  out=$(run_pc01_drive_health "$f")
  printf '%s\n' "$out" > "$TMP_ROOT/dh-pc01-hfail.json"
  jq -e '.drive_health[] | select(.disk == "/dev/pd0") | .smart == "FAILED!"' \
    "$TMP_ROOT/dh-pc01-hfail.json" >/dev/null \
    || fail "a FAILED verdict must be shown: $(jq -c '.drive_health' "$TMP_ROOT/dh-pc01-hfail.json")"
  pass "PC01 snapshot fallbacks and failures are labelled, never healthy"
}

start_inherited_flock() {  # <lockfile> -> prints the surviving holder pid
  bash -c '
    exec 9>"$1"
    flock -x 9
    sleep 300 </dev/null >/dev/null 2>&1 &
    printf "%s" "$!"
    exit 0
  ' _ "$1"
}

run_pc02_slots_live() {  # <name> <remote-home> <host-out-file> <proc-root> -> JSON
  local name=$1 remote_home=$2 host_out=$3 proc_root=$4 rec home fb fake
  rec=$(make_home "pc02-slots-$name" fresh); home=${rec%%|*}; fb=${rec#*|}
  write_fixtures fixture
  fake="$TMP_ROOT/pc02-slots-$name"
  mkdir -p "$fake"
  cat > "$fake/ssh" <<SSH
#!/usr/bin/env bash
script=\$(cat)
case "\$script" in
  *pc02-offload-slots*)
    printf '%s\n' "\$script" | HOME='$remote_home' bash -s -- '$remote_home' '$remote_home' > '$host_out' 2>/dev/null
    cat '$host_out'
    exit 0
    ;;
esac
exit 255
SSH
  chmod +x "$fake/ssh"
  env PATH="$fake:$fb:$BASE_PATH" FM_HOME="$home" FM_RESOURCE_NOW="$NOW" \
    FM_SSH_BIN="$fake/ssh" FM_RESOURCE_REMOTE_FIXTURE= \
    FM_RESOURCE_PROC_ROOT="$proc_root" \
    FM_RESOURCE_HOSTS_JSON="$TMP_ROOT/fixture/hosts-pc01.json" \
    FM_RESOURCE_HERDR_JSON_PC01="$TMP_ROOT/fixture/herdr-pc01.json" \
    FM_RESOURCE_HERDR_JSON_PC02="$TMP_ROOT/fixture/herdr-pc02.json" \
    FM_RESOURCE_ROLES_FILE="$TMP_ROOT/fixture/roles.json" \
    FM_RESOURCE_TESTING_FIXTURE="$TMP_ROOT/fixture/testing.json" \
    FM_RESOURCE_CONTEXT_FIXTURE="$TMP_ROOT/fixture/context.json" \
    FM_RESOURCE_ANDROID_FIXTURE="$TMP_ROOT/fixture/android.json" \
    FM_RESOURCE_DRIVE_HEALTH_FIXTURE="$TMP_ROOT/fixture/drive-health.json" \
    FAKE_QUOTA_JSON="$TMP_ROOT/fixture/quota.json" \
    "$SNAP" --json 2>&1
}

test_pc02_offload_slots_counts_inherited_flock() {
  local remote_home lock holder host_out proc_root fd found=
  if [ ! -r /proc/locks ] || ! command -v flock >/dev/null 2>&1; then
    pass "inherited-flock slot detection needs Linux /proc and flock; skipped here"
    return 0
  fi
  remote_home="$TMP_ROOT/pc02-slots-inherited/remote-home"
  mkdir -p "$remote_home/.config/firstmate" "$TMP_ROOT/pc02-slots-inherited/fakeproc"
  printf '3\n' > "$remote_home/.config/firstmate/pc02-offload-slots"
  lock="$remote_home/.fm-pc02-test-slot-1.lock"
  : > "$lock"
  host_out="$TMP_ROOT/pc02-slots-inherited.host.out"
  proc_root="$TMP_ROOT/pc02-slots-inherited/fakeproc"
  : > "$proc_root/locks"
  holder=$(start_inherited_flock "$lock")
  for fd in /proc/"$holder"/fd/*; do
    [ "$(readlink "$fd" 2>/dev/null)" = "$lock" ] || continue
    grep -q '^lock:' "/proc/$holder/fdinfo/${fd##*/}" 2>/dev/null && { found=1; break; }
  done
  [ -n "$found" ] || fail "setup: the surviving holder must name the inherited lock in fdinfo"
  run_pc02_slots_live inherited "$remote_home" "$host_out" "$proc_root" >/dev/null 2>&1
  kill "$holder" 2>/dev/null || true
  awk -F'\t' '$1 == "T" && $2 == "pc02-offload-slots" && $3 == "1/3" { found = 1 } END { exit !found }' "$host_out" \
    || fail "a flock inherited by a child after its locker exits must read busy: $(awk -F'\t' '$2 == "pc02-offload-slots"' "$host_out")"
  pass "a flock inherited by a child after its locker exits is read as a busy slot"
}

test_every_section_renders_and_agrees
test_android_fixture_renders_both_hosts
test_android_probe_reads_fake_tools
test_android_unresolved_name_is_not_stopped
test_android_adb_failure_keeps_avd_unknown_not_stopped
test_android_probe_failures_are_stated_not_zero
test_android_empty_clean_reads_render_none
test_android_boot_completed_variants
test_android_physical_device_does_not_hide_stopped_avd
test_android_discovery_reports_missing_recorded_root() {
  local fake out base
  base="$TMP_ROOT/android-missing"
  fake="$base/fake"
  mkdir -p "$fake"
  cat > "$fake/adb" <<'STUB'
#!/usr/bin/env bash
case "$*" in devices) printf 'List of devices attached\n\n' ;; *) exit 1 ;; esac
STUB
  cat > "$fake/emulator" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "-list-avds" ] && exit 0
exit 1
STUB
  chmod +x "$fake/adb" "$fake/emulator"
  out=$(run_android_discovery missing FM_RESOURCE_ANDROID_ROOTS="$base/E/Android" FM_RESOURCE_ANDROID_HOME_DIRS="$base/E/avd" FM_RESOURCE_ADB="$fake/adb" FM_RESOURCE_EMULATOR="$fake/emulator")
  printf '%s\n' "$out" > "$base/out.json"
  jq -e '[.android[] | select(.machine == "PC01" and .state == "none")] | length == 0' "$base/out.json" >/dev/null || fail "a missing recorded root must never render none: $(jq -c '.android' "$base/out.json")"
  jq -e --arg r "$base/E/Android" --arg h "$base/E/avd" '[.unavailable[] | select(.source == "android:PC01") | .reason] | (any(contains($r) and contains("missing"))) and (any(contains($h) and contains("missing")))' "$base/out.json" >/dev/null || fail "a missing recorded root and AVD home must be named: $(jq -c '.unavailable' "$base/out.json")"
  pass "a missing recorded root or AVD home is reported with its path, never as none"
}

test_android_probe_timeouts_are_stated
test_pc02_android_live_read
test_pc02_android_live_failure_is_stated
test_android_discovery_reads_environment_json_and_port
test_android_discovery_reads_wsl_only_avd_home
test_android_discovery_reports_unreadable_root
test_android_discovery_reports_missing_recorded_root
test_android_missing_tools_is_stated_not_zero
test_opencode_worker_gets_a_context_band
test_compute_discovers_github_and_gitlab_from_live_state
test_compute_discovers_forgejo_from_local_instance
test_compute_without_identity_says_why
test_drive_health_pc01_snapshot_reads_smart
test_drive_health_pc01_stale_missing_failed_labelled
test_drive_health_pc02_reads_smartctl
test_drive_health_pc02_missing_tool_and_unreachable
test_drive_health_pc02_crlf_and_failed_output
test_drive_health_pc01_snapshot_fallbacks_and_failures
test_pc02_offload_slots_counts_inherited_flock
test_failed_quota_is_labelled_not_zero
test_rate_limited_quota_is_not_zero
test_down_pc02_keeps_pc01
test_remote_fixture_alone_supplies_pc02_rows
test_worker_lane_account_follows_lane_not_role
test_row_caps_and_omitted
test_read_only_leaves_fixture_untouched
test_home_only_renders_workers_only
test_live_reconciliation

echo '# all fm-resource-snapshot tests passed'
