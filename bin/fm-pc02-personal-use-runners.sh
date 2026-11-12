#!/usr/bin/env bash
# fm-pc02-personal-use-runners.sh - the PC02 side of the captain's personal-use
# switch: stop every self-hosted GitHub Actions runner while the flag file is
# present, and start them again when it is gone.
#
# bin/fm-pc02-personal-use.sh owns the flag on PC01 and deploys this helper,
# its user service, its path unit and one per-runner drop-in onto PC02 with
# `install-toggle`. The path unit fires this helper whenever the flag appears or
# disappears, so a flip from the Windows desktop toggle and a flip from PC01
# behave identically. The per-runner drop-in keeps the runners down across a
# PC02 reboot while the flag is still present.
#
# Runners are discovered from the `actions.runner.*` user-unit pattern on every
# pass, never from a hardcoded list, so a newly registered runner is gated too.
#
# A flip that lands while a pass is running is not re-triggered by the path
# unit, because the oneshot is already active. So after each pass the flag is
# read again, and the runners are converged again when it changed, so the final
# state always matches the final flag.
#
# Usage:
#   fm-pc02-personal-use-runners.sh   converge every discovered runner to the
#                                     flag's current state
#
# Env:
#   FM_PC02_OFFLOAD_PERSONAL_USE_FLAG  flag path relative to $HOME
#                                      (default: .fm-pc02-personal-use)
#
# Exit status: 0 when every discovered runner matches the final flag, 1 when a
# systemctl call failed (the failed unit is named on stderr) or the flag kept
# changing through the bounded number of passes.
set -u

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [ "$#" -gt 0 ]; then
  echo "fm-pc02-personal-use-runners.sh: usage: fm-pc02-personal-use-runners.sh" >&2
  exit 2
fi

FLAG="${FM_PC02_OFFLOAD_PERSONAL_USE_FLAG:-.fm-pc02-personal-use}"
FLAG="$HOME/$FLAG"

MAX_PASSES=5

flag_state() {
  if [ -f "$FLAG" ]; then
    echo stop
  else
    echo start
  fi
}

# converge_units <stop|start>: returns 1 when any runner refused the change,
# and exits 1 when the user units cannot be listed at all.
converge_units() {
  local wanted=$1 unit_table units unit found=0 failed=0
  if ! unit_table=$(systemctl --user list-unit-files 'actions.runner.*.service' \
    --no-legend --no-pager 2>/dev/null); then
    echo "fm-pc02-personal-use-runners.sh: cannot list user units with systemctl --user" >&2
    exit 1
  fi
  units=$(printf '%s\n' "$unit_table" | awk 'NF { print $1 }')

  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    case "$unit" in
      actions.runner.*.service) ;;
      *) continue ;;
    esac
    found=$((found + 1))
    if [ "$wanted" = stop ]; then
      if systemctl --user is-active --quiet "$unit"; then
        if ! systemctl --user stop "$unit"; then
          echo "fm-pc02-personal-use-runners.sh: failed to stop $unit" >&2
          failed=1
          continue
        fi
        echo "fm-pc02-personal-use-runners.sh: stopped $unit (personal use on)"
      fi
    else
      if ! systemctl --user is-active --quiet "$unit"; then
        if ! systemctl --user start "$unit"; then
          echo "fm-pc02-personal-use-runners.sh: failed to start $unit" >&2
          failed=1
          continue
        fi
        echo "fm-pc02-personal-use-runners.sh: started $unit (personal use off)"
      fi
    fi
  done <<< "$units"

  if [ "$found" -eq 0 ]; then
    echo "fm-pc02-personal-use-runners.sh: no actions.runner.* user units found"
  fi
  return "$failed"
}

rc=0
passes=0
while :; do
  wanted=$(flag_state)
  passes=$((passes + 1))
  converge_units "$wanted" || rc=1
  if [ "$(flag_state)" = "$wanted" ]; then
    break
  fi
  if [ "$passes" -ge "$MAX_PASSES" ]; then
    echo "fm-pc02-personal-use-runners.sh: the personal-use flag kept changing; gave up after $passes passes" >&2
    rc=1
    break
  fi
  echo "fm-pc02-personal-use-runners.sh: the personal-use flag changed during the pass; converging again"
done

exit "$rc"
