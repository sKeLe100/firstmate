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
#   6. The probe measures the target's recorded account, else its secondmate or
#      home pin, else the ambient login, and ignores ambient quota-axi lane
#      overrides.
#   7. Only a Claude target is capped, and only by an applicable scope.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-cache-ttl-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-cache-ttl-overage)

doc() {  # <percent> <runway-status> [scope] -> a schema 5 claude snapshot on stdout
  jq -n --argjson pct "$1" --arg runway "$2" --arg scope "${3:-all_models}" '{
    schemaVersion: 5,
    providers: [{
      provider: "claude",
      state: {status: "fresh"},
      quotaSemantics: {
        status: "known",
        effectiveAvailability: [{
          scope: $scope,
          status: "known",
          effectivePercentRemaining: $pct,
          runway: {status: $runway}
        }]
      }
    }]
  }'
}

new_config() {  # <name> -> echoes a config dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s%s%s|%s\n' "${CLAUDE_CONFIG_DIR-unset}" "${CLAUDE_CODE_OAUTH_TOKEN-unset}" \
  "${QUOTA_AXI_SNAPSHOT-}" "${QUOTA_AXI_CLAUDE_PROFILES-}" "${QUOTA_AXI_CLAUDE_SWAP-}" "$*" >> "$FAKE_READS"
[ -n "${FAKE_DOC-}" ] || exit 1
if [ -f "${CLAUDE_CONFIG_DIR-}/quota.json" ]; then FAKE_DOC=$CLAUDE_CONFIG_DIR/quota.json; fi
cat -- "$FAKE_DOC"
SH
chmod +x "$FAKEBIN/quota-axi"
export FAKE_READS="$TMP_ROOT/reads"
export PATH="$FAKEBIN:$PATH"

read_ttl() {  # <config-dir> <snapshot> [harness] [model] -> echoes the effective TTL
  : > "$FAKE_READS"
  # shellcheck disable=SC2016  # the program reads its own positional parameters
  FAKE_DOC=$2 bash -c '. "$0"; fm_cache_ttl_seconds "$1" "$2" "$3" "$4" "$5"' \
    "$LIB" "$1" "${3:-claude}" "${4:-default}" "${5-}" "${6-}"
}

snapshot() {  # <name> <percent> <runway-status> [scope] -> echoes a snapshot path
  doc "$2" "$3" "${4:-all_models}" > "$TMP_ROOT/$1.json"
  printf '%s' "$TMP_ROOT/$1.json"
}

test_window_state_drives_the_cap_and_recovery() {
  local config healthy exhausted zero
  config=$(new_config episode)
  healthy=$(snapshot healthy 42 through_reset)
  exhausted=$(snapshot exhausted 0 exhausted_now)
  zero=$(snapshot zero 0 through_reset)
  [ "$(read_ttl "$config" "$healthy")" = 3600 ] || fail "a healthy window must keep the default"
  [ "$(read_ttl "$config" "$exhausted")" = 300 ] || fail "an exhausted window must cap the default"
  printf '1200\n' > "$config/cache-ttl-seconds"
  [ "$(read_ttl "$config" "$zero")" = 300 ] || fail "a known zero remaining must cap a configured TTL"
  [ "$(read_ttl "$config" "$healthy")" = 1200 ] || fail "recovery must restore the configured TTL"
  pass "cache TTL overage: the cap follows the window and recovery restores the TTL"
}

test_quota_read_failure_keeps_ttl() {
  local config invalid empty stale
  config=$(new_config failures)
  printf '1200\n' > "$config/cache-ttl-seconds"
  invalid="$TMP_ROOT/invalid.json"
  empty="$TMP_ROOT/empty.json"
  stale="$TMP_ROOT/stale.json"
  printf 'not json\n' > "$invalid"
  : > "$empty"
  doc 0 exhausted_now | jq '.providers[0].state = {status: "stale", stale: true}' > "$stale"
  [ "$(read_ttl "$config" '')" = 1200 ] || fail "a failing quota-axi must leave the TTL unchanged"
  [ "$(read_ttl "$config" "$invalid")" = 1200 ] || fail "invalid JSON must leave the TTL unchanged"
  [ "$(read_ttl "$config" "$empty")" = 1200 ] || fail "an empty document must leave the TTL unchanged"
  [ "$(read_ttl "$config" "$stale")" = 1200 ] || fail "a stale reading must not start an episode"
  pass "cache TTL overage: a quota read failure leaves the TTL unchanged"
}

test_only_affected_targets_are_capped() {
  local config all scoped products
  config=$(new_config affected)
  all=$(snapshot affected-all 0 exhausted_now)
  scoped=$(snapshot affected-model 0 exhausted_now model:opus)
  products=$(snapshot affected-products 0 exhausted_now all_products)
  [ "$(read_ttl "$config" "$products" claude sonnet)" = 300 ] ||
    fail "an account-wide all_products window must cap"
  [ "$(read_ttl "$config" "$all" codex)" = 3600 ] || fail "a non-Claude target must keep its TTL"
  [ ! -s "$FAKE_READS" ] || fail "a non-Claude target must not read quota"
  [ "$(read_ttl "$config" "$scoped" claude sonnet)" = 3600 ] || fail "another model's window must not cap"
  [ "$(read_ttl "$config" "$scoped" claude opus)" = 300 ] || fail "the target's own model window must cap"
  [ "$(read_ttl "$config" "$scoped" claude claude-opus-5-5)" = 300 ] ||
    fail "a family window must cap a full model id"
  [ "$(read_ttl "$config" "$scoped" claude 'opus[1m]')" = 300 ] ||
    fail "a family window must cap a suffixed alias"
  pass "cache TTL overage: only affected Claude targets are capped"
}

test_tighter_and_disabled_config_skip_the_probe() {
  local config exhausted value
  config=$(new_config tighter)
  exhausted=$(snapshot tighter 0 exhausted_now)
  for value in 60 300 0; do
    printf '%s\n' "$value" > "$config/cache-ttl-seconds"
    [ "$(read_ttl "$config" "$exhausted")" = "$value" ] || fail "TTL $value must stay in force"
    [ ! -s "$FAKE_READS" ] || fail "TTL $value cannot change, so quota must not be read"
  done
  pass "cache TTL overage: a tighter or disabled TTL never probes"
}

test_probe_reads_the_selected_account() {
  local config exhausted pinned
  exhausted=$(snapshot account 0 exhausted_now)
  pinned="$TMP_ROOT/pinned-root"
  mkdir -p "$pinned"
  export CLAUDE_CONFIG_DIR="$TMP_ROOT/supervisor" CLAUDE_CODE_OAUTH_TOKEN=supervisor-token
  export QUOTA_AXI_SNAPSHOT=x QUOTA_AXI_CLAUDE_PROFILES=y QUOTA_AXI_CLAUDE_SWAP=1

  config=$(new_config unpinned)
  [ "$(read_ttl "$config" "$exhausted")" = 300 ] || fail "the unpinned read must see exhaustion"
  assert_contains "$(cat "$FAKE_READS")" "$TMP_ROOT/supervisor|supervisor-token||--provider claude" \
    "no pin must read the ambient login without lane overrides"

  config=$(new_config accounts-list)
  printf 'ordinary\n' > "$config/claude-accounts"
  [ "$(read_ttl "$config" "$exhausted")" = 300 ] || fail "an account list must use the ambient login"
  assert_contains "$(cat "$FAKE_READS")" "$TMP_ROOT/supervisor|" "an account list reads the ambient login"

  config=$(new_config pinned-ordinary)
  printf 'ordinary\n' > "$config/claude-account"
  [ "$(read_ttl "$config" "$exhausted")" = 300 ] || fail "the ordinary pin must see exhaustion"
  assert_contains "$(cat "$FAKE_READS")" "unset|unset||--provider claude" \
    "an ordinary pin must read with CLAUDE_CONFIG_DIR unset"

  config=$(new_config pinned-path)
  printf '%s\n' "$pinned" > "$config/claude-account"
  [ "$(read_ttl "$config" "$exhausted")" = 300 ] || fail "the pinned root must see exhaustion"
  assert_contains "$(cat "$FAKE_READS")" "$pinned|unset||--provider claude --json --profile-only" \
    "a path pin must read that root with --profile-only"

  config=$(new_config malformed-pin)
  printf 'not-a-path\n' > "$config/claude-account"
  [ "$(read_ttl "$config" "$exhausted")" = 3600 ] || fail "a malformed pin must keep the TTL"
  [ ! -s "$FAKE_READS" ] || fail "a malformed pin must not fall back to another account"

  unset CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN
  unset QUOTA_AXI_SNAPSHOT QUOTA_AXI_CLAUDE_PROFILES QUOTA_AXI_CLAUDE_SWAP
  pass "cache TTL overage: the probe measures the selected account"
}

test_target_account_wins_over_home_pin() {
  local config healthy home_root target_root
  config=$(new_config target-account)
  healthy=$(snapshot target-healthy 42 through_reset)
  home_root="$TMP_ROOT/home-account"
  target_root="$TMP_ROOT/target-account-root"
  mkdir -p "$home_root" "$target_root" "$config/secondmate-accounts/ios"
  printf '%s\n' "$home_root" > "$config/claude-account"
  printf '%s\n' "$target_root" > "$config/secondmate-accounts/ios/claude-account"

  doc 0 exhausted_now > "$home_root/quota.json"
  [ "$(read_ttl "$config" "$healthy" claude default "$target_root")" = 3600 ] ||
    fail "an exhausted home account must not cap a target on a healthy account"
  [ "$(read_ttl "$config" "$healthy" claude default '' ios)" = 3600 ] ||
    fail "an exhausted home account must not cap a separately pinned secondmate"
  [ "$(read_ttl "$config" "$healthy" claude default '' other)" = 300 ] ||
    fail "a secondmate without its own pin must follow the home pin"

  rm "$home_root/quota.json"
  doc 0 exhausted_now > "$target_root/quota.json"
  [ "$(read_ttl "$config" "$healthy" claude default "$target_root")" = 300 ] ||
    fail "the target's recorded account must cap it"
  [ "$(read_ttl "$config" "$healthy" claude default '' ios)" = 300 ] ||
    fail "a secondmate's own pin must cap it"
  [ "$(read_ttl "$config" "$healthy" claude default "$home_root" ios)" = 3600 ] ||
    fail "a recorded account must win over the secondmate pin"
  pass "cache TTL overage: the target's account is measured, not the home's"
}

test_idle_age_gates_the_probe() {
  local config exhausted idle want
  config=$(new_config idle)
  exhausted=$(snapshot idle 0 exhausted_now)
  for idle in 300 3601; do
    : > "$FAKE_READS"
    # shellcheck disable=SC2016  # the program reads its own positional parameters
    want=$(FAKE_DOC=$exhausted bash -c '. "$0"; fm_cache_ttl_for_idle "$1" "$2" claude default' "$LIB" "$config" "$idle")
    [ "$want" = 3600 ] && [ ! -s "$FAKE_READS" ] || fail "idle $idle cannot change outcome, so no probe"
  done
  # shellcheck disable=SC2016  # the program reads its own positional parameters
  want=$(FAKE_DOC=$exhausted bash -c '. "$0"; fm_cache_ttl_for_idle "$1" 301 claude default' "$LIB" "$config")
  [ "$want" = 300 ] || fail "idle just past 300s must be judged against the cap"
  pass "cache TTL overage: quota is probed only when idle age makes it matter"
}

test_window_state_drives_the_cap_and_recovery
test_quota_read_failure_keeps_ttl
test_only_affected_targets_are_capped
test_tighter_and_disabled_config_skip_the_probe
test_probe_reads_the_selected_account
test_target_account_wins_over_home_pin
test_idle_age_gates_the_probe

echo "# all fm-cache-ttl-overage tests passed"
