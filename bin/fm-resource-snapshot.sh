#!/usr/bin/env bash
# fm-resource-snapshot.sh - one read-only point-in-time view of fleet resources
# and live workers, for the /fleet skill.
#
# Read-only contract: this script never writes under state/, data/, config/, or
# projects/, never spawns, steers, merges, tears down, or edits backlog, and
# never asks quota-axi to refresh or delegate credential renewal. Its only
# writes are private temp files removed on exit. It answers a different
# question from /bearings: what resources and panes exist and what each worker
# is doing, not where the captain left off. It reuses the existing readers and
# adds no second canonical fleet-state reader; it never forks
# bin/fm-fleet-snapshot.sh.
#
# Usage:
#   fm-resource-snapshot.sh                 full picture, TOON (agent default)
#   fm-resource-snapshot.sh --json          the same model as JSON
#   fm-resource-snapshot.sh --home-only     workers of one home only (used
#                                           locally and by the remote call)
#   fm-resource-snapshot.sh --home <dir>    home to read (default FM_HOME)
#   -h, --help                              this header
#
# Output sections, always in this order:
#   hosts[]        machine,load1,cores,mem_free_pct,disk_free_gb,disk_path,
#                  uptime,read_utc
#   drives[]       machine,mount,total_gb,free_gb,pct_used,warn,read_utc
#                  warn=low under 20 GB, watch under 40 GB, ok otherwise
#   quota[]        lane,account,plan,window,pct_remaining,resets_et,pace,state,
#                  read_utc,reading_utc,reason
#                  reading_utc is when quota-axi itself took the reading (the
#                  provider's refreshedAt, else the document's generatedAt);
#                  no projection is ever rendered as a fact.
#   workers[]      machine,home_lane,task,kind,model,spend_lane,stage,age,
#                  last_active,ctx_band,pr,read_utc
#   panes[]        machine,session,workspace,tab,pane,agent,agent_status,task,
#                  cwd,title,read_utc
#   strays[]       machine,pane,reason,workspace_label,foreground_cwd
#   secondmates[]  id,host,home,state,workers,account,read_utc
#   roles[]        role,where,account,evidence,read_utc
#   testing[]      machine,item,state,detail,read_utc
#   android[]      machine,avd,serial,state,boot_completed,detail,read_utc
#                  one row per AVD listed by `emulator -list-avds` plus any
#                  adb serial with no matching AVD. state is the adb device
#                  state (device/offline/unauthorized), `stopped` for a listed
#                  AVD with no running emulator and a clean adb read, `unknown`
#                  for a listed AVD when adb is missing/failing or another
#                  emulator's AVD name is unresolved, or `none` when both probes
#                  read cleanly and found nothing. avd is `unknown` for a
#                  running emulator whose AVD name cannot be resolved; that
#                  emulator renders once, not also as a stopped listing. Only
#                  emulator-* serials are name-resolved, so a physical or other
#                  adb device renders as its own row and never hides a stopped
#                  AVD. boot_completed is `1`/`0` from
#                  `getprop sys.boot_completed`, `unknown` when empty,
#                  `stale`/`failed` when that probe did not answer, or `-` for a
#                  non-running device. A missing adb or emulator is an
#                  unavailable[] row with its reason, never zero devices.
#                  Probes are read-only: no emulator is ever started or wiped.
#   compute[]      rung,account,plan,used,allowance,reset,status,runs,read_utc
#   unavailable[]  source,reason,read_utc
#
# "Lane" always means the spend lane: claude#1, claude#2, opencode-go, codex
# (other models report `unknown`, which the model column still explains).
# ctx_band is the worker's own harness context band as `<band>(<pct>%)`:
# bin/fm-context-usage.sh reads a Claude transcript and
# bin/fm-opencode-context-usage.sh reads OpenCode's session store; both use the
# config/context-thresholds bands. It is `unknown` when the harness's store has
# no evidence and `n/a` for a harness with no context reader.
# Every figure carries the UTC read time of the snapshot run that produced it;
# a stale or failed figure is labelled stale/failed, never rendered as zero.
#
# Remote path: PC02 worker records are read directly. The primary call is one
# `bin/fm-on.sh <route> fm-resource-snapshot.sh --home-only --json`; when the
# remote checkout does not carry this script yet, or that call fails, the same
# records are read through one bounded ssh batch using the remote checkout's
# existing fm-crew-state.sh and fm-context-usage.sh. PC02 host headroom, drives,
# herdr sessions, offload slots, personal-use switch, runner unit, and its
# pinned account come from one separate ssh batch. The parent secondmate ledger
# is never consulted.
#
# Per-source bounds (seconds, env-overridable): quota 8, each herdr call 5,
# pc02 host batch 10, remote worker read 20, local fleet reads 15, roles 10,
# collie 5, local crew-state 8, context band 5, local host probe 5, testing 10
# per network source, each Android probe 8, PC02 Android batch 20. A bound hit
# produces an unavailable row (or a
# `stale`/`unknown` figure) and never a hang. Collectors run in parallel in
# isolated subshells; exit 0 when any section rendered, 1 only when nothing
# rendered.
#
# Account identities are never built in. They come from one private config file,
# <home>/config/resource-snapshot, of generic key=value lines, and each key can
# be overridden by the environment variable FM_RESOURCE_<KEY in upper case>:
#   github_user, github_repo           GitHub Actions billing and run reads
#   gitlab_namespace                   GitLab free-tier minute read
#   forgejo_url, forgejo_owner,        Forgejo API base, repo owner and repo name
#   forgejo_repo
#   forgejo_credentials                path to a file with "Username: ..." and
#                                      "Password: ..." lines; there is no default
#                                      path, and the secret is only ever piped to
#                                      curl on stdin, never in argv or output
# A collector whose keys are absent renders one unavailable row with reason
# "not configured"; the rest of the snapshot still renders.
#
# Fixture seams, for tests and for deterministic replay:
#   FM_RESOURCE_NOW               epoch seconds or ISO time to report as now
#   FM_RESOURCE_STATE_DIR         override the home's state directory
#   FM_RESOURCE_DATA_DIR          override the home's data directory
#   FM_RESOURCE_HOSTS_JSON        {"hosts":[...],"drives":[...]} replaces live PC01 host
#                                 and drive probes; PC02 rows come from the remote fixture
#   FM_RESOURCE_HERDR_JSON_PC01   {"sessions":[],"workspaces":[],"panes":[]}
#   FM_RESOURCE_HERDR_JSON_PC02   same shape for PC02
#   FM_RESOURCE_ROLES_FILE        JSON array used verbatim as roles[]
#   FM_RESOURCE_REMOTE_FIXTURE    JSON {hosts,drives,sessions,workers,
#                                 mate_account} replaces every PC02 read
#   FM_RESOURCE_TESTING_FIXTURE   JSON {testing:[...],compute:[...]} replaces
#                                 every live testing and compute probe
#   FM_RESOURCE_ANDROID_FIXTURE   JSON {android:[...],unavailable:[...]}
#                                 replaces every live Android probe on both hosts
#   FM_RESOURCE_ADB               explicit adb path (empty means adb is absent)
#   FM_RESOURCE_EMULATOR          explicit emulator path (empty means absent)
#   FM_RESOURCE_CONTEXT_FIXTURE   JSON object mapping task id to ctx_band
#   FM_RESOURCE_<KEY>             override one config key (see below)
#   QUOTA_AXI_SNAPSHOT            passed through to quota-axi (its own seam)
#   FM_RESOURCE_SKIP_REMOTE=1     skip PC02 collection entirely
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_RESOURCE_STATE_DIR:-${FM_STATE_OVERRIDE:-$FM_HOME/state}}"
DATA="${FM_RESOURCE_DATA_DIR:-${FM_DATA_OVERRIDE:-$FM_HOME/data}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SCHEMA=fm-resource-snapshot.v1

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

FORMAT=toon
HOME_ONLY=0

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --home-only) HOME_ONLY=1 ;;
    --home)
      [ "$#" -ge 2 ] || { echo 'fm-resource-snapshot: --home needs a directory' >&2; exit 2; }
      FM_HOME=$2
      STATE="${FM_RESOURCE_STATE_DIR:-$FM_HOME/state}"
      DATA="${FM_RESOURCE_DATA_DIR:-$FM_HOME/data}"
      CONFIG="$FM_HOME/config"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-resource-snapshot: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

cfg() {  # <key> -> env override FM_RESOURCE_<KEY>, else config/resource-snapshot
  local key=$1 up v
  up=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
  eval "v=\${FM_RESOURCE_$up:-}"
  if [ -z "$v" ] && [ -f "$CONFIG/resource-snapshot" ]; then
    v=$(awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$CONFIG/resource-snapshot" 2>/dev/null)
  fi
  printf '%s' "$v"
}

# slot_busy <lockfile>: true when some process holds a lock on the file, read
# from /proc/locks without ever taking the lock; falls back to fuser, then lsof.
slot_busy() {
  local f=$1 inode
  [ -e "$f" ] || return 1
  inode=$(stat -c %i "$f" 2>/dev/null)
  if [ -n "$inode" ] && [ -r /proc/locks ]; then
    awk -v i="$inode" '{ n = split($6, a, ":"); if (a[n] == i) { found = 1 } } END { exit !found }' /proc/locks
    return
  fi
  if command -v fuser >/dev/null 2>&1; then fuser "$f" >/dev/null 2>&1; return; fi
  if command -v lsof >/dev/null 2>&1; then lsof -- "$f" >/dev/null 2>&1; return; fi
  return 1
}

bound() {  # <name> <default>
  local v
  eval "v=\${$1:-}"
  case "$v" in ''|*[!0-9]*|0) printf '%s\n' "$2" ;; *) printf '%s\n' "$v" ;; esac
}

QUOTA_TIMEOUT=$(bound FM_RESOURCE_QUOTA_TIMEOUT 8)
HERDR_TIMEOUT=$(bound FM_RESOURCE_HERDR_TIMEOUT 5)
SSH_TIMEOUT=$(bound FM_RESOURCE_SSH_TIMEOUT 10)
REMOTE_WORKERS_TIMEOUT=$(bound FM_RESOURCE_REMOTE_WORKERS_TIMEOUT 20)
CREW_STATE_TIMEOUT=$(bound FM_RESOURCE_CREW_STATE_TIMEOUT 8)
CONTEXT_TIMEOUT=$(bound FM_RESOURCE_CONTEXT_TIMEOUT 5)
ROLES_TIMEOUT=$(bound FM_RESOURCE_ROLES_TIMEOUT 10)
COLLIE_TIMEOUT=$(bound FM_RESOURCE_COLLIE_TIMEOUT 5)
TESTING_TIMEOUT=$(bound FM_RESOURCE_TESTING_TIMEOUT 10)
ANDROID_TIMEOUT=$(bound FM_RESOURCE_ANDROID_TIMEOUT 8)
ANDROID_REMOTE_TIMEOUT=$(bound FM_RESOURCE_ANDROID_REMOTE_TIMEOUT 20)
CAP_WORKERS=$(bound FM_RESOURCE_CAP_WORKERS 40)
CAP_PANES=$(bound FM_RESOURCE_CAP_PANES 60)
CAP_STRAYS=$(bound FM_RESOURCE_CAP_STRAYS 40)

