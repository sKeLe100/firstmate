#!/usr/bin/env bash
# fm-timed-dispatch.sh - arm a durable wake that names a queued task when a
# clock time or a named account's quota window resets.
#
# Usage:
#   fm-timed-dispatch.sh arm <task-id> --at <epoch|@epoch|ISO-8601-UTC> [options]
#   fm-timed-dispatch.sh arm <task-id> --account <dir|ordinary>
#     [--provider <provider>] [--window <five_hour|seven_day>] [options]
#   fm-timed-dispatch.sh list
#   fm-timed-dispatch.sh cancel <task-id>
#   fm-timed-dispatch.sh cancel --name <name>
#   fm-timed-dispatch.sh _condition <target-epoch>
#
# arm      Record "wake me to dispatch <task-id> at <time or quota reset>" and
#          arm it as a when-adapter watch (bin/fm-procevent-when.sh). The watch
#          survives a firstmate restart through the process-event runner's own
#          reconciliation, and it wakes firstmate with a check naming the task;
#          it never dispatches on its own, so the spawn still goes through
#          firstmate's normal dispatch checks.
#          Exactly one of --at or --account is required.
#            --at accepts epoch seconds, @epoch, or a UTC ISO-8601 time ending
#                 Z or +00:00 (fractional seconds allowed). Non-UTC offsets are
#                 refused; convert to UTC first.
#            --account accepts a Claude config directory or "ordinary" and
#                 reads that account's own quota with
#                 `quota-axi --provider claude --profile-only --json`, then
#                 arms for the named window's resetsAt.
#          Options:
#            --window <id>    quota window to watch (default five_hour); matched
#                             by window id or kind.
#            --provider <p>   quota provider (default claude; only claude).
#            --grace <secs>   wait this long past the target before firing, so a
#                             quota window has actually rolled (default 30;
#                             0 allowed).
#            --interval <s>   poll cadence the watch uses (default 30).
#            --name <name>    override the watch name. Default
#                             dispatch-<task-id>, which is what makes the wake
#                             name the task. Use only to shorten a long id; the
#                             task id still appears in the wake message.
# list     Print every armed timed dispatch and its target, or "none".
# cancel   Retire an armed wake and remove its record.
# _condition <target-epoch>
#          The clock condition the watch runs: exit 0 when now >= target, 1
#          when not yet, and 3 on a malformed target. FM_TIMED_DISPATCH_NOW
#          overrides "now" for the portable regression test; production never
#          sets it.
#
# A quota reset is resolved once at arm time and then awaited on the clock, so
# the wake does not depend on quota-axi staying reachable or the window keeping
# the same reading. Re-arm if the account's window changes.
# The arm record lives at state/timed-dispatch/<name>.record; the watch itself
# and its trust binding are owned by bin/fm-procevent-when.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SELF="$SCRIPT_DIR/fm-timed-dispatch.sh"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

FM_TIMED_DISPATCH_QUOTA_SECONDS=${FM_TIMED_DISPATCH_QUOTA_SECONDS:-60}
RECORD_DIR="$STATE/timed-dispatch"

# The when adapter runs as a child and must resolve the same home as this
# caller, so forward the overrides it reads rather than relying on inheritance.
export FM_HOME
[ -z "${FM_ROOT_OVERRIDE:-}" ] || export FM_ROOT_OVERRIDE
[ -z "${FM_STATE_OVERRIDE:-}" ] || export FM_STATE_OVERRIDE

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

nonneg_int() { case "${1-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

positive_number() {
  local n=${1-}
  local LC_ALL=C
  [[ "$n" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  [ "$n" != 0 ] && [[ ! "$n" =~ ^0+(\.0+)?$ ]]
}

# epoch_of <epoch|@epoch|ISO-8601-UTC>: print epoch seconds, or return 1.
epoch_of() {
  local ts=${1-} n
  case "$ts" in
    '') return 1 ;;
    *[!0-9]*) ;;
    *) printf '%s\n' "$ts"; return 0 ;;
  esac
  case "$ts" in
    @*)
      ts=${ts#@}
      case "$ts" in ''|*[!0-9]*) return 1 ;; esac
      printf '%s\n' "$ts"
      return 0
      ;;
  esac
  command -v jq >/dev/null 2>&1 || return 1
  n=$(jq -rn --arg ts "$ts" '
    ($ts
      | sub("\\.[0-9]+"; "")
      | sub("(\\+00:00|\\+0000|-00:00|-0000)$"; "Z")
      | if test("Z$") then . else . + "Z" end)
    | fromdateiso8601
  ' 2>/dev/null) || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$n"
}

