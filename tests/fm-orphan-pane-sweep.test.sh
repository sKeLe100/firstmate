#!/usr/bin/env bash
# Focused coverage for bin/fm-orphan-pane-sweep.sh: every skip rule (primary
# label, projection-grammar label, known meta pane) and every flag reason
# (cwd-missing, dead-agent, idle-untracked), plus the herdr/jq-absent and
# treehouse-enrichment paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-orphan-pane-sweep)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

export FM_HOME="$TMP_ROOT/home"
export FM_STATE_OVERRIDE="$FM_HOME/state"
mkdir -p "$FM_STATE_OVERRIDE"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_fake_exit0 "$FAKEBIN" herdr
export PATH="$FAKEBIN:$PATH"
export FM_ORPHAN_PANE_SWEEP_SOURCE_ONLY=1
# shellcheck source=/dev/null
. "$ROOT/bin/fm-orphan-pane-sweep.sh"
unset FM_ORPHAN_PANE_SWEEP_SOURCE_ONLY

SESSION=fm-orphan-sweep-test
LIVE_DIR="$TMP_ROOT/live-cwd"
mkdir -p "$LIVE_DIR"
MISSING_DIR="$TMP_ROOT/deleted-cwd"
rm -rf "$MISSING_DIR"

fm_backend_name() { printf herdr; }
fm_backend_herdr_session() { printf '%s' "$SESSION"; }
fm_backend_herdr_workspace_label() { printf 'firstmate'; }
fm_backend_herdr_pane_agent_state() { cat "$TMP_ROOT/agent-state" 2>/dev/null || printf 'no-agent'; }
fm_backend_herdr_pane_idle_shell_pid() {
  [ -e "$TMP_ROOT/no-idle-pid" ] && return 1
  printf '%s' "$$"
}
ps() {
  case "$*" in
    *"-o etimes= -p $$"*) cat "$TMP_ROOT/etimes" 2>/dev/null || printf '0' ;;
    *) command ps "$@" ;;
  esac
}

WORKSPACES_FILE="$TMP_ROOT/workspaces.json"
PANES_FILE="$TMP_ROOT/panes.json"

fm_backend_herdr_cli() {
  local _session=$1 first=${2:-} second=${3:-}
  shift
  case "$first $second" in
    "workspace list") cat "$WORKSPACES_FILE" ;;
    "pane list") cat "$PANES_FILE" ;;
    *) return 1 ;;
  esac
}

