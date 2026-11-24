#!/usr/bin/env bash
# fm-pc02-sleep-guard.sh - the ONE owner of the PC02 "may PC02 sleep now?"
# predicate. It runs on PC02 itself (inside WSL) and answers only whether a
# firstmate-visible activity signal is currently active; Windows itself stays
# the sleep authority through its native idle timer, whose 30-minute countdown
# is reset by the PC02-side watcher when work ends and which already accounts
# for real keyboard, mouse, and controller input. Console input is deliberately
# not re-derived here: a second idle clock would drift from Windows' own.
#
# The predicate reports busy when ANY of these is active:
#   - personal use is ON: the captain's manual flag file
#     (~/.fm-pc02-personal-use, owned by bin/fm-pc02-personal-use.sh and the
#     Windows desktop toggle);
#   - a PC02 test-offload slot lock is held (~/.fm-pc02-test-slot-*.lock, the
#     same flock bin/fm-pc02-test-offload.sh claims);
#   - a GitHub Actions runner job is executing (a Runner.Worker process) or
#     the Forgejo runner has a job child under its daemon;
#   - llama-swap reports a running model, or a Windows llama-server.exe process
#     or the bel-eval backend health endpoint is up;
#   - a secondmate turn or worker on PC02 is busy, read from the semantic busy
#     state records under the registered mate home (an idle record is not
#     busy, and a stale or gen-mismatched record is ignored).
#
# Output (stdout, exactly one line):
#   busy <reason>[,<reason>...]
#   free
# Exit status is 0 whenever the predicate was evaluated, 2 on a usage error.
# A probe that cannot answer must fail toward busy at the caller, which is why
# the watcher treats a non-zero exit or unparsable output as inhibited; this
# script only returns non-zero for usage.
#
# Usage:
#   fm-pc02-sleep-guard.sh status
#   fm-pc02-sleep-guard.sh --help
#
# Env overrides (tests and unusual homes):
#   FM_PC02_GUARD_HOME                 WSL home holding the flag and slot locks
#                                      (default: $HOME)
#   FM_PC02_GUARD_MATE_HOME            registered PC02 secondmate home
#                                      (default: /home/sean_/fm-pc02-mate)
#   FM_PC02_GUARD_PERSONAL_USE_FLAG    flag path relative to FM_PC02_GUARD_HOME
#                                      (default: .fm-pc02-personal-use)
#   FM_PC02_GUARD_LLAMA_SWAP_URL       llama-swap base URL
#                                      (default: http://127.0.0.1:8080)
#   FM_PC02_GUARD_BEL_HEALTH_URL       bel-eval backend health URL
#                                      (default: http://127.0.0.1:18181/health)
#   FM_PC02_GUARD_TASKLIST             Windows tasklist.exe path
#                                      (default: /mnt/c/Windows/System32/tasklist.exe)
#   FM_PC02_GUARD_FORGEJO_UNIT         Forgejo runner unit
#                                      (default: forgejo-runner.service)
#   FM_PC02_GUARD_BUSY_MAX_SECS        how old a busy record may be and still
#                                      count (default: 14400, four hours)
#
# This script never changes state and never sleeps PC02.
set -u

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  status) shift ;;
  *)
    echo "fm-pc02-sleep-guard.sh: usage: fm-pc02-sleep-guard.sh status" >&2
    exit 2
    ;;
esac

[ "$#" -eq 0 ] || {
  echo "fm-pc02-sleep-guard.sh: status takes no arguments" >&2
  exit 2
}

