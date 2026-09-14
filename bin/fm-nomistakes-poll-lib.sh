#!/usr/bin/env bash
# fm-nomistakes-poll-lib.sh - correct polling for a backgrounded
# `no-mistakes axi run`/`axi respond` drive call.
#
# Why this exists: crewmates hand-rolled `axi status` poll loops that checked
# the top-level `status:` field for anything other than "running" as their
# exit condition. That field reads "running" while a step is ACTIVELY running
# AND while a step is GATED awaiting the driving agent's response - the two
# states an ordinary poll loop must tell apart - so those loops either spun
# forever on a parked gate or exited too early. The real exit condition lives
# in per-step/gate detail: an `outcome:` field (terminal), a top-level
# `status`/`state` of `awaiting_approval`/`fix_review`, an `awaiting_agent:`
# line, a step row whose own status is `awaiting_approval`/`fix_review`, or a
# `gate:` block. Confirmed against three independent 2026-09-08 incidents
# (data/learnings.md) and the installed CLI's real TOON shape.
#
# Two subcommands:
#   classify              reads one `axi status` TOON blob from stdin, prints
#                          exactly one of: no-run | running | gate | outcome:<word>
#                          (no-run: no top-level `run:` object, which is what
#                          `axi status` without --run emits when the current
#                          branch has no run - whatever its recent-runs table
#                          lists - so a dead drive call is never polled forever;
#                          `wait` tolerates it for two intervals after start so
#                          a just-backgrounded drive call the daemon has not yet
#                          registered is not refused on the first poll)
#   wait [--dir DIR] [--interval SECS] [--max SECS]
#                          polls `no-mistakes axi status` in DIR (default:
#                          cwd) every INTERVAL seconds (default 20) until
#                          classify returns gate or outcome:*, or MAX seconds
#                          (default 480, matching axi run/respond's own
#                          default --wait) elapse. Prints the last TOON to
#                          stdout, then a final `FM_NMPOLL_RESULT=<result>`
#                          line to stderr.
#
# This is a single bounded call, not an unbounded background loop: `wait`
# returns well inside a 10-minute harness command cap (480s default + one
# interval) so a Bash-tool call never gets killed mid-loop. When it returns
# with FM_NMPOLL_RESULT=running (the max elapsed with no gate/outcome yet),
# call `wait` again - this mirrors the background-drive-call-then-poll shape
# already given to no-mistakes workers.
#
# Caveat - branches with a prior finished run: `axi status` without --run
# reports the branch's ACTIVE-OR-MOST-RECENT run, so if the branch already has
# a finished no-mistakes run and the daemon has not yet registered the NEW
# drive call, the first poll returns the OLD run's `run:` block and its
# terminal `outcome:`, which `wait` reports as this run's result (exit 1).
# Do not rely on `wait` on such a branch until the NEW run's own status/outcome
# actually appears in `axi status` (e.g. confirm run.log shows it registered);
# `wait` does not bind the run to the worktree HEAD.
#
# Exit codes for `wait`: 0 = gate reached, 1 = terminal outcome reached,
# 2 = still running (max elapsed, call again), 3 = usage/lookup error,
# including no current-branch run and a status call that hung past its own
# bound (each status call is itself bounded via fm_nm_run_bounded, and the
# max window counts wall-clock time, not just sleeps).
# A status call exiting 1 with a terminal `outcome:` in its TOON (the CLI's
# documented exit for failed/cancelled final outcomes) is reported as that
# outcome, not as a lookup error.
# Gate/terminal/TOON primitives are owned by bin/fm-nm-run-lib.sh.
# FM_NMPOLL_STATUS_TIMEOUT_OVERRIDE (seconds) is a test-only knob shrinking the
# per-status-call bound (default 30s) so the hung-call path can be exercised.
# Exit codes for `classify`: always 0; the result word is the only signal.
set -u

usage() {
  cat <<'EOF'
Usage:
  fm-nomistakes-poll-lib.sh classify  < axi-status-toon
  fm-nomistakes-poll-lib.sh wait [--dir DIR] [--interval SECS] [--max SECS]

classify reads one `no-mistakes axi status` TOON blob from stdin and prints
exactly one of: no-run, running, gate, outcome:<word>.

wait polls `no-mistakes axi status` in DIR (default: cwd) every INTERVAL
seconds (default 20) until classify returns gate or outcome:*, or MAX seconds
(default 480) elapse. Prints the last TOON to stdout and a final
FM_NMPOLL_RESULT=<result> line to stderr. Exit 0 on gate, 1 on outcome, 2 when
MAX elapsed with no gate/outcome yet (call wait again), 3 on usage error, no
current-branch run after a two-interval grace, or a hung status call.
Caveat: without --run, `axi status` reports the branch's active-or-most-recent
run, so on a branch with a prior finished run the first poll can return the OLD
run's terminal outcome; do not rely on wait there until the NEW run's own
status/outcome appears in `axi status`.
EOF
}

