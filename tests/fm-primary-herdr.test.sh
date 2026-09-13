#!/usr/bin/env bash
# Behavioral coverage for the guarded Herdr primary launcher.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$ROOT/tests/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-primary-herdr)
trap 'rm -rf "$TMP_ROOT"' EXIT
SCRIPT="$ROOT/bin/fm-primary-herdr.sh"

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

make_home() {
  local home=$1
  mkdir -p "$home/bin" "$home/state"
  cp "$ROOT/AGENTS.md" "$home/AGENTS.md"
  cp "$ROOT/bin/fm-session-start.sh" "$home/bin/fm-session-start.sh"
  chmod +x "$home/bin/fm-session-start.sh"
}

make_fakebin() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "${FAKE_LOG:?}"
case "$*" in
  *'status --json'*) printf '{"client":{"protocol":19,"version":"0.9.0"},"server":{"running":true,"protocol":19,"version":"0.9.0"}}\n' ;;
  *'workspace create'*) printf '{"result":{"workspace":{"workspace_id":"w1"},"tab":{"tab_id":"w1:t1"},"root_pane":{"pane_id":"w1:p1"}}}\n' ;;
  *'workspace list'*)
    [ "${FAKE_WORKSPACE_LIST_RC:-0}" -eq 0 ] || exit "$FAKE_WORKSPACE_LIST_RC"
    if [ -n "${FAKE_WORKSPACE_LIST:-}" ]; then printf '%s\n' "$FAKE_WORKSPACE_LIST"; else printf '{"result":{"workspaces":[]}}\n'; fi ;;
  *'agent list'*)
    if [ -n "${FAKE_AGENT_LIST:-}" ]; then printf '%s\n' "$FAKE_AGENT_LIST"; else printf '{"result":{"agents":[]}}\n'; fi ;;
  *'tab get w1:t1'*) printf '{"result":{"tab":{"tab_id":"w1:t1","workspace_id":"%s"}}}\n' "${FAKE_TAB_WORKSPACE:-w1}" ;;
  *'pane get w1:p1'*) printf '{"result":{"pane":{"pane_id":"w1:p1","tab_id":"%s","workspace_id":"%s"}}}\n' "${FAKE_PANE_TAB:-w1:t1}" "${FAKE_PANE_WORKSPACE:-w1}" ;;
  *'agent get w1:p1'*)
    case "${FAKE_AGENT_STATE:-none}" in
      live-claude) printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' ;;
      live-codex) printf '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}\n' ;;
      *) printf '{"error":{"code":"agent_not_found"}}\n' ;;
    esac ;;
  *'agent start'*)
    if [ -n "${FAKE_READY_PID:-}" ]; then
      printf '%s\n' "$FAKE_READY_PID" > "$FAKE_HOME/state/.lock"
      printf '%s\n' "$FAKE_READY_PID" > "$FAKE_HOME/state/.session-start-complete"
    fi
    printf '{"result":{"agent":{"agent_status":"idle"}}}\n' ;;
  *'pane process-info w1:p1'*) printf '{"result":{"shell":{"pid":1,"name":"bash","state":"S"},"foreground":{"pid":1,"pgid":1},"processes":[{"pid":1,"ppid":0,"pgid":1,"name":"bash","state":"S"}]}}\n' ;;
  *'session attach'*) : ;;
esac
SH
  cat > "$dir/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'-o comm='*) printf '%s\n' "${FAKE_PS_COMM:-codex}" ;;
  *'-o args='*) printf '%s\n' "${FAKE_PS_ARGS:-codex}" ;;
  *) /usr/bin/ps "$@" ;;
esac
SH
  cat > "$dir/kill" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -0 ] && exit "${FAKE_KILL_RC:-0}"
exec /usr/bin/kill "$@"
SH
  chmod +x "$dir/herdr" "$dir/ps" "$dir/kill"
}

run_case() {
  local name=$1 mode=$2
  shift 2
  local dir="$TMP_ROOT/$name" home="$TMP_ROOT/$name/home" fake="$TMP_ROOT/$name/fake" log="$TMP_ROOT/$name/log"
  local -a script_args=("$mode")
  make_home "$home"
  make_fakebin "$fake"
  : > "$log"
  case "$mode" in normal|emergency) script_args+=(--no-attach) ;; esac
  env PATH="$fake:$PATH" FAKE_LOG="$log" FAKE_HOME="$home" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    HERDR_SESSION=firstmate FM_PRIMARY_READY_TIMEOUT=1 "$@" "$SCRIPT" "${script_args[@]}"
}

