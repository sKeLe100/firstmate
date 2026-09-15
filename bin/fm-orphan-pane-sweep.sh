#!/usr/bin/env bash
# Bounded, read-only sweep for herdr panes that exist entirely outside
# firstmate's own task tracking - the detection gap that let 6 leaked
# fm-llm-usage-integration test-fixture panes go unnoticed until manually
# found and closed (2026-09-14; two had a cwd pointing at an already-deleted
# /tmp test directory). Detection only: this script never closes, kills, or
# otherwise mutates anything it finds.
#
# Usage: fm-orphan-pane-sweep.sh
#   Prints one line per flagged candidate and exits 0. Silent when clean, or
#   when herdr/jq are unavailable (best-effort, fail-open, like every other
#   bootstrap detect check).
#   Line: "ORPHAN_PANE: session=<s> pane=<id> cwd=<path|missing> reason=<cwd-missing|dead-agent|idle-untracked> title=<terminal-title-or-empty> [slot=<treehouse-slot> slot_status=<status>]"
#
# Scope and false-positive avoidance:
# - Never touches the herdr CLI at all unless this home's resolved backend
#   (fm_backend_name) is herdr, or at least one state/*.meta already records
#   herdr_session=: a tmux (or any other non-herdr) home costs nothing beyond
#   that one local, offline check - never a live herdr-socket round trip.
# - Only the one herdr session fm_backend_herdr_session resolves (HERDR_SESSION,
#   default "default") is inspected, and only this home's own state/*.meta
#   records are read - never a shared endpoint namespace, never another
#   home's work (AGENTS.md section 5).
# - A workspace whose label is this home's own primary/secondmate label
#   (fm_backend_herdr_workspace_label, e.g. "firstmate" or "2ndmate-<id>") is
#   always skipped: it is the home's own container, never a task.
# - A workspace whose label matches the reserved firstmate task-presentation
#   grammar ("<up-to-40-byte-concise-title> \xC2\xB7 p:<22-char-token>", the
#   same shape fm-herdr-session-cleanup.sh parses) is always skipped even when
#   unmatched by this home's own metadata: that grammar is reserved for SOME
#   firstmate home's projected task, and reclaiming an orphaned one is that
#   home's own fm-herdr-session-cleanup.sh's job, not this sweep's guess.
#   Only panes with no such projection grammar at all - out-of-band panes no
#   firstmate home's projection system would ever recognize - are eligible to
#   be flagged, which is exactly the shape the 2026-09-14 leaked test-fixture
#   panes had (spawned by directly calling the herdr backend from a test,
#   bypassing fm-spawn.sh's projection journal).
# - A pane matching this home's own state/*.meta (herdr_session=+herdr_pane_id=)
#   is always skipped.
# - A candidate pane is flagged only on a strong signal: its recorded cwd and
#   foreground_cwd both no longer exist on disk, its registered agent is
#   confirmed dead, or it is a provably idle childless shell with no agent at
#   all and has been running longer than FM_ORPHAN_PANE_IDLE_SECONDS (default
#   3600). A live or merely-idle agent, or a fresh untitled shell, is left
#   alone: false positives are cheap for a report line, expensive for a
#   silent auto-close, so this stays conservative by design (captain-approved
#   scope: detection/reporting only, never automatic teardown).
# - When a flagged pane's cwd matches a treehouse worktree pool slot (queried
#   from FM_ROOT's own pool), the line is enriched with that slot's name and
#   pool status for the operator's next action; treehouse is never treated as
#   an independent flag source, since a pool slot alone cannot tell this home
#   apart from another legitimate one sharing the same project pool.
#
# Environment:
#   FM_ORPHAN_PANE_IDLE_SECONDS  idle-shell threshold in seconds (3600)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source herdr

fm_orphan_sweep_warn() {
  printf 'warning: orphan pane sweep: %s\n' "$*" >&2
}

# A firstmate task-presentation workspace label always has the exact shape
# "<prefix> \xC2\xB7 p:<22-char-token>" (fm_herdr_cleanup_title_token in
# fm-herdr-session-cleanup.sh owns the authoritative parse; this is a
# detection-only membership test, never a mutation input).
fm_orphan_sweep_is_projection_label() { # <label>
  local label=$1 token rest
  case "$label" in
    *' · p:'*) ;;
    *) return 1 ;;
  esac
  token=${label##*' · p:'}
  [ "${#token}" -eq 22 ] || return 1
  case "$token" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  rest=${label#*p:}
  [ "$rest" != "$label" ] || return 1
  case "$rest" in *p:*) return 1 ;; esac
  return 0
}

fm_orphan_sweep_known_panes() { # <session>
  local session=$1 meta msession mpane
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    msession=$(sed -n 's/^herdr_session=//p' "$meta" | tail -1)
    mpane=$(sed -n 's/^herdr_pane_id=//p' "$meta" | tail -1)
    [ "$msession" = "$session" ] && [ -n "$mpane" ] && printf '%s\n' "$mpane"
  done
}

fm_orphan_sweep_pane_known() { # <pane_id> <known-panes-newline-list>
  local pane_id=$1 known=$2
  case "$known" in
    "$pane_id"|"$pane_id"$'\n'*|*$'\n'"$pane_id"|*$'\n'"$pane_id"$'\n'*) return 0 ;;
  esac
  return 1
}

