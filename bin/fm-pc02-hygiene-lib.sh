#!/usr/bin/env bash
# fm-pc02-hygiene-lib.sh - single owner of the PC02 host-capacity probe that
# bin/fm-pc02-test-offload.sh reads before claiming a slot, and of the read-only
# stale-test-root inventory bin/fm-pc02-hygiene.sh reports.
#
# Why one owner: both callers need the same MemAvailable, /tmp and disk readings,
# and the report needs the same definition of a stale root (an offload run root,
# fm-test-run.* root, or a test-fixture root older than the bound with no live
# process reference) and of an owned root. A second copy would drift the moment
# one side changed a rule.
#
# The probe is a plain bash script sent over ssh, so it needs nothing from the
# mirrored worktree: the offload runs it before it creates one. It only ever
# reads another run's state: it never kills a process and never removes a root;
# its only write is its own scratch directory under $HOME. Each offload run
# removes its own mirror and run-scoped TMPDIR on exit; nothing here touches
# another run's root.
#
# Usage (sourced):
#   fm_pc02_hygiene_capacity_script <tmp_root> <meminfo>
#   fm_pc02_hygiene_remote_script <tmp_root> <remote_base> <stale_age_secs>
#       <idle_age_secs> <meminfo>
#
# Both generated scripts start with a "# fm-pc02-hygiene-probe" sentinel so a
# harness fake can identify them, and each prints exactly one line starting
# with "capacity". The capacity script prints the host readings the offload
# gates on; the remote script adds the read-only stale-root and old-process
# inventory the report formats:
#   capacity mem_total_kb=.. mem_available_kb=..
#            tmp_total_kb=.. tmp_used_kb=.. tmp_free_kb=..
#            disk_total_kb=.. disk_used_kb=.. disk_free_kb=..
#            [stale_roots=.. stale_kb=.. old_test_procs=..]
# followed, for the remote script only, by at most
# FM_PC02_DEFAULT_STALE_PATHS_SHOWN "stale_path <root>" lines naming the counted
# roots, and one "stale_paths_omitted <n>" line when more were counted than
# shown. The bound keeps an incident-scale host from producing unbounded
# output for one ssh call.
#
# Any field that could not be read is left empty; callers must treat an empty
# required field as an unclear host read rather than zero.
#
# Definitions (owned here, not restated in the callers):
#   - A test root is "$HOME/<remote_base>"/run-*, "<tmp_root>"/fm-test-run.*, or
#     a "<tmp_root>"/fm-* directory carrying the tests/lib.sh .fm-test-fixture
#     marker: a real directory (not a symlink) whose mtime - the marker's own
#     for a fixture root - is at least stale_age_secs old.
#   - An offload run root is owned while its "pgid" file names a live process
#     group; a fixture root is owned while its .fm-test-fixture marker names a
#     live process whose recorded start time and command line still match that
#     process, so a recycled PID cannot make a dead owner look alive. Any root,
#     offload, test-run or fixture, is also owned while a live process
#     references it by cwd, by a command-line argument (including a
#     --flag=value argument), by an environment value (KEY=value), or by an
#     open file descriptor.
#   - The reference scan is one pass over /proc and its scratch directory lives
#     on $HOME, not on the tmpfs being reported. If that scan cannot run or
#     reads nothing, no root is counted and stale_roots/stale_kb stay empty: an
#     unverified host is never treated as reference-free.
#   - old_test_procs counts processes whose elapsed time exceeds
#     idle_age_secs and whose command line names one of the test surfaces:
#     fm-test-run, fm-lint, fm-test- helpers, fm-live-lab, or a tmux lab whose
#     command line also carries the fm- prefix.
#   - stale_kb and disk/tmp sizes are KiB from du -sk and df -Pk, field numbers
#     2, 3 and 4 (total, used, free), matching every supported Linux target.
#   - Candidate discovery, the reference lookup and du are batched into a
#     bounded number of subprocesses, so a host holding thousands of leaked
#     roots still finishes inside the callers' ssh bounds.

# Shared defaults, so the offload's floors and the hygiene report cannot drift.
# shellcheck disable=SC2034 # Consumed by the sourcing callers, not here.
FM_PC02_DEFAULT_MEM_MIN_FREE_MB=4096
# shellcheck disable=SC2034
FM_PC02_DEFAULT_TMP_MIN_FREE_MB=2048
# shellcheck disable=SC2034
FM_PC02_DEFAULT_DISK_MIN_FREE_MB=5120
# shellcheck disable=SC2034
FM_PC02_DEFAULT_STALE_AGE_SECS=21600
# shellcheck disable=SC2034
FM_PC02_DEFAULT_IDLE_AGE_SECS=10800
# Counted roots whose paths one probe names before it reports the rest as an
# omitted count instead.
FM_PC02_DEFAULT_STALE_PATHS_SHOWN=50