if [ -n "${FM_RESOURCE_NOW:-}" ]; then
  case "$FM_RESOURCE_NOW" in
    ''|*[!0-9]*) NOW=$(date -u -d "$FM_RESOURCE_NOW" +%s 2>/dev/null) || NOW=$(date -u +%s) ;;
    *) NOW=$FM_RESOURCE_NOW ;;
  esac
else
  NOW=$(date -u +%s)
fi
case "$NOW" in ''|*[!0-9]*) NOW=$(date -u +%s) ;; esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-resource-snapshot.XXXXXX") || {
  echo 'fm-resource-snapshot: cannot create temp directory' >&2
  exit 1
}
# shellcheck disable=SC2329 # invoked through the EXIT trap below
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

: > "$TMP/unavailable.tsv"
: > "$TMP/budget.txt"
: > "$TMP/workers_local.tsv"
: > "$TMP/workers_remote.tsv"
: > "$TMP/panes.tsv"
: > "$TMP/strays.tsv"
: > "$TMP/hosts.tsv"
: > "$TMP/drives.tsv"
: > "$TMP/quota.tsv"
: > "$TMP/secondmates.tsv"
: > "$TMP/roles.tsv"
: > "$TMP/testing.tsv"
: > "$TMP/compute.tsv"
: > "$TMP/android.tsv"
: > "$TMP/android_local.tsv"
: > "$TMP/android_remote.tsv"
: > "$TMP/android_probe.tsv"
: > "$TMP/remote_records.tsv"
: > "$TMP/remote_sessions.tsv"
: > "$TMP/mate_account.txt"
: > "$TMP/collie.tsv"
: > "$TMP/verify.txt"

read_iso=$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || read_iso='-'

clean_field() {  # collapse tabs/newlines so one row stays one TSV line
  printf '%s' "${1-}" | tr '\t\r\n' '   '
}

mark_budget() {  # <source>
  printf '%s\n' "$1" >> "$TMP/budget.txt"
}

note_unavailable() {  # <source> <reason>
  printf '%s\t%s\t%s\n' "$1" "$(clean_field "$2")" "$read_iso" >> "$TMP/unavailable.tsv"
}

iso_utc() {  # <epoch>
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "$read_iso"
}

human_age() {  # <seconds>
  local s=$1
  [ "$s" -ge 0 ] 2>/dev/null || { printf '-'; return; }
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%sm' "$((s / 60))"
  elif [ "$s" -lt 86400 ]; then printf '%sh' "$((s / 3600))"
  else printf '%sd' "$((s / 86400))"
  fi
}

meta_get() {  # <meta-file> <key>: last value wins, matching fm_meta_get
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

spawn_age() {  # <spawn_gen>
  local raw=${1-} epoch
  case "$raw" in s*) raw=${raw#s} ;; esac
  epoch=${raw%%.*}
  case "$epoch" in ''|*[!0-9]*) printf '-' ;; *) human_age "$((NOW - epoch))" ;; esac
}

spend_lane() {  # <harness> <model> <account>
  local harness=${1-} model=${2-} account=${3-} base
  case "$model" in
    opencode-go/*) printf 'opencode-go'; return ;;
    *codex*) printf 'codex'; return ;;
  esac
  if [ "$harness" = claude ] || [ "${model#claude-}" != "$model" ]; then
    case "$account" in
      *claude-secondary*) printf 'claude#2' ;;
      */.claude|.claude|''|auto|ordinary) printf 'claude#1' ;;
      *) base=${account##*/}; printf 'claude:%s' "${base:-unknown}" ;;
    esac
    return
  fi
  printf 'unknown'
}

collie_last_active() {  # <pane>
  local pane=${1-} ms
  [ -n "$pane" ] && [ -s "$TMP/collie.tsv" ] || { printf '-'; return; }
  ms=$(awk -F'\t' -v p="$pane" '$1 == p { print $2; exit }' "$TMP/collie.tsv")
  case "$ms" in ''|*[!0-9]*) printf '-' ;; *) iso_utc "$((ms / 1000))" ;; esac
}

context_band() {  # <task> <harness> <worktree> <account>
  local id=${1-} harness=${2-} wt=${3-} account=${4-} line band pct
  if [ -n "${FM_RESOURCE_CONTEXT_FIXTURE:-}" ] && [ -f "$FM_RESOURCE_CONTEXT_FIXTURE" ]; then
    jq -r --arg id "$id" '.[$id] // "n/a"' "$FM_RESOURCE_CONTEXT_FIXTURE" 2>/dev/null || printf 'n/a'
    return
  fi
  [ -n "$wt" ] || { printf 'n/a'; return; }
  case "$harness" in
    claude)
      [ -x "$SCRIPT_DIR/fm-context-usage.sh" ] || { printf 'n/a'; return; }
      line=$(fm_run_timed "$CONTEXT_TIMEOUT" env FM_HOME="$wt" FM_CLAUDE_STORE="${account:-auto}" \
        "$SCRIPT_DIR/fm-context-usage.sh" 2>/dev/null </dev/null | head -1) ;;
    opencode)
      [ -x "$SCRIPT_DIR/fm-opencode-context-usage.sh" ] || { printf 'n/a'; return; }
      line=$(fm_run_timed "$CONTEXT_TIMEOUT" env FM_HOME="$wt" \
        "$SCRIPT_DIR/fm-opencode-context-usage.sh" --worktree "$wt" \
        --session-file "$STATE/$id.opencode-session" 2>/dev/null </dev/null | head -1) ;;
    *)
      printf 'n/a'; return ;;
  esac
  band=$(printf '%s' "$line" | sed -n 's/.*band=\([A-Za-z_-]*\).*/\1/p')
  pct=$(printf '%s' "$line" | sed -n 's/.*percent=\([0-9.]*\).*/\1/p')
  if [ -z "$band" ]; then printf 'unknown'; return; fi
  if [ -n "$pct" ]; then printf '%s(%s%%)' "$band" "$pct"; else printf '%s' "$band"; fi
}

# --- collie cross-check -----------------------------------------------------
collect_collie() {
  local raw rc
  if ! command -v collie >/dev/null 2>&1; then
    note_unavailable 'collie' 'collie not found'
    return
  fi
  raw=$(fm_run_timed "$COLLIE_TIMEOUT" collie sessions --json 2>/dev/null </dev/null)
  rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$raw" | jq -e '.rows | type == "array"' >/dev/null 2>&1; then
    fm_timed_out "$rc" && mark_budget 'collie'
    note_unavailable 'collie' "collie sessions failed (status $rc)"
    return
  fi
  printf '%s' "$raw" | jq -r '.rows[]? | [(.paneId // ""), ((.lastActiveAt // 0) | tostring)] | @tsv' \
    > "$TMP/collie.tsv"
}

# --- hosts and drives -------------------------------------------------------
drive_warn() {  # <available-kb>
  local gb_times10=$(( $1 * 10 / 1048576 ))
  if [ "$gb_times10" -lt 200 ]; then printf 'low'
  elif [ "$gb_times10" -lt 400 ]; then printf 'watch'
  else printf 'ok'
  fi
}

fixture_drive_warn() {
  local machine mount total free pct _w read kb warn
  while IFS=$'\t' read -r machine mount total free pct _w read; do
    case "$free" in
      ''|*[!0-9.]*|*.*.*) warn=unknown ;;
      *) kb=$(awk -v g="$free" 'BEGIN { printf "%d", g * 1048576 + 0.5 }'); warn=$(drive_warn "$kb") ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$machine" "$mount" "$total" "$free" "$pct" "$warn" "$read"
  done
}

drive_one() {  # <machine> <label> <path>
  local machine=$1 label=$2 path=$3 total avail used pct
  read -r total avail <<EOF
$(df -Pk "$path" 2>/dev/null | awk 'NR == 2 { print $2, $4 }')
EOF
  case "$total" in ''|*[!0-9]*) note_unavailable "drives:$machine:$label" 'drive unavailable'; return ;; esac
  case "$avail" in ''|*[!0-9]*) note_unavailable "drives:$machine:$label" 'drive unavailable'; return ;; esac
  used=$((total - avail))
  pct=$((used * 100 / total))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$machine" "$label" \
    "$(awk -v k="$total" 'BEGIN { printf "%.1f", k / 1048576 }')" \
    "$(awk -v k="$avail" 'BEGIN { printf "%.1f", k / 1048576 }')" \
    "$pct" "$(drive_warn "$avail")" "$read_iso" >> "$TMP/drives.tsv"
}

collect_local_host() {
  if [ -n "${FM_RESOURCE_HOSTS_JSON:-}" ] && [ -f "$FM_RESOURCE_HOSTS_JSON" ]; then
    return
  fi
  local load cores mem up freekb path
  load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)
  cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null)
  mem=$(awk '/^MemTotal:/ { t=$2 } /^MemAvailable:/ { a=$2 } END { if (t > 0) printf "%d", a * 100 / t }' /proc/meminfo 2>/dev/null)
  up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
  path=$FM_HOME
  freekb=$(df -Pk "$path" 2>/dev/null | awk 'NR == 2 { print $4 }')
  case "$load" in ''|*[!0-9.]*) load=unknown ;; esac
  case "$cores" in ''|*[!0-9]*) cores=unknown ;; esac
  case "$mem" in ''|*[!0-9]*) mem=unknown ;; esac
  case "$up" in ''|*[!0-9]*) up=unknown ;; esac
  if [ -n "$freekb" ] && [ "$freekb" -gt 0 ] 2>/dev/null; then
    printf 'PC01\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$load" "$cores" "$mem" \
      "$(awk -v k="$freekb" 'BEGIN { printf "%.1f", k / 1048576 }')" "$path" "$up" "$read_iso" \
      >> "$TMP/hosts.tsv"
  else
    printf 'PC01\t%s\t%s\t%s\t-\t%s\t%s\t%s\n' "$load" "$cores" "$mem" "$path" "$up" "$read_iso" \
      >> "$TMP/hosts.tsv"
    note_unavailable 'hosts:pc01' 'disk probe failed'
  fi
}

collect_local_drives() {
  if [ -n "${FM_RESOURCE_HOSTS_JSON:-}" ] && [ -f "$FM_RESOURCE_HOSTS_JSON" ]; then
    return
  fi
  drive_one PC01 / /
  drive_one PC01 'C:' /mnt/c
  drive_one PC01 'G:' /mnt/g
}

