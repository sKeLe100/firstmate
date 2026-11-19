#!/usr/bin/env bash
# Start or reconnect to the primary Firstmate in one named Herdr session.
#
# Usage:
#   fm-primary-herdr.sh normal [--no-attach] [--boot]
#   fm-primary-herdr.sh emergency [--no-attach]
#   fm-primary-herdr.sh server
#   fm-primary-herdr.sh status
#
# normal starts Claude as the ordinary primary.
# normal --boot additionally reconciles a stale or unknown recorded endpoint
# after proving no live primary is rooted in any running Herdr session, then
# clears the record and creates a fresh primary. Every other mode keeps the
# conservative refusals unchanged.
# emergency starts Codex only when no live primary owns this home.
# server starts only the named Herdr server, for a boot/login service.
# status performs no mutation and reports the durable primary record, lock,
# and live Herdr agent verdict.
#
# This command is the startup owner for the primary agent only.
# Persistent secondmates remain owned by fm-spawn.sh --secondmate and the
# locked session-start recovery sweep; this command never launches one itself.
#
# Safety contract:
# - FM_HOME identifies the one primary home; it defaults to this tracked root.
# - This primary-only launcher requires canonical FM_HOME and FM_ROOT to match.
# - The primary Herdr session comes from config/herdr-session and defaults to
#   default. --boot always uses that setting; normal and emergency let
#   HERDR_SESSION override it for one explicit attended launch.
# - state/.primary-herdr records response-derived endpoint ids and the selected
#   primary harness. Labels are presentation only and never authorize reuse.
# - state/.primary-launch.lock serializes normal, emergency, and boot starts.
# - A live session lock held by another harness refuses a role change.
# - A live or unreadable recorded Herdr endpoint refuses duplicate launch.
# - A confirmed no-agent husk may be relaunched in its recorded pane.
# - A missing recorded pane permits a fresh primary workspace.
# - --boot reconciles only when no live primary lock exists and the recorded
#   endpoint is unknown or invalid, and only after proving zero live agents
#   rooted at this home across every running Herdr session.
# - A Claude primary launch pins the orchestrator account named by
#   config/claude-orchestrator-account when that file is present; it never
#   reads config/claude-account, which pins workers.
# - Success is reported only after the new harness owns state/.lock and the
#   matching state/.session-start-complete record exists.
# - Codex interactive TUI has no native SessionStart transport, so emergency
#   mode supplies the exact session-start requirement as its initial prompt.
#
# Environment:
#   FM_HOME                         primary operational home
#   FM_ROOT_OVERRIDE                tracked Firstmate code root
#   HERDR_SESSION                   named Herdr session override (non-boot)
#   FM_PRIMARY_CODEX_MODEL          emergency model (gpt-5.6-luna)
#   FM_PRIMARY_CODEX_EFFORT         emergency effort (low|medium|high|xhigh)
#   FM_PRIMARY_READY_TIMEOUT        seconds to await startup proof (120)
#   FM_PRIMARY_HERDR_START_TIMEOUT  Herdr agent readiness milliseconds (90000)
#
# config/claude-remote-control (docs/configuration.md "Claude Remote
# Control") registers a claude-mode primary as "firstmate-primary" in the
# Claude Code app's session list; absent or "off" launches unchanged.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RECORD="$STATE/.primary-herdr"
START_LOCK="$STATE/.primary-launch.lock"
MODE=${1:-}
ATTACH=1
BOOT=0

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "$MODE" in
  -h|--help) usage; exit 0 ;;
  normal|emergency|server|status) ;;
  *) usage >&2; exit 2 ;;
esac
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-attach) ATTACH=0 ;;
    --boot) BOOT=1 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[ "$MODE" = normal ] || [ "$MODE" = emergency ] || [ "$ATTACH" -eq 1 ] \
  || { echo "error: --no-attach applies only to normal or emergency" >&2; exit 2; }
[ "$BOOT" -eq 0 ] || [ "$MODE" = normal ] \
  || { echo "error: --boot applies only to normal" >&2; exit 2; }

[ -d "$FM_HOME" ] && [ ! -L "$FM_HOME" ] \
  || { echo "error: primary home is unavailable or unsafe: $FM_HOME" >&2; exit 1; }
