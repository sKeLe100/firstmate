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
# That reading already counts every live session's resident memory, idle
# parked worker sessions included, because their pages are not available to a
# new workload; no per-session subtraction is layered on top.
#
# It also bounds swap: when SwapTotal is readable and at least 90% of it is in
# use, the host is thrashing and the reading reports low even with MemAvailable
# above the floor. That is the direction the 2026-11-03 PC01 WSL OOM crash was
# missed from - MemAvailable stayed above the floor while idle sessions' pages
# filled swap. SwapTotal absent or zero means the host reports no swap and
# adds no constraint; SwapTotal readable without SwapFree is disclosed on
# stderr and never treated as free swap.
#
# The floor comes from optional config/host-memory-floor under FM_HOME
# (honoring FM_CONFIG_OVERRIDE), the sibling of config/dispatch-cap documented
# in docs/configuration.md "Host memory floor": exactly one bare positive
# base-10 integer of MiB, no wider than 9 digits, and a trailing newline. An absent file means the
# built-in default of 3072 MiB. A malformed value is rejected loudly rather
# than silently replaced by the default, the same contract config/dispatch-cap
# and config/context-thresholds carry.
#
# Output (one line to stdout):
#   free                          - MemAvailable is at or above the floor and swap is below its bound
#   low: <available>MiB < <floor>MiB
#   low: swap <pct>% used (<used>MiB of <total>MiB) >= 90%
#   low: <available>MiB < <floor>MiB; swap <pct>% used (<used>MiB of <total>MiB) >= 90%
#
# Exit codes: 0 = free, 1 = low, 2 = usage error, unreadable /proc/meminfo, or
# a malformed floor. Exit 2 never reports free: it says the reading could not be
# taken, which callers disclose and proceed past - only exit 1 is evidence of
# memory pressure and only exit 1 blocks a dispatch or a launch.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
MEMINFO="${FM_MEMINFO_OVERRIDE:-/proc/meminfo}"

DEFAULT_FLOOR_MIB=3072
SWAP_MAX_USED_PCT=90

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
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
    *[!0-9]* | '' | 0* | ??????????*)
      echo "fm-host-memory.sh: $floor_file must hold one positive integer of MiB no wider than 9 digits, got: $raw" >&2
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

floor_low=0
[ "$available_mib" -ge "$floor" ] || floor_low=1

swap_low=0
swap_reason=
swap_total=$(awk '$1 == "SwapTotal:" { print $2; found = 1; exit } END { exit !found }' "$MEMINFO" 2>/dev/null) || swap_total=
case "$swap_total" in
  '' | *[!0-9]*) ;;  # no swap reported: the host adds no swap constraint
  *)
    if [ "$swap_total" -gt 0 ]; then
      swap_free=$(awk '$1 == "SwapFree:" { print $2; found = 1; exit } END { exit !found }' "$MEMINFO" 2>/dev/null) || swap_free=
      case "$swap_free" in
        '' | *[!0-9]*)
          echo "fm-host-memory.sh: swap not assessed: SwapTotal is readable but SwapFree is not" >&2
          ;;
        *)
          swap_used=$(( swap_total - swap_free ))
          [ "$swap_used" -ge 0 ] || swap_used=0
          swap_pct=$(( swap_used * 100 / swap_total ))
          if [ "$swap_pct" -ge "$SWAP_MAX_USED_PCT" ]; then
            swap_low=1
            swap_reason="swap ${swap_pct}% used ($(( swap_used / 1024 ))MiB of $(( swap_total / 1024 ))MiB) >= ${SWAP_MAX_USED_PCT}%"
          fi
          ;;
      esac
    fi
    ;;
esac

if [ "$floor_low" -eq 0 ] && [ "$swap_low" -eq 0 ]; then
  echo "free"
  exit 0
fi

reason=
[ "$floor_low" -eq 0 ] || reason="${available_mib}MiB < ${floor}MiB"
[ "$swap_low" -eq 0 ] || reason="${reason:+$reason; }${swap_reason}"
echo "low: $reason"
exit 1
