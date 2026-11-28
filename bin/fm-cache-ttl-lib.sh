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
# account exhausted (effective remaining 0, or runway exhausted_now) for
# all_models, all_products, or the target's own model/product scope, a Claude target's
# effective TTL is capped at FM_CACHE_TTL_OVERAGE_SECONDS for as long as that
# reading holds. Non-Claude targets keep the configured TTL, and callers probe
# only where the cap can change their outcome. The cap is computed at read time from quota state, never by
# rewriting config/cache-ttl-seconds, so the prior value (or the absent
# default) returns by itself when the window recovers. A quota-axi read that
# fails, times out, or returns invalid JSON leaves the configured TTL
# unchanged. A configured value below the cap stays in force (the episode
# never loosens a tighter local setting), and a disabled TTL (<= 0) stays
# disabled. The account read is the target's recorded account=, else a
# secondmate's own pin, else the one config/claude-account pins, else the
# process's ambient Claude login.

FM_CACHE_TTL_DEFAULT_SECONDS=3600
FM_CACHE_TTL_OVERAGE_SECONDS=300
FM_CACHE_TTL_QUOTA_TIMEOUT=10
FM_CACHE_TTL_QUOTA_MAX_AGE=60s

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

# The Claude account the overage probe measures: the target's recorded account,
# else the `ordinary` or absolute root its secondmate or home pin names, else
# `ambient`. The pin parser is bin/fm-worker-account-lib.sh's single owner; an
# unreadable or malformed account is not a quota read failure to guess around,
# so it returns 1 and the caller keeps the configured TTL.
fm_cache_claude_account_root() {  # <config-dir> <recorded-account> <secondmate-id> -> echoes ambient, ordinary, or an absolute root
  local config=$1 declared=$2 mate=$3 selection
  case "$declared" in
    '') ;;
    ordinary|/*) printf '%s' "$declared"; return 0 ;;
    *) return 1 ;;
  esac
  config=$(fm_worker_account_config claude "$config" "$mate") || return 1
  if [ ! -e "$config/claude-account" ]; then
    printf 'ambient'
    return 0
  fi
  selection=$(fm_worker_account_resolve claude "$config" "config/claude-account" 2>/dev/null) || return 1
  declared=${selection%%$'\t'*}
  case "$declared" in
    ordinary|/*) printf '%s' "$declared" ;;
    *) return 1 ;;
  esac
}

# True when the target's Claude account reports an exhausted window that bounds
# <model>. Every failure mode - no quota-axi, no jq, an unreadable pin, a
# timeout, a nonzero exit, invalid JSON - returns nonzero so the caller keeps
# the configured TTL. The 60s reuse window applies only to the ambient and
# `ordinary` reads; --profile-only has no cache.
fm_cache_quota_overage_active() {  # <config-dir> <model> <recorded-account> <secondmate-id> -> 0 when exhausted
  local config=$1 model=${2##*/} account=$3 mate=$4 doc root dir name
  local -a scrub read_args
  command -v quota-axi >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=bin/fm-worker-account-lib.sh
  . "$dir/fm-worker-account-lib.sh"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$dir/fm-timeout-lib.sh"
  root=$(fm_cache_claude_account_root "$config" "$account" "$mate") || return 1
  scrub=(-u QUOTA_AXI_SNAPSHOT -u QUOTA_AXI_CLAUDE_PROFILES -u QUOTA_AXI_CLAUDE_SWAP)
  read_args=(--no-credential-refresh --max-age "$FM_CACHE_TTL_QUOTA_MAX_AGE")
  if [ "$root" != ambient ]; then
    for name in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do
      scrub+=(-u "$name")
    done
    if [ "$root" = ordinary ]; then
      scrub+=(-u CLAUDE_CONFIG_DIR)
    else
      scrub+=("CLAUDE_CONFIG_DIR=$root")
      read_args=(--profile-only)
    fi
  fi
  doc=$(fm_run_timed "$FM_CACHE_TTL_QUOTA_TIMEOUT" env "${scrub[@]}" \
    quota-axi --provider claude --json "${read_args[@]}" 2>/dev/null </dev/null) || return 1
  [ -n "$doc" ] || return 1
  printf '%s' "$doc" | jq -e --arg model "$model" '
    ($model | ascii_downcase) as $lane |
    def binds_model:
      startswith("model:") and
        ((ltrimstr("model:") | ascii_downcase) as $token |
          $token == $lane or
            (($token | IN("opus", "sonnet", "haiku", "fable")) and
              any($lane | splits("[^a-z0-9]+"); . == $token)));
    any(.providers[]? | select(.provider == "claude");
      ((.state.status // "fresh") != "stale") and
      ((.state.stale // false) == false) and
      any(.quotaSemantics.effectiveAvailability[]?;
        (.scope == "all_models" or .scope == "all_products" or
          ($model != "" and $model != "default" and
            (.scope == ("product:" + $model) or (.scope | binds_model)))) and
        (((.runway.status // "") == "exhausted_now") or
          ((.status // "") == "known" and ((.effectivePercentRemaining // 1) <= 0)))
      )
    )
  ' >/dev/null 2>&1
}

# The effective TTL for one target: the configured value, capped at the overage
# value while a Claude target's account reports an exhausted window.
fm_cache_ttl_seconds() {  # <config-dir> <harness> <model> [recorded-account] [secondmate-id] -> echoes the effective TTL
  local config=$1 harness=$2 model=$3 account=${4-} mate=${5-} ttl
  ttl=$(fm_cache_configured_ttl_seconds "$config")
  case "$harness" in
    claude*)
      if [ "$ttl" -gt "$FM_CACHE_TTL_OVERAGE_SECONDS" ] &&
        fm_cache_quota_overage_active "$config" "$model" "$account" "$mate"; then
        ttl=$FM_CACHE_TTL_OVERAGE_SECONDS
      fi
      ;;
  esac
  printf '%s' "$ttl"
}

# The TTL to judge an idle age against: quota is probed only when the age is
# past the overage cap but still within the configured TTL, the one range where
# the cap changes whether the session reads as cold.
fm_cache_ttl_for_idle() {  # <config-dir> <idle-secs> <harness> <model> [recorded-account] [secondmate-id] -> echoes the TTL
  local config=$1 idle=$2 ttl
  ttl=$(fm_cache_configured_ttl_seconds "$config")
  if [ "$idle" -gt "$FM_CACHE_TTL_OVERAGE_SECONDS" ] && [ "$idle" -le "$ttl" ]; then
    ttl=$(fm_cache_ttl_seconds "$config" "$3" "$4" "${5-}" "${6-}")
  fi
  printf '%s' "$ttl"
}

# Near-expiry lead: flag a session once it has burned ~83% of the TTL, so the
# heartbeat can catch it before the cache lapses. Derived from the TTL the
# caller already read rather than a second literal or read. A disabled (<= 0)
# TTL has no near-expiry window, so this echoes 0 and callers flag nothing.
fm_cache_near_expiry_seconds() {  # <ttl-seconds> -> echoes the near-expiry threshold
  local ttl=$1
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
