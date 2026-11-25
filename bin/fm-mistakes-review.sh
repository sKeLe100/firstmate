#!/usr/bin/env bash
# fm-mistakes-review.sh - own the 2-day mistakes-review cadence.
#
# Usage:
#   fm-mistakes-review.sh arm [--in <seconds>]
#   fm-mistakes-review.sh mark [<epoch>]
#   fm-mistakes-review.sh due
#   fm-mistakes-review.sh status
#   fm-mistakes-review.sh --help
#
# The mistakes review is a firstmate procedure (the `mistakes-review` skill)
# that runs at least every 2 days. This helper is the single owner of its
# clock: it records when a pass completed and arms the next one through the
# existing timed-dispatch scheduler (`bin/fm-timed-dispatch.sh`, a durable
# process-event when watch) rather than cron, so the wake survives a firstmate
# restart and names the review.
#
# arm    Arm the next pass. Default target is now + 2 days; `--in <seconds>`
#        overrides it, so `arm --in 60` bootstraps the first pass. The arm goes
#        through `bin/fm-timed-dispatch.sh arm mistakes-review --at @<epoch>`,
#        which wakes firstmate to run the review and never dispatches a worker
#        itself. It rejects a zero delay before cancelling any prior review wake, so a bad
#        request never drops the existing wake; re-arming after a pass replaces
#        the old wake instead of stacking a second or refusing a stale one.
# mark   Record that a pass completed at <epoch> (default: now). This is the
#        transcript-scan cursor the review reads for "since the last pass".
# due    Exit 0 when a pass is due (no completed pass yet, or the recorded pass
#        is at least the interval old), 1 when it is not. A heartbeat or session
#        start that finds it due re-arms a missed pass instead of waiting for a
#        wake that never came.
# status Print the last completed pass, the next due time, and whether the pass
#        is due now.
#
# The pass marker is state/.mistakes-review-last. FM_MISTAKES_REVIEW_NOW
# overrides "now" for the portable regression test; production never sets it.
# FM_MISTAKES_REVIEW_INTERVAL overrides the 2-day interval in seconds, and
# FM_MISTAKES_REVIEW_DISPATCH_BIN overrides the timed-dispatch executable the
# test stubs; both default to production values.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.mistakes-review-last"
DISPATCH_BIN="${FM_MISTAKES_REVIEW_DISPATCH_BIN:-$SCRIPT_DIR/fm-timed-dispatch.sh}"
INTERVAL="${FM_MISTAKES_REVIEW_INTERVAL:-172800}"
TASK=mistakes-review

# The dispatch child must resolve the same home as this caller.
export FM_HOME
[ -z "${FM_ROOT_OVERRIDE:-}" ] || export FM_ROOT_OVERRIDE
[ -z "${FM_STATE_OVERRIDE:-}" ] || export FM_STATE_OVERRIDE

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { awk 'NR == 1 { next } /^set -u$/ { exit } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 2; }

nonneg_int() { case "${1-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

now_epoch() {
  case "${FM_MISTAKES_REVIEW_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_MISTAKES_REVIEW_NOW" ;;
  esac
}

# Print the recorded last-pass epoch, or nothing when no pass has completed.
last_pass() {
  [ -f "$RECORD" ] || return 0
  awk -F '\t' '$1 == "last_pass" { print $2; exit }' "$RECORD" 2>/dev/null
}

cmd_arm() {
  local extra='' base target out prior now
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --in)
        shift
        [ "$#" -gt 0 ] || die "--in needs a number of seconds"
        extra=$1
        shift
        ;;
      --in=*)
        extra=${1#--in=}
        shift
        ;;
      *)
        die "arm takes no positional arguments (got '$1')"
        ;;
    esac
  done
  nonneg_int "$INTERVAL" || die "FM_MISTAKES_REVIEW_INTERVAL must be a whole number of seconds: $INTERVAL"
  base=$INTERVAL
  if [ -n "$extra" ]; then
    nonneg_int "$extra" || die "--in must be a whole number of seconds: $extra"
    [ "$extra" -gt 0 ] || die "--in must be at least 1 second so the wake lands in the future: $extra"
    base=$extra
  fi
  [ "$base" -gt 0 ] || die "the review interval must be at least 1 second: $base"
  [ -x "$DISPATCH_BIN" ] || die "timed-dispatch executable not found or not runnable: $DISPATCH_BIN"
  target=$(( $(now_epoch) + base ))
  # A fired or still-armed review wake leaves its record behind, and timed-dispatch
  # refuses a second arm while that record exists. Retire it first so a re-arm
  # after a pass replaces the schedule instead of failing; nothing armed is fine.
  # Remember its target so a failed arm restores the cadence instead of dropping it.
  prior=$(awk -F= '$1 == "target_epoch" { print $2; exit }' "$STATE/timed-dispatch/dispatch-$TASK.record" 2>/dev/null)
  "$DISPATCH_BIN" cancel "$TASK" >/dev/null 2>&1 || true
  if ! out=$("$DISPATCH_BIN" arm "$TASK" --at "@$target"); then
    now=$(now_epoch)
    case "$prior" in ''|*[!0-9]*) prior=0 ;; esac
    [ "$prior" -gt "$now" ] || prior=$(( now + 60 ))
    if out=$("$DISPATCH_BIN" arm "$TASK" --at "@$prior"); then
      printf '%s\n' "$out"
      die "could not arm the mistakes review wake for $target; restored a wake for $prior"
    fi
    die "could not arm the mistakes review wake for $target and could not restore one: NO review wake remains, run 'fm-mistakes-review.sh arm' again"
  fi
  printf '%s\n' "$out"
  printf 'review: mistakes review armed for %s\n' "$target"
}

cmd_mark() {
  local epoch tmp
  if [ "$#" -gt 1 ]; then usage; fi
  if [ "$#" -eq 1 ]; then
    nonneg_int "$1" || die "mark epoch must be a whole number of seconds: $1"
    epoch=$1
  else
    epoch=$(now_epoch)
  fi
  mkdir -p "$STATE" || die "could not create the state directory: $STATE"
  tmp="$RECORD.${BASHPID:-$$}"
  printf 'schema\tfm-mistakes-review-v1\nlast_pass\t%s\n' "$epoch" > "$tmp" \
    || die "could not write the pass marker: $tmp"
  mv -f "$tmp" "$RECORD" || die "could not publish the pass marker: $RECORD"
  printf 'marked: mistakes review pass completed at %s\n' "$epoch"
}

cmd_due() {
  local now last
  nonneg_int "$INTERVAL" || die "FM_MISTAKES_REVIEW_INTERVAL must be a whole number of seconds: $INTERVAL"
  now=$(now_epoch)
  last=$(last_pass)
  case "$last" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ $(( now - last )) -ge "$INTERVAL" ]
}

cmd_status() {
  local now last next
  now=$(now_epoch)
  last=$(last_pass)
  case "$last" in
    ''|*[!0-9]*)
      printf 'last_pass: none\n'
      printf 'next_due: now (no pass recorded)\n'
      printf 'due: yes\n'
      return 0
      ;;
  esac
  next=$(( last + INTERVAL ))
  printf 'last_pass: %s\n' "$last"
  printf 'next_due: %s\n' "$next"
  if [ "$now" -ge "$next" ]; then
    printf 'due: yes\n'
  else
    printf 'due: no\n'
  fi
}

[ "$#" -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  arm) cmd_arm "$@" ;;
  mark) cmd_mark "$@" ;;
  due) cmd_due "$@" ;;
  status) cmd_status "$@" ;;
  --help|-h|help) usage ;;
  *) die "unknown command: $cmd" ;;
esac
