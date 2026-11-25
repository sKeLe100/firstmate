#!/usr/bin/env bash
# fm-worker-memory-guard.sh - keep one worker's memory from taking the host.
#
# Why: on 2026-11-24 a single OpenCode scout grew to 15.7 GB inside its working
# copy and the kernel kill took down WSL and every pane with it. Two layers
# contain that, and this helper owns both:
#
#   scope-prefix  the CONTAINMENT: a per-worker cgroup memory scope. Prints the
#                 command prefix bin/fm-spawn.sh puts in front of a ship or
#                 scout launch, `systemd-run --user --scope` with MemoryHigh
#                 (throttle), MemoryMax (kernel kill inside the scope only) and
#                 MemorySwapMax=0. The swap cap is load-bearing: measured live,
#                 a 400 MB allocation under MemoryMax=96M merely swapped and
#                 survived, and died (exit 137) only once swap was capped. Keep
#                 MemoryHigh close under MemoryMax: a worker held between a low
#                 MemoryHigh and MemoryMax with no swap is throttled forever
#                 instead of killed (measured: the allocation hung).
#                 It needs no root. The scope is proven before it is trusted:
#                 a probe scope must report the requested memory.max, so a host
#                 whose user manager has no delegated memory controller is
#                 unavailable rather than silently unlimited.
#                   exit 0  prefix on stdout
#                   exit 3  scope unavailable (reason on stderr); the caller
#                           launches WITHOUT a cgroup limit, says so loudly, and
#                           relies on the detection layer below
#                   exit 4  scope disabled by config (scope=off)
#   check         the DETECTION and STOP: one pass over every live ship and
#                 scout task. The process tree of each task (processes
#                 attributed by worktree, as bin/fm-lane-vitals-lib.sh does) is
#                 summed as RSS. A task over rss-stop is stopped. When the host
#                 reports low (bin/fm-host-memory.sh: MemAvailable under
#                 config/host-memory-floor, or swap nearly full), the single
#                 largest task at or above host-stop-min is stopped, one per
#                 pass. A stop is `bin/fm-control.sh <task> exit` - it keeps the
#                 worktree and every uncommitted change, and is never teardown
#                 or discard - followed by a durable `blocked [key=memory-guard]`
#                 status event, so firstmate reconciles it. A task is stopped
#                 once per launch generation; a failed stop is retried after
#                 two minutes. Secondmates are never measured or stopped.
#                 bin/fm-watch.sh runs this every 30 seconds, detached.
#   limits        print the effective settings, one key=value per line.
#
#   brief-check   the PREVENTION: reads a written brief's `# Task` section
#                 (never the scaffold) for an install, clone, or unpack that
#                 lands in the working copy. A line that names an install
#                 command or dependency install, says it happens inside the
#                 worktree, working copy, checkout, or repo, and names no
#                 ~/fm-scratch path is REFUSED (exit 5, lines on stderr); an
#                 install line that names no destination is a stderr warning
#                 (exit 0). Negated lines ("never install ...") pass.
#                 FM_ALLOW_WORKTREE_INSTALL=1 downgrades a refusal to a
#                 warning for the rare task that truly needs it. Scratch trees
#                 belong in ~/fm-scratch/<task-id>/.
#
# Usage: fm-worker-memory-guard.sh scope-prefix [<task-id> [<generation>]]
#        fm-worker-memory-guard.sh check
#        fm-worker-memory-guard.sh brief-check <brief-file>
#        fm-worker-memory-guard.sh limits
#
# Settings: optional config/worker-memory-guard (docs/configuration.md "Worker
# memory guard"), one `key=value` per line, blank lines and # comments allowed:
#   scope=off       no cgroup scope (default on)
#   scope-high=<MiB>  MemoryHigh, default 5120
#   scope-max=<MiB>   MemoryMax, default 6144 (must be >= scope-high)
#   guard=off       no watcher check (default on)
#   rss-stop=<MiB>  per-task RSS that stops it, default 4096
#   host-stop-min=<MiB>  smallest task a low host may stop, default 1024
# A malformed file is rejected loudly (exit 2), never replaced by defaults.
#
# Test seams: FM_SYSTEMD_RUN (the systemd-run binary), FM_PROC_ROOT_OVERRIDE
# (/proc), FM_MEMINFO_OVERRIDE (via bin/fm-host-memory.sh),
# FM_WORKER_MEMORY_GUARD_CONTROL_BIN (bin/fm-control.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SYSTEMD_RUN="${FM_SYSTEMD_RUN:-systemd-run}"
CONTROL_BIN="${FM_WORKER_MEMORY_GUARD_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}"
RETRY_AFTER=120

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
  exit 0
