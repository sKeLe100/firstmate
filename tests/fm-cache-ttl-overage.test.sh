#!/usr/bin/env bash
# tests/fm-cache-ttl-overage.test.sh - the overage episode in
# bin/fm-cache-ttl-lib.sh.
#
# docs/configuration.md "Prompt-cache steer guard" owns the policy: while
# quota-axi reports the current Claude account's window exhausted, the
# effective prompt-cache TTL is capped at 300s, and it returns to the
# configured value (or the 3600s default) when the window recovers. A quota
# read failure never changes the TTL. These tests drive the library the way its
# consumers do:
#   1. A healthy window keeps the default and a configured value.
#   2. An exhausted window caps the TTL at 300s, including the derived
#      near-expiry threshold.
#   3. Recovery restores the configured value (and the absent default).
#   4. A missing, unreadable, invalid, or failing quota read leaves it alone.
#   5. A configured value below 300 stays in force, and a disabled TTL stays
#      disabled.
#   6. The probe measures the account config/claude-account pins.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-cache-ttl-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-cache-ttl-overage)

doc() {  # <percent> <runway-status> -> a schema 5 claude snapshot on stdout
  jq -n --argjson pct "$1" --arg runway "$2" '{
    schemaVersion: 5,
    providers: [{
      provider: "claude",
      state: {status: "fresh"},
      quotaSemantics: {
        status: "known",
        effectiveAvailability: [{
          scope: "all_models",
          status: "known",
          effectivePercentRemaining: $pct,
          runway: {status: $runway}
        }]
      }
    }]
  }'
}

new_config() {  # <name> -> echoes a config dir, optionally with a TTL value
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

read_ttl() {  # <config-dir> [env...] -> echoes the effective TTL
  local config=$1
  shift
  # shellcheck disable=SC2016  # the program reads its own positional parameters
  env "$@" bash -c '. "$0"; fm_cache_ttl_seconds "$1"' "$LIB" "$config"
}

read_near() {  # <config-dir> [env...] -> echoes the near-expiry threshold
  local config=$1
  shift
  # shellcheck disable=SC2016  # the program reads its own positional parameters
  env "$@" bash -c '. "$0"; fm_cache_near_expiry_seconds "$1"' "$LIB" "$config"
}

test_healthy_window_keeps_configured_ttl() {
  local config snap
  config=$(new_config healthy)
  snap="$TMP_ROOT/healthy.json"
  doc 42 through_reset > "$snap"
  [ "$(read_ttl "$config" FM_CACHE_TTL_QUOTA_JSON="$snap")" = 3600 ] \
    || fail "an absent knob and a healthy window must keep the 3600s default"
  printf '1200\n' > "$config/cache-ttl-seconds"
  [ "$(read_ttl "$config" FM_CACHE_TTL_QUOTA_JSON="$snap")" = 1200 ] \
    || fail "a healthy window must keep the configured TTL"
  [ "$(read_near "$config" FM_CACHE_TTL_QUOTA_JSON="$snap")" = 1000 ] \
    || fail "near-expiry must derive from the configured TTL: $(read_near "$config" FM_CACHE_TTL_QUOTA_JSON="$snap")"
  pass "cache TTL overage: a healthy window keeps the configured TTL"
}

test_exhausted_window_caps_at_300() {
  local config snap
  config=$(new_config exhausted)
  snap="$TMP_ROOT/exhausted.json"
  doc 0 exhausted_now > "$snap"
  [ "$(read_ttl "$config" FM_CACHE_TTL_QUOTA_JSON="$snap")" = 300 ] \
    || fail "an exhausted window must cap the default TTL at 300s"
  [ "$(read_near "$config" FM_CACHE_TTL_QUOTA_JSON="$snap")" = 250 ] \
    || fail "near-expiry must derive from the 300s overage TTL"
  printf '1200\n' > "$config/cache-ttl-seconds"
  [ "$(read_ttl "$config" FM_CACHE_TTL_QUOTA_JSON="$snap")" = 300 ] \
    || fail "an exhausted window must cap a configured TTL at 300s"
  pass "cache TTL overage: an exhausted window caps the effective TTL at 300s"
}

test_zero_remaining_counts_as_exhausted() {
  local config snap
  config=$(new_config zero)
  snap="$TMP_ROOT/zero.json"
  doc 0 through_reset > "$snap"
  [ "$(read_ttl "$config" FM_CACHE_TTL_QUOTA_JSON="$snap")" = 300 ] \
    || fail "a known zero remaining window must be an overage episode even when its runway is through_reset"
  pass "cache TTL overage: a known zero remaining window is an overage episode"
}

test_recovery_restores_configured_ttl() {
  local config exhausted healthy
  config=$(new_config recovered)
  printf '1200\n' > "$config/cache-ttl-seconds"
  exhausted="$TMP_ROOT/recovered-exhausted.json"
  healthy="$TMP_ROOT/recovered-healthy.json"
  doc 0 exhausted_now > "$exhausted"
  doc 55 through_reset > "$healthy"
  [ "$(read_ttl "$config" FM_CACHE_TTL_QUOTA_JSON="$exhausted")" = 300 ] \
    || fail "the episode must start at 300s"
  [ "$(read_ttl "$config" FM_CACHE_TTL_QUOTA_JSON="$healthy")" = 1200 ] \
    || fail "a recovered window must restore the configured TTL"
  pass "cache TTL overage: recovery restores the configured TTL"
}

test_quota_read_failure_keeps_ttl() {
  local config invalid empty
  config=$(new_config failures)
  printf '1200\n' > "$config/cache-ttl-seconds"
  invalid="$TMP_ROOT/invalid.json"
  empty="$TMP_ROOT/empty.json"
  printf 'not json\n' > "$invalid"
  : > "$empty"
  [ "$(read_ttl "$config" FM_CACHE_TTL_QUOTA_JSON="$TMP_ROOT/does-not-exist.json")" = 1200 ] \
    || fail "a missing quota document must leave the TTL unchanged"
  [ "$(read_ttl "$config" FM_CACHE_TTL_QUOTA_JSON="$invalid")" = 1200 ] \
    || fail "invalid JSON must leave the TTL unchanged"
  [ "$(read_ttl "$config" FM_CACHE_TTL_QUOTA_JSON="$empty")" = 1200 ] \
    || fail "an empty quota document must leave the TTL unchanged"

  local stale="$TMP_ROOT/stale.json"
  jq -n '{
    schemaVersion: 5,
    providers: [{
      provider: "claude",
      state: {status: "stale", stale: true},
      quotaSemantics: {
        status: "known",
        effectiveAvailability: [{
          scope: "all_models",
          status: "known",
          effectivePercentRemaining: 0,
          runway: {status: "exhausted_now"}
        }]
      }
    }]
  }' > "$stale"
  [ "$(read_ttl "$config" FM_CACHE_TTL_QUOTA_JSON="$stale")" = 1200 ] \
    || fail "a stale quota reading must not start an overage episode"

  local fakebin="$TMP_ROOT/failure-bin"
  mkdir -p "$fakebin"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/quota-axi"
  [ "$(read_ttl "$config" -u FM_CACHE_TTL_QUOTA_JSON PATH="$fakebin:$PATH")" = 1200 ] \
    || fail "a failing quota-axi must leave the TTL unchanged"
  pass "cache TTL overage: a quota read failure leaves the TTL unchanged"
}