_fm_pc02_hygiene_capacity_readings() {  # <tmp_root> <meminfo>
  local q_tmp q_meminfo
  q_tmp=$(printf '%q' "$1")
  q_meminfo=$(printf '%q' "$2")
  cat <<REMOTE
mem_total=\$(awk '\$1 == "MemTotal:" { print \$2; exit }' $q_meminfo 2>/dev/null)
mem_available=\$(awk '\$1 == "MemAvailable:" { print \$2; exit }' $q_meminfo 2>/dev/null)
tmp_total= tmp_used= tmp_free=
read -r tmp_total tmp_used tmp_free <<EOF_DF || true
\$(df -Pk -- $q_tmp 2>/dev/null | awk 'NR == 2 { print \$2, \$3, \$4 }')
EOF_DF
disk_total= disk_used= disk_free=
read -r disk_total disk_used disk_free <<EOF_DF2 || true
\$(df -Pk -- "\$HOME" 2>/dev/null | awk 'NR == 2 { print \$2, \$3, \$4 }')
EOF_DF2
REMOTE
}

fm_pc02_hygiene_capacity_script() {  # <tmp_root> <meminfo>
  printf '# fm-pc02-hygiene-probe\ntmp_root=%q\nmeminfo=%q\n' "$1" "$2"
  _fm_pc02_hygiene_capacity_readings "$1" "$2"
  cat <<'REMOTE'
printf 'capacity mem_total_kb=%s mem_available_kb=%s tmp_total_kb=%s tmp_used_kb=%s tmp_free_kb=%s disk_total_kb=%s disk_used_kb=%s disk_free_kb=%s\n' \
  "$mem_total" "$mem_available" "$tmp_total" "$tmp_used" "$tmp_free" \
  "$disk_total" "$disk_used" "$disk_free"
REMOTE
}

fm_pc02_hygiene_remote_script() {  # <tmp_root> <remote_base> <stale_age> <idle_age> <meminfo>
  local tmp_root=$1 remote_base=$2 stale_age=$3 idle_age=$4 meminfo=$5
  local q_tmp q_base q_meminfo shown_cap=$FM_PC02_DEFAULT_STALE_PATHS_SHOWN
  q_tmp=$(printf '%q' "$tmp_root")
  q_base=$(printf '%q' "$remote_base")
  q_meminfo=$(printf '%q' "$meminfo")
  cat <<REMOTE
# fm-pc02-hygiene-probe
tmp_root=$q_tmp
remote_base=$q_base
stale_age=$stale_age
idle_age=$idle_age
meminfo=$q_meminfo
now=\$(date +%s 2>/dev/null || echo 0)

scratch=
rm_scratch() {
  [ -z "\$scratch" ] || rm -rf -- "\$scratch" 2>/dev/null || true
}
trap rm_scratch EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

roots=()
declare -A seen=()
add_stale_root() {
  case "\$2" in ''|*[!0-9]*) return 0 ;; esac
  [ \$((now - \$2)) -ge "\$stale_age" ] || return 0
  [ -z "\${seen[\$1]:-}" ] || return 0
  seen[\$1]=1
  roots+=("\$1")
}
while read -r m p; do
  d=\${p%/.fm-test-fixture}
  [ -f "\$p" ] || continue
  [ -d "\$d" ] && [ ! -L "\$d" ] || continue
  add_stale_root "\$d" "\$m"
done < <(stat -c '%Y %n' -- "\$tmp_root"/fm-*/.fm-test-fixture 2>/dev/null)
while read -r m d; do
  [ -d "\$d" ] && [ ! -L "\$d" ] || continue
  add_stale_root "\$d" "\$m"
done < <(stat -c '%Y %n' -- "\$HOME/\$remote_base"/run-* "\$tmp_root"/fm-test-run.* 2>/dev/null)