fi

SCOPE=on SCOPE_HIGH=5120 SCOPE_MAX=6144 GUARD=on RSS_STOP=4096 HOST_STOP_MIN=1024

load_config() {
  local file="$CONFIG/worker-memory-guard" line key val
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ -r "$file" ] || { echo "fm-worker-memory-guard: $file must be a readable regular file" >&2; return 2; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    val=${line#*=}
    case "$key" in
      scope|guard)
        [ "$val" = on ] || [ "$val" = off ] || { echo "fm-worker-memory-guard: $key= must be on or off in $file" >&2; return 2; }
        if [ "$key" = scope ]; then SCOPE=$val; else GUARD=$val; fi ;;
      scope-high|scope-max|rss-stop|host-stop-min)
        case "$val" in ''|*[!0-9]*|0*|??????????*) echo "fm-worker-memory-guard: $key= must be a positive integer of MiB no wider than 9 digits in $file" >&2; return 2 ;; esac
        case "$key" in
          scope-high) SCOPE_HIGH=$val ;;
          scope-max) SCOPE_MAX=$val ;;
          rss-stop) RSS_STOP=$val ;;
          host-stop-min) HOST_STOP_MIN=$val ;;
        esac ;;
      *) echo "fm-worker-memory-guard: unrecognized line in $file: $line" >&2; return 2 ;;
    esac
  done < "$file"
  if [ "$SCOPE_MAX" -lt "$SCOPE_HIGH" ]; then
    echo "fm-worker-memory-guard: scope-max must be at least scope-high in $file" >&2
    return 2
  fi
}

cmd_scope_prefix() {
  local id=${1:-} gen=${2:-} unit name probe want got
  [ "$SCOPE" = on ] || { echo "fm-worker-memory-guard: worker memory scope disabled by config (scope=off)" >&2; return 4; }
  command -v "$SYSTEMD_RUN" >/dev/null 2>&1 || { echo "fm-worker-memory-guard: scope unavailable: systemd-run not found" >&2; return 3; }
  want=$(( SCOPE_MAX * 1048576 ))
  # shellcheck disable=SC2016
  probe='p=$(sed -n "s/^0:://p" /proc/self/cgroup); cat "/sys/fs/cgroup$p/memory.max"'
  got=$("$SYSTEMD_RUN" --user --scope --quiet -p "MemoryHigh=${SCOPE_HIGH}M" -p "MemoryMax=${SCOPE_MAX}M" -p MemorySwapMax=0 -- /bin/sh -c "$probe" 2>/dev/null </dev/null) || {
    echo "fm-worker-memory-guard: scope unavailable: systemd-run --user --scope failed (no user systemd manager on this host)" >&2
    return 3
  }
  [ "$got" = "$want" ] || {
    echo "fm-worker-memory-guard: scope unavailable: the probe scope reported memory.max=${got:-none}, not $want (memory controller not delegated to the user manager)" >&2
    return 3
  }
  name=$(printf '%s' "${id:-task}-${gen:-g}" | tr -c 'A-Za-z0-9:_.-' '-')
  unit="fm-worker-$name"
  printf '%s --user --scope --quiet --unit=%s --description=%s -p MemoryHigh=%sM -p MemoryMax=%sM -p MemorySwapMax=0\n' \
    "$SYSTEMD_RUN" "$unit" "firstmate-worker-memory-scope" "$SCOPE_HIGH" "$SCOPE_MAX"
}

