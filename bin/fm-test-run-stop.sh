#!/usr/bin/env bash
# fm-test-run-stop.sh - stop one task's stuck no-mistakes test run, and only that run.
#
# Why: a hung fixture can keep bin/fm-test-run.sh alive for hours. Firstmate's
# raw `kill -TERM -- -<pgid>` was refused by the Claude Code auto-mode
# classifier, so each stuck run needed the operator to run the kill by hand. On
# 2026-11-04 a PC01 Test step ran about two hours with one fake-ssh fixture hung
# about 25 minutes, and an earlier PC02 run did the same. This is the owned,
# verifiable stop path: it finds the process tree of one task's test run from
# that task's own records and stops nothing else.
#
# Two abort paths, with different purposes:
#   - This script ends only a stuck or runaway test process tree, so the step
#     reports failure and can be rerun. The run itself stays alive.
#   - Ending the whole run stays `no-mistakes axi abort`.
#
# Usage:
#   bin/fm-test-run-stop.sh <task-id> [--dry-run] [--host pc01|pc02]
#
# With no --host both hosts are checked. --dry-run lists what would stop and
# changes nothing. --help prints this header block.
#
# Resolution, from records and never from a name pattern alone:
#   - state/<task-id>.meta gives the task's branch and worktree.
#   - fm_nm_select_run in bin/fm-nm-run-lib.sh owns run attribution and yields
#     the branch's run ids; each id's status is read with
#     `no-mistakes axi status --run <id>`. Exactly one run may be running or
#     pending. No active run, or more than one, refuses with exit 2 and stops
#     nothing.
#   - The run directory is the single $NM_HOME/worktrees/*/<run-id> match.
#   - An anchor is a process that runs bin/fm-test-run.sh,
#     bin/fm-test-compute.sh or bin/fm-pc02-test-offload.sh as a program
#     argument, with its working directory inside the run directory. The run
#     root is the topmost shell above an anchor whose command line names one of
#     those scripts; the run tree is that root, every descendant of it, and
#     every member of a process group a run member leads.
#   - Nothing above the run root is signalled: the no-mistakes daemon, the LLM
#     test agent running the step, and this script's own caller sit outside the
#     run tree by construction.
#
# Action: TERM every member of the run tree; after the grace period, KILL any
# process still alive with the identity (pid and start time) seen in the
# snapshot; then verify. A process group is signalled as a group only when
# every live member of it is in the run tree. A group that also holds a
# process outside the run is never signalled as a group: its run members are
# signalled by pid instead, and the outsider survives untouched. A zombie
# counts as stopped. The script removes no files: the offload client's own exit
# trap removes its PC02 mirror once its group has stopped.
#
# PC02: the same walk runs there over one bounded ssh call, over the offload
# run roots named by the prefix
# `bin/fm-pc02-test-offload.sh --remote-run-prefix <run-dir>` prints, which the
# offload owns. A root is walked only when its pgid file names the group the
# run's anchor is in. A PC02 claim is recorded when a PC01-side offload client
# of the run directory is alive when the stop starts; it is captured before the
# PC01 pass can kill that client.
#
# Output (stdout), in this order:
#   pc01 group=<pgid> stopped=<n> signal=TERM|KILL mode=group|pid
#   pc02 group=<pgid> stopped=<n> signal=TERM|KILL mode=group|pid
#   dry-run pc01|pc02 group=<pgid> would-stop=<n> mode=group|pid
#   pc02 unknown                 a PC02 claim or a failed PC02 check leaves
#                                PC02 unconfirmed; PC01 lines may still be there
#   none                         nothing was stopped and no PC02 claim exists
#   run <run-id> status=<word>   the run's own status after the stop lines,
#                                reading `no-mistakes axi status --run <id>`;
#                                never printed under --dry-run
# Refusals and diagnostics go to stderr.
#
# Exit: 0 every checked host is clean; 1 a run member survived, a group was
# refused, or a PC02 check did not confirm PC02; 2 usage error or a refusal
# before any stop (no /proc, unknown task, no active run, ambiguous active
# runs, missing or ambiguous run directory).
#
# Env overrides:
#   FM_HOME                             firstmate home (default: this code root)
#   NM_HOME                             no-mistakes home (default: ~/.no-mistakes)
#   FM_TEST_RUN_STOP_GRACE_SECS         TERM-to-KILL grace, 0-300 (default: 10)
#   FM_PC02_OFFLOAD_HOST                PC02 ssh target (default: pc02)
#   FM_PC02_OFFLOAD_REMOTE_BASE         PC02 run-root base under $HOME
#                                       (default: .fm-pc02-test-offload)
#   FM_TEST_RUN_STOP_SSH_TIMEOUT_SECS   bound for the one PC02 call (default: 60)
#
# Permission rule: the auto-mode classifier must not block this script. The
# operator adds this allow rule in Claude Code settings (for example
# .claude/settings.local.json; firstmate does not edit settings):
#   "Bash(bin/fm-test-run-stop.sh:*)"
# It matches only invocations spelled `bin/fm-test-run-stop.sh ...` from the
# firstmate home. A `cd ... &&` or `VAR=value` prefix does not match, so call
# it bare.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
FM_HOME=${FM_HOME:-$FM_ROOT}
NM_TIMEOUT=15
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