test_emergency_launch_is_explicit_and_completes() {
  local out log
  out=$(run_case emergency emergency env FAKE_READY_PID=$$ FAKE_PS_COMM=codex FAKE_PS_ARGS=codex)
  log=$(cat "$TMP_ROOT/emergency/log")
  printf '%s' "$out" | grep -F 'primary ready: harness=codex' >/dev/null || fail 'emergency launch did not report ready'
  printf '%s' "$log" | grep -F 'agent start firstmate-primary --kind codex --pane w1:p1' >/dev/null || fail 'emergency launch did not target the exact pane as Codex'
  printf '%s' "$log" | grep -F -- '--model gpt-5.6-luna' >/dev/null || fail 'emergency launch omitted the explicit Codex model'
  printf '%s' "$log" | grep -F -- '--dangerously-bypass-approvals-and-sandbox' >/dev/null || fail 'emergency launch omitted the required Codex execution shape'
  grep -F 'harness=codex' "$TMP_ROOT/emergency/home/state/.primary-herdr" >/dev/null || fail 'emergency endpoint record omitted Codex identity'
  pass 'emergency startup pins Codex, records the endpoint, and waits for ownership proof'
}

test_normal_launch_is_explicit_and_completes() {
  local out log
  out=$(run_case normal normal env FAKE_READY_PID=$$ FAKE_PS_COMM=claude FAKE_PS_ARGS=claude)
  log=$(cat "$TMP_ROOT/normal/log")
  printf '%s' "$out" | grep -F 'primary ready: harness=claude' >/dev/null || fail 'normal launch did not report ready'
  printf '%s' "$log" | grep -F 'agent start firstmate-primary --kind claude --pane w1:p1' >/dev/null || fail 'normal launch did not target the exact pane as Claude'
  printf '%s' "$log" | grep -F -- "workspace create --cwd $TMP_ROOT/normal/home --label firstmate --no-focus" >/dev/null || fail 'normal launch did not create the workspace from the tracked root'
  printf '%s' "$log" | grep -F -- '--dangerously-skip-permissions' >/dev/null || fail 'normal launch omitted the verified Claude execution shape'
  grep -F 'harness=claude' "$TMP_ROOT/normal/home/state/.primary-herdr" >/dev/null || fail 'normal endpoint record omitted Claude identity'
  pass 'normal startup selects Claude, records the endpoint, and waits for ownership proof'
}