[ -f "$FM_ROOT/AGENTS.md" ] && [ -x "$FM_ROOT/bin/fm-session-start.sh" ] \
  || { echo "error: tracked Firstmate root is incomplete: $FM_ROOT" >&2; exit 1; }
CANONICAL_ROOT=$(cd "$FM_ROOT" 2>/dev/null && pwd -P) || { echo "error: tracked Firstmate root is unavailable: $FM_ROOT" >&2; exit 1; }
CANONICAL_HOME=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || { echo "error: primary home is unavailable: $FM_HOME" >&2; exit 1; }
[ "$CANONICAL_HOME" = "$CANONICAL_ROOT" ] \
  || { echo "error: primary launcher requires FM_HOME and FM_ROOT to be the same canonical directory" >&2; exit 1; }

# config/herdr-session (docs/configuration.md "Primary Herdr session"):
# names the one Herdr session this launcher uses, defaulting to default so the
# orchestrator follows the same session as its workers. --boot always honors
# the setting; an attended normal or emergency run may name another session
# through HERDR_SESSION for a one-off launch.
primary_session() {
  local setting="$CONFIG/herdr-session" configured=default
  if [ -e "$setting" ]; then
    if [ ! -f "$setting" ] || [ ! -r "$setting" ]; then
      echo "error: config/herdr-session must be a readable regular file holding one Herdr session name" >&2
      return 1
    fi
    configured=$(cat "$setting") || configured=
    case "$configured" in
      ''|*[!A-Za-z0-9._-]*)
        echo "error: config/herdr-session must hold one Herdr session name using only letters, digits, dot, underscore, or dash" >&2
        return 1
        ;;
    esac
    [ "$(printf '%s\n' "$configured" | wc -l)" -eq 1 ] \
      || { echo "error: config/herdr-session must hold exactly one Herdr session name" >&2; return 1; }
  fi
  if [ "$BOOT" -eq 1 ]; then
    printf '%s\n' "$configured"
  else
    printf '%s\n' "${HERDR_SESSION:-$configured}"
  fi
}
SESSION=$(primary_session) || exit 1

# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/backends/herdr.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-worker-account-lib.sh"

# config/claude-remote-control (docs/configuration.md "Claude Remote
# Control"): same fail-closed on/off contract as bin/fm-spawn.sh, resolved
# once per launch so a malformed file refuses instead of launching silently
# without the app-visibility the captain configured.
if ! CLAUDE_RC_PRESENT=$(fm_config_source_present "$CONFIG/claude-remote-control"); then
  exit 1
fi
CLAUDE_REMOTE_CONTROL=off
if [ "$CLAUDE_RC_PRESENT" = 1 ]; then
  if [ ! -f "$CONFIG/claude-remote-control" ] || [ ! -r "$CONFIG/claude-remote-control" ]; then
    echo "error: config/claude-remote-control must be a readable regular file holding one of: on, off" >&2
    exit 1
  fi
  CLAUDE_REMOTE_CONTROL=$(tr -d '[:space:]' < "$CONFIG/claude-remote-control" || true)
  case "$CLAUDE_REMOTE_CONTROL" in
    on|off) ;;
    *)
      echo "error: config/claude-remote-control holds '$CLAUDE_REMOTE_CONTROL'; accepted values are: on, off (the default when the file is absent)" >&2
      exit 1
      ;;
  esac
fi

record_value() { sed -n "s/^$1=//p" "$RECORD" 2>/dev/null | tail -1; }

pid_harness() { # <pid>
  local pid=$1 comm args base path_name
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  fm_harness_process_matches "$comm" "$args" || return 1
  base=$(basename -- "$comm")
  case "$base" in
    *claude*) printf 'claude'; return 0 ;;
    codex) printf 'codex'; return 0 ;;
  esac
  path_name=$(fm_harness_path_name "$comm" 2>/dev/null || fm_harness_path_name "${args%% *}" 2>/dev/null || true)
  case "$path_name" in claude|codex) printf '%s' "$path_name"; return 0 ;; esac
  return 1
}

lock_state() {
  local pid harness
  pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) printf 'free\t\t'; return 0 ;; esac
  if fm_harness_pid_alive "$pid"; then
    harness=$(pid_harness "$pid" 2>/dev/null || printf unknown)
    printf 'live\t%s\t%s' "$pid" "$harness"
  else
    printf 'stale\t%s\t' "$pid"
  fi
}

