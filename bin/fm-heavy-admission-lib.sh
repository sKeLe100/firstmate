#!/usr/bin/env bash
# Shared host admission for fm-test-run.sh and fm-lint.sh.
# fm_heavy_admit <label> reserves fd 9 until the caller exits. Do not unlink
# the slot file: all worktrees on this host/user must lock the same inode.
# Nonblocking flock uses Perl's portable flock(2), including on macOS; the
# inherited open file description keeps the lock held in the calling shell.
# Production always uses $HOME/.fm-heavy-run-slot.lock. FM_HEAVY_SLOT may
# override it only with FM_TEST_SEAM=1; contents name the last holder while locked.
# Wait at most FM_HEAVY_WAIT_SECS (300), polling every FM_HEAVY_POLL_SECS (5).
# A slot whose recorded holder is gone while the flock is still held means a
# killed run's descendant inherited fd 9: after a 1s grace the live waiter takes
# over the record, logs "reclaimed stale slot holder=pid=<pid>", and admits
# instead of waiting out the bounded backoff on a leak nobody will release.
# The record names the holder's process start identity, so a reused pid is stale.
# Admission requires load5 < FM_HEAVY_MAX_LOAD5 (8), and available memory >=
# FM_HEAVY_MIN_MEM_KIB (3145728). Unknown metrics fail closed within that wait.
# Linux uses MemAvailable; macOS uses free + inactive + speculative vm_stat pages.
# FM_TEST_SEAM=1 enables FM_HEAVY_TEST_LOAD5 and FM_HEAVY_TEST_MEM_KIB.
# FM_PC02_OFFLOAD_REMOTE=1 marks a suite already governed by a PC02 offload slot.

fm_heavy_metrics() {
  FM_HEAVY_LOAD=unknown
  FM_HEAVY_MEM=unknown
  if [ -r /proc/loadavg ]; then
    FM_HEAVY_LOAD=$(awk '{print $2}' /proc/loadavg)
    FM_HEAVY_MEM=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  elif command -v sysctl >/dev/null 2>&1; then
    FM_HEAVY_LOAD=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $3}')
    FM_HEAVY_MEM=$(vm_stat 2>/dev/null | awk '
      NR==1 {for (i=1;i<=NF;i++) if ($i=="of") size=$(i+1)}
      /Pages (free|inactive|speculative):/ {gsub(/\./,"",$NF); pages+=$NF}
      END {if (size > 0) printf "%.0f\n", pages*size/1024}')
  fi
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then
    FM_HEAVY_LOAD=${FM_HEAVY_TEST_LOAD5:-$FM_HEAVY_LOAD}
    FM_HEAVY_MEM=${FM_HEAVY_TEST_MEM_KIB:-$FM_HEAVY_MEM}
  fi
}

# Print a process start identity that changes when its pid is reused.
fm_heavy_proc_identity() {
  local pid=$1 stat_line starttime value
  local -a stat_fields
  if [ -r "/proc/$pid/stat" ]; then
    stat_line=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    printf 'starttime=%s\n' "$starttime"
    return 0
  fi
  value=$(TZ=UTC LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf 'lstart=%s\n' "$(printf '%s' "$value" | tr ' ' '_')"
}

# Print the recorded holder fields; fail when either field is absent or invalid.
fm_heavy_slot_record() {
  local record pid start rest
  record=$(head -n 1 "$1" 2>/dev/null) || return 1
  read -r pid start rest <<< "$record"
  case "$pid" in pid=*) ;; *) return 1 ;; esac
  pid=${pid#pid=}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$start" in start=*) ;; *) return 1 ;; esac
  start=${start#start=}
  case "$start" in ''|*[[:space:]]*) return 1 ;; esac
  printf 'pid=%s start=%s\n' "$pid" "$start"
}