# Cheap, local-only guard mirroring fm-herdr-session-cleanup.sh's own pattern
# (check a local signal before ever touching the herdr CLI): only worth a live
# herdr call when this home's config actually selects herdr, or it already
# has at least one task recorded against herdr. A tmux (or any other
# non-herdr) home never shells out to `herdr` at all, so this sweep cannot
# add herdr-socket latency to backends that never use it.
fm_orphan_sweep_backend_active() {
  local backend meta
  backend=$(fm_backend_name 2>/dev/null) || backend=
  [ "$backend" = herdr ] && return 0
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    grep -q '^herdr_session=' "$meta" 2>/dev/null && return 0
  done
  return 1
}

fm_orphan_sweep_treehouse_slot() { # <path>
  local path=$1 slot_json
  command -v treehouse >/dev/null 2>&1 || return 1
  slot_json=$(treehouse status --json --root "$FM_ROOT" 2>/dev/null) || return 1
  printf '%s' "$slot_json" | jq -er --arg path "$path" '
    [.[]? | select(.path == $path)] | if length == 1 then .[0] | [.name, .status] | @tsv else empty end
  ' 2>/dev/null
}

fm_orphan_sweep_pane_reason() { # <session> <pane_id> <cwd> <foreground_cwd> <has_agent>
  local session=$1 pane_id=$2 cwd=$3 fg_cwd=$4 has_agent=$5 state idle_pid etimes idle_seconds
  if { [ -z "$cwd" ] || [ ! -d "$cwd" ]; } && { [ -z "$fg_cwd" ] || [ ! -d "$fg_cwd" ]; }; then
    printf 'cwd-missing'
    return 0
  fi
  if [ "$has_agent" = 1 ]; then
    state=$(fm_backend_herdr_pane_agent_state "$session" "$pane_id" 2>/dev/null)
    [ "$state" = dead ] && printf 'dead-agent'
    return 0
  fi
  idle_pid=$(fm_backend_herdr_pane_idle_shell_pid "$session" "$pane_id" 2>/dev/null) || return 0
  [ -n "$idle_pid" ] || return 0
  idle_seconds=${FM_ORPHAN_PANE_IDLE_SECONDS:-3600}
  case "$idle_seconds" in ''|*[!0-9]*) idle_seconds=3600 ;; esac
  etimes=$(ps -o etimes= -p "$idle_pid" 2>/dev/null | tr -d '[:space:]')
  case "$etimes" in ''|*[!0-9]*) return 0 ;; esac
  [ "$etimes" -ge "$idle_seconds" ] && printf 'idle-untracked'
  return 0
}

fm_orphan_pane_sweep() {
  local session home_label known_panes list workspaces workspace label
  local panes pane_id cwd fg_cwd has_agent title reason slot
  command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
  fm_orphan_sweep_backend_active || return 0
  session=$(fm_backend_herdr_session)
  home_label=$(fm_backend_herdr_workspace_label 2>/dev/null) || home_label=firstmate
  known_panes=$(fm_orphan_sweep_known_panes "$session")
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || {
    fm_orphan_sweep_warn "session '$session' workspace discovery failed"
    return 0
  }
  workspaces=$(printf '%s' "$list" | jq -er '
    .result.workspaces
    | select(type == "array")
    | .[]
    | select((.workspace_id | type) == "string" and (.workspace_id | length) > 0)
    | select((.label | type) == "string")
    | [.workspace_id, .label] | @tsv
  ' 2>/dev/null) || return 0
  while IFS=$'\t' read -r workspace label; do
    [ -n "$workspace" ] || continue
    [ "$label" != "$home_label" ] || continue
    fm_orphan_sweep_is_projection_label "$label" && continue
    panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$workspace" 2>/dev/null) || continue
    while IFS=$'\t' read -r pane_id cwd fg_cwd has_agent title; do
      [ -n "$pane_id" ] || continue
      fm_orphan_sweep_pane_known "$pane_id" "$known_panes" && continue
      reason=$(fm_orphan_sweep_pane_reason "$session" "$pane_id" "$cwd" "$fg_cwd" "$has_agent")
      [ -n "$reason" ] || continue
      slot=$(fm_orphan_sweep_treehouse_slot "$cwd" 2>/dev/null) || slot=
      if [ -n "$slot" ]; then
        printf 'ORPHAN_PANE: session=%s pane=%s cwd=%s reason=%s title=%s slot=%s slot_status=%s\n' \
          "$session" "$pane_id" "${cwd:-missing}" "$reason" "${title:-}" \
          "${slot%%$'\t'*}" "${slot#*$'\t'}"
      else
        printf 'ORPHAN_PANE: session=%s pane=%s cwd=%s reason=%s title=%s\n' \
          "$session" "$pane_id" "${cwd:-missing}" "$reason" "${title:-}"
      fi
    done < <(printf '%s' "$panes" | jq -r '
      .result.panes[]? | [
        .pane_id,
        (.cwd // ""),
        (.foreground_cwd // ""),
        (if .agent then "1" else "0" end),
        ((.terminal_title_stripped // "") | gsub("[\t\n]"; " "))
      ] | @tsv
    ' 2>/dev/null)
  done <<< "$workspaces"
  return 0
}

if [ "${FM_ORPHAN_PANE_SWEEP_SOURCE_ONLY:-0}" != 1 ]; then
  fm_orphan_pane_sweep
  exit 0
fi
