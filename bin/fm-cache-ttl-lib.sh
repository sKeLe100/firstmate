#!/usr/bin/env bash
# fm-cache-ttl-lib.sh - the ONE owner of firstmate's prompt-cache TTL knob, so
# the steer guard (bin/fm-send.sh) and the near-expiry heartbeat flag
# (bin/fm-fleet-snapshot.sh) can never drift onto two different thresholds.
# The policy itself is documented once in docs/configuration.md
# "Prompt-cache steer guard".
#
# config/cache-ttl-seconds is optional and local: its first non-empty line is
# the TTL in seconds. An absent, unreadable, or non-numeric file keeps the
# 3600s default. A value of 0 or below means the guard is DISABLED (steers
# always allowed), never a refuse-everything state.

FM_CACHE_TTL_DEFAULT_SECONDS=3600

fm_cache_ttl_seconds() {  # <config-dir> -> echoes the effective TTL
  local file="$1/cache-ttl-seconds" val
  if [ -f "$file" ]; then
    val=$(head -n1 "$file" 2>/dev/null | tr -d '[:space:]')
    case "$val" in
      ''|-|*[!0-9-]*|?*-*) ;;
      *) printf '%s' "$val"; return 0 ;;
    esac
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