test_unreadable_workspace_inventory_refuses() {
  local home="$TMP_ROOT/unreadable-workspace/home" fake="$TMP_ROOT/unreadable-workspace/fake" log="$TMP_ROOT/unreadable-workspace/log" out
  make_home "$home"; make_fakebin "$fake"; : > "$log"
  if out=$(env PATH="$fake:$PATH" FAKE_LOG="$log" FAKE_HOME="$home" FAKE_WORKSPACE_LIST_RC=1 \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$SCRIPT" normal --no-attach 2>&1); then
    fail 'startup accepted an unreadable primary workspace inventory'
  fi
  printf '%s' "$out" | grep -F 'primary-workspace discovery was unreadable' >/dev/null || fail 'unreadable-workspace refusal was unclear'
  ! grep -F 'workspace create' "$log" >/dev/null || fail 'unreadable-workspace discovery created a workspace'
  pass 'an unreadable primary workspace inventory fails closed'
}

test_split_primary_home_refuses() {
  local home="$TMP_ROOT/split-home/home" fake="$TMP_ROOT/split-home/fake" log="$TMP_ROOT/split-home/log" out
  make_home "$home"; make_fakebin "$fake"; : > "$log"
  if out=$(env PATH="$fake:$PATH" FAKE_LOG="$log" FAKE_HOME="$home" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SCRIPT" normal --no-attach 2>&1); then
    fail 'startup accepted a split primary root and home'
  fi
  printf '%s' "$out" | grep -F 'requires FM_HOME and FM_ROOT to be the same canonical directory' >/dev/null || fail 'split-home refusal was unclear'
  [ ! -s "$log" ] || fail 'split-home refusal mutated Herdr'
  pass 'a split primary root and home are refused before startup'
}

test_unreadable_agent_inventory_refuses() {
  local home="$TMP_ROOT/unreadable-agent/home" fake="$TMP_ROOT/unreadable-agent/fake" log="$TMP_ROOT/unreadable-agent/log" out
  make_home "$home"; make_fakebin "$fake"; : > "$log"
  if out=$(env PATH="$fake:$PATH" FAKE_LOG="$log" FAKE_HOME="$home" \
    FAKE_AGENT_LIST='{"result":{}}' FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    "$SCRIPT" normal --no-attach 2>&1); then
    fail 'startup accepted an unreadable primary agent inventory'
  fi
  printf '%s' "$out" | grep -F 'primary-agent discovery was unreadable' >/dev/null || fail 'unreadable-agent refusal was unclear'
  ! grep -F 'workspace create' "$log" >/dev/null || fail 'unreadable-agent discovery created a workspace'
  pass 'an unreadable primary agent inventory fails closed'
}

test_incomplete_record_refuses() {
  local home="$TMP_ROOT/incomplete-record/home" fake="$TMP_ROOT/incomplete-record/fake" log="$TMP_ROOT/incomplete-record/log" out
  make_home "$home"; make_fakebin "$fake"; : > "$log"
  cat > "$home/state/.primary-herdr" <<'EOF'
version=1
session=firstmate
pane=w1:p1
harness=claude
EOF
  if out=$(env PATH="$fake:$PATH" FAKE_LOG="$log" FAKE_HOME="$home" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$SCRIPT" normal --no-attach 2>&1); then
    fail 'startup accepted an incomplete primary endpoint record'
  fi
  printf '%s' "$out" | grep -F 'recorded primary endpoint is invalid' >/dev/null || fail 'incomplete-record refusal was unclear'
  ! grep -F 'workspace create' "$log" >/dev/null || fail 'incomplete record created a workspace'
  pass 'an incomplete primary endpoint record is refused'
}

write_husk_record() {
  local home=$1
  cat > "$home/state/.primary-herdr" <<'EOF'
version=1
session=firstmate
workspace=w1
tab=w1:t1
pane=w1:p1
harness=claude
EOF
}

test_recorded_husk_checks_competing_agent() {
  local home="$TMP_ROOT/husk-agent/home" fake="$TMP_ROOT/husk-agent/fake" log="$TMP_ROOT/husk-agent/log" out
  make_home "$home"; make_fakebin "$fake"; : > "$log"; write_husk_record "$home"
  if out=$(env PATH="$fake:$PATH" FAKE_LOG="$log" FAKE_HOME="$home" \
    FAKE_AGENT_LIST='{"result":{"agents":[{"name":"firstmate-primary"}]}}' \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$SCRIPT" normal --no-attach 2>&1); then
    fail 'husk reuse accepted a competing primary agent'
  fi
  printf '%s' "$out" | grep -F 'unrecorded firstmate-primary agent' >/dev/null || fail 'husk competitor refusal was unclear'
  ! grep -F 'agent start' "$log" >/dev/null || fail 'husk competitor launched an agent'
  pass 'recorded husk reuse refuses a competing primary agent'
}

test_recorded_husk_checks_competing_workspace() {
  local home="$TMP_ROOT/husk-workspace/home" fake="$TMP_ROOT/husk-workspace/fake" log="$TMP_ROOT/husk-workspace/log" out
  make_home "$home"; make_fakebin "$fake"; : > "$log"; write_husk_record "$home"
  if out=$(env PATH="$fake:$PATH" FAKE_LOG="$log" FAKE_HOME="$home" \
    FAKE_WORKSPACE_LIST='{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"firstmate"}]}}' \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$SCRIPT" normal --no-attach 2>&1); then
    fail 'husk reuse accepted competing primary workspaces'
  fi
  printf '%s' "$out" | grep -F 'not the unique, consistent primary endpoint' >/dev/null || fail 'husk workspace refusal was unclear'
  ! grep -F 'agent start' "$log" >/dev/null || fail 'husk workspace competitor launched an agent'
  pass 'recorded husk reuse refuses competing primary workspaces'
}

test_recorded_husk_checks_parent_relationships() {
  local home="$TMP_ROOT/husk-parent/home" fake="$TMP_ROOT/husk-parent/fake" log="$TMP_ROOT/husk-parent/log" out
  make_home "$home"; make_fakebin "$fake"; : > "$log"; write_husk_record "$home"
  if out=$(env PATH="$fake:$PATH" FAKE_LOG="$log" FAKE_HOME="$home" FAKE_TAB_WORKSPACE=w2 \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$SCRIPT" normal --no-attach 2>&1); then
    fail 'husk reuse accepted an inconsistent tab parent'
  fi
  printf '%s' "$out" | grep -F 'not the unique, consistent primary endpoint' >/dev/null || fail 'husk parent refusal was unclear'
  ! grep -F 'agent start' "$log" >/dev/null || fail 'inconsistent husk launched an agent'
  pass 'recorded husk reuse refuses inconsistent tab relationships'
}

test_status_does_not_create_state() {
  local home="$TMP_ROOT/status/home" out
  mkdir -p "$home/bin"
  cp "$ROOT/AGENTS.md" "$home/AGENTS.md"
  cp "$ROOT/bin/fm-session-start.sh" "$home/bin/fm-session-start.sh"
  chmod +x "$home/bin/fm-session-start.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$SCRIPT" status)
  printf '%s' "$out" | grep -F "home=$home" >/dev/null || fail 'status did not report the primary home'
  [ ! -e "$home/state" ] || fail 'status created the state directory'
  pass 'status remains read-only when state is absent'
}

test_healthy_same_role_reconnects_without_launch() {
  local dir="$TMP_ROOT/reconnect" home="$TMP_ROOT/reconnect/home" fake="$TMP_ROOT/reconnect/fake" log="$TMP_ROOT/reconnect/log" out
  make_home "$home"; make_fakebin "$fake"; : > "$log"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s\n' "$$" > "$home/state/.session-start-complete"
  cat > "$home/state/.primary-herdr" <<'EOF'
version=1
session=firstmate
workspace=w1
tab=w1:t1
pane=w1:p1
harness=claude
EOF
  out=$(env PATH="$fake:$PATH" FAKE_LOG="$log" FAKE_HOME="$home" FAKE_AGENT_STATE=live-claude \
    FAKE_PS_COMM=claude FAKE_PS_ARGS=claude FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    "$SCRIPT" normal --no-attach)
  printf '%s' "$out" | grep -F 'primary reconnected: harness=claude' >/dev/null || fail 'healthy same-role startup did not reconnect'
  ! grep -F 'agent start' "$log" >/dev/null || fail 'healthy same-role reconnect launched a duplicate agent'
  pass 'a healthy same-role primary reconnects without duplicate launch'
}

test_live_other_primary_refuses() {
  local dir="$TMP_ROOT/live-other" home="$TMP_ROOT/live-other/home" fake="$TMP_ROOT/live-other/fake" log="$TMP_ROOT/live-other/log" out
  make_home "$home"; make_fakebin "$fake"; : > "$log"
  printf '%s\n' "$$" > "$home/state/.lock"
  if out=$(env PATH="$fake:$PATH" FAKE_LOG="$log" FAKE_HOME="$home" FAKE_PS_COMM=codex FAKE_PS_ARGS=codex \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$SCRIPT" normal --no-attach 2>&1); then
    fail 'normal startup accepted a live Codex owner'
  fi
  printf '%s' "$out" | grep -F 'already owned by live codex' >/dev/null || fail 'role-conflict refusal was unclear'
  ! grep -F 'agent start' "$log" >/dev/null || fail 'role-conflict refusal still launched an agent'
  pass 'a live primary of the other role prevents duplicate startup'
}

test_live_endpoint_without_lock_refuses() {
  local dir="$TMP_ROOT/orphan-live" home="$TMP_ROOT/orphan-live/home" fake="$TMP_ROOT/orphan-live/fake" log="$TMP_ROOT/orphan-live/log" out
  make_home "$home"; make_fakebin "$fake"; : > "$log"
  cat > "$home/state/.primary-herdr" <<'EOF'
version=1
session=firstmate
workspace=w1
tab=w1:t1
pane=w1:p1
harness=claude
EOF
  if out=$(env PATH="$fake:$PATH" FAKE_LOG="$log" FAKE_HOME="$home" FAKE_AGENT_STATE=live-claude \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$SCRIPT" normal --no-attach 2>&1); then
    fail 'startup accepted a live endpoint without matching lock ownership'
  fi
  printf '%s' "$out" | grep -F 'exists without matching lock ownership' >/dev/null || fail 'orphan live endpoint refusal was unclear'
  ! grep -F 'agent start' "$log" >/dev/null || fail 'orphan live endpoint refusal still launched an agent'
  pass 'a live recorded endpoint without matching ownership is preserved and refused'
}

test_unrecorded_named_agent_refuses() {
  local home="$TMP_ROOT/unrecorded-agent/home" fake="$TMP_ROOT/unrecorded-agent/fake" log="$TMP_ROOT/unrecorded-agent/log" out
  make_home "$home"; make_fakebin "$fake"; : > "$log"
  if out=$(env PATH="$fake:$PATH" FAKE_LOG="$log" FAKE_HOME="$home" \
    FAKE_AGENT_LIST='{"result":{"agents":[{"name":"firstmate-primary"}]}}' \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$SCRIPT" normal --no-attach 2>&1); then
    fail 'startup accepted an unrecorded named primary agent'
  fi
  printf '%s' "$out" | grep -F 'unrecorded firstmate-primary agent' >/dev/null || fail 'unrecorded-agent refusal was unclear'
  ! grep -F 'workspace create' "$log" >/dev/null || fail 'unrecorded-agent refusal created a workspace'
  pass 'an unrecorded named primary agent prevents duplicate startup'
}

test_unrecorded_workspace_refuses() {
  local home="$TMP_ROOT/unrecorded-workspace/home" fake="$TMP_ROOT/unrecorded-workspace/fake" log="$TMP_ROOT/unrecorded-workspace/log" out
  make_home "$home"; make_fakebin "$fake"; : > "$log"
  if out=$(env PATH="$fake:$PATH" FAKE_LOG="$log" FAKE_HOME="$home" \
    FAKE_WORKSPACE_LIST='{"result":{"workspaces":[{"workspace_id":"other","label":"firstmate"}]}}' \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$SCRIPT" normal --no-attach 2>&1); then
    fail 'startup accepted an unrecorded primary workspace'
  fi
  printf '%s' "$out" | grep -F 'unrecorded workspace' >/dev/null || fail 'unrecorded-workspace refusal was unclear'
  ! grep -F 'workspace create' "$log" >/dev/null || fail 'unrecorded-workspace refusal created another workspace'
  pass 'an unrecorded primary workspace prevents conflicting creation'
}

test_confirmed_empty_pane_allows_role_handoff() {
  local home="$TMP_ROOT/empty-handoff/home" fake="$TMP_ROOT/empty-handoff/fake" log="$TMP_ROOT/empty-handoff/log" out
  make_home "$home"; make_fakebin "$fake"; : > "$log"
  cat > "$home/state/.primary-herdr" <<'EOF'
version=1
session=firstmate
workspace=w1
tab=w1:t1
pane=w1:p1
harness=claude
EOF
  out=$(env PATH="$fake:$PATH" FAKE_LOG="$log" FAKE_HOME="$home" FAKE_READY_PID=$$ \
    FAKE_WORKSPACE_LIST='{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}' \
    FAKE_PS_COMM=codex FAKE_PS_ARGS=codex FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_PRIMARY_READY_TIMEOUT=1 "$SCRIPT" emergency --no-attach)
  printf '%s' "$out" | grep -F 'primary ready: harness=codex' >/dev/null || fail 'confirmed empty-pane handoff did not start Codex'
  grep -F 'agent start firstmate-primary --kind codex --pane w1:p1' "$log" >/dev/null || fail 'empty-pane handoff did not reuse the recorded pane'
  ! grep -F 'workspace create' "$log" >/dev/null || fail 'empty-pane handoff created a duplicate workspace'
  pass 'a confirmed empty recorded pane permits explicit role handoff'
}

test_server_mode_never_starts_agent() {
  local out log
  out=$(run_case server server env)
  log=$(cat "$TMP_ROOT/server/log")
  printf '%s' "$out" | grep -F 'primary server ready' >/dev/null || fail 'server mode did not report readiness'
  ! printf '%s' "$log" | grep -F 'agent start' >/dev/null || fail 'server mode launched a primary agent'
  pass 'boot server mode starts no primary agent'
}

test_emergency_launch_is_explicit_and_completes
test_normal_launch_is_explicit_and_completes
test_unreadable_workspace_inventory_refuses
test_split_primary_home_refuses
test_unreadable_agent_inventory_refuses
test_incomplete_record_refuses
test_recorded_husk_checks_competing_agent
test_recorded_husk_checks_competing_workspace
test_recorded_husk_checks_parent_relationships
test_status_does_not_create_state
test_healthy_same_role_reconnects_without_launch
test_live_other_primary_refuses
test_live_endpoint_without_lock_refuses
test_unrecorded_named_agent_refuses
test_unrecorded_workspace_refuses
test_confirmed_empty_pane_allows_role_handoff
test_server_mode_never_starts_agent
printf 'PASS fm-primary-herdr.test.sh\n'
