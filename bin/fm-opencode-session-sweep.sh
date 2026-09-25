#!/usr/bin/env bash
# One-time owner-run sweep for state/<id>.opencode-session files left behind by
# tasks torn down before fm-teardown.sh started removing that file on close
# (data/task-system-architecture-audit/report.md section 7, fix #1). Teardown
# now cleans up its own task's session file on every close, so this sweep only
# clears the pre-existing backlog of orphans; it is not meant to run on a
# schedule and is not wired into bootstrap or supervision.
#
# Usage: fm-opencode-session-sweep.sh [--dry-run]
#   --dry-run reports what would be removed and removes nothing.
#
# An orphan is a state/<id>.opencode-session file whose state/<id>.meta is
# absent: fm-teardown.sh always removes a task's own .meta on close
# (fm_backlog_atomic_transition remove, fm-teardown.sh:3533), so a missing
# .meta beside a surviving .opencode-session means the task that owned it is
# already gone and nothing else will ever clean this file up. A session file
# whose .meta still exists belongs to a task that is still tracked (in flight,
# held, or a live secondmate) and is left alone; that task's own eventual
# teardown owns it.
#
# Prints one line per removed (or, under --dry-run, would-remove) candidate:
#   "REMOVED: <id>" or "ORPHAN (dry-run): <id>"
# and nothing when there is nothing to do. Exits 0 unless a candidate could
# not be removed.
set -u

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

DRY_RUN=0

sweep_usage() {
  cat <<'TXT'
Usage: fm-opencode-session-sweep.sh [--dry-run]

Remove every state/<id>.opencode-session file whose state/<id>.meta is
absent: a task record already gone, so this session id can never be cleaned
up any other way. --dry-run reports the candidates and removes nothing. Read
this script's header for the full rule.
TXT
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sweep_usage; exit 0 ;;
    *) printf 'fm-opencode-session-sweep: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

[ -d "$STATE" ] || exit 0

status=0
shopt -s nullglob
for session_file in "$STATE"/*.opencode-session; do
  id=$(basename "$session_file" .opencode-session)
  meta="$STATE/$id.meta"
  [ -e "$meta" ] && continue
  if [ "$DRY_RUN" = 1 ]; then
    printf 'ORPHAN (dry-run): %s\n' "$id"
    continue
  fi
  if rm -f "$session_file"; then
    printf 'REMOVED: %s\n' "$id"
  else
    printf 'fm-opencode-session-sweep: failed to remove %s\n' "$session_file" >&2
    status=1
  fi
done
shopt -u nullglob

exit "$status"
