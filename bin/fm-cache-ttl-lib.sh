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

FM_CACHE_TTL_DEFAULT_SECONDS=3600

fm_cache_ttl_seconds() {  # <config-dir> -> echoes the effective TTL
  local file="$1/cache-ttl-seconds" line val
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      val=$(printf '%s' "$line" | tr -d '[:space:]')
      case "$val" in
        ''|'#'*) continue ;;
        -|*[!0-9-]*|?*-*) break ;;
        *) printf '%s' "$val"; return 0 ;;
      esac
    done < "$file"
  fi
  printf '%s' "$FM_CACHE_TTL_DEFAULT_SECONDS"
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
fm_cache_marker_mtime() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null || return 1
  else
    stat -c %Y "$1" 2>/dev/null || return 1
  fi
}

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