endpoint_state() {
  local version record_session workspace tab pane harness state identity
  if [ ! -f "$RECORD" ] || [ -L "$RECORD" ]; then
    printf 'absent\t\t'
    return 0
  fi
  version=$(record_value version)
  record_session=$(record_value session)
  workspace=$(record_value workspace)
  tab=$(record_value tab)
  pane=$(record_value pane)
  harness=$(record_value harness)
  if [ "$version" = 1 ] && [ "$record_session" = "$SESSION" ] \
    && [ -n "$workspace" ] && [ -n "$tab" ] && [ -n "$pane" ]; then
    case "$harness" in
      claude|codex) ;;
      *) printf 'invalid\t%s\t%s' "$pane" "$harness"; return 0 ;;
    esac
  else
    printf 'invalid\t%s\t%s' "$pane" "$harness"
    return 0
  fi
  state=$(fm_backend_herdr_pane_agent_state "$SESSION" "$pane")
  if [ "$state" = live ]; then
    identity=$(fm_backend_herdr_agent_identity_raw "$SESSION" "$pane" 2>/dev/null | cut -f1)
    [ -n "$identity" ] || identity=unknown
    printf 'live\t%s\t%s' "$pane" "$identity"
  else
    printf '%s\t%s\t%s' "$state" "$pane" "$harness"
  fi
}