# --- local workers ----------------------------------------------------------
worker_row_local() {  # <meta> <home_lane>
  local meta=$1 lane=$2 id kind harness model account wt spawn pr pane stage ctx spend last
  id=$(meta_get "$meta" endpoint_task_id)
  id=${id:-$(basename "$meta" .meta)}
  kind=$(meta_get "$meta" kind); kind=${kind:-unknown}
  harness=$(meta_get "$meta" harness); harness=${harness:-unknown}
  model=$(meta_get "$meta" model); model=${model:-unknown}
  account=$(meta_get "$meta" account)
  if [ -z "$account" ] && [ -f "$CONFIG/claude-account" ]; then
    account=$(sed -n '1p' "$CONFIG/claude-account" 2>/dev/null)
  fi
  wt=$(meta_get "$meta" worktree)
  spawn=$(meta_get "$meta" spawn_gen)
  pr=$(meta_get "$meta" pr); pr=${pr:--}
  pane=$(meta_get "$meta" herdr_pane_id)
  stage=$(fm_run_timed "$CREW_STATE_TIMEOUT" env FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null </dev/null | head -1)
  stage=$(clean_field "${stage:-unknown}")
  ctx=$(context_band "$id" "$harness" "$wt" "$account")
  spend=$(spend_lane "$harness" "$model" "$account")
  last=$(collie_last_active "$pane")
  printf 'PC01\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(clean_field "$lane")" "$(clean_field "$id")" "$(clean_field "$kind")" \
    "$(clean_field "$model")" "$spend" "$stage" "$(spawn_age "$spawn")" \
    "$(clean_field "$last")" "$(clean_field "$ctx")" "$(clean_field "$pr")" "$read_iso"
}

collect_local_workers() {
  local i=0 meta
  local -a files=()
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    i=$((i + 1))
    files+=("$TMP/wlocal.$i")
    ( worker_row_local "$meta" main > "$TMP/wlocal.$i" ) &
  done
  wait
  local f
  for f in "${files[@]}"; do
    [ -s "$f" ] && cat "$f"
  done > "$TMP/workers_local.tsv"
}

# --- remote secondmate ------------------------------------------------------
remote_records() {  # print "<id>\t<host>\t<root>\t<home>" per remote mate
  local reg=$DATA/secondmates.md line
  [ -f "$reg" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || continue
    printf '%s\t%s\t%s\t%s\n' "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOST" \
      "$SECONDMATE_REGISTRY_ROOT" "$SECONDMATE_REGISTRY_HOME"
  done < "$reg"
}

remote_host_script() {
  cat <<'REMOTE'
root=$1
home=$2
read -r load1 _ < /proc/loadavg 2>/dev/null || load1=unknown
cores=$( (getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null) | head -1)
mem=$(awk '/^MemTotal:/ { t=$2 } /^MemAvailable:/ { a=$2 } END { if (t > 0) printf "%d", a * 100 / t }' /proc/meminfo 2>/dev/null)
up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
freekb=$(df -Pk "$home" 2>/dev/null | awk 'NR == 2 { print $4 }')
printf 'H\t%s\t%s\t%s\t%s\t%s\t%s\n' "${load1:-unknown}" "${cores:-unknown}" "${mem:-unknown}" "${freekb:--}" "$home" "${up:-unknown}"
for spec in '/|/' 'C:|/mnt/c' 'D:|/mnt/d' 'E:|/mnt/e'; do
  label=${spec%%|*}
  path=${spec#*|}
  set -- $(df -Pk "$path" 2>/dev/null | awk 'NR == 2 { print $2, $4 }')
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && printf 'D\t%s\t%s\t%s\n' "$label" "$1" "$2"
done
herdr session list 2>/dev/null | awk 'NR > 1 && NF >= 2 { print "S\t" $1 "\t" $2 }'
acct=$(cat "$home/config/claude-account" 2>/dev/null | head -1)
[ -n "$acct" ] && printf 'A\t%s\n' "$acct"
slots=2
sf="$HOME/.config/firstmate/pc02-offload-slots"
if [ -f "$sf" ]; then v=$(head -1 "$sf" 2>/dev/null); case "$v" in ''|*[!0-9]*) ;; *) slots=$v ;; esac; fi
used=0
i=1
while [ "$i" -le "$slots" ]; do
  f="$HOME/.fm-pc02-test-slot-$i.lock"
  ino=$(stat -c %i "$f" 2>/dev/null)
  if [ -n "$ino" ] && awk -v i="$ino" '{ n = split($6, a, ":"); if (a[n] == i) found = 1 } END { exit !found }' /proc/locks 2>/dev/null; then used=$((used + 1)); fi
  i=$((i + 1))
done
printf 'T\tpc02-offload-slots\t%s/%s\tlocked slots under ~/.fm-pc02-test-slot-*.lock\n' "$used" "$slots"
pu=off
[ -e "$HOME/.fm-pc02-personal-use" ] && pu=on
printf 'T\tpc02-personal-use\t%s\t-\n' "$pu"
runner=$(systemctl --user is-active forgejo-runner.service 2>/dev/null | head -1)
printf 'T\tforgejo-runner\t%s\t-\n' "${runner:-unknown}"
runs=$(ps -eo args= 2>/dev/null | grep -E 'fm-test-run\.sh|fm-test-compute\.sh' | grep -v grep | wc -l)
printf 'T\ttest-runs\t%s\t-\n' "$runs"
REMOTE
}

remote_worker_script() {
  cat <<'REMOTE'
root=$1
home=$2
now=$(date +%s)
for m in "$home"/state/*.meta; do
  [ -f "$m" ] || continue
  id=$(sed -n 's/^endpoint_task_id=//p' "$m" | tail -1)
  [ -n "$id" ] || continue
  kind=$(sed -n 's/^kind=//p' "$m" | tail -1)
  harness=$(sed -n 's/^harness=//p' "$m" | tail -1)
  model=$(sed -n 's/^model=//p' "$m" | tail -1)
  account=$(sed -n 's/^account=//p' "$m" | tail -1)
  if [ -z "$account" ]; then account=$(head -1 "$home/config/claude-account" 2>/dev/null); fi
  wt=$(sed -n 's/^worktree=//p' "$m" | tail -1)
  spawn=$(sed -n 's/^spawn_gen=//p' "$m" | tail -1)
  pr=$(sed -n 's/^pr=//p' "$m" | tail -1)
  pane=$(sed -n 's/^herdr_pane_id=//p' "$m" | tail -1)
  raw=${spawn#s}; epoch=${raw%%.*}
  case "$epoch" in ''|*[!0-9]*) age=- ;; *)
    d=$((now - epoch))
    if [ "$d" -lt 60 ]; then age=${d}s
    elif [ "$d" -lt 3600 ]; then age=$((d / 60))m
    elif [ "$d" -lt 86400 ]; then age=$((d / 3600))h
    else age=$((d / 86400))d; fi ;;
  esac
  stage=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-crew-state.sh" "$id" 2>/dev/null | head -1)
  ctx=n/a
  if [ "$harness" = claude ] && [ -n "$wt" ] && [ -x "$root/bin/fm-context-usage.sh" ]; then
    line=$(FM_HOME="$wt" FM_CLAUDE_STORE="${account:-auto}" "$root/bin/fm-context-usage.sh" 2>/dev/null | head -1)
    band=$(printf '%s' "$line" | sed -n 's/.*band=\([A-Za-z_-]*\).*/\1/p')
    pct=$(printf '%s' "$line" | sed -n 's/.*percent=\([0-9.]*\).*/\1/p')
    if [ -n "$band" ]; then [ -n "$pct" ] && ctx="$band($pct%)" || ctx=$band; fi
  fi
  printf 'W\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "${kind:-unknown}" "${harness:-unknown}" "${model:-unknown}" "$account" \
    "$wt" "$age" "${pr:--}" "$pane" "${stage:-unknown}" "$ctx"
done
REMOTE
}

remote_android_script() {
  printf '%s\n' 'set -u'
  declare -f android_find_tool android_passthru android_boot_completed android_probe_host
  cat <<'REMOTE'
adb=$(android_find_tool adb) || adb=''
emu=$(android_find_tool emulator) || emu=''
android_probe_host "$adb" "$emu" android_passthru 0
REMOTE
}

run_remote() {  # <host> <timeout> <script-text> <arg>...
  local host=$1 timeout=$2 script=$3 runner stdin_file
  shift 3
  runner=$TMP/remote.runner.$$.$RANDOM.sh
  stdin_file=$TMP/remote.stdin.$$.$RANDOM
  printf '%s\n' "$script" > "$stdin_file"
  {
    printf '#!/usr/bin/env bash\nexec %q' "${FM_SSH_BIN:-ssh}"
    printf ' %q' -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2
    printf ' -- %q bash -s --' "$host"
    printf ' %q' "$@"
    printf ' < %q\n' "$stdin_file"
  } > "$runner"
  chmod 0700 "$runner"
  fm_run_timed "$timeout" bash "$runner"
}

