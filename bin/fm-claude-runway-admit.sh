#!/usr/bin/env bash
# fm-claude-runway-admit.sh - may a Claude gate-agent invocation start on an
# account now, judged by the same per-account five-hour runway rule that gates
# dispatched lanes?
#
# Why: no-mistakes gate agents launch Claude outside bin/fm-spawn.sh, so they
# bypass that gate and can drain a five-hour window on their own
# (data/claude2-5h-drain-scout/report.md). The private gate-agent wrapper
# (~/.no-mistakes/claude-account2.sh) calls this before exec'ing claude, so a
# gate agent waits instead of starting once the window is nearly spent.
#
# The runway ladder itself is owned by bin/fm-dispatch-quota-cap.sh: this
# script only calls it and reads its `claude_reading`, `claude_runway_cap`,
# `claude_account`, and `claude_runway_reason` lines. Because a gate agent is
# not a dispatched lane, the refusal does not depend on the lane count; a real
# reading is refused when its runway cap is 0 (exhausted, or projected to
# exhaust more than 20 minutes before the reset on a non-early projection) or
# 1 (under 40% remaining, which
# in fm-spawn still admits one implementing lane). An unavailable or
# rate-limited reading is not a real reading: it admits, because an outage of
# the quota endpoint must never stop every check. The same holds for a cap
# script that cannot evaluate the reading at all (exit 2): it admits with a
# warning rather than blocking work on a broken quota document.
#
# Usage: fm-claude-runway-admit.sh [--claude-account <ordinary|/path>]
#                                 [--quota-json <file>]
#                                 [--state-dir <dir>] [--ttl <seconds>]
#   --claude-account <v>  evaluate this bound account instead of reading
#                         config/claude-account, exactly as
#                         bin/fm-dispatch-quota-cap.sh does. A gate-agent
#                         wrapper MUST pass this explicitly (the path of the
#                         account it launches): its environment may not point
#                         at the right config, and the helper would then judge
#                         the wrong account's window.
#   --quota-json <file>   pass the offline quota fixture through to the cap
#                         script (FM_DISPATCH_QUOTA_JSON is the env form).
#   --state-dir <dir>     keep the decision cache in <dir> instead of
#                         $FM_HOME/state.
#   --ttl <seconds>       cache lifetime, default 120 and env
#                         FM_CLAUDE_RUNWAY_ADMIT_TTL. 0 disables the cache.
#
# The decision is cached per account for the TTL so per-invocation calls do
# not hammer the rate-limited quota endpoint; a cache write failure degrades
# to an uncached call, never to a refusal. The cache file records the account
# so a pinned-account change inside one TTL is harmless; without an explicit
# account the key is `default` and the cap script's own pin resolution still
# decides the account.
#
# Opt out with FM_CLAUDE_RUNWAY_ADMIT=0 (also no/off/false/disable/disabled),
# for tests and manual runs.
#
# Exit codes: 0 admit; 75 refuse (one stderr line names the account and the
# reason); 2 on a usage error in this script's own arguments.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CAP="$SCRIPT_DIR/fm-dispatch-quota-cap.sh"

REFUSE_EXIT=75
DEFAULT_TTL=120
TTL=${FM_CLAUDE_RUNWAY_ADMIT_TTL:-$DEFAULT_TTL}
QUOTA_JSON=${FM_DISPATCH_QUOTA_JSON:-}
CLAUDE_ACCOUNT=

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

case "${FM_CLAUDE_RUNWAY_ADMIT:-1}" in
  0 | no | off | false | disable | disabled) exit 0 ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --claude-account)
      CLAUDE_ACCOUNT="${2:?--claude-account needs a value}"
      shift 2
      ;;
    --quota-json)
      QUOTA_JSON="${2:?--quota-json needs a value}"
      shift 2
      ;;
    --state-dir)
      STATE="${2:?--state-dir needs a value}"
      shift 2
      ;;
    --ttl)
      TTL="${2:?--ttl needs a value}"
      shift 2
      ;;
    *)
      echo "fm-claude-runway-admit: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

case "$TTL" in
  '' | *[!0-9]*)
    echo "fm-claude-runway-admit: ignoring non-numeric TTL '$TTL'; using $DEFAULT_TTL" >&2
    TTL=$DEFAULT_TTL
    ;;