epoch_to_iso() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s' "$1"
}

# quota_reset <provider> <account> <window>: print the window's resetsAt.
quota_reset() {
  local provider=$1 account=$2 window=$3 root json row status err ts
  case "$account" in
    ordinary) root="${HOME:?HOME is required to resolve the ordinary account}/.claude" ;;
    /*) root=$account ;;
    *) die "--account must be 'ordinary' or an absolute config directory: $account" ;;
  esac
  [ -d "$root" ] || die "account config directory does not exist: $root"
  case "$FM_TIMED_DISPATCH_QUOTA_SECONDS" in
    ''|*[!0-9]*|0) die "FM_TIMED_DISPATCH_QUOTA_SECONDS must be a positive integer" ;;
  esac
  command -v quota-axi >/dev/null 2>&1 || die "quota-axi is not installed; cannot resolve a quota reset"
  command -v jq >/dev/null 2>&1 || die "jq is required to read the quota reset"
  json=$(fm_run_timed "$FM_TIMED_DISPATCH_QUOTA_SECONDS" \
    env -u QUOTA_AXI_SNAPSHOT CLAUDE_CONFIG_DIR="$root" \
    quota-axi --provider "$provider" --profile-only --json 2>/dev/null) || true
  [ -n "$json" ] || die "quota-axi produced no reading for $account"
  row=$(printf '%s\n' "$json" \
    | jq -c --arg p "$provider" '[.providers[]? | select(.provider == $p)] | first // empty' 2>/dev/null) \
    || die "quota-axi returned an unreadable snapshot for $account"
  [ -n "$row" ] || die "quota-axi reported no $provider row for $account"
  status=$(printf '%s\n' "$row" | jq -r '.state.status // "unknown"' 2>/dev/null)
  err=$(printf '%s\n' "$row" | jq -r '.state.error // empty' 2>/dev/null)
  ts=$(printf '%s\n' "$row" \
    | jq -r --arg w "$window" \
      '[.windows[]? | select((.id // "") == $w or (.kind // "") == $w) | .resetsAt // empty] | first // empty' 2>/dev/null)
  if [ -z "$ts" ]; then
    if [ -n "$err" ]; then
      die "quota-axi reports $provider for $account as $status: $err"
    fi
    die "quota-axi reports no $window reset for $account (status: $status); the window may not have started or the reading is unavailable"
  fi
  printf '%s\n' "$ts"
}

# write_record <name> <task> <kind> <target-epoch> <fire-epoch> <grace> \
#   <account> <window> <provider> <interval> <armed>
write_record() {
  local name=$1 task=$2 kind=$3 target=$4 fire=$5 grace=$6
  local account=$7 window=$8 provider=$9 interval=${10} armed=${11}
  local tmp
  (umask 077; mkdir -p "$RECORD_DIR") || die "cannot create the timed-dispatch record directory"
  [ -d "$RECORD_DIR" ] && [ ! -L "$RECORD_DIR" ] || die "timed-dispatch record directory is unavailable"
  tmp=$(umask 077; mktemp "$RECORD_DIR/.record.XXXXXX") || die "cannot stage the timed-dispatch record"
  {
    printf 'name=%s\n' "$name"
    printf 'task=%s\n' "$task"
    printf 'kind=%s\n' "$kind"
    printf 'target_epoch=%s\n' "$target"
    printf 'fire_epoch=%s\n' "$fire"
    printf 'grace=%s\n' "$grace"
    printf 'account=%s\n' "$account"
    printf 'window=%s\n' "$window"
    printf 'provider=%s\n' "$provider"
    printf 'interval=%s\n' "$interval"
    printf 'armed=%s\n' "$armed"
  } > "$tmp" || { rm -f -- "$tmp"; die "cannot write the timed-dispatch record"; }
  mv -f -- "$tmp" "$RECORD_DIR/$name.record" || { rm -f -- "$tmp"; die "cannot publish the timed-dispatch record"; }
}

cmd_arm() {
  local task=${1-} at='' account='' provider=claude window=five_hour grace=30 interval=30 name=''
  local now target reset effective deadline label message sid record kind
  local lib_account='-' lib_window='-' lib_provider='-'
  [ -n "$task" ] || usage
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --at)          [ "$#" -ge 2 ] || die "--at needs a value"; at=$2; shift 2 ;;
      --at=*)        at=${1#--at=}; shift ;;
      --account)     [ "$#" -ge 2 ] || die "--account needs a value"; account=$2; shift 2 ;;
      --account=*)   account=${1#--account=}; shift ;;
      --provider)    [ "$#" -ge 2 ] || die "--provider needs a value"; provider=$2; shift 2 ;;
      --provider=*)  provider=${1#--provider=}; shift ;;
      --window)      [ "$#" -ge 2 ] || die "--window needs a value"; window=$2; shift 2 ;;
      --window=*)    window=${1#--window=}; shift ;;
      --grace)       [ "$#" -ge 2 ] || die "--grace needs a value"; grace=$2; shift 2 ;;
      --grace=*)     grace=${1#--grace=}; shift ;;
      --interval)    [ "$#" -ge 2 ] || die "--interval needs a value"; interval=$2; shift 2 ;;
      --interval=*)  interval=${1#--interval=}; shift ;;
      --name)        [ "$#" -ge 2 ] || die "--name needs a value"; name=$2; shift 2 ;;
      --name=*)      name=${1#--name=}; shift ;;
      -h|--help|help) usage ;;
      *) die "unknown arm argument: $1" ;;
    esac
  done

  fm_task_id_path_safe "$task" || die "task id must be path-safe (letters, digits, dot, underscore, hyphen): $task"
  if [ -n "$at" ] && [ -n "$account" ]; then
    die "give exactly one of --at or --account"
  fi
  if [ -z "$at" ] && [ -z "$account" ]; then
    die "arm needs --at or --account"
  fi
  [ "$provider" = claude ] || die "only --provider claude is supported"
  nonneg_int "$grace" || die "--grace needs a non-negative integer of seconds: $grace"
  positive_number "$interval" || die "--interval needs a positive number of seconds: $interval"
  [ -n "$window" ] || die "--window needs a value"

  if [ -z "$name" ]; then
    name="dispatch-$task"
    if ! "$SCRIPT_DIR/fm-procevent-when.sh" source-id "$name" >/dev/null 2>&1; then
      die "the task id is too long to name the wake (the watch name limit leaves 50 chars); pass --name <short-slug>, and the task id still appears in the wake message"
    fi
  else
    "$SCRIPT_DIR/fm-procevent-when.sh" source-id "$name" >/dev/null 2>&1 \
      || die "--name must be path-safe and short enough for a watch name: $name"
  fi
  sid="when-$name"
  record="$RECORD_DIR/$name.record"
  [ ! -e "$record" ] || die "a timed dispatch named $name is already armed; cancel it first"

  now=$(date +%s)
  if [ -n "$at" ]; then
    target=$(epoch_of "$at") \
      || die "--at must be epoch seconds, @epoch, or a UTC ISO-8601 time (ending Z or +00:00): $at"
    kind='at'
    lib_account='-'
    lib_window='-'
    lib_provider='-'
    label="at $(epoch_to_iso "$target")"
  else
    reset=$(quota_reset "$provider" "$account" "$window") || exit 1
    target=$(epoch_of "$reset") \
      || die "quota-axi returned an unparseable $window reset time: $reset"
    kind='quota'
    lib_account=$account
    lib_window=$window
    lib_provider=$provider
    label="$account $window reset at $(epoch_to_iso "$target")"
  fi
  case "$target" in ''|*[!0-9]*) die "resolved target is not an epoch: $target" ;; esac
  if [ "$target" -le "$now" ]; then
    die "the armed time $(epoch_to_iso "$target") is not in the future (now $(epoch_to_iso "$now")); dispatch now or pass a future --at"
  fi
  effective=$((target + grace))
  [ "$effective" -gt "$now" ] || effective=$((now + 1))
  deadline=$((effective - now + 3600))
  [ "$deadline" -ge 3600 ] || deadline=3600
  message="wake to dispatch $task: $label; fires $(epoch_to_iso "$effective")"

  write_record "$name" "$task" "$kind" "$target" "$effective" "$grace" \
    "$lib_account" "$lib_window" "$lib_provider" "$interval" "$now"

  if ! "$SCRIPT_DIR/fm-procevent-when.sh" arm "$name" \
      --interval "$interval" --stable 2 --deadline "$deadline" \
      --condition "$SELF" _condition "$effective" \
      --action echo "$message"; then
    rm -f -- "$record"
    die "could not arm the timed dispatch wake for $task"
  fi

  printf 'armed: %s\n' "$sid"
  printf 'task: %s\n' "$task"
  printf 'fires: %s (in %ss, %ss after the target)\n' "$(epoch_to_iso "$effective")" "$((effective - now))" "$grace"
  printf 'wake: firstmate is woken to dispatch; this never dispatches on its own\n'
  if [ "$name" = "dispatch-$task" ]; then
    printf 'cancel: bin/fm-timed-dispatch.sh cancel %s\n' "$task"
  else
    printf 'cancel: bin/fm-timed-dispatch.sh cancel --name %s\n' "$name"
  fi
}

cmd_list() {
  local rec seen=0 name='' task='' kind='' target='' fire='' account='' window='' provider='' state=''
  local sid reg
  if [ -d "$RECORD_DIR" ]; then
    for rec in "$RECORD_DIR"/*.record; do
      [ -e "$rec" ] || continue
      seen=1
      name='' task='' kind='' target='' fire='' account='' window='' provider=''
      while IFS='=' read -r k v; do
        case "$k" in
          name) name=$v ;;
          task) task=$v ;;
          kind) kind=$v ;;
          target_epoch) target=$v ;;
          fire_epoch) fire=$v ;;
          account) account=$v ;;
          window) window=$v ;;
          provider) provider=$v ;;
        esac
      done < "$rec"
      sid="when-$name"
      reg="$STATE/procevent/$sid.source"
      if [ -e "$STATE/when/$sid.fired" ]; then
        state='fired'
      elif [ -e "$reg" ]; then
        state='armed'
      else
        state='stale'
      fi
      printf '  name=%s  task=%s  fires=%s  kind=%s' \
        "$name" "$task" "$(epoch_to_iso "${fire:-0}")" "$kind"
      [ "$account" = - ] || printf '  account=%s  window=%s' "$account" "$window"
      printf '  state=%s\n' "$state"
    done
  fi
  if [ "$seen" -eq 0 ]; then
    printf 'timed-dispatch: none\n'
  else
    printf 'timed-dispatch: %s record(s)\n' "$seen"
  fi
}

cmd_cancel() {
  local task='' name='' rec sid
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) [ "$#" -ge 2 ] || die "--name needs a value"; name=$2; shift 2 ;;
      --name=*) name=${1#--name=}; shift ;;
      -h|--help|help) usage ;;
      -*) die "unknown cancel argument: $1" ;;
      *) [ -z "$task" ] || die "cancel takes one task id"; task=$1; shift ;;
    esac
  done
  if [ -n "$name" ]; then
    [ -z "$task" ] || die "give either a task id or --name, not both"
  else
    [ -n "$task" ] || usage
    fm_task_id_path_safe "$task" || die "task id must be path-safe: $task"
    name="dispatch-$task"
    "$SCRIPT_DIR/fm-procevent-when.sh" source-id "$name" >/dev/null 2>&1 \
      || die "the task id is too long to name the wake; pass --name <slug>"
  fi
  sid="when-$name"
  rec="$RECORD_DIR/$name.record"
  if [ ! -e "$rec" ] && [ ! -e "$STATE/when/$sid.spec" ] && [ ! -e "$STATE/procevent/$sid.source" ]; then
    die "no timed dispatch is armed for ${task:-$name}"
  fi
  "$SCRIPT_DIR/fm-procevent-when.sh" retire "$name" || die "could not retire $sid"
  rm -f -- "$rec"
  printf 'cancelled: %s\n' "$sid"
}

cmd_condition() {
  local target=${1-} now
  [ "$#" -eq 1 ] || usage
  nonneg_int "$target" || exit 3
  if [ -n "${FM_TIMED_DISPATCH_NOW:-}" ]; then
    now=$FM_TIMED_DISPATCH_NOW
    nonneg_int "$now" || exit 3
  else
    now=$(date +%s)
  fi
  [ "$now" -ge "$target" ] && exit 0
  exit 1
}

case "${1-}" in
  arm)        shift; cmd_arm "$@" ;;
  list)       shift; [ "$#" -eq 0 ] || usage; cmd_list ;;
  cancel)     shift; cmd_cancel "$@" ;;
  _condition) shift; cmd_condition "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
