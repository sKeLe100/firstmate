#!/usr/bin/env bash
# fm-actions-storage-check.sh - warn when GitHub Actions artifact storage
# approaches the account plan's included allowance.
#
# Usage:
#   fm-actions-storage-check.sh [check]
#   fm-actions-storage-check.sh arm
#   fm-actions-storage-check.sh disarm
#   fm-actions-storage-check.sh --help
#
# `check` prints one line when the account's pooled GitHub Actions artifact and
# Packages storage reaches 80 percent of the plan's included allowance, and
# prints nothing at all otherwise, so it composes with the existing watcher
# state-check contract instead of needing a schedule of its own. `arm` writes
# state/actions-storage.check.sh and binds its bytes with fm-check-register.sh,
# so the watcher dispatches it on its normal FM_CHECK_INTERVAL cadence and turns
# its line into a `check:` wake, which is the heartbeat surface. The same report
# record is read locally by bin/fm-bearings-snapshot.sh and shown there as
# storage_alert, with no network call in bearings. `disarm` removes the shim,
# its trust binding, and the report record.
#
# Source and scope. Storage is read from GitHub's enhanced billing usage
# report, GET /users/{username}/settings/billing/usage, whose documented
# usageItems carry one row per day, product, SKU, and repository. Actions
# artifact storage is sku actions_storage and GitHub Packages storage is sku
# packages_storage, both in gigabyte-hours; this check requests the report for
# yesterday in UTC, the most recent completed day, sums every storage row in it,
# and divides by 24 for that day's average gigabytes, which is the pooled figure
# the plan's included allowance applies to. The current UTC day is never read,
# because its gigabyte-hours are still accumulating. That endpoint requires a classic token with the `user` scope;
# authorize once with `gh auth refresh -h github.com -s user`. A token without
# that scope gets a 404, and this check reports that as an actionable finding
# rather than going quiet, because an unwatched account blocks uploads at 100
# percent when it has no payment method or a zero spending limit.
#
# The figure is yesterday's average, so it trails current storage by up to a
# day. It is the
# supported replacement for the retired shared-storage estimate endpoint, which
# now answers 410 Gone.
#
# Why 80 percent and 500 MB. GitHub Free includes 500 MB of shared artifact and
# GitHub Packages storage (GitHub Pro 1 GB, Team 2 GB, Enterprise Cloud 50 GB),
# measured in binary units where 1 GB is 1024 MB. Cache storage is a separate
# per-repository allowance and is not part of this pool. Uploads stop when the
# included allowance is consumed, so the warning is deliberately ahead of 100
# percent. Set FM_ACTIONS_STORAGE_ALLOWANCE_MB when the plan includes a
# different amount.
#
# What this check never does: it reports, and it deletes nothing. It does not
# expire artifacts, change retention settings, or touch a spending limit.
#
# Probing costs a network call, so `check` probes at most once per day (86400
# seconds) and only reads its small record in between. Each probe request is
# bounded to 10 seconds. The report record
# state/.actions-storage-check is written only when a sweep runs to its end, and
# it carries the last reported finding, so the warning prints once per daily
# evaluation rather than on every watcher pass.
set -u
export LC_ALL=C
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.actions-storage-check"
CHECK_ID=actions-storage
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
GH_BIN=gh
RECORD_SCHEMA_LINE=$'schema\tfm-actions-storage-check-v1'
INTERVAL=86400
WARN_PERCENT=80
MAX_LINE=400
PROBE_SECS=10

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  sed -n '2,57{s/^# \{0,1\}//;p;}' "$0"
}

fail() {
  printf 'fm-actions-storage-check: %s\n' "$1" >&2
  exit 1
}

ALLOWANCE_MB=${FM_ACTIONS_STORAGE_ALLOWANCE_MB:-500}
case "$ALLOWANCE_MB" in
  ''|*[!0-9]*|0)
    fail "FM_ACTIONS_STORAGE_ALLOWANCE_MB must be a positive whole number of megabytes"
    ;;
esac

now_epoch() {
  case "${FM_ACTIONS_STORAGE_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_ACTIONS_STORAGE_NOW" ;;
  esac
}

record_usable() {
  local line
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  IFS= read -r line < "$RECORD" || return 1
  [ "$line" = "$RECORD_SCHEMA_LINE" ]
}

read_last_eval() {
  record_usable || return 0
  awk -F '\t' '$1 == "last_eval" { print $2; exit }' "$RECORD" 2>/dev/null || true
}

