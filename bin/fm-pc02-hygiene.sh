#!/usr/bin/env bash
# fm-pc02-hygiene.sh - cheap, read-only PC02 storage, memory and stray-test
# report for firstmate's heartbeat host check.
#
# Why: PC02's /tmp is tmpfs, so a leaked /tmp/fm-test-run.* root spends RAM.
# On 2026-11-04 one leaked run root was 5.2 GiB, 8731 /tmp/fm-* entries were
# older than six hours with no live process referencing them, and MemAvailable
# fell to about 6 GiB of 27 until the captain cleaned it by hand. This script
# makes that pressure visible before a run fails or the host wedges.
#
# Usage:
#   fm-pc02-hygiene.sh
#
# One bounded ssh call to PC02 runs bin/fm-pc02-hygiene-lib.sh's inventory
# probe, which never kills a process and never removes a test root; its only
# write is the probe's own scratch directory on PC02's home disk. Nothing else
# on PC02 deletes a root it does not own.
#
# Output (stdout, one key=value per line):
#   host=<ssh target>
#   mem_total_mib=<n> mem_available_mib=<n>
#   tmp_total_mib=<n> tmp_used_mib=<n> tmp_free_mib=<n> tmp_used_pct=<n>
#   disk_total_mib=<n> disk_used_mib=<n> disk_free_mib=<n> disk_used_pct=<n>
#   stale_test_roots=<n> stale_test_mib=<n>
#   stale_test_root=<path>          (one per counted root, at most 50)
#   stale_test_roots_omitted=<n>    (only when more than 50 were counted)
#   stale_age_secs=<n>
#   old_test_procs=<n>
#   idle_age_secs=<n>
#   pressure=<comma list|->
#   status=ok|pressure
#
# pressure names every crossed bound: mem_available, tmp_free, disk_free,
# stale_test_roots, old_test_procs. A field that could not be read makes the
# reading unknown (exit 2) rather than zero, because a missing capacity number
# is not evidence of free space. The counted root paths are the exact set a
# manual reclaim may consider; the report never deletes or kills anything.
#
# Exit codes: 0 = report taken with no pressure, 1 = report taken with at
# least one bound crossed, 2 = the reading could not be taken (unreachable
# PC02, unparseable output, malformed local setting). The report is read-only
# in every case.
#
# Env overrides:
#   FM_PC02_OFFLOAD_HOST           ssh target (default: pc02)
#   FM_PC02_HYGIENE_TIMEOUT_SECS   bound for the one ssh call (default: 20)
#   FM_PC02_OFFLOAD_TMP_ROOT       PC02 tmp directory to inspect (default: /tmp)
#   FM_PC02_OFFLOAD_REMOTE_BASE    PC02 offload run-root base, relative to
#                                  $HOME (default: .fm-pc02-test-offload)
#   FM_PC02_OFFLOAD_MEMINFO        meminfo path on PC02 (default: /proc/meminfo)
#   FM_PC02_HYGIENE_STALE_AGE_SECS test-root age that reads stale
#                                  (default: 21600, six hours)
#   FM_PC02_HYGIENE_IDLE_AGE_SECS  process age that reads old
#                                  (default: 10800, three hours)
#   FM_PC02_OFFLOAD_MEM_MIN_FREE_MB  MemAvailable floor (default: 4096; 0
#                                  disables the check)
#   FM_PC02_OFFLOAD_TMP_MIN_FREE_MB  /tmp free floor (default: 2048; 0
#                                  disables)
#   FM_PC02_OFFLOAD_DISK_MIN_FREE_MB PC02 $HOME disk free floor (default:
#                                  5120; 0 disables)
#   FM_PC02_HYGIENE_STALE_ROOTS_MAX stale test-root count that reads as
#                                  pressure (default: 0)
#   FM_PC02_HYGIENE_OLD_PROCS_MAX  old test-process count that reads as
#                                  pressure (default: 0)
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [ "$#" -gt 0 ]; then
  echo "fm-pc02-hygiene.sh: unknown argument: $1" >&2
  exit 2
fi

# shellcheck source=bin/fm-pc02-hygiene-lib.sh
. "$SELF_DIR/fm-pc02-hygiene-lib.sh"