build_scan() {
  scratch=\$(mktemp -d "\$HOME/.fm-pc02-hygiene.XXXXXX" 2>/dev/null) || return 1
  {
    find /proc/[0-9]*/fd -maxdepth 1 -type l -printf '%l\n' 2>/dev/null
    find /proc/[0-9]* -maxdepth 1 -name cwd -printf '%l\n' 2>/dev/null
    cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\0' '\n'
    cat /proc/[0-9]*/environ 2>/dev/null | tr '\0' '\n'
  } >"\$scratch/refs"
  [ -s "\$scratch/refs" ] || return 1
  printf '%s\n' "\${roots[@]}" >"\$scratch/roots"
  awk '
    function owned_root(s) {
      if (s in root) { print s; return 1 }
      while (sub(/\\/[^\\/]*\$/, "", s)) if (s in root) { print s; return 1 }
      return 0
    }
    NR == FNR { root[\$0] = 1; next }
    {
      rest = \$0
      if (owned_root(rest)) next
      while ((eq = index(rest, "=")) > 0) {
        rest = substr(rest, eq + 1)
        if (owned_root(rest)) next
      }
    }' "\$scratch/roots" "\$scratch/refs" >"\$scratch/owned" || return 1
}
live_group() {
  local g
  [ -f "\$1/pgid" ] || return 1
  read -r g <"\$1/pgid" 2>/dev/null || return 1
  case "\$g" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 -- "-\$g" 2>/dev/null
}
marker_owner_alive() {
  local pid identity stored_start starttime statline hex
  local -a fields=()
  [ -f "\$1" ] || return 1
  { read -r pid; read -r identity; } <"\$1" 2>/dev/null || return 1
  case "\$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "\$identity" ] || return 1
  [ -r "/proc/\$pid/stat" ] || return 1
  read -r statline <"/proc/\$pid/stat" 2>/dev/null || return 1
  read -r -a fields <<<"\${statline##*)}"
  [ "\${#fields[@]}" -ge 20 ] || return 1
  starttime=\${fields[19]}
  case "\$starttime" in ''|*[!0-9]*) return 1 ;; esac
  stored_start=\${identity#*=}
  stored_start=\${stored_start%% *}
  [ "\$stored_start" = "\$starttime" ] || return 1
  hex=\$(od -An -v -tx1 "/proc/\$pid/cmdline" 2>/dev/null | tr -d '[:space:]') || return 1
  [ -n "\$hex" ] || return 1
  [ "\${identity##*cmdline-hex=}" = "\$hex" ]
}

stale_roots=0
stale_kb=0
stale_list=()
if [ \${#roots[@]} -gt 0 ]; then
  if build_scan; then
    declare -A owned=()
    while read -r p; do
      owned["\$p"]=1
    done <"\$scratch/owned"
    for d in "\${roots[@]}"; do
      live_group "\$d" && continue
      marker_owner_alive "\$d/.fm-test-fixture" && continue
      [ -z "\${owned[\$d]:-}" ] || continue
      stale_list+=("\$d")
    done
    stale_roots=\${#stale_list[@]}
    if [ \${#stale_list[@]} -gt 0 ]; then
      if du_out=\$(du -sk -- "\${stale_list[@]}" 2>/dev/null); then
        stale_kb=\$(printf '%s\n' "\$du_out" | awk '{ size += \$1 } END { print size + 0 }')
      else
        stale_kb=
      fi
    fi
  else
    stale_roots=
    stale_kb=
  fi
fi
REMOTE
  _fm_pc02_hygiene_capacity_readings "$tmp_root" "$meminfo"
  cat <<REMOTE
old_test_procs=
if ps -eo pid=,etimes=,args= >/dev/null 2>&1; then
  old_test_procs=\$(ps -eo pid=,etimes=,args= 2>/dev/null | awk -v age="\$idle_age" -v self="\$\$" '
    \$1 ~ /^[0-9]+\$/ && \$1 != self && \$2 ~ /^[0-9]+\$/ && \$2 > age {
      line = \$0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", line)
      if (line ~ /^awk / || line ~ /^ps /) next
      if (line ~ /fm-test-run|fm-lint|fm-test-|fm-live-lab/ || (line ~ /tmux/ && line ~ /fm-/)) n++
    }
    END { print n + 0 }')
  case "\$old_test_procs" in ''|*[!0-9]*) old_test_procs= ;; esac
fi

printf 'capacity mem_total_kb=%s mem_available_kb=%s tmp_total_kb=%s tmp_used_kb=%s tmp_free_kb=%s disk_total_kb=%s disk_used_kb=%s disk_free_kb=%s stale_roots=%s stale_kb=%s old_test_procs=%s\n' \\
  "\$mem_total" "\$mem_available" "\$tmp_total" "\$tmp_used" "\$tmp_free" \\
  "\$disk_total" "\$disk_used" "\$disk_free" "\$stale_roots" "\$stale_kb" \\
  "\$old_test_procs"

shown=0
for d in \${stale_list[@]+"\${stale_list[@]}"}; do
  [ "\$shown" -lt $shown_cap ] || break
  printf 'stale_path %s\n' "\$d"
  shown=\$((shown + 1))
done
[ -z "\$stale_roots" ] || [ "\$stale_roots" -le "\$shown" ] \\
  || printf 'stale_paths_omitted %s\n' "\$((stale_roots - shown))"
REMOTE
}
