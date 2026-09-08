#!/usr/bin/env bash
# fm-host-memory.sh - is this HOST carrying enough free memory to launch
# another agent?
#
# Why: config/dispatch-cap and the PC02 lane guard are quota and lane
# accounting - neither knows what the machine can actually carry. An agent
# launched onto a host with no memory left does not fail to start; it wedges
# mid-run, taking its pipeline with it (the 2026-09-08 codex-phase1b test-step
# wedge: 14G total, 11G used, 3G available, two drive attempts OOM-killed with
# no sensor anywhere in the fleet to see it coming). This helper is the one
# owner of that reading, in the shape bin/fm-context-usage.sh and
# bin/fm-autonomous-pc02-lane.sh already use.
#
# Usage: fm-host-memory.sh
#
# Reads MemAvailable from /proc/meminfo - the kernel's own estimate of what a
# new workload can claim without swapping, which is what "can this host carry
# another agent" actually asks; MemFree is not that number and is not used.
#
# The floor comes from optional config/host-memory-floor under FM_HOME
# (honoring FM_CONFIG_OVERRIDE), the sibling of config/dispatch-cap documented
# in docs/configuration.md "Host memory floor": exactly one bare positive
# base-10 integer of MiB and a trailing newline. An absent file means the
# built-in default of 3072 MiB. A malformed value is rejected loudly rather
# than silently replaced by the default, the same contract config/dispatch-cap
# and config/context-thresholds carry.
#
# Output (one line to stdout):
#   free                          - MemAvailable is at or above the floor
#   low: <available>MiB < <floor>MiB
#
# Exit codes: 0 = free, 1 = low, 2 = usage error, unreadable /proc/meminfo, or
# a malformed floor. Exit 2 is fail-closed: callers treat it exactly like low,
# never as free, matching fm-autonomous-pc02-lane.sh's direction.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
MEMINFO="${FM_MEMINFO_OVERRIDE:-/proc/meminfo}"

DEFAULT_FLOOR_MIB=3072

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [ $# -gt 0 ]; then
  echo "fm-host-memory.sh: unknown argument: $1" >&2
  exit 2
fi

floor=$DEFAULT_FLOOR_MIB
floor_file="$CONFIG/host-memory-floor"
if [ -e "$floor_file" ]; then
  if ! raw=$(cat "$floor_file" 2>/dev/null); then
    echo "fm-host-memory.sh: cannot read $floor_file" >&2
    exit 2
  fi
  case "$raw" in
    *[!0-9]* | '' | 0*)
      echo "fm-host-memory.sh: $floor_file must hold one positive integer of MiB, got: $raw" >&2
      exit 2
      ;;
  esac
  floor=$raw
fi

available=$(awk '$1 == "MemAvailable:" { print $2; found = 1; exit } END { exit !found }' "$MEMINFO" 2>/dev/null) || {
  echo "fm-host-memory.sh: cannot read MemAvailable from $MEMINFO" >&2
  exit 2
}
case "$available" in
  '' | *[!0-9]*)
    echo "fm-host-memory.sh: unreadable MemAvailable value in $MEMINFO: $available" >&2
    exit 2
    ;;
esac

available_mib=$(( available / 1024 ))

if [ "$available_mib" -ge "$floor" ]; then
  echo "free"
  exit 0
fi

echo "low: ${available_mib}MiB < ${floor}MiB"
exit 1