collect_remote() {
  local id host root home line rc raw account=''
  remote_records > "$TMP/remote_records.tsv" 2>/dev/null || : > "$TMP/remote_records.tsv"

  if [ -n "${FM_RESOURCE_REMOTE_FIXTURE:-}" ] && [ -f "$FM_RESOURCE_REMOTE_FIXTURE" ]; then
    jq -r '.hosts[]? | [.machine, (.load1 // "unknown"), (.cores // "unknown"), (.mem_free_pct // "unknown"), (.disk_free_gb // "-"), (.disk_path // "-"), (.uptime // "unknown"), (.read_utc // "-")] | @tsv' \
      "$FM_RESOURCE_REMOTE_FIXTURE" >> "$TMP/hosts.tsv"
    jq -r '.drives[]? | [.machine, .mount, (.total_gb // "-"), (.free_gb // "-"), (.pct_used // "-"), "-", (.read_utc // "-")] | @tsv' \
      "$FM_RESOURCE_REMOTE_FIXTURE" | fixture_drive_warn >> "$TMP/drives.tsv"
    jq -r '.sessions[]? | [.name, (.status // "-")] | @tsv' \
      "$FM_RESOURCE_REMOTE_FIXTURE" > "$TMP/remote_sessions.tsv"
    jq -r '.workers[]? | ["PC02", .home_lane, .task, (.kind // "unknown"), (.model // "unknown"), (.spend_lane // "unknown"), (.stage // "unknown"), (.age // "-"), (.last_active // "-"), (.ctx_band // "n/a"), (.pr // "-"), (.read_utc // "-")] | @tsv' \
      "$FM_RESOURCE_REMOTE_FIXTURE" > "$TMP/workers_remote.tsv"
    jq -r '(.mate_account // "")' "$FM_RESOURCE_REMOTE_FIXTURE" > "$TMP/mate_account.txt"
    jq -r '.android[]? | ["PC02", (.avd // "-"), (.serial // "-"), (.state // "unknown"), (.boot_completed // "-"), (.detail // "-"), (.read_utc // "-")] | @tsv' \
      "$FM_RESOURCE_REMOTE_FIXTURE" > "$TMP/android_remote.tsv"
    jq -r '.unavailable[]? | [.source, .reason, (.read_utc // "-")] | @tsv' \
      "$FM_RESOURCE_REMOTE_FIXTURE" >> "$TMP/unavailable.tsv"
    return 0
  fi

  [ -s "$TMP/remote_records.tsv" ] || return 0
  [ "${FM_RESOURCE_SKIP_REMOTE:-0}" = 1 ] && return 0

  id=$(awk -F'\t' 'NR == 1 { print $1 }' "$TMP/remote_records.tsv")
  host=$(awk -F'\t' 'NR == 1 { print $2 }' "$TMP/remote_records.tsv")
  root=$(awk -F'\t' 'NR == 1 { print $3 }' "$TMP/remote_records.tsv")
  home=$(awk -F'\t' 'NR == 1 { print $4 }' "$TMP/remote_records.tsv")
  case "$host" in
    ''|-*|*[!A-Za-z0-9._-]*) note_unavailable 'pc02' 'secondmate host is unsafe or empty'; return 0 ;;
  esac

  if [ -x "$SCRIPT_DIR/fm-on.sh" ]; then
    raw=$(fm_run_timed "$REMOTE_WORKERS_TIMEOUT" "$SCRIPT_DIR/fm-on.sh" "$id" \
      fm-resource-snapshot.sh --home-only --json 2>/dev/null </dev/null)
    rc=$?
    fm_timed_out "$rc" && mark_budget "workers:$host"
    if [ "$rc" -eq 0 ] && printf '%s' "$raw" | jq -e '.workers | type == "array"' >/dev/null 2>&1; then
      printf '%s' "$raw" | jq -r --arg lane "$id" --arg read "$read_iso" \
        '.workers[]? | ["PC02", $lane, .task, (.kind // "unknown"), (.model // "unknown"), (.spend_lane // "unknown"), (.stage // "unknown"), (.age // "-"), (.last_active // "-"), (.ctx_band // "n/a"), (.pr // "-"), $read] | @tsv' \
        > "$TMP/workers_remote.tsv" || : > "$TMP/workers_remote.tsv"
    else
      raw=$(run_remote "$host" "$REMOTE_WORKERS_TIMEOUT" "$(remote_worker_script)" "$root" "$home" 2>/dev/null)
      rc=$?
      if [ "$rc" -eq 0 ]; then
        printf '%s' "$raw" | awk -F'\t' -v OFS='\t' -v lane="$id" -v read="$read_iso" '
          function spend(h, m, a) {
            if (m ~ /^opencode-go\//) return "opencode-go"
            if (m ~ /codex/ || h == "codex") return "codex"
            if (h == "claude" || m ~ /^claude-/) {
              if (a ~ /claude-secondary/) return "claude#2"
              if (a == "" || a == "auto" || a == "ordinary" || a ~ /\/\.claude$/) return "claude#1"
              n = a; sub(/.*\//, "", n); return "claude:" (n == "" ? "unknown" : n)
            }
            return "unknown"
          }
          $1 == "W" { print "PC02", lane, $2, $3, $5, spend($4, $5, $6), $11, $8, "-", $12, $9, read }
        ' > "$TMP/workers_remote.tsv"
      else
        fm_timed_out "$rc" && mark_budget "workers:$host"
        note_unavailable "workers:$host" "remote worker read failed (status $rc)"
      fi
    fi
  fi

  raw=$(run_remote "$host" "$SSH_TIMEOUT" "$(remote_host_script)" "$root" "$home" 2>/dev/null)
  rc=$?
  : > "$TMP/remote_host.tsv"
  : > "$TMP/remote_drives.tsv"
  : > "$TMP/remote_sessions.tsv"
  : > "$TMP/remote_testing.tsv"
  : > "$TMP/mate_account.txt"
  if [ "$rc" -eq 0 ]; then
    while IFS=$'\t' read -r tag a b c d e f; do
      case "$tag" in
        H)
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "PC02" "$a" "$b" "$c" \
            "$(awk -v k="$d" 'BEGIN { if (k ~ /^[0-9]+$/) printf "%.1f", k / 1048576; else printf "-" }')" \
            "$e" "$f" "$read_iso" >> "$TMP/remote_host.tsv"
          ;;
        D)
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "PC02" "$a" \
            "$(awk -v k="$b" 'BEGIN { printf "%.1f", k / 1048576 }')" \
            "$(awk -v k="$c" 'BEGIN { printf "%.1f", k / 1048576 }')" \
            "$(awk -v t="$b" -v a="$c" 'BEGIN { printf "%d", (t - a) * 100 / t }')" \
            "$(drive_warn "$c")" "$read_iso" >> "$TMP/remote_drives.tsv"
          ;;
        S) printf '%s\t%s\n' "$a" "${b:--}" >> "$TMP/remote_sessions.tsv" ;;
        A) printf '%s\n' "$a" > "$TMP/mate_account.txt"; account=$a ;;
        T) printf '%s\t%s\t%s\n' "$a" "$b" "$(clean_field "$c")" >> "$TMP/remote_testing.tsv" ;;
      esac
    done <<< "$raw"
    cat "$TMP/remote_host.tsv" >> "$TMP/hosts.tsv"
    cat "$TMP/remote_drives.tsv" >> "$TMP/drives.tsv"
  else
    fm_timed_out "$rc" && mark_budget "pc02:$host"
    note_unavailable "pc02:$host" "remote host read failed (status $rc)"
  fi

  [ -n "${FM_RESOURCE_ANDROID_FIXTURE:-}" ] && return 0
  raw=$(run_remote "$host" "$ANDROID_REMOTE_TIMEOUT" "$(remote_android_script)" 2>/dev/null)
  rc=$?
  : > "$TMP/android_remote.tsv"
  if [ "$rc" -eq 0 ]; then
    while IFS=$'\t' read -r tag a b c d e; do
      case "$tag" in
        A) printf 'PC02\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(clean_field "$a")" "$(clean_field "$b")" \
             "$(clean_field "$c")" "$(clean_field "$d")" "$(clean_field "$e")" "$read_iso" \
             >> "$TMP/android_remote.tsv" ;;
        N) note_unavailable 'android:PC02' "$a" ;;
      esac
    done <<< "$raw"
  else
    fm_timed_out "$rc" && mark_budget "android:$host"
    note_unavailable "android:$host" "remote Android read failed (status $rc)"
  fi
}