test_tighter_and_disabled_config_win() {
  local config snap
  config=$(new_config tighter)
  snap="$TMP_ROOT/tighter.json"
  doc 0 exhausted_now > "$snap"
  printf '60\n' > "$config/cache-ttl-seconds"
  [ "$(read_ttl "$config" FM_CACHE_TTL_QUOTA_JSON="$snap")" = 60 ] \
    || fail "the episode must never loosen a configured value below 300s"
  printf '0\n' > "$config/cache-ttl-seconds"
  [ "$(read_ttl "$config" FM_CACHE_TTL_QUOTA_JSON="$snap")" = 0 ] \
    || fail "a disabled TTL must stay disabled during an episode"
  pass "cache TTL overage: a tighter configured TTL and a disabled TTL win"
}

test_probe_reads_the_pinned_account() {
  local config fakebin pinned
  config=$(new_config pinned)
  pinned="$TMP_ROOT/pinned-root"
  mkdir -p "$pinned"
  printf '%s\n' "$pinned" > "$config/claude-account"
  fakebin="$TMP_ROOT/pinned-bin"
  mkdir -p "$fakebin"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\${CLAUDE_CONFIG_DIR-unset}" "\$*" >> '$TMP_ROOT/pinned-reads'
[ "\${CLAUDE_CONFIG_DIR-}" = '$pinned' ] || { echo 'wrong account' >&2; exit 1; }
case "\$*" in *--profile-only*) ;; *) echo 'missing --profile-only' >&2; exit 1 ;; esac
printf '%s' '$(doc 0 exhausted_now)'
SH
  chmod +x "$fakebin/quota-axi"
  [ "$(read_ttl "$config" -u FM_CACHE_TTL_QUOTA_JSON PATH="$fakebin:$PATH")" = 300 ] \
    || fail "the probe must measure the pinned account and read its exhaustion"
  [ -s "$TMP_ROOT/pinned-reads" ] || fail "the probe must invoke quota-axi"
  assert_contains "$(cat "$TMP_ROOT/pinned-reads")" "$pinned --provider claude --profile-only --json" \
    "the probe must pass the pinned root with --profile-only"
  pass "cache TTL overage: the probe measures the account config/claude-account pins"
}

test_pinned_malformed_keeps_ttl() {
  local config
  config=$(new_config malformed-pin)
  printf '1200\n' > "$config/cache-ttl-seconds"
  printf 'not-a-path\n' > "$config/claude-account"
  [ "$(read_ttl "$config")" = 1200 ] \
    || fail "an unreadable pin must leave the TTL unchanged rather than guess an account"
  pass "cache TTL overage: an unreadable pin leaves the TTL unchanged"
}

test_healthy_window_keeps_configured_ttl
test_exhausted_window_caps_at_300
test_zero_remaining_counts_as_exhausted
test_recovery_restores_configured_ttl
test_quota_read_failure_keeps_ttl
test_tighter_and_disabled_config_win
test_probe_reads_the_pinned_account
test_pinned_malformed_keeps_ttl

echo "# all fm-cache-ttl-overage tests passed"
