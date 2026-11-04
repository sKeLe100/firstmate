#!/usr/bin/env bash
# fm-pc02-hygiene-lib.sh - single owner of the PC02 stale-test-root and
# host-capacity probe that bin/fm-pc02-test-offload.sh runs before claiming a
# slot and bin/fm-pc02-hygiene.sh reports read-only.
#
# Why one owner: both callers need the same definition of a stale root (an
# offload run root or an fm-test-run.* root older than the bound with no live
# process reference), the same offload-owner marker rule, and the same
# MemAvailable//tmp/disk readings. A second copy would drift the moment one
# side changed a rule.
#
# The probe is a plain bash script sent over ssh, so it needs nothing from the
# mirrored worktree: the offload runs it before it creates one.
#
# Usage (sourced):
#   fm_pc02_hygiene_remote_script <sweep:yes|no> <tmp_root> <remote_base>
#       <stale_age_secs> <idle_age_secs> <meminfo>
#
# The generated script starts with a "# fm-pc02-hygiene-probe" sentinel so a
# harness fake can identify it, and prints exactly one line starting with
# "capacity":
#   capacity mem_total_kb=.. mem_available_kb=..
#            tmp_total_kb=.. tmp_used_kb=.. tmp_free_kb=..
#            disk_total_kb=.. disk_used_kb=.. disk_free_kb=..
#            stale_roots=.. stale_kb=.. old_test_procs=.. swept_roots=..
#
# Any field that could not be read is left empty; callers must treat an empty
# required field as an unclear host read rather than zero.
#
# Definitions (owned here, not restated in the callers):
#   - A test root is "$HOME/<remote_base>"/run-* or "<tmp_root>"/fm-test-run.*,
#     a real directory (not a symlink) whose mtime is at least stale_age_secs
#     old.
#   - An offload run root is owned while its "pgid" file names a live process
#     group; that is the existing owner marker the remote run writes. Any root,
#     offload or test-run, is also owned while a live process references it by
#     cwd or by an exact command-line argument.
#   - With sweep=yes the script removes every stale root no owner holds,
#     restoring owner write first (test fixtures leave read-only *.git-hooks
#     directories behind), and reports how many it removed. With sweep=no it
#     only measures, so the hygiene report can never kill or delete anything.
#   - old_test_procs counts processes whose elapsed time exceeds
#     idle_age_secs and whose command line names one of the test surfaces:
#     fm-test-run, fm-lint, fm-test- helpers, fm-live-lab, or a tmux lab whose
#     command line also carries the fm- prefix.
#   - stale_kb and disk/tmp sizes are KiB from du -sk and df -Pk, field numbers
#     2, 3 and 4 (total, used, free), matching every supported Linux target.

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

fm_pc02_hygiene_remote_script() {
  local sweep=$1 tmp_root=$2 remote_base=$3 stale_age=$4 idle_age=$5 meminfo=$6
  local q_tmp q_base q_meminfo
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
sweep=$sweep
now=\$(date +%s 2>/dev/null || echo 0)
mem_total=\$(awk '\$1 == "MemTotal:" { print \$2; exit }' "\$meminfo" 2>/dev/null)
mem_available=\$(awk '\$1 == "MemAvailable:" { print \$2; exit }' "\$meminfo" 2>/dev/null)
tmp_total= tmp_used= tmp_free=
read -r tmp_total tmp_used tmp_free <<EOF_DF || true
\$(df -Pk -- "\$tmp_root" 2>/dev/null | awk 'NR == 2 { print \$2, \$3, \$4 }')
EOF_DF
disk_total= disk_used= disk_free=
read -r disk_total disk_used disk_free <<EOF_DF2 || true
\$(df -Pk -- "\$HOME" 2>/dev/null | awk 'NR == 2 { print \$2, \$3, \$4 }')
EOF_DF2

roots=()
for d in "\$HOME/\$remote_base"/run-* "\$tmp_root"/fm-test-run.*; do
  [ -d "\$d" ] && [ ! -L "\$d" ] || continue
  m=\$(stat -c %Y -- "\$d" 2>/dev/null) || continue
  case "\$m" in ''|*[!0-9]*) continue ;; esac
  [ \$((now - m)) -ge "\$stale_age" ] && roots+=("\$d")
done

refs=
build_refs() {
  refs=\$(mktemp "\${TMPDIR:-\$tmp_root}/fm-pc02-hygiene-refs.XXXXXX" 2>/dev/null) || return 1
  for p in /proc/[0-9]*; do
    [ -r "\$p/cmdline" ] || continue
    tr '\0' '\n' < "\$p/cmdline" 2>/dev/null >>"\$refs"
    readlink "\$p/cwd" >>"\$refs" 2>/dev/null || true
  done
}
referenced() {
  [ -n "\$refs" ] || return 1
  grep -qxF -- "\$1" "\$refs" 2>/dev/null && return 0
  grep -qF -- "\$1/" "\$refs" 2>/dev/null
}
live_group() {
  [ -f "\$1/pgid" ] || return 1
  local g
  g=\$(cat "\$1/pgid" 2>/dev/null) || return 1
  case "\$g" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 -- "-\$g" 2>/dev/null
}

stale_roots=0
stale_kb=0
swept_roots=0
for d in \${roots[@]+"\${roots[@]}"}; do
  live_group "\$d" && continue
  [ -n "\$refs" ] || build_refs
  [ -n "\$refs" ] || continue
  referenced "\$d" && continue
  stale_roots=\$((stale_roots + 1))
  kb=\$(du -sk -- "\$d" 2>/dev/null | awk '{ print \$1; exit }')
  case "\$kb" in ''|*[!0-9]*) kb=0 ;; esac
  stale_kb=\$((stale_kb + kb))
  if [ "\$sweep" = yes ]; then
    chmod -R u+w -- "\$d" 2>/dev/null || true
    rm -rf -- "\$d" 2>/dev/null && swept_roots=\$((swept_roots + 1))
  fi
done
[ -z "\$refs" ] || rm -f -- "\$refs" 2>/dev/null || true

old_test_procs=0
if ps -eo pid=,etimes=,args= >/dev/null 2>&1; then
  old_test_procs=\$(ps -eo pid=,etimes=,args= 2>/dev/null | awk -v age="\$idle_age" -v self="\$\$" '
    \$1 ~ /^[0-9]+\$/ && \$1 != self && \$2 ~ /^[0-9]+\$/ && \$2 > age {
      line = \$0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", line)
      if (line ~ /^awk / || line ~ /^ps /) next
      if (line ~ /fm-test-run|fm-lint|fm-test-|fm-live-lab/ || (line ~ /tmux/ && line ~ /fm-/)) n++
    }
    END { print n + 0 }')
fi

printf 'capacity mem_total_kb=%s mem_available_kb=%s tmp_total_kb=%s tmp_used_kb=%s tmp_free_kb=%s disk_total_kb=%s disk_used_kb=%s disk_free_kb=%s stale_roots=%s stale_kb=%s old_test_procs=%s swept_roots=%s\n' \
  "\$mem_total" "\$mem_available" "\$tmp_total" "\$tmp_used" "\$tmp_free" \
  "\$disk_total" "\$disk_used" "\$disk_free" "\$stale_roots" "\$stale_kb" \
  "\$old_test_procs" "\$swept_roots"
REMOTE
}