rooted_primary_count_in_session() { # <session>
  local out count
  out=$(fm_backend_herdr_cli "$1" agent list 2>/dev/null) || return 1
  count=$(jq -r --arg home "$CANONICAL_HOME" '
    if (.result.agents | type) != "array" then
      error("invalid agent inventory")
    else
      [.result.agents[] | select(.cwd == $home or .foreground_cwd == $home)] | length
    end
  ' <<<"$out") || return 1
  case "$count" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$count"
}

rooted_primary_count() {
  rooted_primary_count_in_session "$SESSION"
}

# rooted_primary_count_all_sessions: live agents rooted at this primary home in
# every running Herdr session. Boot reconcile uses this to prove no primary is
# alive anywhere before it clears a stale record; an unreadable inventory
# fails closed rather than risking a duplicate primary.
rooted_primary_count_all_sessions() {
  local list sessions session count total=0
  list=$(fm_backend_herdr_cli "$SESSION" session list --json 2>/dev/null) || return 1
  sessions=$(jq -r '
    if (.sessions | type) != "array" then
      error("invalid sessions inventory")
    else
      .sessions[] | select(.running == true) | .name
    end
  ' <<<"$list") || return 1
  [ -n "$sessions" ] || { printf '0'; return 0; }
  while IFS= read -r session; do
    [ -n "$session" ] || return 1
    count=$(rooted_primary_count_in_session "$session") || return 1
    total=$((total + count))
  done <<<"$sessions"
  printf '%s' "$total"
}

primary_workspace_count() {
  local label list count
  label=$(fm_backend_herdr_workspace_label) || return 1
  list=$(fm_backend_herdr_cli "$SESSION" workspace list 2>/dev/null) || return 1
  count=$(jq -r --arg want "$label" '
    if (.result.workspaces | type) != "array" then
      error("invalid workspace inventory")
    else
      [.result.workspaces[] | select(.label == $want)] | length
    end
  ' <<<"$list") || return 1
  case "$count" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$count"
}

verify_recorded_endpoint() {
  local workspace=$1 tab=$2 pane=$3 label list workspace_id tab_out pane_out
  label=$(fm_backend_herdr_workspace_label) || return 1
  list=$(fm_backend_herdr_cli "$SESSION" workspace list 2>/dev/null) || return 1
  workspace_id=$(jq -r --arg want "$label" '
    if (.result.workspaces | type) != "array" then
      error("invalid workspace inventory")
    else
      [.result.workspaces[] | select(.label == $want and (.workspace_id | type) == "string" and (.workspace_id | length) > 0)]
      | if length == 1 then .[0].workspace_id else error("ambiguous workspace inventory") end
    end
  ' <<<"$list") || return 1
  [ "$workspace_id" = "$workspace" ] || return 1
  tab_out=$(fm_backend_herdr_cli "$SESSION" tab get "$tab" 2>/dev/null) || return 1
  jq -e --arg tab "$tab" --arg workspace "$workspace" '
    .result.tab.tab_id == $tab and .result.tab.workspace_id == $workspace
  ' <<<"$tab_out" >/dev/null 2>&1 || return 1
  pane_out=$(fm_backend_herdr_cli "$SESSION" pane get "$pane" 2>/dev/null) || return 1
  jq -e --arg pane "$pane" --arg tab "$tab" --arg workspace "$workspace" '
    .result.pane.pane_id == $pane
    and .result.pane.tab_id == $tab
    and .result.pane.workspace_id == $workspace
  ' <<<"$pane_out" >/dev/null 2>&1
}

validate_positive_integer() {
  case "$2" in
    ''|*[!0-9]*) echo "error: $1 must be a positive integer" >&2; exit 1 ;;
  esac
  [ "$2" -gt 0 ] || { echo "error: $1 must be positive" >&2; exit 1; }
}

write_primary_record() {
  local tmp
  tmp=$(mktemp "$STATE/.primary-herdr.XXXXXX")
  {
    printf 'version=1\n'
    printf 'session=%s\n' "$SESSION"
    printf 'workspace=%s\n' "$WORKSPACE"
    printf 'tab=%s\n' "$TAB"
    printf 'pane=%s\n' "$PANE"
    printf 'harness=%s\n' "$REQUESTED"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$RECORD"
}

create_primary_workspace() {
  local create
  create=$(fm_backend_herdr_cli "$SESSION" workspace create --cwd "$FM_ROOT" --label firstmate --no-focus)
  WORKSPACE=$(jq -er '.result.workspace.workspace_id | select(type == "string" and length > 0)' <<<"$create")
  TAB=$(jq -er '.result.tab.tab_id | select(type == "string" and length > 0)' <<<"$create")
  PANE=$(jq -er '.result.root_pane.pane_id | select(type == "string" and length > 0)' <<<"$create")
}

# reconcile_stale_primary_on_boot: the one boot-only relaxation of the
# duplicate-launch refusal. It runs only when no live primary lock exists and
# the recorded endpoint is unknown or invalid, and only after proving zero
# live agents are rooted at this home across every running Herdr session. Any
# unreadable inventory or a single live rooted primary refuses instead, so a
# boot can never create a second primary beside a live one.
reconcile_stale_primary_on_boot() {
  local count
  count=$(rooted_primary_count_all_sessions) || {
    echo "error: Herdr primary-agent discovery across all running sessions was unreadable; refusing boot reconcile" >&2
    return 1
  }
  case "$count" in
    ''|*[!0-9]*) echo "error: Herdr primary-agent discovery across all running sessions was unreadable; refusing boot reconcile" >&2; return 1 ;;
  esac
  [ "$count" -eq 0 ] || {
    echo "error: Herdr reports $count live agent(s) rooted at the primary home in a running session; refusing boot reconcile" >&2
    return 1
  }
  rm -f -- "$RECORD" || {
    echo "error: could not clear the stale primary endpoint record: $RECORD" >&2
    return 1
  }
  echo "primary record reconciled: cleared stale endpoint record and creating a fresh primary"
}

report_status() {
  local ls es
  ls=$(lock_state)
  es=$(endpoint_state)
  printf 'home=%s session=%s lock=%s endpoint=%s\n' "$FM_HOME" "$SESSION" "${ls//$'\t'/,}" "${es//$'\t'/,}"
}

if [ "$MODE" = status ]; then
  report_status
  exit 0
fi

# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
mkdir -p "$STATE"

START_TIMEOUT=${FM_PRIMARY_HERDR_START_TIMEOUT:-90000}
READY_TIMEOUT=${FM_PRIMARY_READY_TIMEOUT:-120}
validate_positive_integer FM_PRIMARY_HERDR_START_TIMEOUT "$START_TIMEOUT"
validate_positive_integer FM_PRIMARY_READY_TIMEOUT "$READY_TIMEOUT"
MODEL=${FM_PRIMARY_CODEX_MODEL:-gpt-5.6-luna}
EFFORT=${FM_PRIMARY_CODEX_EFFORT:-low}
if [ "$MODE" = emergency ]; then
  [ -n "$MODEL" ] || { echo "error: FM_PRIMARY_CODEX_MODEL must not be empty" >&2; exit 1; }
  case "$EFFORT" in low|medium|high|xhigh) ;; *) echo "error: invalid Codex effort: $EFFORT" >&2; exit 1 ;; esac
fi

if ! fm_lock_try_acquire "$START_LOCK"; then
  echo "error: another primary startup is already in progress for $FM_HOME" >&2
  exit 1
fi
release_start_lock() { fm_lock_release "$START_LOCK"; }
trap release_start_lock EXIT
trap 'exit 1' HUP INT TERM

fm_backend_herdr_version_check
fm_backend_herdr_server_ensure "$SESSION"

if [ "$MODE" = server ]; then
  echo "primary server ready: session=$SESSION"
  exit 0
fi

REQUESTED=claude
[ "$MODE" = emergency ] && REQUESTED=codex
ORCHESTRATOR_ROOT=
if [ "$REQUESTED" = claude ]; then
  # config/claude-orchestrator-account names the orchestrator account. It is
  # deliberately never config/claude-account, which pins workers away from it.
  ORCHESTRATOR_ROOT=$(fm_worker_account_orchestrator_root "$CONFIG") || exit 1
  if [ -n "$ORCHESTRATOR_ROOT" ] && { [ ! -d "$ORCHESTRATOR_ROOT" ] || [ ! -r "$ORCHESTRATOR_ROOT" ]; }; then
    echo "error: config/claude-orchestrator-account names $ORCHESTRATOR_ROOT, which is not a readable directory; sign in with CLAUDE_CONFIG_DIR=$ORCHESTRATOR_ROOT claude, then /login, or fix the file" >&2
    exit 1
  fi
fi

IFS=$'\t' read -r LOCK_KIND LOCK_PID LOCK_HARNESS <<EOF
$(lock_state)
EOF
if [ "$LOCK_KIND" = live ]; then
  if [ "$LOCK_HARNESS" != "$REQUESTED" ]; then
    echo "error: primary home is already owned by live $LOCK_HARNESS pid $LOCK_PID; refusing $REQUESTED startup" >&2
    exit 1
  fi
  IFS=$'\t' read -r ENDPOINT_KIND ENDPOINT_PANE ENDPOINT_HARNESS <<EOF
$(endpoint_state)
EOF
  if [ "$ENDPOINT_KIND" != live ] || [ "$ENDPOINT_HARNESS" != "$REQUESTED" ]; then
    echo "error: the live $REQUESTED primary lock and recorded Herdr endpoint disagree; refusing duplicate startup" >&2
    exit 1
  fi
  if [ "$(cat "$STATE/.session-start-complete" 2>/dev/null || true)" != "$LOCK_PID" ]; then
    echo "error: the live $REQUESTED primary has no matching completed startup record; refusing to report it ready" >&2
    exit 1
  fi
  echo "primary reconnected: harness=$REQUESTED session=$SESSION pane=$ENDPOINT_PANE"
  [ "$ATTACH" -eq 0 ] || exec herdr session attach "$SESSION"
  exit 0
fi

IFS=$'\t' read -r ENDPOINT_KIND ENDPOINT_PANE ENDPOINT_HARNESS <<EOF
$(endpoint_state)
EOF
case "$ENDPOINT_KIND" in
  live)
    echo "error: a live $ENDPOINT_HARNESS primary agent exists without matching lock ownership; refusing duplicate startup" >&2
    exit 1 ;;
  unknown|invalid)
    if [ "$BOOT" -eq 1 ]; then
      reconcile_stale_primary_on_boot || exit 1
      create_primary_workspace
    else
      echo "error: recorded primary endpoint is $ENDPOINT_KIND; refusing startup until its identity is reconciled" >&2
      exit 1
    fi ;;
  no-agent)
    PANE=$ENDPOINT_PANE
    WORKSPACE=$(record_value workspace)
    TAB=$(record_value tab)
    primary_count=$(rooted_primary_count) || {
      echo "error: Herdr primary-agent discovery was unreadable; refusing a potentially duplicate startup" >&2
      exit 1
    }
    [ "$primary_count" -eq 0 ] || {
      echo "error: Herdr already reports $primary_count unrecorded agent(s) rooted at the primary home; refusing duplicate startup" >&2
      exit 1
    }
    verify_recorded_endpoint "$WORKSPACE" "$TAB" "$PANE" || {
      echo "error: recorded Herdr primary endpoint is not the unique, consistent primary endpoint; refusing startup" >&2
      exit 1
    }
    ;;
  dead|absent)
    primary_count=$(rooted_primary_count) || {
      echo "error: Herdr primary-agent discovery was unreadable; refusing a potentially duplicate startup" >&2
      exit 1
    }
    [ "$primary_count" -eq 0 ] || {
      echo "error: Herdr already reports $primary_count unrecorded agent(s) rooted at the primary home; refusing duplicate startup" >&2
      exit 1
    }
    workspace_count=$(primary_workspace_count) || {
      echo "error: Herdr primary-workspace discovery was unreadable; refusing startup" >&2
      exit 1
    }
    [ "$workspace_count" -eq 0 ] || {
      echo "error: Herdr already has $workspace_count unrecorded workspace(s) labeled firstmate; refusing to create a conflicting primary workspace" >&2
      exit 1
    }
    create_primary_workspace
    ;;
  *)
    echo "error: unexpected primary endpoint state: $ENDPOINT_KIND" >&2
    exit 1 ;;