# Print the pid recorded as the live slot holder; fail when the record is absent,
# invalid, or names a process whose start identity no longer matches.
fm_heavy_slot_pid() {
  local record pid start current
  record=$(fm_heavy_slot_record "$1") || return 1
  read -r pid start <<< "$record"
  pid=${pid#pid=}
  start=${start#start=}
  current=$(fm_heavy_proc_identity "$pid") || return 1
  [ "$current" = "$start" ] || return 1
  printf '%s\n' "$pid"
}

# Record this shell as the slot holder, preserving the slot's inode.
fm_heavy_write_holder() {
  local identity
  identity=$(fm_heavy_proc_identity "$$") || {
    echo 'heavy admission: could not read this process start identity' >&2
    return 1
  }
  printf 'pid=%s start=%s task=%s run=%s\n' "$$" "$identity" "${FM_TASK_ID:-local}" "$2" >"$1" 2>/dev/null && return 0
  echo "heavy admission: could not record holder in slot file: $1" >&2
  return 1
}

# Reclaim a slot whose recorded owner is gone while its flock is still held.
# Returns 0 and prints the stale pid after taking over the record, 2 when the
# record cannot be written, and 1 when the slot belongs to a live owner.
fm_heavy_reclaim() {
  local slot=$1 record stale start current
  record=$(fm_heavy_slot_record "$slot") || return 1
  read -r stale start <<< "$record"
  stale=${stale#pid=}
  start=${start#start=}
  [ "$stale" != "$$" ] || return 1
  if current=$(fm_heavy_proc_identity "$stale" 2>/dev/null) && [ "$current" = "$start" ]; then
    return 1
  fi
  # Grace lets a concurrent reclaimer win and lets a dying owner finish.
  sleep 1
  [ "$(fm_heavy_slot_record "$slot" 2>/dev/null || true)" = "$record" ] || return 1
  if current=$(fm_heavy_proc_identity "$stale" 2>/dev/null) && [ "$current" = "$start" ]; then
    return 1
  fi
  fm_heavy_write_holder "$slot" "$2" || return 2
  # Read back after the grace so only the last reclaimer proceeds.
  sleep 1
  [ "$(fm_heavy_slot_pid "$slot" 2>/dev/null || true)" = "$$" ] || return 1
  echo "heavy admission: reclaimed stale slot holder=pid=$stale" >&2
  printf '%s\n' "$stale"
}

fm_heavy_admit() {
  local label=$1 slot
  if [ "${FM_PC02_OFFLOAD_REMOTE:-}" = 1 ]; then
    echo "heavy admission: admitted $label on PC02 offload; offload slots govern concurrency" >&2
    return 0
  fi
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then
    slot=${FM_HEAVY_SLOT:-$HOME/.fm-heavy-run-slot.lock}
  else
    slot=$HOME/.fm-heavy-run-slot.lock
  fi
  local max_wait=${FM_HEAVY_WAIT_SECS:-300} poll=${FM_HEAVY_POLL_SECS:-5}
  local max_load=${FM_HEAVY_MAX_LOAD5:-8} min_mem=${FM_HEAVY_MIN_MEM_KIB:-3145728}
  local started now remaining delay locked=0 reason holder reclaimed='' rc
  for now in "$max_wait" "$poll" "$max_load" "$min_mem"; do
    case "$now" in ''|*[!0-9]*) echo 'heavy admission: limits must be whole nonnegative numbers' >&2; return 2 ;; esac
  done
  if [ "$poll" -eq 0 ] || [ "$max_load" -eq 0 ]; then
    echo 'heavy admission: poll interval and maximum load must be greater than zero' >&2
    return 2
  fi
  command -v perl >/dev/null 2>&1 || { echo 'heavy admission: perl is required for flock' >&2; return 2; }
  if ! exec 9>>"$slot"; then
    echo "heavy admission: could not open slot file for locking: $slot" >&2
    return 2
  fi
  started=$(date +%s)
  while :; do
    if [ "$locked" -eq 0 ]; then
      if perl -e 'open(my $f, ">&=9") or die $!; exit(flock($f, 2|4) ? 0 : 75)' 9>&9; then
        locked=1
        reclaimed=
        # Truncate only after owning the lock, preserving its inode.
        if ! fm_heavy_write_holder "$slot" "$label"; then
          exec 9>&-
          return 2
        fi
        if [ "$(fm_heavy_slot_pid "$slot" 2>/dev/null || true)" != "$$" ]; then
          echo "heavy admission: slot holder record is not this process after locking" >&2
          exec 9>&-
          return 2
        fi
      fi
    fi
    if [ "$locked" -eq 0 ] && [ -z "$reclaimed" ]; then
      if reclaimed=$(fm_heavy_reclaim "$slot" "$label"); then
        :
      else
        rc=$?
        if [ "$rc" -eq 2 ]; then
          exec 9>&-
          return 2
        fi
        reclaimed=
      fi
    fi
    if [ "$locked" -eq 0 ] && [ -n "$reclaimed" ] \
      && [ "$(fm_heavy_slot_pid "$slot" 2>/dev/null || true)" != "$$" ]; then
      reclaimed=
    fi
    reason="slot-busy"
    if [ "$locked" -eq 1 ] || [ -n "$reclaimed" ]; then
      fm_heavy_metrics
      reason=$(awk -v l="$FM_HEAVY_LOAD" -v m="$FM_HEAVY_MEM" -v max="$max_load" -v min="$min_mem" '
        BEGIN {
          detail = ""
          if (l !~ /^[0-9]+([.][0-9]+)?$/ || l + 0 >= max + 0) {
            detail = "load5=" l " (need <" max ")"
          }
          if (m !~ /^[0-9]+$/ || m + 0 < min + 0) {
            detail = detail (detail == "" ? "" : "; ") "MemAvailable_KiB=" m " (need >=" min ")"
          }
          print detail
        }')
      if [ -z "$reason" ]; then
        echo "heavy admission: admitted $label pid=$$ load5=$FM_HEAVY_LOAD MemAvailable_KiB=$FM_HEAVY_MEM" >&2
        return 0
      fi
      reason="resources $reason"
    fi
    holder=$(cat "$slot" 2>/dev/null) || holder=unknown
    now=$(date +%s)
    remaining=$((max_wait - now + started))
    if [ "$remaining" -le 0 ]; then
      echo "heavy admission: refused $label after ${max_wait}s: $reason; holder=$holder" >&2
      exec 9>&-
      return 75
    fi
    delay=$poll
    [ "$delay" -le "$remaining" ] || delay=$remaining
    echo "heavy admission: waiting ${delay}s for $label: $reason; holder=$holder" >&2
    sleep "$delay"
  done
}
