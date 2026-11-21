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
  for section in hosts drives quota workers panes strays secondmates roles testing compute unavailable; do
    jq -e "has(\"$section\")" "$TMP_ROOT/model.json" >/dev/null || fail "missing section $section"
  done
  [ "$(count_json "$TMP_ROOT/model.json" '.hosts')" = 2 ] || fail "hosts count"
  [ "$(count_json "$TMP_ROOT/model.json" '.drives')" = 7 ] || fail "drives count"
  [ "$(count_json "$TMP_ROOT/model.json" '.quota')" = 8 ] || fail "quota rows: $(jq -c '.quota' "$TMP_ROOT/model.json")"
  [ "$(count_json "$TMP_ROOT/model.json" '.workers')" = 5 ] || fail "workers must union both homes"
  [ "$(count_json "$TMP_ROOT/model.json" '.panes')" = 4 ] || fail "panes count"
  [ "$(count_json "$TMP_ROOT/model.json" '.strays')" = 2 ] || fail "bare + unknown-agent panes are exactly two strays"
  [ "$(count_json "$TMP_ROOT/model.json" '.secondmates')" = 1 ] || fail "secondmates count"
  [ "$(count_json "$TMP_ROOT/model.json" '.roles')" = 3 ] || fail "roles fixture count"
  [ "$(count_json "$TMP_ROOT/model.json" '.testing')" = 2 ] || fail "testing count"
  [ "$(count_json "$TMP_ROOT/model.json" '.compute')" = 2 ] || fail "compute count"
  jq -e '.drives[] | select(.machine == "PC02" and .mount == "C:") | .free_gb == "23.0" and .warn == "watch"' \
    "$TMP_ROOT/model.json" >/dev/null || fail "PC02 C: must be watch at 23 GB"
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

test_every_section_renders_and_agrees
test_opencode_worker_gets_a_context_band
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