esac

write_primary_record

if [ "$REQUESTED" = claude ]; then
  if [ -n "$ORCHESTRATOR_ROOT" ]; then
    # Herdr starts the agent from the pane's own shell, not from this process,
    # so export the orchestrator account into that shell before the launch.
    fm_backend_herdr_cli "$SESSION" pane run "$PANE" \
      "export CLAUDE_CONFIG_DIR=$(printf '%q' "$ORCHESTRATOR_ROOT"); printf 'fm-pin-%s\\n' \"\$CLAUDE_CONFIG_DIR\"" >/dev/null \
      && fm_backend_herdr_cli "$SESSION" pane wait-output "$PANE" --match "fm-pin-$ORCHESTRATOR_ROOT" --timeout "$((START_TIMEOUT))" >/dev/null \
      || {
        echo "error: could not confirm the orchestrator Claude account in pane $PANE; refusing to launch on an unpinned account" >&2
        exit 1
      }
  fi
  CLAUDE_RC_ARGS=()
  [ "$CLAUDE_REMOTE_CONTROL" != on ] || CLAUDE_RC_ARGS=(--remote-control firstmate-primary)
  fm_backend_herdr_cli "$SESSION" agent start firstmate-primary --kind claude --pane "$PANE" --timeout "$START_TIMEOUT" -- \
    --dangerously-skip-permissions "${CLAUDE_RC_ARGS[@]}"
