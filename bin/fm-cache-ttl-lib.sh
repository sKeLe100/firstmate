#!/usr/bin/env bash
# fm-cache-ttl-lib.sh - the ONE owner of firstmate's prompt-cache TTL knob AND
# of the activity-age fold it is measured against, so the steer guard
# (bin/fm-send.sh), the near-expiry heartbeat flag (bin/fm-fleet-snapshot.sh),
# and the inactivity reconciler (bin/fm-inactive-reconcile.sh) can never drift
# onto two different thresholds or two different definitions of "idle". The
# policy itself is documented once in docs/configuration.md "Prompt-cache
# steer guard".
#
# config/cache-ttl-seconds is optional and local: its first non-empty,
# non-comment line is the TTL in seconds. An absent, unreadable, or
# non-numeric file keeps the 3600s default. A value of 0 or below means the
# guard is DISABLED (steers always allowed), never a refuse-everything state.
#
# Overage episode: an exhausted Claude window silently drops every session to
# a five-minute prompt-cache TTL, so while quota-axi reports the current Claude
# account exhausted (effective remaining 0, or runway exhausted_now) the
# effective TTL is capped at FM_CACHE_TTL_OVERAGE_SECONDS for as long as that
# reading holds. The cap is computed at read time from quota state, never by
# rewriting config/cache-ttl-seconds, so the prior value (or the absent
# default) returns by itself when the window recovers. A quota-axi read that
# fails, times out, or returns invalid JSON leaves the configured TTL
# unchanged. A configured value below the cap stays in force (the episode
# never loosens a tighter local setting), and a disabled TTL (<= 0) stays
# disabled. The account read is the one config/claude-account pins, or the
# process's ambient Claude login when the home pins none; a home with
# config/claude-accounts is out of scope here because it has no single current
# account, so the ambient login answers for the home-wide guard.
#
# FM_CACHE_TTL_QUOTA_JSON names a captured quota-axi --json document instead of
# running quota-axi (the test seam and offline replay). An unreadable or
# invalid file is a read failure, so the TTL stays unchanged.

FM_CACHE_TTL_DEFAULT_SECONDS=3600
FM_CACHE_TTL_OVERAGE_SECONDS=300
FM_CACHE_TTL_QUOTA_TIMEOUT=${FM_CACHE_TTL_QUOTA_TIMEOUT:-10}
FM_CACHE_TTL_QUOTA_MAX_AGE=${FM_CACHE_TTL_QUOTA_MAX_AGE:-60s}

# A configured value keeps its base-10 meaning everywhere: 0600 is 600 seconds
# to the [ -gt ] comparisons AND to the near-expiry arithmetic, which would
# otherwise read a leading zero as octal (or abort outright on 08/09).
fm_cache_strip_leading_zeros() {  # <numeric-string> -> echoes it without leading zeros
  local v=$1 sign=''
  case "$v" in -*) sign=-; v=${v#-} ;; esac
  while [ "${#v}" -gt 1 ] && [ "${v#0}" != "$v" ]; do v=${v#0}; done
  printf '%s%s' "$sign" "$v"
}

fm_cache_configured_ttl_seconds() {  # <config-dir> -> echoes the configured TTL
  local file="$1/cache-ttl-seconds" line val
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      val=$(printf '%s' "$line" | tr -d '[:space:]')
      case "$val" in
        ''|'#'*) continue ;;
        -|*[!0-9-]*|?*-*) break ;;
        *) printf '%s' "$(fm_cache_strip_leading_zeros "$val")"; return 0 ;;
      esac
    done < "$file"
  fi
  printf '%s' "$FM_CACHE_TTL_DEFAULT_SECONDS"
}