esac

now() { date +%s; }

cache_field() {  # <key> <file>
  local key=$1 k v
  while IFS=' ' read -r k v; do
    [ "$k" = "$key" ] || continue
    printf '%s\n' "$v"
    return 0
  done < "$2"
  return 1
}

cache_key=${CLAUDE_ACCOUNT:-default}
cache_id=$(printf '%s' "$cache_key" | cksum | cut -d' ' -f1)
cache_file="$STATE/claude-runway-admit.$cache_id.cache"

emit_refuse() {  # <account> <reason>
  echo "fm-claude-runway-admit: refusing Claude gate agent on account $1: $2" >&2
  exit "$REFUSE_EXIT"
}

emit_admit_note() {  # <account> <reason>
  echo "fm-claude-runway-admit: admitting Claude gate agent on account $1: $2" >&2
}

run_cap() {
  local -a args=()
  [ -z "$CLAUDE_ACCOUNT" ] || args+=(--claude-account "$CLAUDE_ACCOUNT")
  [ -z "$QUOTA_JSON" ] || args+=(--quota-json "$QUOTA_JSON")
  FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" FM_STATE_OVERRIDE="$STATE" \
    "$CAP" "${args[@]}" 2>&1
}

field() {  # <output> <name>
  printf '%s\n' "$1" | sed -n "s/^$2: //p" | head -1
}

# A cached decision is valid only while unexpired and for the same account.
if [ "$TTL" -gt 0 ] && [ -f "$cache_file" ]; then
  expires=$(cache_field expires "$cache_file") || expires=
  decision=$(cache_field decision "$cache_file") || decision=
  note=$(cache_field note "$cache_file") || note=
  account=$(cache_field account "$cache_file") || account=
  reason=$(cache_field reason "$cache_file") || reason=
  if [ -n "$expires" ] && [ "$expires" -gt "$(now)" ] 2>/dev/null; then
    case "$decision" in
      refuse)
        [ -z "$account" ] && account=unknown
        emit_refuse "$account" "${reason:-runway cap reached}"
        ;;
      admit)
        if [ "$note" = 1 ]; then
          [ -z "$account" ] && account=unknown
          emit_admit_note "$account" "${reason:-quota reading unavailable}"
        fi
        exit 0
        ;;
    esac
  fi
fi

out=$(run_cap) || rc=$?
rc=${rc:-0}

account=$(field "$out" claude_account)
reading=$(field "$out" claude_reading)
cap=$(field "$out" claude_runway_cap)
reason=$(field "$out" claude_runway_reason)
[ -n "$account" ] || account=${CLAUDE_ACCOUNT:-ordinary}
[ -n "$reason" ] || reason="the runway reading could not be evaluated"

decision=admit
note=0
if [ "$rc" -ne 0 ]; then
  note=1
  reason="the runway reading could not be evaluated (fm-dispatch-quota-cap exit $rc)"
elif [ "$reading" != "available" ]; then
  note=1
else
  case "$cap" in
    0 | 1)
      decision=refuse
      ;;
    none)
      decision=admit
      ;;
    *)
      note=1
      reason="the runway reading could not be evaluated"
      ;;
  esac
fi

if [ "$TTL" -gt 0 ]; then
  if mkdir -p "$STATE" 2>/dev/null; then
    tmp=$(mktemp "$STATE/.claude-runway-admit.XXXXXX" 2>/dev/null) || tmp=
    if [ -n "$tmp" ]; then
      if {
        printf 'expires %s\n' "$(( $(now) + TTL ))"
        printf 'decision %s\n' "$decision"
        printf 'note %s\n' "$note"
        printf 'account %s\n' "$account"
        printf 'reason %s\n' "$reason"
      } > "$tmp"; then
        mv -f "$tmp" "$cache_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
      else
        rm -f "$tmp" 2>/dev/null
      fi
    fi
  fi
fi

if [ "$decision" = refuse ]; then
  emit_refuse "$account" "$reason"
fi
if [ "$note" = 1 ]; then
  emit_admit_note "$account" "$reason"
fi
exit 0