GUARD_HOME=${FM_PC02_GUARD_HOME:-$HOME}
MATE_HOME=${FM_PC02_GUARD_MATE_HOME:-/home/sean_/fm-pc02-mate}
PERSONAL_USE_FLAG=${FM_PC02_GUARD_PERSONAL_USE_FLAG:-.fm-pc02-personal-use}
LLAMA_SWAP_URL=${FM_PC02_GUARD_LLAMA_SWAP_URL:-http://127.0.0.1:8080}
BEL_HEALTH_URL=${FM_PC02_GUARD_BEL_HEALTH_URL:-http://127.0.0.1:18181/health}
TASKLIST=${FM_PC02_GUARD_TASKLIST:-/mnt/c/Windows/System32/tasklist.exe}
FORGEJO_UNIT=${FM_PC02_GUARD_FORGEJO_UNIT:-forgejo-runner.service}
BUSY_MAX_SECS=${FM_PC02_GUARD_BUSY_MAX_SECS:-14400}

reasons=()
add_reason() {
  local want=$1 existing
  for existing in "${reasons[@]}"; do
    [ "$existing" = "$want" ] && return 0
  done
  reasons+=("$want")
}

# personal use: the captain's manual switch outranks every other signal.
[ ! -e "$GUARD_HOME/$PERSONAL_USE_FLAG" ] || add_reason personal-use

# A test-offload slot is busy while its flock is held. A short-lived subshell
# probes the same lock the offload claims: if it can take the lock, no run
# holds the slot; if it cannot, a run does. The probe releases immediately and
# the offload's own retry loop absorbs the tiny probe window.
shopt -s nullglob
for lock in "$GUARD_HOME"/.fm-pc02-test-slot-*.lock; do
  if ! ( exec 9>"$lock"; flock -n 9 ) 2>/dev/null; then
    add_reason test-slot
    break
  fi
done
shopt -u nullglob

# GitHub Actions executes exactly one Runner.Worker child per job; the idle
# Runner.Listener does not spawn it. The Forgejo runner daemon has no children
# while idle, so any child means it is executing a job.
if command -v pgrep >/dev/null 2>&1 && pgrep -x 'Runner.Worker' >/dev/null 2>&1; then
  add_reason github-runner
fi
forgejo_pid=$(timeout 3 systemctl --user show -p MainPID --value "$FORGEJO_UNIT" 2>/dev/null | head -1)
case "$forgejo_pid" in
  '' | 0 | *[!0-9]*) ;;
  *)
    if pgrep -P "$forgejo_pid" >/dev/null 2>&1; then
      add_reason forgejo-runner
    fi
    ;;
esac

# llama-swap: /running is empty while no model is loaded and names every
# running model otherwise, so it covers both a loaded model and an inference in
# flight. The backend probes are backstops for a swap process that has gone
# away while its model process is still alive.
if curl -fsS --max-time 2 "$LLAMA_SWAP_URL/running" 2>/dev/null \
  | grep -Eq '"running"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{'; then
  add_reason llama-swap
elif [ -x "$TASKLIST" ] \
  && timeout 3 "$TASKLIST" /FI 'IMAGENAME eq llama-server.exe' /NH 2>/dev/null \
    | grep -qi 'llama-server\.exe'; then
  add_reason llama-swap
elif curl -fsS --max-time 2 -o /dev/null "$BEL_HEALTH_URL" 2>/dev/null; then
  add_reason llama-swap
fi

# A live secondmate or worker turn on PC02. bin/fm-busy-lib.sh owns the record
# contract; a busy record counts only while it is fresh and its incarnation gen
# still matches the sidecar, so a crashed turn cannot hold PC02 awake forever.
now=$(date +%s)
for record in "$MATE_HOME"/state/*.busy-state "$MATE_HOME"/state/parent-route/*.busy-state; do
  [ -f "$record" ] || continue
  line=$(head -1 "$record" 2>/dev/null) || continue
  state=$(printf '%s\n' "$line" | sed -n 's/.* state=\([^ ]*\).*/\1/p')
  [ "$state" = busy ] || continue
  gen=$(printf '%s\n' "$line" | sed -n 's/.* gen=\([^ ]*\).*/\1/p')
  ts=$(printf '%s\n' "$line" | sed -n 's/.* ts=\([0-9][0-9]*\).*/\1/p')
  case "$ts" in
    '' | *[!0-9]*) continue ;;
  esac
  [ $((now - ts)) -le "$BUSY_MAX_SECS" ] || continue
  sidecar=${record%.busy-state}.busy-gen
  if [ -f "$sidecar" ]; then
    current_gen=$(head -1 "$sidecar" 2>/dev/null) || current_gen=
    [ "$current_gen" = "$gen" ] || continue
  fi
  add_reason worker
  break
done

if [ "${#reasons[@]}" -eq 0 ]; then
  printf 'free\n'
else
  IFS=,
  printf 'busy %s\n' "${reasons[*]}"
fi