reset_fixture() {
  rm -f "$TMP_ROOT/agent-state" "$TMP_ROOT/no-idle-pid" "$TMP_ROOT/etimes"
  rm -f "$FM_STATE_OVERRIDE"/*.meta
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"task-under-test"}]}}' > "$WORKSPACES_FILE"
  printf '%s\n' "{\"result\":{\"panes\":[{\"pane_id\":\"w1:p1\",\"cwd\":\"$LIVE_DIR\",\"foreground_cwd\":\"$LIVE_DIR\"}]}}" > "$PANES_FILE"
}

run_sweep() { fm_orphan_pane_sweep; }

reset_fixture
printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w0","label":"firstmate"}]}}' > "$WORKSPACES_FILE"
out=$(run_sweep)
[ -z "$out" ] || fail "primary's own workspace label was not skipped: $out"
pass "primary/home workspace label is always skipped"

reset_fixture
printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","label":"└ some task · p:AbCdEfGhIjKlMnOpQrStUv"}]}}' > "$WORKSPACES_FILE"
printf '%s\n' "{\"result\":{\"panes\":[{\"pane_id\":\"w2:p1\",\"cwd\":\"$MISSING_DIR\",\"foreground_cwd\":\"$MISSING_DIR\"}]}}" > "$PANES_FILE"
out=$(run_sweep)
[ -z "$out" ] || fail "reserved projection-grammar label was flagged: $out"
pass "reserved firstmate task-presentation label is never flagged, even with a missing cwd"

reset_fixture
printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","label":"some task · p:AbCdEfGhIjKlMnOpQrStUv"}]}}' > "$WORKSPACES_FILE"
printf '%s\n' "{\"result\":{\"panes\":[{\"pane_id\":\"w2:p1\",\"cwd\":\"$MISSING_DIR\",\"foreground_cwd\":\"$MISSING_DIR\"}]}}" > "$PANES_FILE"
out=$(run_sweep)
case "$out" in
  *"pane=w2:p1"*"reason=cwd-missing"*) ;;
  *) fail "label lacking the '└ ' prefix was treated as reserved and skipped: $out" ;;
esac
pass "a label with the projection token shape but no '└ ' prefix is not treated as reserved"

reset_fixture
printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w3","label":null}]}}' > "$WORKSPACES_FILE"
printf '%s\n' "{\"result\":{\"panes\":[{\"pane_id\":\"w3:p1\",\"cwd\":\"$MISSING_DIR\",\"foreground_cwd\":\"$MISSING_DIR\"}]}}" > "$PANES_FILE"
out=$(run_sweep)
case "$out" in
  *"pane=w3:p1"*"reason=cwd-missing"*) ;;
  *) fail "workspace with a null label was dropped from the sweep instead of being evaluated: $out" ;;
esac
pass "a workspace with a null/missing label is still swept, not dropped"

reset_fixture
printf "herdr_session=%s\nherdr_pane_id=w1:p1\n" "$SESSION" > "$FM_STATE_OVERRIDE/task.meta"
printf '%s\n' "{\"result\":{\"panes\":[{\"pane_id\":\"w1:p1\",\"cwd\":\"$MISSING_DIR\",\"foreground_cwd\":\"$MISSING_DIR\"}]}}" > "$PANES_FILE"
out=$(run_sweep)
[ -z "$out" ] || fail "pane matching this home's own metadata was flagged: $out"
pass "a pane recorded in this home's state/*.meta is never flagged"

reset_fixture
out=$(run_sweep)
[ -z "$out" ] || fail "a live, tracked-looking pane with an existing cwd was flagged: $out"
pass "an untracked pane with a live cwd and no other signal is left alone"

reset_fixture
printf '%s\n' "{\"result\":{\"panes\":[{\"pane_id\":\"w1:p1\",\"cwd\":\"$MISSING_DIR\",\"foreground_cwd\":\"$MISSING_DIR\"}]}}" > "$PANES_FILE"
out=$(run_sweep)
case "$out" in
  *"pane=w1:p1"*"reason=cwd-missing"*) ;;
  *) fail "missing-cwd pane was not flagged: $out" ;;
esac
pass "an untracked pane whose cwd no longer exists is flagged cwd-missing"

reset_fixture
printf '%s\n' "{\"result\":{\"panes\":[{\"pane_id\":\"w1:p1\",\"cwd\":\"$LIVE_DIR\",\"foreground_cwd\":\"$LIVE_DIR\",\"agent\":{}}]}}" > "$PANES_FILE"
printf 'dead\n' > "$TMP_ROOT/agent-state"
out=$(run_sweep)
case "$out" in
  *"reason=dead-agent"*) ;;
  *) fail "dead registered agent was not flagged: $out" ;;
esac
pass "an untracked pane with a confirmed-dead registered agent is flagged dead-agent"

reset_fixture
printf '%s\n' "{\"result\":{\"panes\":[{\"pane_id\":\"w1:p1\",\"cwd\":\"$LIVE_DIR\",\"foreground_cwd\":\"$LIVE_DIR\",\"agent\":{},\"agent_status\":\"idle\"}]}}" > "$PANES_FILE"
printf 'live\n' > "$TMP_ROOT/agent-state"
out=$(run_sweep)
[ -z "$out" ] || fail "a live registered agent was flagged: $out"
pass "an untracked pane with a live registered agent is never flagged"

reset_fixture
: > "$TMP_ROOT/etimes_unset"
printf '9999\n' > "$TMP_ROOT/etimes"
export FM_ORPHAN_PANE_IDLE_SECONDS=3600
out=$(run_sweep)
case "$out" in
  *"reason=idle-untracked"*) ;;
  *) fail "long-idle untracked shell was not flagged: $out" ;;
esac
pass "an untracked, agent-less pane idle past the threshold is flagged idle-untracked"

reset_fixture
printf '10\n' > "$TMP_ROOT/etimes"
out=$(run_sweep)
[ -z "$out" ] || fail "a freshly idle untracked shell was flagged too early: $out"
pass "an untracked, agent-less pane under the idle threshold is left alone"
unset FM_ORPHAN_PANE_IDLE_SECONDS

reset_fixture
: > "$TMP_ROOT/no-idle-pid"
printf '%s\n' "{\"result\":{\"panes\":[{\"pane_id\":\"w1:p1\",\"cwd\":\"$LIVE_DIR\",\"foreground_cwd\":\"$LIVE_DIR\"}]}}" > "$PANES_FILE"
out=$(run_sweep)
[ -z "$out" ] || fail "a pane with no provable idle shell was flagged: $out"
pass "a pane whose idle-shell proof fails is left alone rather than guessed at"

reset_fixture
printf '%s\n' "{\"result\":{\"panes\":[{\"pane_id\":\"w1:p1\",\"cwd\":\"$MISSING_DIR\",\"foreground_cwd\":\"$MISSING_DIR\"}]}}" > "$PANES_FILE"
fm_orphan_sweep_treehouse_slot() { printf '7\tavailable'; }
out=$(run_sweep)
case "$out" in
  *"slot=7 slot_status=available"*) ;;
  *) fail "treehouse slot enrichment was missing from a flagged line: $out" ;;
esac
pass "a flagged pane is enriched with its matching treehouse pool slot when one exists"
unset -f fm_orphan_sweep_treehouse_slot

PATH_NO_HERDR="$TMP_ROOT/no-herdr-path"
mkdir -p "$PATH_NO_HERDR"
reset_fixture
printf '%s\n' "{\"result\":{\"panes\":[{\"pane_id\":\"w1:p1\",\"cwd\":\"$MISSING_DIR\",\"foreground_cwd\":\"$MISSING_DIR\"}]}}" > "$PANES_FILE"
out=$(PATH="$PATH_NO_HERDR" run_sweep)
[ -z "$out" ] || fail "sweep ran without herdr on PATH: $out"
pass "the sweep is silent and fail-open when herdr is unavailable"

reset_fixture
printf '%s\n' "{\"result\":{\"panes\":[{\"pane_id\":\"w1:p1\",\"cwd\":\"$MISSING_DIR\",\"foreground_cwd\":\"$MISSING_DIR\"}]}}" > "$PANES_FILE"
CLI_CALL_LOG="$TMP_ROOT/cli-calls.log"
: > "$CLI_CALL_LOG"
fm_backend_name() { printf tmux; }
fm_backend_herdr_cli() {
  printf '%s\n' "$*" >> "$CLI_CALL_LOG"
  return 1
}
out=$(run_sweep)
[ -z "$out" ] || fail "a tmux-backend home was flagged: $out"
[ ! -s "$CLI_CALL_LOG" ] || fail "a tmux-backend home with no herdr task metadata still called the herdr CLI: $(cat "$CLI_CALL_LOG")"
pass "a home whose backend is not herdr, with no herdr task on record, never touches the herdr CLI"
fm_backend_name() { printf herdr; }

printf 'all fm-orphan-pane-sweep tests passed\n'