HOST="${FM_PC02_OFFLOAD_HOST:-pc02}"
TIMEOUT="${FM_PC02_HYGIENE_TIMEOUT_SECS:-20}"
TMP_ROOT="${FM_PC02_OFFLOAD_TMP_ROOT:-/tmp}"
REMOTE_BASE="${FM_PC02_OFFLOAD_REMOTE_BASE:-.fm-pc02-test-offload}"
MEMINFO="${FM_PC02_OFFLOAD_MEMINFO:-/proc/meminfo}"
STALE_AGE="${FM_PC02_HYGIENE_STALE_AGE_SECS:-$FM_PC02_DEFAULT_STALE_AGE_SECS}"
IDLE_AGE="${FM_PC02_HYGIENE_IDLE_AGE_SECS:-$FM_PC02_DEFAULT_IDLE_AGE_SECS}"
MEM_FLOOR="${FM_PC02_OFFLOAD_MEM_MIN_FREE_MB:-$FM_PC02_DEFAULT_MEM_MIN_FREE_MB}"
TMP_FLOOR="${FM_PC02_OFFLOAD_TMP_MIN_FREE_MB:-$FM_PC02_DEFAULT_TMP_MIN_FREE_MB}"
DISK_FLOOR="${FM_PC02_OFFLOAD_DISK_MIN_FREE_MB:-$FM_PC02_DEFAULT_DISK_MIN_FREE_MB}"
STALE_MAX="${FM_PC02_HYGIENE_STALE_ROOTS_MAX:-0}"
OLD_PROC_MAX="${FM_PC02_HYGIENE_OLD_PROCS_MAX:-0}"

for setting in \
  "FM_PC02_HYGIENE_TIMEOUT_SECS:$TIMEOUT" \
  "FM_PC02_HYGIENE_STALE_AGE_SECS:$STALE_AGE" \
  "FM_PC02_HYGIENE_IDLE_AGE_SECS:$IDLE_AGE" \
  "FM_PC02_OFFLOAD_MEM_MIN_FREE_MB:$MEM_FLOOR" \
  "FM_PC02_OFFLOAD_TMP_MIN_FREE_MB:$TMP_FLOOR" \
  "FM_PC02_OFFLOAD_DISK_MIN_FREE_MB:$DISK_FLOOR" \
  "FM_PC02_HYGIENE_STALE_ROOTS_MAX:$STALE_MAX" \
  "FM_PC02_HYGIENE_OLD_PROCS_MAX:$OLD_PROC_MAX"; do
  name=${setting%%:*}
  value=${setting#*:}
  case "$value" in
    '' | *[!0-9]*)
      echo "fm-pc02-hygiene.sh: $name must be a non-negative integer, got '$value'" >&2
      exit 2
      ;;
  esac
done

command -v ssh >/dev/null 2>&1 || {
  echo "fm-pc02-hygiene.sh: ssh not available on this host" >&2
  exit 2
}

remote_script=$(fm_pc02_hygiene_remote_script "$TMP_ROOT" "$REMOTE_BASE" \
  "$STALE_AGE" "$IDLE_AGE" "$MEMINFO")
out=$(timeout "$TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout="$TIMEOUT" \
  -o ConnectionAttempts=1 "$HOST" "bash -lc $(printf '%q' "$remote_script")" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "fm-pc02-hygiene.sh: PC02 probe failed (ssh exit $rc): $out" >&2
  exit 2
fi

capacity=$(printf '%s\n' "$out" | awk '$1 == "capacity" { sub(/^capacity /, ""); print; found = 1; exit } END { exit !found }') || {
  echo "fm-pc02-hygiene.sh: PC02 probe returned no capacity line: $out" >&2
  exit 2
}

mem_total=''
mem_available=''
tmp_total=''
tmp_used=''
tmp_free=''
disk_total=''
disk_used=''
disk_free=''
stale_roots=''
stale_kb=''
old_procs=''
stale_omitted=''
stale_paths=()
for field in $capacity; do
  key=${field%%=*}
  value=${field#*=}
  case "$key" in
    mem_total_kb) mem_total=$value ;;
    mem_available_kb) mem_available=$value ;;
    tmp_total_kb) tmp_total=$value ;;
    tmp_used_kb) tmp_used=$value ;;
    tmp_free_kb) tmp_free=$value ;;
    disk_total_kb) disk_total=$value ;;
    disk_used_kb) disk_used=$value ;;
    disk_free_kb) disk_free=$value ;;
    stale_roots) stale_roots=$value ;;
    stale_kb) stale_kb=$value ;;
    old_test_procs) old_procs=$value ;;
  esac
