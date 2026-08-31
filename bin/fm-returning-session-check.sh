#!/usr/bin/env bash
# fm-returning-session-check.sh - decide bare-resume vs restart-with-carryover
# for a RETURNING session (one being pinged or restarted after a gap), not a
# fresh spawn.
#
# Why: resuming an old session pays a "return tax" - the harness re-reads a
# large prior transcript on its first turn back. When that session's context
# was already past the restart band before the gap, a bare resume just walks
# straight back into the same wall. This check reads the session's last known
# context level with the existing bin/fm-context-usage.sh machinery and the
# thresholds already documented in docs/configuration.md "Session context
# thresholds", and reports which resume path the caller should take. It reads
# and decides only; it does not itself resume, relaunch, or send anything, and
# it owns no threshold or trigger machinery of its own - the companion
# autocompact-wake mechanism (queued separately) owns deciding WHEN a ping or
# restart happens, this owns the verdict at THAT moment.
#
# Usage: fm-returning-session-check.sh <home-path>
#   <home-path> is the FM_HOME of the returning session: a crewmate task
#   worktree, a local secondmate home, or this firstmate's own home. It is
#   passed straight through as FM_HOME to fm-context-usage.sh, so the same
#   transcript-discovery and config/context-thresholds resolution apply.
#
# Output, one data-only line:
#   verdict=resume band=<ok|warn|restart> context_tokens=<N> \
#     restart_tokens=<N> transcript=<path>
#   verdict=restart-with-carryover band=restart context_tokens=<N> \
#     restart_tokens=<N> transcript=<path>
#   verdict=unknown reason=<text>
#     printed when no transcript or usage record exists yet (a non-claude
#     harness, or no session has run there yet). Unknown is not evidence of
#     either band, so callers proceed with an ordinary bare resume rather than
#     forcing a restart on missing data.
#
# verdict=restart-with-carryover means: do not bare-resume this session.
# Checkpoint its durable state and bring it back through the existing
# carryover-restart mechanics already owned elsewhere - bin/fm-control.sh
# <task-id> relaunch --note "carryover: ..." for a crewmate or secondmate,
# /stow then a fresh session for a primary firstmate - exactly as
# docs/configuration.md "Session context thresholds" already prescribes for
# the restart band. This script does not invoke those itself, so it composes
# with any caller's own delivery mechanics.
#
# Exit status: 0 whenever a verdict line was printed, including verdict=
# unknown. Non-zero only for a usage error (missing or wrong argument count).
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [ "$#" -ne 1 ]; then
  echo "fm-returning-session-check: usage: fm-returning-session-check.sh <home-path>" >&2
  exit 1
fi

home_path="$1"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage_output=""
usage_status=0
usage_output="$(FM_HOME="$home_path" "$script_dir/fm-context-usage.sh" 2>&1)" || usage_status=$?

if [ "$usage_status" -ne 0 ]; then
  reason="$(printf '%s' "$usage_output" | tr '\n' ' ' | sed 's/  */ /g')"
  echo "verdict=unknown reason=${reason:-fm-context-usage.sh failed}"
  exit 0
fi

# usage_output is one data-only line: context_tokens=<N> window=<W>
# percent=<P> warn_tokens=<W1> restart_tokens=<W2> band=<ok|warn|restart>
# transcript=<path> age_seconds=<S>
band=""
context_tokens=""
restart_tokens=""
transcript=""
for field in $usage_output; do
  case "$field" in
    band=*) band="${field#band=}" ;;
    context_tokens=*) context_tokens="${field#context_tokens=}" ;;
    restart_tokens=*) restart_tokens="${field#restart_tokens=}" ;;
    transcript=*) transcript="${field#transcript=}" ;;
  esac
done

if [ -z "$band" ]; then
  echo "verdict=unknown reason=fm-context-usage.sh produced no band field"
  exit 0
fi

if [ "$band" = "restart" ]; then
  verdict="restart-with-carryover"
else
  verdict="resume"
fi

echo "verdict=$verdict band=$band context_tokens=$context_tokens restart_tokens=$restart_tokens transcript=$transcript"