# Functions the PC02 walk needs. They are sent to PC02 verbatim with
# `declare -f`, so they must use bash builtins plus readlink only.
TS_FUNCS=(ts_snapshot ts_under ts_alive ts_group_alive ts_engine ts_remote_main)

die() {
  printf 'fm-test-run-stop: %s\n' "$*" >&2
  exit 2
}

usage() {  # [exit-code]
  if [ "${1:-0}" = 0 ]; then
    awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'
    exit 0
  fi
  printf 'usage: bin/fm-test-run-stop.sh <task-id> [--dry-run] [--host pc01|pc02]\n' >&2
  exit "$1"
}

# --- Process-table engine -------------------------------------------------

# Snapshot /proc into PT_* tables keyed by pid:
#   PT_PPID PT_PGID PT_START PT_STATE   from /proc/<pid>/stat
#   PT_WRAP   a shell (sh/bash/dash/zsh) whose command line names a test-run script
#   PT_ANCH   a process with a test-run script as a standalone program argument
#   PT_OFFL   a process whose program argument is bin/fm-pc02-test-offload.sh
ts_snapshot() {
  local d pid line rest joined tok a0
  local -a f av
  declare -gA PT_PPID=() PT_PGID=() PT_START=() PT_STATE=() PT_WRAP=() PT_ANCH=() PT_OFFL=()
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    IFS= read -r line < "$d/stat" 2>/dev/null || continue
    rest=${line##*) }
    read -r -a f <<< "$rest" || continue
    [ "${#f[@]}" -ge 20 ] || continue
    PT_STATE[$pid]=${f[0]}
    PT_PPID[$pid]=${f[1]}
    PT_PGID[$pid]=${f[2]}
    PT_START[$pid]=${f[19]}
    av=()
    mapfile -d '' -t av < "$d/cmdline" 2>/dev/null || true
    joined="${av[*]:-}"
    a0=${av[0]:-}
    a0=${a0##*/}
    case "$a0" in
      sh|bash|dash|zsh)
        case "$joined" in
          *bin/fm-test-run.sh*|*bin/fm-test-compute.sh*|*bin/fm-pc02-test-offload.sh*) PT_WRAP[$pid]=1 ;;
        esac
        ;;
    esac
    for tok in ${av[@]+"${av[@]}"}; do
      case "$tok" in
        *" "*) continue ;;
        bin/fm-test-run.sh|*/bin/fm-test-run.sh|bin/fm-test-compute.sh|*/bin/fm-test-compute.sh)
          PT_ANCH[$pid]=1
          break
          ;;
        bin/fm-pc02-test-offload.sh|*/bin/fm-pc02-test-offload.sh)
          PT_ANCH[$pid]=1
          PT_OFFL[$pid]=1
          break
          ;;
      esac
    done
  done
}