done
while IFS= read -r line; do
  case "$line" in
    'stale_path '*) stale_paths+=("${line#stale_path }") ;;
    'stale_paths_omitted '*) stale_omitted=${line#stale_paths_omitted } ;;
  esac
done <<<"$out"

for field in "$mem_total" "$mem_available" "$tmp_total" "$tmp_used" "$tmp_free" \
  "$disk_total" "$disk_used" "$disk_free" "$stale_roots" "$stale_kb" "$old_procs"; do
  case "$field" in
    '' | *[!0-9]*)
      echo "fm-pc02-hygiene.sh: PC02 probe returned an unreadable field (capacity='$capacity')" >&2
      exit 2
      ;;
  esac
done
case "$stale_omitted" in
  '') ;;
  *[!0-9]*)
    echo "fm-pc02-hygiene.sh: PC02 probe returned an unreadable omitted-root count (capacity='$capacity')" >&2
    exit 2
    ;;
esac

mib() { printf '%s' "$(( $1 / 1024 ))"; }
pct() {  # used total
  if [ "$2" -gt 0 ]; then printf '%s' "$(( ($1 * 100) / $2 ))"; else printf '0'; fi
}

mem_total_mib=$(mib "$mem_total")
mem_available_mib=$(mib "$mem_available")
tmp_total_mib=$(mib "$tmp_total")
tmp_used_mib=$(mib "$tmp_used")
tmp_free_mib=$(mib "$tmp_free")
disk_total_mib=$(mib "$disk_total")
disk_used_mib=$(mib "$disk_used")
disk_free_mib=$(mib "$disk_free")
stale_test_mib=$(mib "$stale_kb")
tmp_used_pct=$(pct "$tmp_used" "$tmp_total")
disk_used_pct=$(pct "$disk_used" "$disk_total")

pressure=
add_pressure() {  # <name> [detail]
  if [ -n "$pressure" ]; then pressure="$pressure,$1"; else pressure=$1; fi
}
[ "$MEM_FLOOR" -eq 0 ] || [ "$mem_available_mib" -ge "$MEM_FLOOR" ] || add_pressure mem_available
[ "$TMP_FLOOR" -eq 0 ] || [ "$tmp_free_mib" -ge "$TMP_FLOOR" ] || add_pressure tmp_free
[ "$DISK_FLOOR" -eq 0 ] || [ "$disk_free_mib" -ge "$DISK_FLOOR" ] || add_pressure disk_free
[ "$stale_roots" -le "$STALE_MAX" ] || add_pressure stale_test_roots
[ "$old_procs" -le "$OLD_PROC_MAX" ] || add_pressure old_test_procs

printf 'host=%s\n' "$HOST"
printf 'mem_total_mib=%s mem_available_mib=%s\n' "$mem_total_mib" "$mem_available_mib"
printf 'tmp_total_mib=%s tmp_used_mib=%s tmp_free_mib=%s tmp_used_pct=%s\n' \
  "$tmp_total_mib" "$tmp_used_mib" "$tmp_free_mib" "$tmp_used_pct"
printf 'disk_total_mib=%s disk_used_mib=%s disk_free_mib=%s disk_used_pct=%s\n' \
  "$disk_total_mib" "$disk_used_mib" "$disk_free_mib" "$disk_used_pct"
printf 'stale_test_roots=%s stale_test_mib=%s\n' "$stale_roots" "$stale_test_mib"
for p in ${stale_paths[@]+"${stale_paths[@]}"}; do
  printf 'stale_test_root=%s\n' "$p"
done
[ -z "$stale_omitted" ] || printf 'stale_test_roots_omitted=%s\n' "$stale_omitted"
printf 'stale_age_secs=%s\n' "$STALE_AGE"
printf 'old_test_procs=%s\n' "$old_procs"
printf 'idle_age_secs=%s\n' "$IDLE_AGE"
printf 'pressure=%s\n' "${pressure:--}"
if [ -z "$pressure" ]; then
  printf 'status=ok\n'
  exit 0
fi
printf 'status=pressure\n'
exit 1
