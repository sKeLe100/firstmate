#!/usr/bin/env bash
# Enumerate this home's registered secondmates for an internal /stow cascade.
# Usage: fm-stow-cascade.sh [--complete] [--help]
#
# The durable stow-completion marker (state/.stow-last-run) means this home's
# own /stow pass finished; secondmate stows may still be running in the
# background. The enumeration run stamps it after this home's own pass even
# when secondmates exist, so a primary can clear without waiting on them.
#
# --complete stamps the same marker and exits; it is idempotent. When the
# caller is still collecting per-home receipts for secondmate stows it already
# dispatched in the background, --complete waits no longer than
# FM_STOW_CASCADE_RECEIPT_WAIT seconds (default 300, about five minutes) for
# each local home with a live agent to stamp its own marker, returns as soon as
# all of them report, then stamps regardless. It never awaits a direct,
# deferred, or remote home, so an unreachable one cannot extend the bound.
#
# The internal /stow skill owns curation judgement; this command owns only the
# mechanical inputs a cascade needs: which homes exist, what each home's own
# startup-memory accounting says right now, and how the sweep can reach it.
#
# Enumeration comes from data/secondmates.md, the registry that already refuses
# a duplicate id, a duplicate home, and an overlapping home, so each registered
# secondmate is emitted exactly once and no home is accounted twice. A home's
# budget is that home's alone: this command never sums a fleet total, because
# config/startup-memory-budget is a per-home allowance.
#
# Each home is reported as one blank-line-separated key=value stanza:
#   secondmate=<id>
#   placement=local|remote            (host=<alias> on a remote route)
#   home=<path>
#   budget_report=ok|error|timeout    (report lines follow on ok)
#   transport=agent|direct|deferred|unavailable
#   reason=<one line>                 (whenever a step did not complete)
#
# transport says how the sweep reaches that home:
#   agent     - a live secondmate agent owns the home; steer it with
#               bin/fm-send.sh so it sweeps its own uncaptured session
#               knowledge and replies through its marked return channel.
#   direct    - a local home with no live agent; curate its editable memory
#               files in place.
#   deferred  - a remote home with no live agent. There is deliberately no
#               generic remote write path (bin/fm-remote-file.sh put reaches
#               only the handoff outbox), so that home is accounted read-only
#               and curated by its next cascade once its agent is back.
#   unavailable - the home's own accounting did not complete, so no transport
#               conclusion is safe.
#
# Every step that crosses a host, plus each home's own accounting, runs under
# one hard bound (FM_STOW_CASCADE_TIMEOUT seconds, default 60), so a slow or
# unreachable home reports an exception and the sweep continues instead of
# blocking the primary's own /stow. A local endpoint probe reads this host's
# recorded backend in process, like every other caller of that contract.
#
# Secondmate stows themselves are never run or awaited here: the /stow skill
# dispatches them in the background, and the primary's marker is already
# stamped by the enumeration, so a slow secondmate never deadlocks a
# /stow-then-clear.
#
# A secondmate home never cascades: secondmates do not own secondmates, so this
# command reports the empty cascade there rather than reaching for a registry.
#
# Exit status: 0 every home reported cleanly (or there were none); 3 at least
# one home reported an exception and every home was still reported; 1 the
# cascade input itself is unusable; 2 invalid use.
set -u

usage() {
  sed -n '2,65{s/^# \{0,1\}//;p;}' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --complete) MODE=complete ;;
  "") MODE=enumerate ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REGISTRY="$DATA/secondmates.md"
BUDGET_CMD=fm-startup-memory-budget.sh
SUB_HOME_MARKER="${SUB_HOME_MARKER:-.fm-secondmate-home}"

# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

BOUND=${FM_STOW_CASCADE_TIMEOUT:-60}
case "$BOUND" in
  ''|*[!0-9]*) printf 'error: FM_STOW_CASCADE_TIMEOUT must be a positive integer: %s\n' "$BOUND" >&2; exit 2 ;;
esac
[ "$BOUND" -gt 0 ] \
  || { printf 'error: FM_STOW_CASCADE_TIMEOUT must be a positive integer: %s\n' "$BOUND" >&2; exit 2; }

RECEIPT_WAIT=${FM_STOW_CASCADE_RECEIPT_WAIT:-300}
case "$RECEIPT_WAIT" in
  ''|*[!0-9]*) printf 'error: FM_STOW_CASCADE_RECEIPT_WAIT must be a non-negative integer: %s\n' "$RECEIPT_WAIT" >&2; exit 2 ;;
