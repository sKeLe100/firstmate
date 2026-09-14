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
#                          exactly one of: running | gate | outcome:<word>
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
# Exit codes for `wait`: 0 = gate reached, 1 = terminal outcome reached,
# 2 = still running (max elapsed, call again), 3 = usage/lookup error.
# Exit codes for `classify`: always 0; the result word is the only signal.
set -u

usage() {
  cat <<'EOF'
Usage:
  fm-nomistakes-poll-lib.sh classify  < axi-status-toon
  fm-nomistakes-poll-lib.sh wait [--dir DIR] [--interval SECS] [--max SECS]

classify reads one `no-mistakes axi status` TOON blob from stdin and prints
exactly one of: running, gate, outcome:<word>.

wait polls `no-mistakes axi status` in DIR (default: cwd) every INTERVAL
seconds (default 20) until classify returns gate or outcome:*, or MAX seconds
(default 480) elapse. Prints the last TOON to stdout and a final
FM_NMPOLL_RESULT=<result> line to stderr. Exit 0 on gate, 1 on outcome, 2 when
MAX elapsed with no gate/outcome yet (call wait again), 3 on usage error.
EOF
}

fm_nmpoll_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nmpoll_strip_quotes() {
  local s
  s=$(fm_nmpoll_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nmpoll_trim "$s"
}

# Scalar value of top-level TOON key $2 in blob $1.
fm_nmpoll_field() {
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# classify <toon> - prints running | gate | outcome:<word>
fm_nmpoll_classify() {
  local toon=$1 outcome status awaiting_line gate_step_line has_gate_block
  outcome=$(fm_nmpoll_strip_quotes "$(fm_nmpoll_field "$toon" outcome)")
  if [ -n "$outcome" ]; then
    printf 'outcome:%s' "$outcome"
    return 0
  fi
  status=$(fm_nmpoll_strip_quotes "$(fm_nmpoll_field "$toon" status)")
  case "$status" in
    completed|failed|cancelled)
      printf 'outcome:%s' "$status"
      return 0
      ;;
    awaiting_approval|fix_review)
      printf 'gate'
      return 0
      ;;
  esac
  awaiting_line=$(printf '%s\n' "$toon" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
  gate_step_line=$(printf '%s\n' "$toon" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,' | head -1 || true)
  has_gate_block=0
  printf '%s\n' "$toon" | grep -Eq '^[[:space:]]*gate:[[:space:]]*' && has_gate_block=1
  if [ -n "$awaiting_line" ] || [ -n "$gate_step_line" ] || [ "$has_gate_block" = 1 ]; then
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
  local elapsed=0 toon result
  while :; do
    toon=$(cd "$dir" 2>/dev/null && no-mistakes axi status 2>&1) || {
      printf 'error: no-mistakes axi status failed in %s\n' "$dir" >&2
      return 3
    }
    result=$(fm_nmpoll_classify "$toon")
    case "$result" in
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
    if [ "$elapsed" -ge "$max" ]; then
      printf '%s\n' "$toon"
      printf 'FM_NMPOLL_RESULT=running\n' >&2
      return 2
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
}

case "${1:-}" in
  -h|--help|'') usage; [ "${1:-}" = '' ] && exit 3 || exit 0 ;;
  classify) shift; cmd_classify "$@" ;;
  wait) shift; cmd_wait "$@" ;;
  *) printf 'error: unknown subcommand %s\n' "$1" >&2; usage >&2; exit 3 ;;
esac