meta_get() {  # <meta-file> <key>
  awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1" 2>/dev/null
}

append_status() {  # <task> <line>
  local task=$1 line=$2 status="$STATE/$1.status"
  printf '%s\n' "$line" >> "$status" || return 1
  if [ -e "$CONFIG/fleet-ledger" ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$status" >/dev/null 2>&1 || true
  fi
}

# stop_task <task> <reason> <gen> <rss-mib>: stop through the control plane
# (never teardown), then record the durable event. Skips a task already stopped
# for this launch generation; retries a failed stop after RETRY_AFTER seconds.
stop_task() {
  local task=$1 reason=$2 gen=$3 rss=$4 marker="$STATE/.memory-guard-stopped-$1" prior='' now out rc
  now=$(date +%s)
  if [ -e "$marker" ]; then
    prior=$(cat "$marker" 2>/dev/null)
    case "$prior" in
      "$gen:stopped") return 0 ;;
      "$gen:failed")
        [ $(( now - $(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null || echo 0) )) -ge "$RETRY_AFTER" ] || return 0 ;;
    esac
  fi
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" "$CONTROL_BIN" "$task" exit 2>&1 </dev/null)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s:stopped\n' "$gen" > "$marker"
    append_status "$task" "blocked [at=$now] [key=memory-guard]: worker stopped by the memory guard (${reason}; process tree ${rss} MiB); worktree and uncommitted work kept, review before relaunch"
    echo "fm-worker-memory-guard: stopped $task: $reason"
  else
    printf '%s:failed\n' "$gen" > "$marker"
    if [ "$prior" != "$gen:failed" ]; then
      append_status "$task" "blocked [at=$now] [key=memory-guard]: memory guard could not stop the worker (${reason}; process tree ${rss} MiB): ${out##*$'\n'}"
    fi
    echo "fm-worker-memory-guard: stop of $task FAILED ($rc): $out" >&2
  fi
}

cmd_check() {
  local rc
  [ "$GUARD" = on ] || return 0
  # One pass at a time: a slow control call must not stack another behind it.
  local lock="$STATE/.worker-memory-guard.lock" holder
  if ! mkdir "$lock" 2>/dev/null; then
    holder=$(cat "$lock/pid" 2>/dev/null)
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then return 0; fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || return 0
  fi
  printf '%s\n' "$$" > "$lock/pid"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-wmg.XXXXXX") || { rm -rf "$lock"; return 1; }
  check_pass "$tmp"
  rc=$?
  rm -rf "$tmp" "$lock"
  return "$rc"
}

check_pass() {  # <tmp-dir>
  local tmp=$1 os lanes procs attr id meta kind wt gen host_out host_rc
  lanes="$tmp/lanes"; procs="$tmp/procs"; attr="$tmp/attr"
  : > "$lanes"
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(meta_get "$meta" kind)
    case "$kind" in ship|scout) ;; *) continue ;; esac
    wt=$(meta_get "$meta" worktree)
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    printf '%s\t%s\n' "$id" "$wt" >> "$lanes"
  done
  [ -s "$lanes" ] || return 0
  # shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  # shellcheck source=bin/fm-lane-vitals-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-lane-vitals-lib.sh"
  os=$(uname -s 2>/dev/null || echo Linux)
  fm_lane_vitals_processes "$os" "$procs" || { echo "fm-worker-memory-guard: process table unreadable; nothing measured" >&2; return 0; }
  fm_lane_vitals_attribute "$lanes" "$procs" > "$attr"
  # Per-task RSS in MiB, largest first.
  local sums="$tmp/sums"
  awk -F'\t' '{ kb[$1] += $3 } END { for (k in kb) printf "%d\t%s\n", kb[k] / 1024, k }' "$attr" | sort -rn > "$sums"
  local rss
  while IFS=$'\t' read -r rss id; do
    [ "$rss" -ge "$RSS_STOP" ] || continue
    gen=$(meta_get "$STATE/$id.meta" spawn_gen)
    stop_task "$id" "process tree over the ${RSS_STOP} MiB per-worker limit" "${gen:-none}" "$rss"
  done < "$sums"
  host_out=$("$SCRIPT_DIR/fm-host-memory.sh" 2>/dev/null); host_rc=$?
  if [ "$host_rc" -eq 1 ]; then
    while IFS=$'\t' read -r rss id; do
      [ "$rss" -ge "$HOST_STOP_MIN" ] || break
      gen=$(meta_get "$STATE/$id.meta" spawn_gen)
      [ "$(cat "$STATE/.memory-guard-stopped-$id" 2>/dev/null)" = "${gen:-none}:stopped" ] && continue
      stop_task "$id" "host memory low - ${host_out#low: }" "${gen:-none}" "$rss"
      break
    done < "$sums"
  fi
  return 0
}

