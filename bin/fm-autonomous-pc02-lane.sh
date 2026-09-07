#!/usr/bin/env bash
# fm-autonomous-pc02-lane.sh - is the PC02 lane free for the
# /autonomous skill's step 3 dispatch-availability check?
#
# Why: PC02's llama-swap serves one model at a time (bin/fm-spawn.sh's
# pc02_lane_guard), so a second concurrent pc02-llamaswap/* task starves the
# first. Step 3 of the autonomous pass already checks the generic Claude
# dispatch-cap gate (config/dispatch-cap reduced by the quota ladder), but
# that check says nothing about PC02 occupancy: a PC02-routed candidate can
# read as dispatchable purely because the Claude lane count has headroom
# while PC02 itself is already held by another task. This script is the
# pass's separate, explicit answer to "is PC02 itself free right now",
# mirroring pc02_lane_guard's scan-and-liveness read (never its lock or
# meta-publication half, which only apply at spawn time) rather than
# inventing new detection logic.
#
# Usage: fm-autonomous-pc02-lane.sh
#
# Scans state/*.meta for a task whose meta shows a pc02-llamaswap/* model,
# exactly as pc02_lane_guard matches. A match is occupied unless its
# recorded endpoint reads back positively dead (fm_backend_agent_alive = dead); ambiguous or
# unknown liveness keeps the lane occupied, matching pc02_lane_guard's
# fail-closed direction. A remote secondmate's lane (remote_host set) always
# reads as occupied outright - liveness lives behind the remote host, which
# this local endpoint probe cannot settle.
#
# Output (one line to stdout):
#   free                       - no live PC02 task holds the lane
#   occupied: <task-id>        - <task-id>'s live pc02-llamaswap/* endpoint holds it
#
# Exit codes: 0 = free, 1 = occupied, 2 = usage error or unreadable state
# directory (never a silent free).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [ $# -gt 0 ]; then
  echo "fm-autonomous-pc02-lane.sh: unknown argument: $1" >&2
  exit 2
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

if [ ! -d "$STATE" ]; then
  echo "fm-autonomous-pc02-lane.sh: state directory is unavailable: $STATE" >&2
  exit 2
fi

for other_meta in "$STATE"/*.meta; do
  [ -f "$other_meta" ] || continue
  case "$(fm_meta_get "$other_meta" model)" in
    pc02-llamaswap/*) ;;
    *) continue ;;
  esac
  other_task=$(basename "$other_meta" .meta)
  if [ -z "$(fm_meta_get "$other_meta" remote_host)" ]; then
    other_target=$(fm_backend_target_of_meta "$other_meta")
    if [ -n "$other_target" ] \
      && [ "$(fm_backend_agent_alive "$(fm_backend_of_meta "$other_meta")" "$other_target")" = dead ]; then
      continue
    fi
  fi
  echo "occupied: $other_task"
  exit 1
done

echo "free"
exit 0