# --- quota ------------------------------------------------------------------
collect_quota() {
  local out rc profiles='' orchestrator workers
  if ! command -v quota-axi >/dev/null 2>&1; then
    note_unavailable 'quota' 'quota-axi not found'
    return
  fi
  if [ -f "$CONFIG/claude-accounts" ]; then
    profiles=$(awk -F: 'NF >= 2 && $2 ~ /^\// { print $2 }' "$CONFIG/claude-accounts" 2>/dev/null | paste -sd: -)
  fi
  if [ -z "$profiles" ] && [ -f "$CONFIG/claude-roles" ]; then
    orchestrator=$(sed -n 's/^orchestrator=//p' "$CONFIG/claude-roles" 2>/dev/null | tail -1)
    workers=$(sed -n 's/^workers=//p' "$CONFIG/claude-roles" 2>/dev/null | tail -1)
    profiles=$(printf '%s\n%s\n' "$orchestrator" "$workers" | awk 'NF && !seen[$0]++' | paste -sd: -)
  fi
  if [ -n "$profiles" ]; then
    out=$(fm_run_timed "$QUOTA_TIMEOUT" env QUOTA_AXI_CLAUDE_PROFILES="$profiles" \
      quota-axi --json --max-age 60s --no-credential-refresh 2>/dev/null </dev/null)
  else
    out=$(fm_run_timed "$QUOTA_TIMEOUT" quota-axi --json --max-age 60s --no-credential-refresh 2>/dev/null </dev/null)
  fi
  rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | jq -e '.providers | type == "array"' >/dev/null 2>&1; then
    fm_timed_out "$rc" && mark_budget 'quota'
    note_unavailable 'quota' "quota-axi read failed (status $rc)"
    return
  fi
  printf '%s' "$out" | jq -r --arg read "$read_iso" --arg profiles "$profiles" '
    def frac: sub("\\.[0-9]+"; "");
    def et:
      if . == null or . == "" then "-"
      else (frac | sub("\\+00:00$"; "Z") | (try fromdateiso8601 catch null)) as $e
        | (if $e == null then "-" else ($e | strflocaltime("%Y-%m-%d %H:%M %Z")) end)
      end;
    def clabel($path):
      ($path // "") | if endswith("claude-secondary") then "claude#2"
        elif endswith("/.claude") or . == "" then "claude#1"
        else "claude:" + (split("/") | last) end;
    def lane($p; $ci; $paths):
      if $p.provider == "claude" then
        (($p.accountLocator.path // "") as $path
         | if $path != "" then ($path | clabel(.)) else (($paths[$ci] // "-") | clabel(.)) end)
      elif $p.provider == "opencode-go" then "opencode-go"
      elif $p.provider == "codex" then "codex"
      else $p.provider end;
    def stateof:
      if .state.stale == true or .state.reused == true then "stale"
      else (.state.status // "unknown") end;
    def reasonof:
      if .state.stale == true or .state.reused == true then "cached reading"
      elif (.state.status // "") == "fresh" then "-"
      else ((.error // .state.error // .state.status // "unavailable")
            + (if (.retryAfter // .state.retryAfter) then " retry " + (.retryAfter // .state.retryAfter) else "" end)) end;
    def winorder: { five_hour: 0, seven_day: 1, rolling: 2, weekly: 3, monthly: 4 };
    (.generatedAt // "-") as $gen
    | ($profiles | split(":") | map(select(length > 0))) as $paths
    | .providers as $all
    | ($all | map(select(.provider == "claude"))) as $claudes
    | [ $all[] | select(.provider == "claude" or .provider == "opencode-go" or .provider == "codex")
        | . as $p
        | (($claudes | map(.accountKey) | index($p.accountKey)) // 0) as $ci
        | {p: $p, ci: $ci, lane: lane($p; $ci; $paths)} ]
    | sort_by(.lane | if . == "claude#1" then 0 elif . == "claude#2" then 1 elif . == "opencode-go" then 2 else 3 end)
    | .[] as $row
    | ($row.p) as $p
    | ($row.lane) as $lane
    | (if $p.provider == "claude" then (($p.accountLocator.path // "") as $path | if $path != "" then $path else ($paths[$row.ci] // "-") end) else "-" end) as $account
    | ($p.state.refreshedAt // $gen // "-") as $reading
    | ($p | stateof) as $state
    | if (($p.windows // []) | length) == 0 or ($state != "fresh" and $state != "stale") then
        [$lane, $account, ($p.plan // "-"), "-", "", "-", "-", $state, $read, $reading, ($p | reasonof)] | @tsv
      else
        ($p.windows | sort_by(winorder[.id] // 9) | .[]) as $w
        | [$lane, $account, ($p.plan // "-"),
           ($w.id | sub("^window:"; "")), (($w.percentRemaining // "") | tostring),
           ($w.resetsAt | et), ($w.pace.status // "-"), $state, $read, $reading,
           (if $state == "stale" then "cached reading" else "-" end)] | @tsv
      end
  ' > "$TMP/quota.tsv"
}

# --- herdr panes ------------------------------------------------------------
payload_for_host() {  # <PC01|PC02> <out-payload>
  local machine=$1 out=$2 fixture='' session='-' raw rc pane_file ws_file sess_file
  case "$machine" in
    PC01) fixture=${FM_RESOURCE_HERDR_JSON_PC01:-} ;;
    PC02) fixture=${FM_RESOURCE_HERDR_JSON_PC02:-} ;;
  esac
  if [ -n "$fixture" ] && [ -f "$fixture" ]; then
    cp "$fixture" "$out"
    return 0
  fi
  pane_file=$TMP/herdr_panes.$machine.json
  ws_file=$TMP/herdr_ws.$machine.json
  sess_file=$TMP/herdr_sess.$machine.txt
  if [ "$machine" = PC02 ]; then
    raw=$(fm_run_timed "$HERDR_TIMEOUT" herdr --machine PC02 pane list 2>/dev/null </dev/null)
    rc=$?
    [ "$rc" -eq 0 ] && printf '%s' "$raw" > "$pane_file" || return 1
    raw=$(fm_run_timed "$HERDR_TIMEOUT" herdr --machine PC02 workspace list 2>/dev/null </dev/null)
    rc=$?
    [ "$rc" -eq 0 ] && printf '%s' "$raw" > "$ws_file" || return 1
    session=$(awk -F'\t' '$2 == "running" { print $1; exit }' "$TMP/remote_sessions.tsv" 2>/dev/null)
  else
    raw=$(fm_run_timed "$HERDR_TIMEOUT" herdr pane list 2>/dev/null </dev/null)
    rc=$?
    [ "$rc" -eq 0 ] && printf '%s' "$raw" > "$pane_file" || return 1
    raw=$(fm_run_timed "$HERDR_TIMEOUT" herdr workspace list 2>/dev/null </dev/null)
    rc=$?
    [ "$rc" -eq 0 ] && printf '%s' "$raw" > "$ws_file" || return 1
    raw=$(fm_run_timed "$HERDR_TIMEOUT" herdr session list 2>/dev/null </dev/null)
    rc=$?
    [ "$rc" -eq 0 ] && printf '%s\n' "$raw" > "$sess_file"
    session=$(awk 'NR > 1 && $2 == "running" { print $1; exit }' "$sess_file" 2>/dev/null)
  fi
  [ -n "$session" ] || session='-'
  jq -n --slurpfile p "$pane_file" --slurpfile w "$ws_file" --arg session "$session" \
    '{panes: ($p[0].result.panes // []), workspaces: ($w[0].result.workspaces // []), sessions: [{name: $session, status: "running"}]}' \
    > "$out" 2>/dev/null
}

collect_panes_for() {  # <machine> <payload> <tasks-file>
  local machine=$1 payload=$2 tasks=$3 rc
  jq -rn --slurpfile payload "$payload" --rawfile tasklines "$tasks" \
    --arg machine "$machine" --arg read "$read_iso" '
    ($tasklines | split("\n") | map(select(length > 0))) as $t
    | ($payload[0].workspaces | map({key: .workspace_id, value: .label}) | from_entries) as $labels
    | ($payload[0].sessions[0].name // "-") as $session
    | $payload[0].panes
    | map(
        . as $p
        | ($labels[$p.workspace_id] // "-") as $wl
        | ([ $t[] | . as $tid | select($wl | contains($tid)) ] | sort_by(length) | last) as $task
        | {machine: $machine, session: $session, workspace: $wl,
           tab: ($p.tab_id // "-"), pane: ($p.pane_id // "-"),
           agent: ($p.agent // "-"), agent_status: ($p.agent_status // "unknown"),
           task: ($task // "-"), cwd: ($p.cwd // "-"),
           title: ($p.terminal_title_stripped // $p.terminal_title // "-"),
           read_utc: $read})
    | .[]
    | [ .machine, .session, .workspace, .tab, .pane, .agent, .agent_status, .task, .cwd, .title, .read_utc ]
    | @tsv
  ' > "$TMP/panes.$machine.tsv" 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] && cat "$TMP/panes.$machine.tsv" >> "$TMP/panes.tsv"

  jq -rn --slurpfile payload "$payload" '
    ($payload[0].workspaces | map({key: .workspace_id, value: .label}) | from_entries) as $labels
    | $payload[0].panes
    | map(. as $p
        | if ($p.agent // "") == "" then
            {pane: ($p.pane_id // "-"), reason: "no-agent",
             workspace_label: ($labels[$p.workspace_id] // "-"),
             foreground_cwd: ($p.foreground_cwd // $p.cwd // "-")}
          elif ($p.agent_status // "unknown") == "unknown" then
            {pane: ($p.pane_id // "-"), reason: "agent-unknown",
             workspace_label: ($labels[$p.workspace_id] // "-"),
             foreground_cwd: ($p.foreground_cwd // $p.cwd // "-")}
          else empty end)
    | .[]
    | [ .pane, .reason, .workspace_label, .foreground_cwd ]
    | @tsv
  ' 2>/dev/null | while IFS=$'\t' read -r pane reason wl fg; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$machine" "$pane" "$reason" "$wl" "$fg" >> "$TMP/strays.tsv"
      done
}

collect_herdr() {
  local payload tasks
  for machine in PC01 PC02; do
    payload=$TMP/herdr_payload.$machine.json
    if [ "$machine" = PC02 ] && [ -n "${FM_RESOURCE_HERDR_JSON_PC02:-}" ]; then
      payload_for_host PC02 "$payload" || { note_unavailable 'herdr:pc02' 'herdr pane read failed'; continue; }
    elif [ "$machine" = PC02 ] && [ -n "${FM_RESOURCE_REMOTE_FIXTURE:-}" ]; then
      note_unavailable 'herdr:pc02' 'no remote herdr payload in fixture'
      continue
    else
      payload_for_host "$machine" "$payload" || {
        note_unavailable "herdr:$(printf '%s' "$machine" | tr '[:upper:]' '[:lower:]')" 'herdr pane read failed'
        continue
      }
    fi
    tasks=$TMP/tasks.$machine.txt
    if [ "$machine" = PC02 ]; then
      awk -F'\t' '$1 == "PC02" { print $3 }' "$TMP/workers_remote.tsv" > "$tasks"
    else
      awk -F'\t' '$1 == "PC01" { print $3 }' "$TMP/workers_local.tsv" > "$tasks"
    fi
    collect_panes_for "$machine" "$payload" "$tasks"
  done
}

# --- roles and secondmates --------------------------------------------------
collect_verify() {
  local file=$DATA/account-roles/fm-claude-roles.sh rc
  [ -f "$file" ] || return 0
  fm_run_timed "$ROLES_TIMEOUT" bash "$file" verify > "$TMP/verify.txt" 2>&1 </dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fm_timed_out "$rc" && mark_budget 'roles:verify'
    note_unavailable 'roles:verify' "claude roles verify failed (status $rc)"
  fi
}

collect_secondmate_state() {
  local id line
  : > "$TMP/secondmate_state.tsv"
  while IFS=$'\t' read -r id _; do
    [ -n "$id" ] || continue
    if [ ! -f "$STATE/$id.meta" ]; then
      printf '%s\tunknown\n' "$id" >> "$TMP/secondmate_state.tsv"
      continue
    fi
    line=$(fm_run_timed "$CREW_STATE_TIMEOUT" env FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
      "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null </dev/null | head -1)
    printf '%s\t%s\n' "$id" "$(clean_field "${line:-unknown}")" >> "$TMP/secondmate_state.tsv"
  done < "$TMP/remote_records.tsv"
}

build_secondmates() {
  local id host root home state account count
  account=$(cat "$TMP/mate_account.txt" 2>/dev/null)
  : > "$TMP/secondmates.tsv"
  while IFS=$'\t' read -r id host root home; do
    [ -n "$id" ] || continue
    state=$(awk -F'\t' -v i="$id" '$1 == i { print $2; exit }' "$TMP/secondmate_state.tsv")
    [ -n "$state" ] || state='unknown'
    count=$(awk -F'\t' -v l="$id" '$1 == "PC02" && $2 == l { c++ } END { print c + 0 }' "$TMP/workers_remote.tsv" 2>/dev/null)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$host" "$home" \
      "$state" "${count:-0}" "$(clean_field "${account:--}")" "$read_iso" \
      >> "$TMP/secondmates.tsv"
  done < "$TMP/remote_records.tsv"
}

build_roles() {
  local orchestrator worker_account primary sup evidence account
  if [ -n "${FM_RESOURCE_ROLES_FILE:-}" ] && [ -f "$FM_RESOURCE_ROLES_FILE" ]; then
    jq -r '.[]? | [.role, .where, .account, .evidence, .read_utc] | @tsv' "$FM_RESOURCE_ROLES_FILE" > "$TMP/roles.tsv"
    return
  fi
  orchestrator=$(sed -n 's/^ok: *.*claude-orchestrator-account = //p' "$TMP/verify.txt" 2>/dev/null | head -1)
  worker_account=$(sed -n 's/^ok: *.*config\/claude-account = //p' "$TMP/verify.txt" 2>/dev/null | head -1)
  [ -n "$orchestrator" ] || orchestrator=unknown
  [ -n "$worker_account" ] || worker_account=unknown
  : > "$TMP/roles.tsv"
  printf 'orchestrator\tPC01\t%s\t%s\t%s\n' "$orchestrator" \
    'config/claude-orchestrator-account (fm-claude-roles.sh verify)' "$read_iso" >> "$TMP/roles.tsv"

  primary=$(fm_run_timed "$HERDR_TIMEOUT" "$SCRIPT_DIR/fm-harness.sh" 2>/dev/null </dev/null)
  primary=${primary:-unknown}
  sup=$(
    # shellcheck source=bin/fm-supervision-engine-lib.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/fm-supervision-engine-lib.sh"
    if fm_supervision_host_config "$CONFIG" "$primary"; then
      printf 'enabled\t%s\t%s\t%s\t%s' "$FM_SUPERVISION_ENGINE" "$FM_SUPERVISION_ENGINE_MODEL" "${FM_SUPERVISION_ENGINE_ACCOUNT:--}" "${FM_SUPERVISION_ENGINE_PROBLEM:-}"
    else
      printf 'disabled\t-\t-\t-'
    fi
  )
  evidence=$(printf '%s' "$sup" | cut -f1)
  account=$(printf '%s' "$sup" | cut -f4)
  local engine model
  engine=$(printf '%s' "$sup" | cut -f2)
  model=$(printf '%s' "$sup" | cut -f3)
  if [ "$evidence" = enabled ] && [ -n "$engine" ]; then
    # shellcheck disable=SC2031
    printf 'supervision\tPC01\t%s\tenabled engine=%s model=%s primary=%s\t%s\n' \
      "$(clean_field "$account")" "$engine" "$model" "$primary" "$read_iso" >> "$TMP/roles.tsv"
  elif [ "$evidence" = enabled ]; then
    # shellcheck disable=SC2031
    printf 'supervision\tPC01\t-\tenabled but no usable engine for primary=%s: %s\t%s\n' \
      "$primary" "$(clean_field "$(printf '%s' "$sup" | cut -f5)")" "$read_iso" >> "$TMP/roles.tsv"
  else
    printf 'supervision\t-\t-\t%s\t%s\n' "$evidence" "$read_iso" >> "$TMP/roles.tsv"
  fi

  awk -F'\t' '$6 != "" && $6 != "unknown" { n[$6]++; key = $6 "\t" $1; if (!seen[key]++) { if (m[$6] != "") m[$6] = m[$6] ","; m[$6] = m[$6] $1 } } END { for (l in m) print l "\t" m[l] "\t" n[l] }' \
    "$TMP/workers_local.tsv" "$TMP/workers_remote.tsv" | sort \
    | while IFS=$'\t' read -r lane where count; do
        lane_account='-'
        for account in "$worker_account" "$orchestrator"; do
          if [ "$(spend_lane claude '' "$account")" = "$lane" ]; then lane_account=$account; break; fi
        done
        printf 'worker-lane:%s\t%s\t%s\t%s worker(s) on %s\t%s\n' "$lane" "$(clean_field "$where")" \
          "$(clean_field "$lane_account")" "${count:-0}" "$lane" "$read_iso" >> "$TMP/roles.tsv"
      done

  awk -F'\t' '!seen[$1]++ { print $1 "\t" $2 "\t" $6 }' "$TMP/secondmates.tsv" \
    | while IFS=$'\t' read -r id host account; do
        printf 'secondmate\t%s\t%s\thome lane %s\t%s\n' "$(clean_field "$host")" \
          "$(clean_field "${account:--}")" "$id" "$read_iso" >> "$TMP/roles.tsv"
      done
}

# --- Android emulators ------------------------------------------------------
# These four helpers are also shipped verbatim to PC02 through `declare -f`
# and executed under `bash -s`, so they must not call this script's local
# helpers (fm_run_timed, clean_field, note_unavailable, ...).
android_find_tool() {  # <adb|emulator> -> path, else status 1
  local name=$1 c root f
  for c in "$name" "$name.exe"; do
    c=$(command -v "$c" 2>/dev/null) && [ -n "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  local -a roots=()
  for root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
    "$HOME/Android/Sdk" "$HOME/android-sdk" /usr/lib/android-sdk; do
    [ -n "$root" ] && roots+=("$root")
  done
  for root in /mnt/*/Android /mnt/*/Android/Sdk; do
    [ -d "$root" ] && roots+=("$root")
  done
  for root in "${roots[@]}"; do
    case "$name" in
      adb)
        for f in "$root/platform-tools/adb" "$root/platform-tools/adb.exe"; do
          [ -x "$f" ] && { printf '%s\n' "$f"; return 0; }
        done ;;
      emulator)
        for f in "$root/emulator/emulator" "$root/emulator/emulator.exe"; do
          [ -x "$f" ] && { printf '%s\n' "$f"; return 0; }
        done ;;
    esac
  done
  return 1
}

# shellcheck disable=SC2329 # shipped to PC02 through declare -f and invoked there
android_passthru() {  # remote probe runner: the ssh call is already bounded
  shift
  "$@"
}

android_boot_completed() {  # <adb> <serial> <runner> <timeout>
  local out rc line
  out=$("$3" "$4" "$1" -s "$2" shell getprop sys.boot_completed 2>/dev/null </dev/null)
  rc=$?
  case "$rc" in
    124) printf 'stale'; return ;;
    0) ;;
    *) printf 'failed'; return ;;
  esac
  line=${out%%$'\n'*}
  line=${line//$'\r'/}
  line=${line//[[:space:]]/}
  case "$line" in
    1) printf 1 ;;
    0) printf 0 ;;
    *) printf unknown ;;
  esac
}

android_probe_host() {  # <adb> <emulator> <runner> <timeout>
  local adb=$1 emu=$2 runner=$3 timeout=$4
  local out rc line serial state avd boot detail
  local -a avds=() serials=() states=() serial_avds=() matched=()
  local adb_clean=1 emu_clean=1 unresolved_running=0 unresolved_other=0 found i j
  if [ -z "$adb" ]; then printf 'N\t%s\n' 'adb not found'; adb_clean=0; fi
  if [ -z "$emu" ]; then printf 'N\t%s\n' 'emulator not found'; emu_clean=0; fi
  if [ -n "$emu" ]; then
    out=$("$runner" "$timeout" "$emu" -list-avds 2>/dev/null </dev/null); rc=$?
    out=${out//$'\r'/}
    case "$rc" in
      124) printf 'N\t%s\n' 'emulator -list-avds timed out'; emu_clean=0 ;;
      0)
        while IFS= read -r line; do
          line=${line//$'\r'/}
          [ -n "$line" ] || continue
          case "$line" in \#*|'*'*) continue ;; esac
          avds+=("$line")
        done <<< "$out" ;;
      *) printf 'N\t%s\n' "emulator -list-avds failed (status $rc)"; emu_clean=0 ;;
    esac
  fi
  if [ -n "$adb" ]; then
    out=$("$runner" "$timeout" "$adb" devices 2>/dev/null </dev/null); rc=$?
    out=${out//$'\r'/}
    case "$rc" in
      124) printf 'N\t%s\n' 'adb devices timed out'; adb_clean=0 ;;
      0)
        while IFS=$'\t ' read -r serial state _; do
          [ -n "$serial" ] || continue
          case "$serial" in List|'*'*) continue ;; esac
          [ -n "$state" ] || continue
          serials+=("$serial"); states+=("$state")
        done <<< "$out" ;;
      *) printf 'N\t%s\n' "adb devices failed (status $rc)"; adb_clean=0 ;;
    esac
  fi
  for j in "${!serials[@]}"; do
    serial_avds[j]=-
    # Only an emulator host serial can resolve to an AVD; a physical or other
    # adb device renders as its own row and never makes a listed AVD unknown.
    case "${serials[$j]}" in emulator-*) ;; *) continue ;; esac
    case "${states[$j]}" in device) ;; *) continue ;; esac
    out=$("$runner" "$timeout" "$adb" -s "${serials[$j]}" emu avd name 2>/dev/null </dev/null); rc=$?
    if [ "$rc" -eq 0 ]; then
      while IFS= read -r line; do
        line=${line//$'\r'/}
        [ -n "$line" ] || continue
        case "$line" in OK) continue ;; esac
        serial_avds[j]=$line
        break
      done <<< "$out"
    fi
    # Some adb builds answer `emu avd name` with no name; the guest property
    # names the same AVD and keeps the running row attached to its AVD.
    if [ "${serial_avds[$j]}" = - ]; then
      out=$("$runner" "$timeout" "$adb" -s "${serials[$j]}" shell getprop ro.boot.qemu.avd_name 2>/dev/null </dev/null); rc=$?
      [ "$rc" -eq 0 ] || continue
      out=${out//$'\r'/}
      out=${out%%$'\n'*}
      out=${out//[[:space:]]/}
      [ -z "$out" ] || serial_avds[j]=$out
    fi
  done
  for j in "${!serials[@]}"; do
    case "${serials[$j]}" in
      emulator-*)
        [ "${serial_avds[$j]}" = - ] || continue
        case "${states[$j]}" in
          device) unresolved_running=$((unresolved_running + 1)) ;;
          *) unresolved_other=$((unresolved_other + 1)) ;;
        esac ;;
    esac
  done
  for i in "${!avds[@]}"; do
    avd=${avds[$i]}
    serial=- state=stopped boot=- detail='AVD listed; no running emulator' found=0
    for j in "${!serials[@]}"; do
      [ "${serial_avds[$j]}" = "$avd" ] || continue
      serial=${serials[$j]}; state=${states[$j]}; detail='running emulator'
      [ "$state" = device ] && boot=$(android_boot_completed "$adb" "$serial" "$runner" "$timeout")
      matched[j]=1; found=1
      break
    done
    if [ "$found" -eq 0 ]; then
      if [ "$adb_clean" -eq 0 ]; then
        state=unknown; detail='adb unavailable; running state unread'
      elif [ "$unresolved_running" -gt 0 ]; then
        # The running emulator whose AVD name is unknown renders once below.
        continue
      elif [ "$unresolved_other" -gt 0 ]; then
        state=unknown; detail='AVD listed; an emulator serial has no resolved AVD name'
      fi
    fi
    printf 'A\t%s\t%s\t%s\t%s\t%s\n' "$avd" "$serial" "$state" "$boot" "$detail"
  done
  for j in "${!serials[@]}"; do
    [ -z "${matched[$j]:-}" ] || continue
    serial=${serials[$j]}; state=${states[$j]}; avd=${serial_avds[$j]}
    boot=-
    [ "$state" = device ] && boot=$(android_boot_completed "$adb" "$serial" "$runner" "$timeout")
    case "$serial" in
      emulator-*)
        if [ "$avd" = - ]; then
          if [ "$state" = device ]; then
            avd=unknown; detail='running emulator; AVD name unresolved'
          else
            avd=-; detail='emulator serial; AVD name unresolved'
          fi
        else
          detail='running emulator'
        fi ;;
      *) avd=-; detail='adb device' ;;
    esac
    printf 'A\t%s\t%s\t%s\t%s\t%s\n' "$avd" "$serial" "$state" "$boot" "$detail"
  done
  if [ "$adb_clean" -eq 1 ] && [ "$emu_clean" -eq 1 ] \
    && [ "${#avds[@]}" -eq 0 ] && [ "${#serials[@]}" -eq 0 ]; then
    printf 'A\t-\t-\t%s\t-\t%s\n' none 'no AVDs and no running emulators'
  fi
}

collect_android_local() {
  local tag a b c d e adb='' emu=''
  [ -z "${FM_RESOURCE_ANDROID_FIXTURE:-}" ] || return 0
  if [ "${FM_RESOURCE_ADB+x}" = x ]; then adb=$FM_RESOURCE_ADB
  else adb=$(android_find_tool adb 2>/dev/null) || adb=''; fi
  if [ "${FM_RESOURCE_EMULATOR+x}" = x ]; then emu=$FM_RESOURCE_EMULATOR
  else emu=$(android_find_tool emulator 2>/dev/null) || emu=''; fi
  android_probe_host "$adb" "$emu" fm_run_timed "$ANDROID_TIMEOUT" > "$TMP/android_probe.tsv"
  : > "$TMP/android_local.tsv"
  while IFS=$'\t' read -r tag a b c d e; do
    case "$tag" in
      A) printf 'PC01\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(clean_field "$a")" "$(clean_field "$b")" \
           "$(clean_field "$c")" "$(clean_field "$d")" "$(clean_field "$e")" "$read_iso" \
           >> "$TMP/android_local.tsv" ;;
      N) note_unavailable 'android:PC01' "$a" ;;
    esac
  done < "$TMP/android_probe.tsv"
}

collect_android() {
  if [ -n "${FM_RESOURCE_ANDROID_FIXTURE:-}" ] && [ -f "$FM_RESOURCE_ANDROID_FIXTURE" ]; then
    jq -r '.android[]? | [.machine, (.avd // "-"), (.serial // "-"), (.state // "unknown"), (.boot_completed // "-"), (.detail // "-"), (.read_utc // "-")] | @tsv' \
      "$FM_RESOURCE_ANDROID_FIXTURE" > "$TMP/android.tsv"
    jq -r '.unavailable[]? | [.source, .reason, (.read_utc // "-")] | @tsv' \
      "$FM_RESOURCE_ANDROID_FIXTURE" >> "$TMP/unavailable.tsv"
    return
  fi
  cat "$TMP/android_local.tsv" "$TMP/android_remote.tsv" > "$TMP/android.tsv"
}

# --- testing environments and compute accounts ------------------------------
testing_row() {  # <machine> <item> <state> <detail>
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$(clean_field "$3")" "$(clean_field "$4")" "$read_iso" \
    >> "$TMP/testing.tsv"
}

compute_row() {  # <rung> <account> <plan> <used> <allowance> <reset> <status> <runs>
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" \
    "$(clean_field "$4")" "$(clean_field "$5")" "$(clean_field "$6")" "$7" "$(clean_field "$8")" "$read_iso" \
    >> "$TMP/compute.tsv"
}

collect_local_testing() {
  local lock=$HOME/.fm-heavy-run-slot.lock holder state runs count
  if [ -e "$lock" ]; then
    holder=$(head -1 "$lock" 2>/dev/null)
    if slot_busy "$lock"; then state=busy; else state=free; fi
    testing_row PC01 pc01-test-slot "$state" "${holder:-holder unknown}"
  else
    testing_row PC01 pc01-test-slot free 'no holder recorded'
  fi
  # shellcheck disable=SC2009 # deliberate fixed-string process match, no pgrep dependency
  runs=$(ps -eo args= 2>/dev/null | grep -E 'fm-test-run\.sh|fm-test-compute\.sh' | grep -v grep)
  count=$(printf '%s\n' "$runs" | awk 'NF { n++ } END { print n + 0 }')
  testing_row PC01 test-runs "$count running" "$(printf '%s' "$runs" | head -3 | tr '\n' ' ' | cut -c1-180)"
}

collect_forgejo() {
  local state queued='-' runners='-' user pass code url owner repo cred
  url=$(cfg forgejo_url); owner=$(cfg forgejo_owner); repo=$(cfg forgejo_repo); cred=$(cfg forgejo_credentials)
  if [ -z "$url" ] || [ -z "$owner" ] || [ -z "$repo" ] || [ -z "$cred" ]; then
    note_unavailable 'forgejo' 'not configured'
    return
  fi
  if systemctl --user is-active --quiet forgejo.service 2>/dev/null; then state=active; else state=down; fi
  testing_row PC01 forgejo-pc01 "$state" 'forgejo.service (user unit)'
  if [ "$state" = active ]; then
    code=$(fm_run_timed 3 curl -sS -m 3 -o /dev/null -w '%{http_code}' "$url/api/v1/version" 2>/dev/null </dev/null)
    testing_row PC01 forgejo-api "${code:-failed}" 'GET /api/v1/version'
    user=$(awk -F': *' '/^Username:/{print $2; exit}' "$cred" 2>/dev/null)
    pass=$(awk -F': *' '/^Password:/{print $2; exit}' "$cred" 2>/dev/null)
    if [ -n "$user" ] && [ -n "$pass" ]; then
      runners=$(printf 'user = "%s:%s"\n' "$user" "$pass" \
        | fm_run_timed "$TESTING_TIMEOUT" curl -sS -m "$TESTING_TIMEOUT" -K - \
          "$url/api/v1/admin/actions/runners" 2>/dev/null \
        | jq -r '[.[]? | .name + ":" + (.status // "unknown")] | join(",")' 2>/dev/null)
      queued=$(printf 'user = "%s:%s"\n' "$user" "$pass" \
        | fm_run_timed "$TESTING_TIMEOUT" curl -sS -m "$TESTING_TIMEOUT" -K - \
          "$url/api/v1/repos/$owner/$repo/actions/runs?limit=50" 2>/dev/null \
        | jq -r '[.workflow_runs[]? | select(.status == "waiting" or .status == "running" or .status == "queued")] | length' 2>/dev/null)
    else
      note_unavailable 'forgejo' 'credential file unreadable'
    fi
  fi
  [ -n "$runners" ] || runners='unavailable'
  [ -n "$queued" ] || queued='unavailable'
  testing_row PC01 forgejo-runners "${runners:-unavailable}" 'PC02 runner registered to PC01 Forgejo'
  testing_row PC01 forgejo-queued "${queued:-unavailable}" 'waiting+running workflow runs'
  compute_row forgejo "$owner" self-hosted - - - "$state" "${queued} queued"
}

collect_github() {
  local usage minutes runs since ghuser ghrepo
  ghuser=$(cfg github_user); ghrepo=$(cfg github_repo)
  if [ -z "$ghuser" ] || [ -z "$ghrepo" ]; then
    note_unavailable 'github' 'not configured'
    return
  fi
  if ! command -v gh >/dev/null 2>&1; then
    note_unavailable 'github' 'gh not found'
    return
  fi
  local year month
  year=$(jq -rn --argjson t "$NOW" '$t | todate | .[0:4]')
  month=$(jq -rn --argjson t "$NOW" '$t | todate | .[5:7] | tonumber')
  usage=$(fm_run_timed "$TESTING_TIMEOUT" gh api \
    "/users/$ghuser/settings/billing/usage?year=$year&month=$month" 2>/dev/null </dev/null)
  if [ -n "$usage" ] && printf '%s' "$usage" | jq -e '.usageItems | type == "array"' >/dev/null 2>&1; then
    minutes=$(printf '%s' "$usage" | jq -r '[.usageItems[]? | select(.product == "actions" and ((.sku | ascii_downcase) | contains("storage") | not)) | .quantity] | add // 0')
    compute_row github-actions "$ghuser" 'free/public' "${minutes} min MTD" 'public unlimited; private 2000/mo' 'month rollover' ok '-'
    local gb_hours allowance percent as_of
    if [ -f "$STATE/.actions-storage-check" ] && [ ! -L "$STATE/.actions-storage-check" ]; then
      gb_hours=$(awk -F'\t' '$1 == "storage_gb_hours" { print $2; exit }' "$STATE/.actions-storage-check" 2>/dev/null)
      allowance=$(awk -F'\t' '$1 == "allowance_gb_hours" { print $2; exit }' "$STATE/.actions-storage-check" 2>/dev/null)
      percent=$(awk -F'\t' '$1 == "percent" { print $2; exit }' "$STATE/.actions-storage-check" 2>/dev/null)
      as_of=$(awk -F'\t' '$1 == "as_of" { print $2; exit }' "$STATE/.actions-storage-check" 2>/dev/null)
    fi
    if [ -z "${gb_hours:-}" ]; then
      mkdir -p "$TMP/ghstate"
      fm_run_timed "$TESTING_TIMEOUT" env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$TMP/ghstate" \
        "$SCRIPT_DIR/fm-actions-storage-check.sh" check >/dev/null 2>&1 </dev/null
      if [ -f "$TMP/ghstate/.actions-storage-check" ]; then
        gb_hours=$(awk -F'\t' '$1 == "storage_gb_hours" { print $2; exit }' "$TMP/ghstate/.actions-storage-check" 2>/dev/null)
        allowance=$(awk -F'\t' '$1 == "allowance_gb_hours" { print $2; exit }' "$TMP/ghstate/.actions-storage-check" 2>/dev/null)
        percent=$(awk -F'\t' '$1 == "percent" { print $2; exit }' "$TMP/ghstate/.actions-storage-check" 2>/dev/null)
        as_of=$(awk -F'\t' '$1 == "as_of" { print $2; exit }' "$TMP/ghstate/.actions-storage-check" 2>/dev/null)
      fi
    fi
    if [ -n "${gb_hours:-}" ] && [ -n "${allowance:-}" ]; then
      local st=ok
      if [ -n "${percent:-}" ] && awk -v p="$percent" 'BEGIN { exit !(p >= 80) }'; then st=warn; fi
      compute_row github-storage "$ghuser" free "${gb_hours} GB-h to ${as_of:--}" "${allowance} GB-h" 'month rollover' "$st" '-'
    else
      note_unavailable 'github:storage' 'artifact storage probe returned no figure'
    fi
  else
    note_unavailable 'github' 'billing usage read failed'
  fi
  since=$(jq -rn --argjson t "$NOW" '($t - 86400) | todate')
  runs=$(fm_run_timed "$TESTING_TIMEOUT" gh api \
    "/repos/$ghuser/$ghrepo/actions/runs?created=%3E%3D${since}&per_page=1" 2>/dev/null </dev/null \
    | jq -r '.total_count // empty' 2>/dev/null)
  [ -z "$runs" ] || compute_row github-runs "$ghuser" free - - - ok "${runs} runs/24h"
}

collect_gitlab() {
  local usage used plan reset status ns
  ns=$(cfg gitlab_namespace)
  if [ -z "$ns" ]; then
    note_unavailable 'gitlab' 'not configured'
    return
  fi
  if ! command -v glab >/dev/null 2>&1; then
    note_unavailable 'gitlab' 'glab not found'
    return
  fi
  usage=$(fm_run_timed "$TESTING_TIMEOUT" glab api "namespaces/$ns" 2>/dev/null </dev/null)
  if [ -z "$usage" ]; then
    note_unavailable 'gitlab' 'namespace quota read failed'
    return
  fi
  used=$(printf '%s' "$usage" | jq -r '.ci_minutes_usage.total_minutes_used // empty' 2>/dev/null)
  plan=$(printf '%s' "$usage" | jq -r '.plan // "free"' 2>/dev/null)
  [ -n "$used" ] || { note_unavailable 'gitlab' 'namespace quota had no minute figure'; return; }
  reset=$(jq -rn --argjson t "$NOW" '
    ($t | todate) as $d
    | ($d[0:4] | tonumber) as $y
    | ($d[5:7] | tonumber) as $m
    | if $m == 12 then "\($y + 1)-01-01" else "\($y)-\(if $m < 9 then "0" else "" end)\($m + 1)-01" end')
  if [ "$used" -ge 400 ] 2>/dev/null; then status=exhausted; else status=ok; fi
  compute_row gitlab "$ns" "${plan:-free}" "${used} min MTD" '400 min/mo' "${reset:--}" "$status" 'relay rung'
}

collect_testing_and_compute() {
  if [ -n "${FM_RESOURCE_TESTING_FIXTURE:-}" ] && [ -f "$FM_RESOURCE_TESTING_FIXTURE" ]; then
    jq -r '.testing[]? | [.machine, .item, .state, .detail, (.read_utc // "-")] | @tsv' \
      "$FM_RESOURCE_TESTING_FIXTURE" > "$TMP/testing.tsv"
    jq -r '.compute[]? | [.rung, .account, .plan, .used, .allowance, .reset, .status, .runs, (.read_utc // "-")] | @tsv' \
      "$FM_RESOURCE_TESTING_FIXTURE" > "$TMP/compute.tsv"
    return
  fi
  ( collect_local_testing ) &
  ( collect_forgejo ) &
  ( collect_github ) &
  ( collect_gitlab ) &
  wait
  while IFS=$'\t' read -r item state detail; do
    [ -n "$item" ] || continue
    testing_row PC02 "$item" "$state" "$(printf '%s' "$detail" | cut -c1-180)"
  done < "$TMP/remote_testing.tsv"
  if [ ! -s "$TMP/remote_testing.tsv" ] && [ -s "$TMP/remote_records.tsv" ]; then
    note_unavailable 'testing:pc02' 'PC02 testing probes unavailable'
  fi
}

# --- assembly ---------------------------------------------------------------
tsv_to_json() {  # <tsv> <fields-json-array-literal>
  local file=$1 fields=$2
  jq -R -s --argjson fields "$fields" '
    split("\n") | map(select(length > 0)) | map(split("\t") as $v
      | reduce range(0; $fields | length) as $i ({}; .[$fields[$i]] = ($v[$i] // "")))
  ' "$file"
}

tsv_to_json_quota() {  # <tsv>
  jq -R -s '
    split("\n") | map(select(length > 0)) | map(split("\t") |
      {lane: .[0], account: .[1], plan: .[2], window: .[3],
       pct_remaining: (if (.[4] // "") == "" then null else (.[4] | tonumber? // .[4]) end),
       resets_et: .[5], pace: .[6], state: .[7], read_utc: .[8],
       reading_utc: .[9], reason: .[10]})
  ' "$1"
}

render_toon() {  # <model-json-file>
  jq -r '
    def q:
      tostring
      | if (. == "")
          or test("^\\s|\\s$")
          or (. == "true" or . == "false" or . == "null")
          or test("^-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$")
          or test("[:\"\\\\\\[\\]{},]")
          or test("[[:cntrl:]]")
          or test("^-")
        then "\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n") | gsub("\r"; "\\r") | gsub("\t"; "\\t")) + "\""
        else . end;
    def scal:
      if . == null then "null"
      elif type == "boolean" then (if . then "true" else "false" end)
      elif type == "number" then tostring
      else q end;
    def emit($k; $v):
      if ($v | type) == "object" then
        "\($k): ", ($v | to_entries[] | emit(.key; .value) | "  " + .)
      elif ($v | type) == "array" then
        if ($v | length) == 0 then "\($k): []"
        elif all($v[]; type != "object" and type != "array") then
          "\($k)[\($v | length)]: " + ([$v[] | scal] | join(","))
        else
          ($v[0] | keys_unsorted) as $ks
          | ( "\($k)[\($v | length)]{\($ks | map(q) | join(","))}:",
              ($v[] as $row | "  " + ([ $ks[] as $kk | ($row[$kk] | scal) ] | join(","))) )
        end
      else "\($k): " + ($v | scal)
      end;
    [ to_entries[] | emit(.key; .value) ] | join("\n")
  ' "$1"
}

build_model() {
  local host_json drive_json quota_json worker_json pane_json stray_json sm_json role_json
  local test_json android_json compute_json un_json gen_et nw np ns

  if [ -n "${FM_RESOURCE_HOSTS_JSON:-}" ] && [ -f "$FM_RESOURCE_HOSTS_JSON" ]; then
    jq -r '.hosts[]? | [.machine, (.load1 // "unknown"), (.cores // "unknown"), (.mem_free_pct // "unknown"), (.disk_free_gb // "-"), (.disk_path // "-"), (.uptime // "unknown"), (.read_utc // "-")] | @tsv' \
      "$FM_RESOURCE_HOSTS_JSON" >> "$TMP/hosts.tsv"
    jq -r '.drives[]? | [.machine, .mount, (.total_gb // "-"), (.free_gb // "-"), (.pct_used // "-"), "-", (.read_utc // "-")] | @tsv' \
      "$FM_RESOURCE_HOSTS_JSON" | fixture_drive_warn >> "$TMP/drives.tsv"
  fi

  cat "$TMP/workers_local.tsv" "$TMP/workers_remote.tsv" > "$TMP/workers.tsv"

  host_json=$TMP/hosts.json
  drive_json=$TMP/drives.json
  quota_json=$TMP/quota.json
  worker_json=$TMP/workers.json
  pane_json=$TMP/panes.json
  stray_json=$TMP/strays.json
  sm_json=$TMP/secondmates.json
  role_json=$TMP/roles.json
  test_json=$TMP/testing.json
  android_json=$TMP/android.json
  compute_json=$TMP/compute.json
  un_json=$TMP/unavailable.json

  tsv_to_json "$TMP/hosts.tsv" \
    '["machine","load1","cores","mem_free_pct","disk_free_gb","disk_path","uptime","read_utc"]' > "$host_json"
  tsv_to_json "$TMP/drives.tsv" \
    '["machine","mount","total_gb","free_gb","pct_used","warn","read_utc"]' > "$drive_json"
  tsv_to_json_quota "$TMP/quota.tsv" > "$quota_json"
  tsv_to_json "$TMP/workers.tsv" \
    '["machine","home_lane","task","kind","model","spend_lane","stage","age","last_active","ctx_band","pr","read_utc"]' > "$worker_json"
  tsv_to_json "$TMP/panes.tsv" \
    '["machine","session","workspace","tab","pane","agent","agent_status","task","cwd","title","read_utc"]' > "$pane_json"
  tsv_to_json "$TMP/strays.tsv" \
    '["machine","pane","reason","workspace_label","foreground_cwd"]' > "$stray_json"
  tsv_to_json "$TMP/secondmates.tsv" \
    '["id","host","home","state","workers","account","read_utc"]' > "$sm_json"
  tsv_to_json "$TMP/roles.tsv" \
    '["role","where","account","evidence","read_utc"]' > "$role_json"
  tsv_to_json "$TMP/testing.tsv" \
    '["machine","item","state","detail","read_utc"]' > "$test_json"
  tsv_to_json "$TMP/android.tsv" \
    '["machine","avd","serial","state","boot_completed","detail","read_utc"]' > "$android_json"
  tsv_to_json "$TMP/compute.tsv" \
    '["rung","account","plan","used","allowance","reset","status","runs","read_utc"]' > "$compute_json"
  tsv_to_json "$TMP/unavailable.tsv" \
    '["source","reason","read_utc"]' > "$un_json"

  jq -R -s 'split("\n") | map(select(length > 0))' "$TMP/budget.txt" > "$TMP/budget.json"

  gen_et=$(jq -nr --arg now "$NOW" '($now | tonumber | strflocaltime("%Y-%m-%dT%H:%M:%S%z"))')
  nw=$(jq 'length' "$worker_json")
  np=$(jq 'length' "$pane_json")
  ns=$(jq 'length' "$stray_json")

  jq -n \
    --arg schema "$SCHEMA" --arg generated "$read_iso" --arg generated_et "$gen_et" \
    --arg home "$FM_HOME" \
    --slurpfile hosts "$host_json" --slurpfile drives "$drive_json" --slurpfile quota "$quota_json" \
    --slurpfile workers "$worker_json" --slurpfile panes "$pane_json" --slurpfile strays "$stray_json" \
    --slurpfile secondmates "$sm_json" --slurpfile roles "$role_json" \
    --slurpfile testing "$test_json" --slurpfile android "$android_json" \
    --slurpfile compute "$compute_json" \
    --slurpfile unavailable "$un_json" --slurpfile budget "$TMP/budget.json" \
    --argjson capw "$CAP_WORKERS" --argjson capp "$CAP_PANES" --argjson caps "$CAP_STRAYS" \
    --argjson nw "$nw" --argjson np "$np" --argjson ns "$ns" \
    --argjson homeonly "$HOME_ONLY" '
    {
      schema: $schema,
      generated: $generated,
      generated_et: $generated_et,
      budget_exceeded: ($budget[0] // []),
      omitted: {workers: (if $nw > $capw then ($nw - $capw) else 0 end),
                panes: (if $np > $capp then ($np - $capp) else 0 end),
                strays: (if $ns > $caps then ($ns - $caps) else 0 end)},
      hosts: ($hosts[0] // []),
      drives: ($drives[0] // []),
      quota: ($quota[0] // []),
      workers: (($workers[0] // [])[0:$capw]),
      panes: (($panes[0] // [])[0:$capp]),
      strays: (($strays[0] // [])[0:$caps]),
      secondmates: ($secondmates[0] // []),
      roles: ($roles[0] // []),
      testing: ($testing[0] // []),
      android: ($android[0] // []),
      compute: ($compute[0] // []),
      unavailable: ($unavailable[0] // [])
    }
    | if $homeonly == 1 then {schema, generated, generated_et, home: $home, budget_exceeded, omitted: {workers: .omitted.workers}, workers, unavailable} else . end
  ' > "$TMP/model.json"

  if [ "$FORMAT" = json ]; then
    cat "$TMP/model.json"
  else
    render_toon "$TMP/model.json"
  fi
}

# --- run --------------------------------------------------------------------
if [ "$HOME_ONLY" -eq 1 ]; then
  collect_collie
  collect_local_workers
  build_model
  exit 0
fi

( collect_collie ) &
( collect_local_host ) &
( collect_local_drives ) &
( collect_quota ) &
( collect_verify ) &
( collect_local_workers ) &
( collect_android_local ) &
( collect_remote ) &
wait

collect_secondmate_state
build_secondmates
collect_herdr
build_roles
collect_testing_and_compute
collect_android
build_model

if [ -s "$TMP/hosts.tsv" ] || [ -s "$TMP/drives.tsv" ] || [ -s "$TMP/quota.tsv" ] \
  || [ -s "$TMP/workers_local.tsv" ] || [ -s "$TMP/workers_remote.tsv" ] \
  || [ -s "$TMP/panes.tsv" ] || [ -s "$TMP/secondmates.tsv" ] || [ -s "$TMP/roles.tsv" ] \
  || [ -s "$TMP/testing.tsv" ] || [ -s "$TMP/android.tsv" ] || [ -s "$TMP/compute.tsv" ]; then
  exit 0
fi
exit 1