esac

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
emit() { printf '%s\n' "$1"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-stow-cascade.XXXXXX") || exit 1
# shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap.
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
STEP_OUT="$TMP/step.out"

# Run one bounded external step, capturing its stdout for the caller.
# Returns the step's own status, or 124 when the bound was hit.
run_step() {
  local rc=0
  fm_run_timed "$BOUND" "$@" < /dev/null > "$STEP_OUT" 2>/dev/null || rc=$?
  return "$rc"
}

# This home's recorded secondmate endpoint for <id>, if it has one.
meta_for() { # <id>
  local meta="$STATE/$1.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  grep -q '^kind=secondmate$' "$meta" 2>/dev/null || return 1
  printf '%s\n' "$meta"
}

TRANSPORT=
TRANSPORT_REASON=
set_transport() { TRANSPORT=$1; TRANSPORT_REASON=${2:-}; }

# A local home is curated in place when no live agent owns it.
resolve_local_transport() { # <id> <resolved-home>
  local id=$1 home=$2 meta backend target meta_home
  if ! meta=$(meta_for "$id"); then
    set_transport direct 'no recorded endpoint for this home'
    return 0
  fi
  meta_home=$(fm_meta_get "$meta" home)
  if [ -n "$meta_home" ] \
    && [ "$(secondmate_registry_path_key "$meta_home" 2>/dev/null || true)" != "$home" ]; then
    set_transport direct 'recorded endpoint belongs to another home'
    return 0
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
  if [ -z "$target" ]; then
    set_transport direct 'recorded endpoint has no target'
    return 0
  fi
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable')" in
    alive) set_transport agent ;;
    *) set_transport direct 'no live agent on the recorded endpoint' ;;
  esac
}

# A remote home with no live agent is deferred, never direct: this repo has no
# generic remote write path for a home's own memory files.
resolve_remote_transport() { # <id>
  local id=$1 rc=0
  if ! meta_for "$id" >/dev/null; then
    set_transport deferred 'no recorded endpoint and no remote memory write path'
    return 0
  fi
  run_step "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh state "$id" || rc=$?
  if [ "$rc" -eq 124 ]; then
    set_transport deferred "remote endpoint probe exceeded the ${BOUND}s bound"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    set_transport deferred 'remote endpoint probe failed'
    return 0
  fi
  case "$(tail -1 "$STEP_OUT")" in
    alive) set_transport agent ;;
    *) set_transport deferred 'no live agent and no remote memory write path' ;;
  esac
}

# Durable stow-completion evidence. The marker's mtime is the contract other
# tooling anchors on (bin/fm-primary-watchdog.sh waits for it before restarting
# a limit-blocked primary), so it means this home's own /stow pass is done.
# Secondmate stows dispatched in the background may still be running, which is
# exactly the deadlock this marker must not inherit: the enumeration run stamps
# it after this home's own pass even when secondmates were enumerated.
record_stow_completion() {
  mkdir -p "$STATE" 2>/dev/null || return 0
  : >"$STATE/.stow-last-run" 2>/dev/null || true
}

# Bounded wait for secondmate stows the /stow skill dispatched in the
# background. Only a local home with a live agent is observable: it stamps its
# own state/.stow-last-run when its pass finishes. Direct, deferred, and remote
# homes are never awaited, so none can extend the bound. The caller's own
# marker already exists, so this only enriches the receipt and never gates
# clearing.
await_secondmate_stows() {
  local since deadline interval=5 line id home resolved marker pending mtime baseline own
  local -a markers=()
  [ "$RECEIPT_WAIT" -gt 0 ] || return 0
  if [ -e "$FM_HOME/$SUB_HOME_MARKER" ] || [ -L "$FM_HOME/$SUB_HOME_MARKER" ]; then
    return 0
  fi
  [ -e "$REGISTRY" ] || [ -L "$REGISTRY" ] || return 0
  secondmate_registry_validate_bindings "$REGISTRY" secondmate_registry_path_key || return 0
  # This pass's own receipt is the baseline: the enumeration stamped it right
  # before the skill dispatched the background stows, so a secondmate marker at
  # least that new has reported for this pass. Fall back to now when no receipt
  # exists yet.
  since=$(date +%s)
  own="$STATE/.stow-last-run"
  if [ -e "$own" ]; then
    baseline=$(stat -c %Y "$own" 2>/dev/null || stat -f %m "$own" 2>/dev/null || printf '')
    case "$baseline" in ''|*[!0-9]*) baseline= ;; esac
    [ -z "$baseline" ] || since=$baseline
  fi
  deadline=$(( $(date +%s) + RECEIPT_WAIT ))
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    secondmate_registry_parse_line "$line" || continue
    [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
    id=$SECONDMATE_REGISTRY_ID
    home=$SECONDMATE_REGISTRY_HOME
    validate_secondmate_home "$id" "$home" || continue
    resolved=$VALIDATED_HOME
    resolve_local_transport "$id" "$resolved"
    [ "$TRANSPORT" = agent ] || continue
    markers+=("$resolved/state/.stow-last-run")
  done < <(grep '^- ' "$REGISTRY" 2>/dev/null || true)
  [ "${#markers[@]}" -gt 0 ] || return 0
  while :; do
    pending=0
    for marker in "${markers[@]}"; do
      mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null || printf '0')
      case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
      [ "$mtime" -gt "$since" ] || pending=1
    done
    [ "$pending" -eq 0 ] && return 0
    [ "$(date +%s)" -ge "$deadline" ] && return 0
    sleep "$interval"
  done
}