FM_NMPOLL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$FM_NMPOLL_LIB_DIR/fm-nm-run-lib.sh"

FM_NMPOLL_STATUS_TIMEOUT=${FM_NMPOLL_STATUS_TIMEOUT_OVERRIDE:-30}

# classify <toon> - prints no-run | running | gate | outcome:<word>
fm_nmpoll_classify() {
  local toon=$1 outcome status
  if ! printf '%s\n' "$toon" | grep -Eq '^run:[[:space:]]*$'; then
    printf 'no-run'
    return 0
  fi
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$toon" outcome)")
  if [ -n "$outcome" ]; then
    printf 'outcome:%s' "$outcome"
    return 0
  fi
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$toon" status)")
  case "$status" in
    completed|failed|cancelled)
      printf 'outcome:%s' "$status"
      return 0
      ;;
  esac
  if fm_nm_run_is_gated "$toon"; then
    printf 'gate'
    return 0
  fi
  printf 'running'
}

cmd_classify() {
  local toon
  toon=$(cat)
  fm_nmpoll_classify "$toon"
  printf '\n'
}

cmd_wait() {
  local dir="." interval=20 max=480
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) dir=$2; shift 2 ;;
      --interval) interval=$2; shift 2 ;;
      --max) max=$2; shift 2 ;;
      *) printf 'error: unknown argument %s\n' "$1" >&2; usage >&2; return 3 ;;
    esac
  done
  case "$interval" in *[!0-9]*|'') printf 'error: --interval must be a positive integer\n' >&2; return 3 ;; esac
  case "$max" in *[!0-9]*|'') printf 'error: --max must be a positive integer\n' >&2; return 3 ;; esac
  if ! command -v no-mistakes >/dev/null 2>&1; then
    printf 'error: no-mistakes not found on PATH\n' >&2
    return 3
  fi
  [ -d "$dir" ] || { printf 'error: --dir %s is not a directory\n' "$dir" >&2; return 3; }
  local start=$SECONDS toon result rc
  while :; do
    toon=$(fm_nm_run_bounded "$dir" "$FM_NMPOLL_STATUS_TIMEOUT" axi status)
    rc=$?
    result=$(fm_nmpoll_classify "$toon")
    if [ "$rc" -eq 124 ]; then
      printf 'error: no-mistakes axi status timed out after %ss in %s\n' "$FM_NMPOLL_STATUS_TIMEOUT" "$dir" >&2
      return 3
    fi
    if [ "$rc" -ne 0 ]; then
      case "$rc:$result" in
        1:outcome:*) ;;
        *)
          printf '%s\n' "$toon" >&2
          printf 'error: no-mistakes axi status failed (exit %s) in %s\n' "$rc" "$dir" >&2
          return 3
          ;;
      esac
    fi
    case "$result" in
      no-run)
        if [ $((SECONDS - start)) -lt $((interval * 2)) ]; then
          sleep "$interval"
          continue
        fi
        printf '%s\n' "$toon" >&2
        printf 'error: no run for the current branch in %s (axi status returned no run object); the drive call is not registered - check its log\n' "$dir" >&2
        printf 'FM_NMPOLL_RESULT=no-run\n' >&2
        return 3
        ;;
      gate)
        printf '%s\n' "$toon"
        printf 'FM_NMPOLL_RESULT=gate\n' >&2
        return 0
        ;;
      outcome:*)
        printf '%s\n' "$toon"
        printf 'FM_NMPOLL_RESULT=%s\n' "$result" >&2
        return 1
        ;;
    esac
    if [ $((SECONDS - start)) -ge "$max" ]; then
      printf '%s\n' "$toon"
      printf 'FM_NMPOLL_RESULT=running\n' >&2
      return 2
    fi
    sleep "$interval"
  done
}

case "${1:-}" in
  -h|--help|'') usage; [ "${1:-}" = '' ] && exit 3 || exit 0 ;;
  classify) shift; cmd_classify "$@" ;;
  wait) shift; cmd_wait "$@" ;;
  *) printf 'error: unknown subcommand %s\n' "$1" >&2; usage >&2; exit 3 ;;
esac
