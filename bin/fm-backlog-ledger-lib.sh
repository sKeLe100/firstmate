#!/usr/bin/env bash
# fm-backlog-ledger-lib.sh - append-only ledger of backlog transitions.
#
# Storage: data/backlog-ledger.tsv, one line per transition -
#   <epoch>\t<event>\t<task-id>\t<kind>\t<repo>
# epoch is a UTC unix timestamp (date -u +%s).
# event is one of: added, started, done, closed.
# task-id is the tasks-axi task identity.
# kind is the task kind (ship, scout, captain, etc.; resolved from the backlog row).
# repo is the project repo name (resolved from the backlog row, or "-" when
#   the row carries no repo).
#
# This is an append-only file: callers never rewrite or remove rows.
# Concurrent appends are serialized via a mkdir-lockdir mutex at
# data/.backlog-ledger.lock, following the same pattern as
# bin/fm-backlog-routing.sh's ledger_append.
#
# Usage (library): source this file, then call:
#   fm_backlog_ledger_append <event> <data-dir> <task-id>
#   fm_backlog_ledger_append_kind_repo <event> <data-dir> <task-id> <kind> <repo>
# The second variant accepts kind/repo directly (useful for upstream-sync
# where the caller already knows these values).
#
# Exit codes: 0 success, 1 validation error, 2 write/lock failure.
#
# Caller requirements: DATA must be set (to the home's data directory) and
# tasks-axi must be on PATH (for kind/repo resolution when the caller does
# not supply them directly).

FM_BACKLOG_LEDGER_FILE="${FM_BACKLOG_LEDGER_FILE:-$DATA/backlog-ledger.tsv}"
FM_BACKLOG_LEDGER_LOCK="${FM_BACKLOG_LEDGER_LOCK:-$DATA/.backlog-ledger.lock}"

# Sanitize a free-text field so it can never corrupt the TSV shape
# (strip tabs and newlines, preserving everything else).
fm_backlog_ledger_sanitize_field() {
  printf '%s' "$1" | tr '\t\n\r' '   '
}

# Resolve the kind and repo for <task-id> from the backlog row via
# tasks-axi show. Sets FM_LEDGER_KIND and FM_LEDGER_REPO globals.
# Returns 0 on success, 1 if the row is not found or cannot be read.
fm_backlog_ledger_resolve_meta() {  # <task-id>
  local id=$1 show_out kind repo

  show_out=$(tasks-axi show "$id" 2>/dev/null) || return 1
  kind=$(printf '%s\n' "$show_out" | sed -n 's/^  kind: *//p' | head -1)
  repo=$(printf '%s\n' "$show_out" | sed -n 's/^  repo: *//p' | head -1)

  # Normalize empty/placeholder values
  case "$kind" in
    ''|'-') kind='ship' ;;
  esac
  case "$repo" in
    ''|'-') repo='-' ;;
  esac

  FM_LEDGER_KIND="$kind"
  FM_LEDGER_REPO="$repo"
  return 0
}

# Append one transition record to the ledger, resolving kind/repo from the
# backlog row via tasks-axi show.
#   fm_backlog_ledger_append <event> <data-dir> <task-id>
fm_backlog_ledger_append() {  # <event> <data-dir> <task-id>
  local event=$1 data_dir=$2 id=$3
  local kind repo

  # Validate event name
  case "$event" in
    added|started|done|closed) ;;
    *) return 1 ;;
  esac

  # Resolve kind and repo from the backlog row
  if ! fm_backlog_ledger_resolve_meta "$id"; then
    kind="unknown"
    repo="-"
  else
    kind="$FM_LEDGER_KIND"
    repo="$FM_LEDGER_REPO"
  fi

  _fm_backlog_ledger_write "$event" "$data_dir" "$id" "$kind" "$repo"
}

# Append one transition record to the ledger, accepting kind/repo directly
# (avoids a tasks-axi show call).
#   fm_backlog_ledger_append_kind_repo <event> <data-dir> <task-id> <kind> <repo>
fm_backlog_ledger_append_kind_repo() {  # <event> <data-dir> <task-id> <kind> <repo>
  local event=$1 data_dir=$2 id=$3 kind=$4 repo=$5

  # Validate event name
  case "$event" in
    added|started|done|closed) ;;
    *) return 1 ;;
  esac

  _fm_backlog_ledger_write "$event" "$data_dir" "$id" "$kind" "$repo"
}

# Internal: acquire the lock and write one ledger record.
_fm_backlog_ledger_write() {  # <event> <data-dir> <task-id> <kind> <repo>
  local event=$1 data_dir=$2 id=$3 kind=$4 repo=$5

  # Ensure the data directory exists
  mkdir -p "$data_dir" 2>/dev/null || return 2

  # Acquire lock and append atomically
  local lockdir="$data_dir/.backlog-ledger.lock"
  local tries=0
  mkdir -p "$(dirname "$lockdir")" 2>/dev/null || true
  while ! mkdir "$lockdir" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 50 ]; then
      return 2
    fi
    sleep 0.1
  done

  # Append the record
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%s)" "$event" "$id" \
    "$(fm_backlog_ledger_sanitize_field "$kind")" \
    "$(fm_backlog_ledger_sanitize_field "$repo")" \
    >> "$FM_BACKLOG_LEDGER_FILE"

  rmdir "$lockdir" 2>/dev/null || true
  return 0
}