# The Claude config root the overage probe measures: the one
# config/claude-account pins, or `ordinary` for the process's ambient login.
# The pin parser is bin/fm-worker-account-lib.sh's single owner; an unreadable
# or malformed pin is not a quota read failure to guess around, so it returns 1
# and the caller keeps the configured TTL.
fm_cache_claude_account_root() {  # <config-dir> -> echoes ordinary or an absolute root
  local config=$1 lib selection declared
  if [ ! -e "$config/claude-account" ]; then
    printf 'ordinary'
    return 0
  fi
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-worker-account-lib.sh"
  # shellcheck source=bin/fm-worker-account-lib.sh
  . "$lib"
  selection=$(fm_worker_account_resolve claude "$config" "config/claude-account" 2>/dev/null) || return 1
  declared=${selection%%$'\t'*}
  case "$declared" in
    ordinary) printf 'ordinary' ;;
    /*) printf '%s' "$declared" ;;
    *) return 1 ;;
  esac
}

# True when the current Claude account reports an exhausted/overage window.
# Reads quota-axi's own --json document with a hard bound and a short reuse
# window, or FM_CACHE_TTL_QUOTA_JSON when that seam is set. Every failure mode -
# no quota-axi, no jq, an unreadable pin, a timeout, a nonzero exit, invalid
# JSON - returns nonzero so the caller keeps the configured TTL.
fm_cache_quota_overage_active() {  # <config-dir> -> 0 when exhausted/overage
  local config=$1 doc root lib
  if [ -n "${FM_CACHE_TTL_QUOTA_JSON:-}" ]; then
    doc=$(cat -- "$FM_CACHE_TTL_QUOTA_JSON" 2>/dev/null) || return 1
  else
    command -v quota-axi >/dev/null 2>&1 || return 1
    command -v jq >/dev/null 2>&1 || return 1
    root=$(fm_cache_claude_account_root "$config") || return 1
    lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$lib"
    if [ "$root" = ordinary ]; then
      doc=$(fm_run_timed "$FM_CACHE_TTL_QUOTA_TIMEOUT" \
        quota-axi --provider claude --json --no-credential-refresh \
        --max-age "$FM_CACHE_TTL_QUOTA_MAX_AGE" 2>/dev/null) || return 1
    else
      doc=$(CLAUDE_CONFIG_DIR="$root" fm_run_timed "$FM_CACHE_TTL_QUOTA_TIMEOUT" \
        quota-axi --provider claude --profile-only --json 2>/dev/null) || return 1
    fi
  fi
  [ -n "$doc" ] || return 1
  printf '%s' "$doc" | jq -e '
    any(.providers[]? | select(.provider == "claude");
      ((.state.status // "fresh") != "stale") and
      ((.state.stale // false) == false) and
      any(.quotaSemantics.effectiveAvailability[]?;
        ((.runway.status // "") == "exhausted_now") or
        ((.status // "") == "known" and ((.effectivePercentRemaining // 1) <= 0))
      )
    )
  ' >/dev/null 2>&1
}

# The effective TTL: the configured value, capped at the overage value while a
# Claude overage episode is reported. Memoized per process so a caller that
# reads both the TTL and the near-expiry threshold runs at most one probe.
_fm_cache_ttl_memo_config=
_fm_cache_ttl_memo_value=
_fm_cache_overage_memo_config=
_fm_cache_overage_memo_rc=

fm_cache_ttl_overage_active() {  # <config-dir> -> 0 active; memoized
  local config=$1 rc=0
  if [ "$config" = "${_fm_cache_overage_memo_config:-}" ]; then
    return "${_fm_cache_overage_memo_rc:-1}"
  fi
  fm_cache_quota_overage_active "$config" || rc=$?
  _fm_cache_overage_memo_config=$config
  _fm_cache_overage_memo_rc=$rc
  return "$rc"
}

fm_cache_ttl_seconds() {  # <config-dir> -> echoes the effective TTL
  local config=$1 ttl
  if [ "$config" = "${_fm_cache_ttl_memo_config:-}" ] && [ -n "${_fm_cache_ttl_memo_value:-}" ]; then
    printf '%s' "$_fm_cache_ttl_memo_value"
    return 0
  fi
  ttl=$(fm_cache_configured_ttl_seconds "$config")
  if [ "$ttl" -gt 0 ] && fm_cache_ttl_overage_active "$config" &&
    [ "$ttl" -gt "$FM_CACHE_TTL_OVERAGE_SECONDS" ]; then
    ttl=$FM_CACHE_TTL_OVERAGE_SECONDS
  fi
  _fm_cache_ttl_memo_config=$config
  _fm_cache_ttl_memo_value=$ttl
  printf '%s' "$ttl"
}

# Near-expiry lead: flag a session once it has burned ~83% of the TTL, so the
# heartbeat can catch it before the cache lapses. Derived from the same
# effective TTL rather than a second literal. A disabled (<= 0) TTL has no
# near-expiry window, so this echoes 0 and callers flag nothing.
fm_cache_near_expiry_seconds() {  # <config-dir> -> echoes the near-expiry threshold
  local ttl
  ttl=$(fm_cache_ttl_seconds "$1")
  if [ "$ttl" -le 0 ]; then
    printf '0'
    return 0
  fi
  printf '%s' $(( ttl * 5 / 6 ))
}

# Activity age: a task is idle for as long as its NEWEST activity marker -
# state/<id>.meta, state/<id>.status, state/<id>.turn-ended - has gone
# untouched. turn-ended alone only moves when a turn ENDS, so folding it with
# the other two is what keeps a worker mid-turn from reading as idle for the
# whole length of that turn. All three markers are already written for every
# backend, so this costs no new probe or daemon. A future mtime (clock skew,
# a restored file) clamps to 0 rather than becoming a negative age; no
# readable marker at all is UNKNOWN, signalled by a non-zero return so each
# caller can choose its own safe default.
if [ "$(uname)" = Darwin ]; then
  fm_cache_marker_mtime() { stat -f %m "$1" 2>/dev/null || return 1; }
else
  fm_cache_marker_mtime() { stat -c %Y "$1" 2>/dev/null || return 1; }
fi

fm_cache_activity_age_seconds() {  # <state-dir> <id> [now-epoch] -> echoes age; nonzero rc = unknown
  local state=$1 id=$2 now=${3-} marker mtime newest=0
  for marker in "$state/$id.meta" "$state/$id.status" "$state/$id.turn-ended"; do
    [ -e "$marker" ] || continue
    mtime=$(fm_cache_marker_mtime "$marker") || continue
    case "$mtime" in ''|*[!0-9]*) continue ;; esac
    [ "$mtime" -le "$newest" ] || newest=$mtime
  done
  [ "$newest" -gt 0 ] || return 1
  case "$now" in ''|*[!0-9]*) now=$(date +%s) ;; esac
  if [ "$now" -le "$newest" ]; then
    printf '0'
  else
    printf '%s' $(( now - newest ))
  fi
}