else
  # shellcheck disable=SC2016
  START_PROMPT='Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions. If another live session owns this home, remain read-only and report that conflict.'
  fm_backend_herdr_cli "$SESSION" agent start firstmate-primary --kind codex --pane "$PANE" --timeout "$START_TIMEOUT" -- \
    --model "$MODEL" -c "model_reasoning_effort=\"$EFFORT\"" \
    --dangerously-bypass-approvals-and-sandbox "$START_PROMPT"
fi

ready=0
i=0
while [ "$i" -lt "$READY_TIMEOUT" ]; do
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  complete_pid=$(cat "$STATE/.session-start-complete" 2>/dev/null || true)
  if [ -n "$lock_pid" ] && [ "$lock_pid" = "$complete_pid" ] \
     && fm_harness_pid_alive "$lock_pid" \
     && [ "$(pid_harness "$lock_pid" 2>/dev/null || true)" = "$REQUESTED" ]; then
    ready=1
    break
  fi
  sleep 1
  i=$((i + 1))
done

if [ "$ready" -ne 1 ]; then
  echo "error: $REQUESTED started in Herdr but did not prove primary-home startup ownership within ${READY_TIMEOUT}s; inspect with: FM_HOME='$FM_HOME' '$0' status" >&2
  exit 1
fi

echo "primary ready: harness=$REQUESTED session=$SESSION pane=$PANE pid=$lock_pid"
[ "$ATTACH" -eq 0 ] || exec herdr session attach "$SESSION"