# 0 when path $1 is directory $2 or inside it.
ts_under() {
  case "$1" in
    "$2"|"$2"/*) return 0 ;;
  esac
  return 1
}

# 0 when identity $1 (pid:start) names a live, non-zombie process.
ts_alive() {
  local pid=${1%%:*} start=${1#*:} line rest
  local -a f
  [ -r "/proc/$pid/stat" ] || return 1
  IFS= read -r line < "/proc/$pid/stat" 2>/dev/null || return 1
  rest=${line##*) }
  read -r -a f <<< "$rest" || return 1
  [ "${f[19]:-}" = "$start" ] || return 1
  [ "${f[0]:-}" != Z ]
}

# 0 when any identity in the space-separated list $1 is still alive.
ts_group_alive() {
  local x
  for x in $1; do
    ts_alive "$x" && return 0
  done
  return 1
}

# Stop or report the test run in RUN_DIR. Inputs: RUN_DIR, REQUIRE_PGID (empty,
# or the pgid anchors must belong to), HOST_LABEL, GRACE, DRY_RUN. Result lines
# go to stdout, refusals to stderr. Returns 0 clean, 1 refused or a member
# survived, 2 when RUN_DIR cannot be resolved.
ts_engine() {
  local rd a c p g m mode ident
  local -i i n mixed tries limit alive_any hops rc=0
  local -a q=() targets=()
  local -A anchor=() kids=() RUN=() roots=() members=() cand=() tident=() tcount=() tgroup=() tsig=()

  rd=$(readlink -f -- "$RUN_DIR" 2>/dev/null) && [ -n "$rd" ] || return 2
  ts_snapshot

  for a in "${!PT_PPID[@]}"; do
    [ -n "${PT_ANCH[$a]:-}" ] || continue
    if [ -n "${REQUIRE_PGID:-}" ] && [ "${PT_PGID[$a]}" != "$REQUIRE_PGID" ]; then
      continue
    fi
    c=$(readlink -f -- "/proc/$a/cwd" 2>/dev/null) || continue
    ts_under "$c" "$rd" || continue
    anchor[$a]=1
  done
  [ "${#anchor[@]}" -gt 0 ] || return 0

  for p in "${!PT_PPID[@]}"; do
    kids[${PT_PPID[$p]}]+="$p "
    members[${PT_PGID[$p]}]+="$p "
  done

  for a in "${!anchor[@]}"; do
    roots[$a]=1
    p=${PT_PPID[$a]:-0}
    hops=0
    while [ "$p" -gt 1 ] && [ -n "${PT_PPID[$p]:-}" ] && [ "$hops" -lt 64 ]; do
      [ -z "${PT_WRAP[$p]:-}" ] || roots[$p]=1
      p=${PT_PPID[$p]}
      hops=$((hops + 1))
    done
  done

  q=("${!roots[@]}")
  for ((i = 0; i < ${#q[@]}; i++)); do
    p=${q[i]}
    [ -z "${RUN[$p]:-}" ] || continue
    RUN[$p]=1
    for c in ${kids[$p]:-}; do
      q+=("$c")
    done
    for c in ${members[$p]:-}; do
      q+=("$c")
    done
  done

  for p in "${!RUN[@]}"; do
    cand[${PT_PGID[$p]}]=1
  done

  for g in "${!cand[@]}"; do
    case "$g" in
      ''|0|1) continue ;;
    esac
    if [ "$g" = "${PT_PGID[$$]:-}" ]; then
      printf 'fm-test-run-stop: refused %s group %s: it is this script'\''s own group\n' "$HOST_LABEL" "$g" >&2
      rc=1
      continue
    fi
    ident=""
    n=0
    mixed=0
    for m in ${members[$g]:-}; do
      case "${PT_STATE[$m]:-}" in
        Z) continue ;;
      esac
      if [ -z "${RUN[$m]:-}" ]; then
        mixed=1
        continue
      fi
      ident+="$m:${PT_START[$m]} "
      n=$((n + 1))
    done
    [ "$n" -gt 0 ] || continue
    targets+=("$g")
    tident[$g]=$ident
    tcount[$g]=$n
    tgroup[$g]=$((1 - mixed))
  done

  [ "${#targets[@]}" -gt 0 ] || return "$rc"

  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    for g in "${targets[@]}"; do
      mode=group
      [ "${tgroup[$g]}" -eq 1 ] || mode=pid
      printf 'dry-run %s group=%s would-stop=%s mode=%s\n' "$HOST_LABEL" "$g" "${tcount[$g]}" "$mode"
    done
    return "$rc"
  fi

  for g in "${targets[@]}"; do
    if [ "${tgroup[$g]}" -eq 1 ]; then
      kill -TERM -- "-$g" 2>/dev/null || true
    else
      for m in ${tident[$g]}; do
        kill -TERM "${m%%:*}" 2>/dev/null || true
      done
    fi
  done
  tries=0
  limit=$((GRACE * 5))
  while :; do
    alive_any=0
    for g in "${targets[@]}"; do
      if ts_group_alive "${tident[$g]}"; then
        alive_any=1
        break
      fi
    done
    [ "$alive_any" -eq 1 ] || break
    [ "$tries" -lt "$limit" ] || break
    sleep 0.2
    tries=$((tries + 1))
  done

  for g in "${targets[@]}"; do
    tsig[$g]=TERM
    ts_group_alive "${tident[$g]}" || continue
    tsig[$g]=KILL
    if [ "${tgroup[$g]}" -eq 1 ]; then
      kill -KILL -- "-$g" 2>/dev/null || true
    else
      for m in ${tident[$g]}; do
        kill -KILL "${m%%:*}" 2>/dev/null || true
      done
    fi
  done

  for g in "${targets[@]}"; do
    tries=0
    while ts_group_alive "${tident[$g]}" && [ "$tries" -lt 25 ]; do
      sleep 0.2
      tries=$((tries + 1))
    done
    mode=group
    [ "${tgroup[$g]}" -eq 1 ] || mode=pid
    if ts_group_alive "${tident[$g]}"; then
      printf 'fm-test-run-stop: %s group %s still has live processes after KILL\n' "$HOST_LABEL" "$g" >&2
      rc=1
    else
      printf '%s group=%s stopped=%s signal=%s mode=%s\n' \
        "$HOST_LABEL" "$g" "${tcount[$g]}" "${tsig[$g]}" "$mode"
    fi
  done
  return "$rc"
}

# PC01-side PC02 claim: 0 when a live offload client of run directory $1 exists.
ts_pc02_claim() {  # <run-dir>
  local rd a c
  rd=$(readlink -f -- "$1" 2>/dev/null) || return 1
  ts_snapshot
  for a in "${!PT_OFFL[@]}"; do
    c=$(readlink -f -- "/proc/$a/cwd" 2>/dev/null) || continue
    ts_under "$c" "$rd" && return 0
  done
  return 1
}

# PC02 entry point, run as `bash -s` over ssh. Walks each offload run root the
# offload's own prefix names and whose pgid file names the run's group.
# shellcheck disable=SC2329 # Invoked on PC02 from the text `declare -f` sends over ssh.
ts_remote_main() {  # <remote-prefix> <grace> <dry-run>
  local prefix=$1 d g rc=0
  local -a hits=()
  GRACE=$2
  DRY_RUN=$3
  HOST_LABEL=pc02
  shopt -s nullglob
  case "$prefix" in
    /*) hits=("$prefix"*) ;;
    *) hits=("$HOME/$prefix"*) ;;
  esac
  shopt -u nullglob
  for d in ${hits[@]+"${hits[@]}"}; do
    [ -d "$d/worktree" ] && [ ! -L "$d/worktree" ] || continue
    IFS= read -r g < "$d/pgid" 2>/dev/null || continue
    case "$g" in
      ''|*[!0-9]*) continue ;;
    esac
    RUN_DIR=$d/worktree
    REQUIRE_PGID=$g
    ts_engine || rc=1
  done
  return "$rc"
}

# Status word of run $2 as worktree $1's no-mistakes records it.
fm_nm_run_status() {  # <worktree> <run-id>
  local out
  out=$(fm_nm_run "$1" "$NM_TIMEOUT" axi status --run "$2")
  fm_nm_strip_quotes "$(fm_nm_field "$out" status)"
}

# --- Entry point ------------------------------------------------------------

main() {
  local task="" dry=0 arg r rc=0 grace ssh_timeout meta branch wt overview sel ids id st
  local do_pc01=0 do_pc02=0 run_id="" nm_root local_dir="" prefix="" claim=0
  local pc01_out="" pc02_out="" pc02_unknown=0
  local -a want=() matches=() active=()

  while [ "$#" -gt 0 ]; do
    arg=$1
    case "$arg" in
      --dry-run) dry=1 ;;
      --host)
        [ "$#" -ge 2 ] || die "--host needs pc01 or pc02"
        case "$2" in
          pc01|pc02) want+=("$2") ;;
          *) die "--host must be pc01 or pc02" ;;
        esac
        shift
        ;;
      --host=*)
        case "${arg#--host=}" in
          pc01|pc02) want+=("${arg#--host=}") ;;
          *) die "--host must be pc01 or pc02" ;;
        esac
        ;;
      -h|--help) usage 0 ;;
      -*) die "unknown option: $arg" ;;
      *)
        [ -z "$task" ] || die "one task id only"
        task=$arg
        ;;
    esac
    shift
  done

  [ -n "$task" ] || usage 2
  case "$task" in
    ''|.*|*[!A-Za-z0-9._-]*) die "invalid task id: $task" ;;
  esac
  [ -d /proc/self ] || die "needs Linux /proc to read the process table; nothing stopped"

  grace=${FM_TEST_RUN_STOP_GRACE_SECS:-10}
  case "$grace" in
    ''|*[!0-9]*) die "FM_TEST_RUN_STOP_GRACE_SECS must be a whole number of seconds" ;;
  esac
  [ "$grace" -le 300 ] || die "FM_TEST_RUN_STOP_GRACE_SECS must be 300 or less"
  GRACE=$grace

  ssh_timeout=${FM_TEST_RUN_STOP_SSH_TIMEOUT_SECS:-60}
  case "$ssh_timeout" in
    ''|*[!0-9]*|0) die "FM_TEST_RUN_STOP_SSH_TIMEOUT_SECS must be a positive whole number" ;;
  esac

  if [ "${#want[@]}" -eq 0 ]; then
    do_pc01=1
    do_pc02=1
  else
    for arg in "${want[@]}"; do
      case "$arg" in
        pc01) do_pc01=1 ;;
        pc02) do_pc02=1 ;;
      esac
    done
  fi

  meta="$FM_HOME/state/$task.meta"
  [ -r "$meta" ] || die "no task record for $task under $FM_HOME/state; nothing stopped"
  branch=$(sed -n 's/^branch=//p' "$meta" | head -n 1)
  wt=$(sed -n 's/^worktree=//p' "$meta" | head -n 1)
  { [ -n "$branch" ] && [ -n "$wt" ]; } || die "task record for $task names no branch or worktree; nothing stopped"
  [ -d "$wt" ] || die "task worktree is gone ($wt), so its run cannot be resolved; nothing stopped"

  overview=$(fm_nm_run "$wt" "$NM_TIMEOUT" axi)
  [ -n "$overview" ] || die "no-mistakes status unavailable from $wt; nothing stopped"
  sel=$(fm_nm_select_run "$branch" "$overview" "$wt" "$NM_TIMEOUT")
  case "$sel" in
    absent) ids="" ;;
    selected\|*) IFS='|' read -r _ _ _ ids <<< "$sel" ;;
    *) die "no-mistakes run for $task is not unambiguous ($sel); nothing stopped" ;;
  esac
  for id in ${ids//,/ }; do
    [ -n "$id" ] || continue
    st=$(fm_nm_run_status "$wt" "$id")
    case "$st" in
      running|pending) active+=("$id") ;;
    esac
  done
  case "${#active[@]}" in
    1) run_id=${active[0]} ;;
    0) die "no active no-mistakes run for $task; nothing stopped" ;;
    *) die "$task has ${#active[@]} active no-mistakes runs (${active[*]}); nothing stopped" ;;
  esac

  nm_root=$(dirname "$(fm_nm_state_db "$wt")")
  shopt -s nullglob
  matches=("$nm_root"/worktrees/*/"$run_id")
  shopt -u nullglob
  case "${#matches[@]}" in
    0) die "run $run_id has no local run directory; nothing stopped" ;;
    1) ;;
    *) die "run $run_id has ${#matches[@]} run directories; nothing stopped" ;;
  esac
  local_dir=${matches[0]}
  [ -d "$local_dir" ] || die "run directory $local_dir is not a directory; nothing stopped"

  if [ "$do_pc02" -eq 1 ] && ts_pc02_claim "$local_dir"; then
    claim=1
  fi

  if [ "$do_pc01" -eq 1 ]; then
    RUN_DIR=$local_dir
    REQUIRE_PGID=
    HOST_LABEL=pc01
    DRY_RUN=$dry
    pc01_out=$(ts_engine)
    r=$?
    [ "$r" -eq 2 ] && die "run directory $local_dir cannot be resolved; nothing stopped"
    [ "$r" -eq 0 ] || rc=1
  fi

  if [ "$do_pc02" -eq 1 ]; then
    prefix=$(bash "$SCRIPT_DIR/fm-pc02-test-offload.sh" --remote-run-prefix "$local_dir" 2>/dev/null) || prefix=""
    if [ -z "$prefix" ]; then
      printf 'fm-test-run-stop: PC02 run-root prefix unavailable from bin/fm-pc02-test-offload.sh; PC02 state is not confirmed\n' >&2
      rc=1
      pc02_unknown=1
    else
      pc02_out=$(
        {
          declare -f "${TS_FUNCS[@]}"
          printf 'ts_remote_main %q %q %q\n' "$prefix" "$GRACE" "$dry"
        } | timeout "$ssh_timeout" ssh -o BatchMode=yes -o ConnectTimeout=10 \
              "${FM_PC02_OFFLOAD_HOST:-pc02}" bash -s
      )
      r=$?
      if [ "$r" -ne 0 ]; then
        printf 'fm-test-run-stop: PC02 check exited %s; PC02 state is not confirmed\n' "$r" >&2
        rc=1
        [ -n "$pc02_out" ] || pc02_unknown=1
      elif [ -z "$pc02_out" ] && [ "$claim" -eq 1 ]; then
        rc=1
        pc02_unknown=1
      fi
    fi
  fi

  [ -z "$pc01_out" ] || printf '%s\n' "$pc01_out"
  [ -z "$pc02_out" ] || printf '%s\n' "$pc02_out"
  [ "$pc02_unknown" -eq 0 ] || printf 'pc02 unknown\n'
  if [ -z "$pc01_out" ] && [ -z "$pc02_out" ] && [ "$pc02_unknown" -eq 0 ]; then
    printf 'none\n'
  fi
  if [ "$dry" -eq 0 ]; then
    st=$(fm_nm_run_status "$wt" "$run_id")
    printf 'run %s status=%s\n' "$run_id" "${st:-unknown}"
  fi
  exit "$rc"
}

main "$@"
