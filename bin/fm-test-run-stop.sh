#!/usr/bin/env bash
# fm-test-run-stop.sh - stop one task's stuck no-mistakes test run, and only that run.
#
# Why: a hung fixture can keep bin/fm-test-run.sh alive for hours. Firstmate's
# raw `kill -TERM -- -<pgid>` was refused by the Claude Code auto-mode
# classifier, so each stuck run needed the operator to run the kill by hand. On
# 2026-11-04 a PC01 Test step ran about two hours with one fake-ssh fixture hung
# about 25 minutes, and an earlier PC02 run did the same. This is the owned,
# verifiable stop path: it finds the process groups of one task's test run from
# that task's own records and stops nothing else.
#
# Usage:
#   bin/fm-test-run-stop.sh <task-id> [--dry-run] [--host pc01|pc02]
#
# With no --host both hosts are checked. --dry-run lists what would stop and
# changes nothing.
#
# Resolution, from records and never from a name pattern alone:
#   - state/<task-id>.meta gives the task's branch and worktree. The branch's
#     run is chosen by fm_nm_select_run in bin/fm-nm-run-lib.sh, which owns run
#     attribution; an ambiguous choice refuses.
#   - The run directory is the single $NM_HOME/worktrees/*/<run-id> match.
#   - An anchor is a process that runs bin/fm-test-run.sh,
#     bin/fm-test-compute.sh or bin/fm-pc02-test-offload.sh as a program
#     argument, with its working directory inside the run directory. Those are
#     the names the test chain runs or execs, and a hung run may sit in any.
#   - A target is a process group that holds an anchor or a descendant of one.
#     A group is refused, and left alone, when it holds the no-mistakes daemon,
#     or when it has a member that is neither a descendant of an anchor nor a
#     shell wrapper of one, unless the group's own leader is such a process, in
#     which case same-group orphans belong to the run too.
#
# Action: TERM each target group; after the grace period, KILL any group that
# still has a live member with the identity (pid and start time) seen in the
# snapshot; then verify. A zombie counts as stopped. The script removes no
# files: the offload client's own exit trap removes its PC02 mirror once its
# group has stopped.
#
# PC02: the same walk runs there over one bounded ssh call, scoped to the
# offload run roots that hash to this run directory (run-<cksum>-*). A root is
# walked only when its pgid file names the group that the anchor leads. PC01 is
# stopped first, so the offload client's exit trap usually removes the PC02
# mirror before PC02 is walked.
#
# Output (stdout): one line per group stopped, one `dry-run` line per group
# under --dry-run, or `none`. Refusals and diagnostics go to stderr.
#   pc01 group=<pgid> stopped=<n> signal=TERM|KILL
#   dry-run pc02 group=<pgid> would-stop=<n>
#
# Exit: 0 every checked host is clean; 1 a group survived, was refused, or a
# PC02 check did not finish; 2 usage error or refusal before any stop (no
# /proc, unknown task, ambiguous run choice, ambiguous run directory).
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
  printf 'usage: bin/fm-test-run-stop.sh <task-id> [--dry-run] [--host pc01|pc02]\n'
  exit "${1:-0}"
}

# --- Process-table engine -------------------------------------------------