check_due() {
  local now last age
  now=$(now_epoch)
  last=$(read_last_eval)
  case "$last" in
    ''|*[!0-9]*) printf '%s\n' "$now"; return 0 ;;
  esac
  age=$((now - last))
  if [ "$age" -lt 0 ] || [ "$age" -ge "$INTERVAL" ]; then
    printf '%s\n' "$now"
    return 0
  fi
  return 1
}

write_record_atomically() {
  local tmp=$1 dest=$2 state_device
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  state_device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$dest" "$state_device" || return 1
  mv -f -- "$tmp" "$dest"
}

append_finding() {
  if [ -z "$FINDINGS" ]; then
    FINDINGS=$1
  else
    FINDINGS="$FINDINGS; $1"
  fi
}

# The usage report is read as a documented shape: usageItems must be an array,
# and the value that counts is every storage row of the one requested day. A
# response that is absent, of the wrong type, or carries a storage row dated
# another day, with a non-numeric or negative quantity, or with a unit other
# than gigabyte-hours is an
# unusable response, never a zero. A zero would turn a broken read into a silent
# "everything is fine". The unit is compared without case or punctuation, so
# both "gigabyte-hours" and "GigabyteHours" are accepted.
read_usage() {  # <json-text> <day>
  printf '%s' "$1" | jq -r --arg day "$2" '
    if (.usageItems | type) != "array" then empty
    else
      [ .usageItems[]
        | select(type == "object")
        | select((((.sku // "") | ascii_downcase) as $s
                  | $s == "actions_storage" or $s == "packages_storage"))
      ]
      | if all(.[]; ((.date // "") | tostring | startswith($day))
                    and (.quantity | type == "number" and . >= 0)
                    and ((.unitType // "") | ascii_downcase | gsub("[^a-z0-9]"; "")) == "gigabytehours")
        then ([ .[].quantity ] | (add // 0) / 24 * 1000000 | round) / 1000000
        else error("unusable storage row") end
    end
  ' 2>/dev/null
}

utc_yesterday() {  # <now-epoch>
  jq -rn --argjson t "$(( $1 - 86400 ))" '$t | todate | .[0:10]' 2>/dev/null
}

probe_billing() {  # <stderr-file> <day>
  local login out status err=$1 day=$2 query
  out=$(fm_run_timed "$PROBE_SECS" "$GH_BIN" api /user --jq .login 2>/dev/null) || status=$?
  if [ "${status:-0}" -ne 0 ]; then
    if fm_timed_out "${status:-0}"; then
      append_finding "billing usage unreadable: the GitHub login lookup exceeded ${PROBE_SECS}s"
    else
      append_finding "billing usage unreadable: the GitHub login lookup failed (is gh authenticated?)"
    fi
    return 1
  fi
  case "$out" in
    ''|*[!A-Za-z0-9-]*)
      append_finding "billing usage unreadable: the GitHub login lookup returned no usable login"
      return 1
      ;;
  esac
  login=$out

  query="year=$((10#${day:0:4}))&month=$((10#${day:5:2}))&day=$((10#${day:8:2}))"
  status=0
  : > "$err"
  out=$(fm_run_timed "$PROBE_SECS" "$GH_BIN" api "/users/$login/settings/billing/usage?$query" 2>"$err") || status=$?
  if [ "$status" -ne 0 ]; then
    if fm_timed_out "$status"; then
      append_finding "billing usage unreadable: the GitHub billing request exceeded ${PROBE_SECS}s"
    elif grep -qi 'user.*scope' "$err" 2>/dev/null; then
      append_finding 'billing usage unreadable: the GitHub token needs the "user" scope (run: gh auth refresh -h github.com -s user)'
    else
      append_finding "billing usage unreadable: the GitHub billing request failed (gh exited $status)"
    fi
    return 1
  fi

  if ! USAGE=$(read_usage "$out" "$day") || [ -z "$USAGE" ]; then
    append_finding "billing usage unreadable: the GitHub billing response was not usable JSON"
    return 1
  fi
  return 0
}

run_check() {
  local now reported_previous storage_gb as_of percent mb_used line
  if ! now=$(check_due); then
    return 0
  fi
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"

  OLD_RECORD=$RECORD
  record_usable || OLD_RECORD=/dev/null
  reported_previous=$(awk -F '\t' '$1 == "reported" { print substr($0, index($0, "\t") + 1); exit }' "$OLD_RECORD" 2>/dev/null || true)
  NEW_RECORD=$(mktemp "$STATE/.actions-storage-check.XXXXXX") || exit 1
  ERR_FILE="$STATE/.actions-storage-check.err.$$"
  trap 'rm -f -- "${NEW_RECORD:-}" "${ERR_FILE:-}"' EXIT
  trap 'rm -f -- "${NEW_RECORD:-}" "${ERR_FILE:-}"; exit 1' HUP INT TERM
  FINDINGS=
  USAGE=
  printf '%s\n' "$RECORD_SCHEMA_LINE" > "$NEW_RECORD" || exit 1
  printf '%s\t%s\n' last_eval "$now" >> "$NEW_RECORD" || exit 1

  as_of=$(utc_yesterday "$now")
  case "$as_of" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) fail "could not compute yesterday's UTC date" ;;
  esac

  if ! command -v "$GH_BIN" >/dev/null 2>&1; then
    append_finding "billing usage unreadable: gh not found"
  elif probe_billing "$ERR_FILE" "$as_of"; then
    storage_gb=$USAGE
    mb_used=$(awk -v gb="$storage_gb" 'BEGIN { printf "%.1f", gb * 1024 }')
    percent=$(awk -v gb="$storage_gb" -v mb="$ALLOWANCE_MB" 'BEGIN { printf "%.1f", (gb * 1024 / mb) * 100 }')
    printf '%s\t%s\n' as_of "$as_of" >> "$NEW_RECORD" || exit 1
    printf '%s\t%s\n' storage_gb "$storage_gb" >> "$NEW_RECORD" || exit 1
    printf '%s\t%s\n' allowance_mb "$ALLOWANCE_MB" >> "$NEW_RECORD" || exit 1
    printf '%s\t%s\n' percent "$percent" >> "$NEW_RECORD" || exit 1
    if awk -v p="$percent" -v warn="$WARN_PERCENT" 'BEGIN { exit !(p >= warn) }'; then
      append_finding "${mb_used} MB of ${ALLOWANCE_MB} MB used (${percent}%) as of ${as_of}; uploads block at 100%"
    fi
  fi

  if [ -n "$FINDINGS" ]; then
    if [ "$FINDINGS" != "$reported_previous" ]; then
      line=$(fm_cap_line "actions-storage: $FINDINGS" "$MAX_LINE")
      printf '%s\n' "$line"
    fi
    printf '%s\t%s\n' reported "$FINDINGS" >> "$NEW_RECORD" || exit 1
  fi
  write_record_atomically "$NEW_RECORD" "$RECORD" || fail "could not publish report record"
  NEW_RECORD=
}

SHIM_TMP=
ARM_BACKUP=

shim_write() {  # <wanted-bytes> <state-device>
  local want=$1 device=$2
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  SHIM_TMP=$(umask 077; mktemp "$STATE/.actions-storage-check-shim.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$want" > "$SHIM_TMP" \
    || ! chmod 0700 "$SHIM_TMP" \
    || ! fm_pr_private_file_valid "$SHIM_TMP" 700 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$SHIM_TMP" "$CHECK_SHIM"; then
    rm -f -- "$SHIM_TMP"
    SHIM_TMP=
    return 1
  fi
  SHIM_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {  # <state-device>
  local device=$1 tmp
  tmp=$(umask 077; mktemp "$STATE/.actions-storage-check-shim.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

arm_rollback() {
  [ -z "$SHIM_TMP" ] || rm -f -- "$SHIM_TMP"
  SHIM_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
}

arm_failed() {  # <message>
  trap - HUP INT TERM
  arm_rollback
  fail "$1"
}

arm() {
  local state_device home want
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || fail "cannot resolve FM_HOME $FM_HOME" ;;
  esac
  state_device=$(fm_pr_file_device "$STATE") || fail "state directory is unavailable"
  want=$(printf '%s\n' \
    '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-actions-storage-check.sh") check")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup "$state_device") || fail "could not save the existing check shim"
  fi
  trap 'arm_failed "arming was interrupted"' HUP INT TERM
  shim_write "$want" "$state_device" || arm_failed "check shim path is unavailable"
  FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null || arm_failed "could not register the check shim"
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check)
    [ "$#" -le 1 ] || { usage >&2; exit 2; }
    run_check
    ;;
  arm)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    arm
    ;;
  disarm)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    disarm
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