if [ "$MODE" = complete ]; then
  await_secondmate_stows
  record_stow_completion
  exit 0
fi

if [ -e "$FM_HOME/$SUB_HOME_MARKER" ] || [ -L "$FM_HOME/$SUB_HOME_MARKER" ]; then
  emit 'role=secondmate'
  emit 'secondmates=0'
  emit 'reason=a secondmate home stows its own memory only and never cascades'
  record_stow_completion
  exit 0
fi
emit 'role=primary'

if [ ! -e "$REGISTRY" ] && [ ! -L "$REGISTRY" ]; then
  emit 'secondmates=0'
  emit 'exceptions=0'
  emit 'reason=no secondmate registry in this home'
  record_stow_completion
  exit 0
fi
if ! secondmate_registry_validate_bindings "$REGISTRY" secondmate_registry_path_key; then
  die "$SECONDMATE_REGISTRY_ERROR"
fi

grep '^- ' "$REGISTRY" > "$TMP/records" 2>/dev/null || : > "$TMP/records"
total=0
exceptions=0
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  secondmate_registry_parse_line "$line" || die "malformed secondmate registry entry: $line"
  id=$SECONDMATE_REGISTRY_ID
  home=$SECONDMATE_REGISTRY_HOME
  remote=$SECONDMATE_REGISTRY_REMOTE
  host=$SECONDMATE_REGISTRY_HOST
  total=$((total + 1))
  rc=0
  printf '\n'
  emit "secondmate=$id"
  if [ "$remote" -eq 1 ]; then
    emit 'placement=remote'
    emit "host=$host"
    emit "home=$home"
    run_step "$SCRIPT_DIR/fm-on.sh" "$id" "$BUDGET_CMD" report || rc=$?
  else
    emit 'placement=local'
    if ! validate_secondmate_home "$id" "$home"; then
      emit "home=$home"
      emit 'budget_report=error'
      emit 'transport=unavailable'
      emit "reason=$VALIDATION_ERROR"
      exceptions=$((exceptions + 1))
      continue
    fi
    resolved=$VALIDATED_HOME
    emit "home=$resolved"
    # Every FM_*_OVERRIDE is restated so a caller's own override cannot leak
    # this home's memory files into the accounting of another home.
    run_step env \
      FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$resolved" \
      FM_STATE_OVERRIDE="$resolved/state" \
      FM_DATA_OVERRIDE="$resolved/data" \
      FM_CONFIG_OVERRIDE="$resolved/config" \
      "$SCRIPT_DIR/$BUDGET_CMD" report || rc=$?
  fi
  if [ "$rc" -eq 124 ]; then
    emit 'budget_report=timeout'
    emit 'transport=unavailable'
    emit "reason=this home's own accounting exceeded the ${BOUND}s bound"
    exceptions=$((exceptions + 1))
    continue
  fi
  if [ "$rc" -ne 0 ]; then
    emit 'budget_report=error'
    emit 'transport=unavailable'
    emit "reason=this home's own accounting failed"
    exceptions=$((exceptions + 1))
    continue
  fi
  emit 'budget_report=ok'
  cat "$STEP_OUT"
  if [ "$remote" -eq 1 ]; then
    resolve_remote_transport "$id"
  else
    resolve_local_transport "$id" "$resolved"
  fi
  emit "transport=$TRANSPORT"
  [ -z "$TRANSPORT_REASON" ] || emit "reason=$TRANSPORT_REASON"
  case "$TRANSPORT" in agent|direct) ;; *) exceptions=$((exceptions + 1)) ;; esac
done < "$TMP/records"

printf '\n'
emit "secondmates=$total"
emit "exceptions=$exceptions"
# This home's own pass is done; secondmate stows continue in the background.
record_stow_completion
[ "$exceptions" -eq 0 ] || exit 3
exit 0