cmd_brief_check() {
  local file=${1:-} out rc=0
  [ -n "$file" ] && [ -r "$file" ] || return 0
  out=$(awk '
    /^# / { in_task = ($0 ~ /^# Task/); next }
    !in_task { next }
    {
      l = tolower($0)
      if (l ~ /(^|[^a-z])(not|never|no|don.t|without|avoid|forbid|forbidden|refuse|instead of|out of scope)([^a-z]|$)/) next
      if (l !~ /((npm|pnpm|yarn|bun)[ ]+(install|i|ci|add)([^a-z]|$)|pip3? install|git clone|cargo install|go install|uv (pip|sync)|composer install|bundle install|install(s|ing)? .*(node_modules|dependencies|packages|npm))/) next
      if (l ~ /fm-scratch/) next
      kind = (l ~ /(in|into|inside|within|under)( the| your| this)? (task |working |disposable )?(worktree|working copy|checkout|repo)/) ? "refuse" : "warn"
      print kind "\t" $0
    }' "$file")
  [ -n "$out" ] || return 0
  if printf '%s\n' "$out" | grep -q '^refuse'; then
    if [ "${FM_ALLOW_WORKTREE_INSTALL:-0}" = 1 ]; then
      echo "warning: brief names an install inside the working copy (allowed by FM_ALLOW_WORKTREE_INSTALL=1):" >&2
    else
      rc=5
      echo "error: brief names an install inside the working copy; a runaway install can exhaust the host (2026-11-24). Rewrite it to build under ~/fm-scratch/<task-id>/ instead:" >&2
    fi
    printf '%s\n' "$out" | sed -n 's/^refuse\t/  /p' >&2
  fi
  if printf '%s\n' "$out" | grep -q '^warn'; then
    echo "warning: brief names an install without a destination; installs and clones belong under ~/fm-scratch/<task-id>/, never the working copy:" >&2
    printf '%s\n' "$out" | sed -n 's/^warn\t/  /p' >&2
  fi
  return "$rc"
}

cmd_limits() {
  printf 'scope=%s\nscope-high=%s\nscope-max=%s\nguard=%s\nrss-stop=%s\nhost-stop-min=%s\n' \
    "$SCOPE" "$SCOPE_HIGH" "$SCOPE_MAX" "$GUARD" "$RSS_STOP" "$HOST_STOP_MIN"
}

sub=${1:-}
[ $# -eq 0 ] || shift
load_config || exit 2
case "$sub" in
  scope-prefix) cmd_scope_prefix "$@" ;;
  check) cmd_check ;;
  brief-check) cmd_brief_check "$@" ;;
  limits) cmd_limits ;;
  *) echo "usage: fm-worker-memory-guard.sh scope-prefix [<task-id> [<generation>]] | check | brief-check <brief-file> | limits" >&2; exit 2 ;;
esac