# Snapshot /proc into PT_* tables keyed by pid:
#   PT_PPID PT_PGID PT_START PT_STATE   from /proc/<pid>/stat
#   PT_WRAP   a shell (sh/bash/dash/zsh) whose command line names a test-run script
#   PT_ANCH   a process with a test-run script as a standalone program argument
#   PT_DAEMON a command line naming the no-mistakes daemon
ts_snapshot() {
  local d pid line rest joined tok a0
  local -a f av
  declare -gA PT_PPID=() PT_PGID=() PT_START=() PT_STATE=() PT_WRAP=() PT_ANCH=() PT_DAEMON=()
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
    case "$joined" in
      *"no-mistakes daemon"*) PT_DAEMON[$pid]=1 ;;
    esac
    for tok in ${av[@]+"${av[@]}"}; do
      case "$tok" in
        *" "*) continue ;;
        bin/fm-test-run.sh|*/bin/fm-test-run.sh|bin/fm-test-compute.sh|*/bin/fm-test-compute.sh|bin/fm-pc02-test-offload.sh|*/bin/fm-pc02-test-offload.sh)
          PT_ANCH[$pid]=1
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
# or the pgid anchors must lead), HOST_LABEL, GRACE, DRY_RUN. Result lines go to
# stdout, refusals to stderr. Returns 0 clean, 1 refused or a group survived,
# 2 when RUN_DIR cannot be resolved.
ts_engine() {
  local rd a c p g m ccwd ident bad sig
  local -i i n tries limit alive_any hops rc=0
  local ok leader_ok
  local -a q=() targets=()
  local -A anchor=() desc=() anc=() kids=() members=() cand=() tident=() tcount=() tsig=()

  rd=$(readlink -f -- "$RUN_DIR" 2>/dev/null) && [ -n "$rd" ] || return 2
  ts_snapshot

  for a in "${!PT_PPID[@]}"; do
    [ -n "${PT_ANCH[$a]:-}" ] || continue
    if [ -n "${REQUIRE_PGID:-}" ] && [ "${PT_PGID[$a]}" != "$REQUIRE_PGID" ]; then
      continue
    fi
    ccwd=$(readlink -f -- "/proc/$a/cwd" 2>/dev/null) || continue
    ts_under "$ccwd" "$rd" || continue
    anchor[$a]=1
  done
  [ "${#anchor[@]}" -gt 0 ] || return 0

  for p in "${!PT_PPID[@]}"; do
    c=${PT_PPID[$p]}
    kids[$c]+="$p "
  done

  q=("${!anchor[@]}")
  for ((i = 0; i < ${#q[@]}; i++)); do
    p=${q[i]}
    [ -z "${desc[$p]:-}" ] || continue
    desc[$p]=1
    for c in ${kids[$p]:-}; do
      q+=("$c")
    done
  done

  for a in "${!anchor[@]}"; do
    p=${PT_PPID[$a]:-0}
    hops=0
    while [ "$p" -gt 1 ] && [ -n "${PT_PPID[$p]:-}" ] && [ "$hops" -lt 64 ]; do
      anc[$p]=1
      p=${PT_PPID[$p]}
      hops=$((hops + 1))
    done
  done

  for p in "${!PT_PGID[@]}"; do
    g=${PT_PGID[$p]}
    members[$g]+="$p "
  done
  for p in "${!desc[@]}"; do
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
    # A group led by an anchor's own wrapper or anchor is the run's group, so
    # its same-group orphans belong to the run too.
    leader_ok=0
    if { [ -n "${desc[$g]:-}" ] || { [ -n "${anc[$g]:-}" ] && [ -n "${PT_WRAP[$g]:-}" ]; }; } \
      && [ -z "${PT_DAEMON[$g]:-}" ]; then
      leader_ok=1
    fi
    ok=1
    bad=""
    ident=""
    n=0
    for m in ${members[$g]:-}; do
      if [ -n "${PT_DAEMON[$m]:-}" ]; then
        ok=0
        bad="$m (no-mistakes daemon)"
        break
      fi
      case "${PT_STATE[$m]:-}" in
        Z) continue ;;
      esac
      if [ -n "${desc[$m]:-}" ] || { [ -n "${anc[$m]:-}" ] && [ -n "${PT_WRAP[$m]:-}" ]; }; then
        :
      elif [ "$leader_ok" -eq 1 ]; then
        :
      else
        ok=0
        bad=$m
        break
      fi
      ident+="$m:${PT_START[$m]} "
      n=$((n + 1))
    done
    if [ "$ok" -eq 1 ]; then
      if [ "$n" -gt 0 ]; then
        targets+=("$g")
        tident[$g]=$ident
        tcount[$g]=$n
      fi
    else
      printf 'fm-test-run-stop: refused %s group %s: member %s is outside the test run\n' "$HOST_LABEL" "$g" "$bad" >&2
      rc=1
    fi
  done

  [ "${#targets[@]}" -gt 0 ] || return "$rc"

  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    for g in "${targets[@]}"; do
      printf 'dry-run %s group=%s would-stop=%s\n' "$HOST_LABEL" "$g" "${tcount[$g]}"
    done
    return "$rc"
  fi

  for g in "${targets[@]}"; do
    kill -TERM -- "-$g" 2>/dev/null || true
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
    sig=TERM
    if ts_group_alive "${tident[$g]}"; then
      sig=KILL
      kill -KILL -- "-$g" 2>/dev/null || true
    fi
    tsig[$g]=$sig
  done

  for g in "${targets[@]}"; do
    tries=0
    while ts_group_alive "${tident[$g]}" && [ "$tries" -lt 25 ]; do
      sleep 0.2
      tries=$((tries + 1))
    done
    if ts_group_alive "${tident[$g]}"; then
      printf 'fm-test-run-stop: %s group %s still has live processes after KILL\n' "$HOST_LABEL" "$g" >&2
      rc=1
    else
      printf '%s group=%s stopped=%s signal=%s\n' "$HOST_LABEL" "$g" "${tcount[$g]}" "${tsig[$g]}"
    fi
  done
  return "$rc"
}

# PC02 entry point, run as `bash -s` over ssh. Walks each offload run root that
# hashes to this run directory and whose pgid file names the run's group.
# shellcheck disable=SC2329 # Invoked on PC02 from the text `declare -f` sends over ssh.
ts_remote_main() {  # <cksum> <remote-base> <grace> <dry-run>
  local ck=$1 base=$2 d g rc=0
  GRACE=$3
  DRY_RUN=$4
  HOST_LABEL=pc02
  for d in "$HOME/$base/run-$ck-"*; do
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

# --- Entry point ------------------------------------------------------------

main() {
  local task="" dry=0 arg r rc=0 probe_failed=0 out_all="" out
  local do_pc01=0 do_pc02=0 grace ssh_timeout meta branch wt overview sel run_id nm_root local_dir=""
  local ck host base
  local -a want=() matches=()

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
      -h|--help) usage ;;
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
    absent)
      printf 'none\n'
      exit 0
      ;;
    selected\|*)
      IFS='|' read -r _ run_id _ _ <<< "$sel"
      ;;
    *)
      die "no-mistakes run for $task is not unambiguous ($sel); nothing stopped"
      ;;
  esac
  case "$run_id" in
    ''|*[!A-Za-z0-9_-]*) die "unreadable run id for $task; nothing stopped" ;;
  esac

  nm_root=$(dirname "$(fm_nm_state_db "$wt")")
  shopt -s nullglob
  matches=("$nm_root"/worktrees/*/"$run_id")
  shopt -u nullglob
  case "${#matches[@]}" in
    0) ;;
    1)
      [ -d "${matches[0]}" ] && local_dir=${matches[0]}
      ;;
    *) die "run $run_id has ${#matches[@]} run directories; nothing stopped" ;;
  esac

  if [ "$do_pc01" -eq 1 ]; then
    if [ -n "$local_dir" ]; then
      RUN_DIR=$local_dir
      REQUIRE_PGID=
      HOST_LABEL=pc01
      DRY_RUN=$dry
      out=$(ts_engine)
      r=$?
      [ -z "$out" ] || out_all+="$out"$'\n'
      if [ "$r" -ne 0 ]; then
        rc=1
        [ "$r" -eq 2 ] && printf 'fm-test-run-stop: pc01 run directory cannot be resolved\n' >&2
      fi
    fi
  fi

  if [ "$do_pc02" -eq 1 ]; then
    if [ -z "$local_dir" ]; then
      printf 'fm-test-run-stop: PC02 not checked: the local run directory for %s is gone, so its mirror cannot be matched\n' "$run_id" >&2
      probe_failed=1
      rc=1
    else
      ck=$(printf '%s' "$(cd "$local_dir" && pwd)" | cksum | cut -d' ' -f1)
      host=${FM_PC02_OFFLOAD_HOST:-pc02}
      base=${FM_PC02_OFFLOAD_REMOTE_BASE:-.fm-pc02-test-offload}
      case "$base" in
        ''|/*|*..*|*[!A-Za-z0-9._/-]*) die "FM_PC02_OFFLOAD_REMOTE_BASE must be a plain relative path" ;;
      esac
      out=$(
        {
          declare -f "${TS_FUNCS[@]}"
          printf 'ts_remote_main %q %q %q %q\n' "$ck" "$base" "$GRACE" "$dry"
        } | timeout "$ssh_timeout" ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" bash -s
      )
      r=$?
      [ -z "$out" ] || out_all+="$out"$'\n'
      if [ "$r" -ne 0 ]; then
        printf 'fm-test-run-stop: PC02 check exited %s; PC02 state is not confirmed\n' "$r" >&2
        probe_failed=1
        rc=1
      fi
    fi
  fi

  if [ -n "$out_all" ]; then
    printf '%s' "$out_all"
  elif [ "$probe_failed" -eq 0 ]; then
    printf 'none\n'
  fi
  exit "$rc"
}

main "$@"
