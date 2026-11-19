#!/usr/bin/env bash
# Behavioral coverage for the GitHub Actions artifact-storage warning check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-actions-storage-check)
CHECK="$ROOT/bin/fm-actions-storage-check.sh"
# 2026-11-20T03:00:00Z, so the latest fully settled UTC day (the day before
# yesterday) is 2026-11-18.
T0=1795143600
T1=$((T0 + 89000))

make_fake_gh() {  # <dir>
  local fb=$1
  mkdir -p "$fb"
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "${GH_CALL_LOG:-/dev/null}"
if [ "${1:-}" = api ] && [ "${2:-}" = /user ]; then
  [ "${FAKE_LOGIN_FAIL:-0}" = 1 ] && exit 1
  printf 'octocat\n'
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2%%\?*}" = /users/octocat/settings/billing/usage ]; then
  if [ "${FAKE_SCOPE_MISSING:-0}" = 1 ]; then
    printf '{"message":"Not Found","status":"404"}\n'
    printf 'gh: This API operation needs the "user" scope. To request it, run:  gh auth refresh -h github.com -s user\n' >&2
    exit 1
  fi
  if [ "${FAKE_BILLING_FAIL:-0}" = 1 ]; then
    printf 'gh: Server Error (HTTP 500)\n' >&2
    exit 1
  fi
  cat "${FAKE_USAGE_JSON:?}"
  exit 0
fi
exit 1
SH
  chmod +x "$fb/gh"
}

make_world() {  # <name>
  local name=$1 home fb
  home="$TMP_ROOT/$name/home"
  fb="$TMP_ROOT/$name/bin"
  mkdir -p "$home/config" "$home/data" "$home/state"
  make_fake_gh "$fb"
  printf '%s|%s\n' "$home" "$fb"
}

# A documented-shape enhanced billing usage response: usageItems rows of
# date/product/sku/quantity/unitType. Storage is reported in gigabyte-hours, so
# one day's average gigabytes is quantity / 24.
usage_json() {  # <file> <storage-gb> [date]
  local file=$1 gb=$2 date=${3:-2026-11-18}
  awk -v gb="$gb" -v d="$date" 'BEGIN {
    printf "{\"usageItems\":[{\"date\":\"%s\",\"product\":\"actions\",\"sku\":\"actions_storage\",\"quantity\":%.9f,\"unitType\":\"gigabyte-hours\",\"pricePerUnit\":0.000336,\"grossAmount\":0.001,\"discountAmount\":0.001,\"netAmount\":0,\"repositoryName\":\"sKeLe100/firstmate\"}]}\n", d, gb * 24
  }' > "$file"
}

run_check() {  # <home> <fakebin> <now> [extra-env...]
  local home=$1 fb=$2 now=$3 status=0 out
  shift 3
  out=$(env "$@" PATH="$fb:$PATH" FM_HOME="$home" FM_ACTIONS_STORAGE_NOW="$now" "$CHECK" check 2>&1) || status=$?
  printf '%s\t%s\n' "$status" "$out"
}

output_part() { printf '%s' "$1" | cut -f2-; }
status_part() { printf '%s' "$1" | cut -f1; }

test_under_threshold_is_silent_and_records_usage() {
  local rec home fb usage result out
  rec=$(make_world under); home=${rec%%|*}; fb=${rec#*|}
  usage="$TMP_ROOT/under-usage.json"; usage_json "$usage" 0.2
  result=$(run_check "$home" "$fb" "$T0" FAKE_USAGE_JSON="$usage")
  [ "$(status_part "$result")" = 0 ] || fail "under-threshold check failed: $(output_part "$result")"
  out=$(output_part "$result")
  [ -z "$out" ] || fail "storage under the threshold must stay silent: $out"
  assert_grep $'last_eval\t'"$T0" "$home/state/.actions-storage-check" "the evaluation time was not recorded"
  assert_grep $'storage_gb\t0.2' "$home/state/.actions-storage-check" "the reported storage was not recorded"
  assert_grep $'percent\t41.0' "$home/state/.actions-storage-check" "the computed percentage was not recorded"
  pass "storage under the threshold stays silent and records its usage"
}

test_over_threshold_reports_the_completed_day() {
  local rec home fb usage result out
  rec=$(make_world over); home=${rec%%|*}; fb=${rec#*|}
  usage="$TMP_ROOT/over-usage.json"; usage_json "$usage" 0.4125
  result=$(run_check "$home" "$fb" "$T0" FAKE_USAGE_JSON="$usage")
  [ "$(status_part "$result")" = 0 ] || fail "over-threshold check failed: $(output_part "$result")"
  out=$(output_part "$result")
  assert_contains "$out" 'actions-storage: 422.4 MB of 500 MB used (84.5%)' "the over-threshold storage warning was not reported"
  assert_contains "$out" 'as of 2026-11-18' "the warning did not date the measurement"
  assert_contains "$out" 'uploads block at 100%' "the warning did not explain the consequence"
  pass "an over-threshold warning reports the latest fully settled day"
}

# GitHub reports storage hourly in gigabyte-hours, so the current UTC day is a
# partial sum, and the report is ingested with a lag of hours, so yesterday can
# be partial too; the request must name the day before yesterday in UTC,
# including across a year boundary.
test_request_names_the_settled_day_in_utc() {
  local rec home fb usage result out log
  rec=$(make_world settled); home=${rec%%|*}; fb=${rec#*|}
  usage="$TMP_ROOT/settled-usage.json"; usage_json "$usage" 0.4125
  log="$TMP_ROOT/settled-calls.log"; : > "$log"
  result=$(run_check "$home" "$fb" "$T0" FAKE_USAGE_JSON="$usage" GH_CALL_LOG="$log")
  assert_grep 'gh api /users/octocat/settings/billing/usage?year=2026&month=11&day=18' "$log" \
    "the billing request did not name the day before yesterday in UTC"
  if grep -Eq 'day=(19|20)$' "$log"; then
    fail "the billing request read the current or the previous UTC day: $(cat "$log")"
  fi
  : > "$log"
  rec=$(make_world newyear); home=${rec%%|*}; fb=${rec#*|}
  usage_json "$usage" 0.4125 2026-12-31
  # 2027-01-02T03:00:00Z
  result=$(run_check "$home" "$fb" 1798858800 FAKE_USAGE_JSON="$usage" GH_CALL_LOG="$log")
  out=$(output_part "$result")
  assert_grep 'gh api /users/octocat/settings/billing/usage?year=2026&month=12&day=31' "$log" \
    "the billing request did not roll back across the year boundary"
  assert_contains "$out" '(84.5%) as of 2026-12-31' "the warning did not fire for the settled day"
  pass "the billing request names the latest fully settled UTC day"
}

test_unchanged_finding_is_deduped() {
  local rec home fb usage result out
  rec=$(make_world dedupe); home=${rec%%|*}; fb=${rec#*|}
  usage="$TMP_ROOT/dedupe-usage.json"; usage_json "$usage" 0.2
  result=$(run_check "$home" "$fb" "$T0" FAKE_USAGE_JSON="$usage" FAKE_SCOPE_MISSING=1)
  assert_contains "$(output_part "$result")" 'needs the "user" scope' "the first finding was not reported"
  result=$(run_check "$home" "$fb" "$T1" FAKE_USAGE_JSON="$usage" FAKE_SCOPE_MISSING=1)
  out=$(output_part "$result")
  [ -z "$out" ] || fail "an unchanged finding was repeated on the next daily evaluation: $out"
  pass "an unchanged finding is reported once and deduped"
}

test_storage_row_with_unknown_unit_is_unusable() {
  local rec home fb usage result out
  rec=$(make_world badunit); home=${rec%%|*}; fb=${rec#*|}
  usage="$TMP_ROOT/badunit-usage.json"
  printf '{"usageItems":[{"date":"2026-11-18","product":"actions","sku":"actions_storage","quantity":9.9,"unitType":"gigabytes"}]}\n' > "$usage"
  result=$(run_check "$home" "$fb" "$T0" FAKE_USAGE_JSON="$usage")
  out=$(output_part "$result")
  assert_contains "$out" 'the GitHub billing response was not usable JSON' \
    "a storage row with an unrecognized unit was not reported as unusable"
  pass "a storage row with an unrecognized unit is reported rather than read as zero"
}

test_changed_usage_reports_again() {
  local rec home fb usage result out
  rec=$(make_world changed); home=${rec%%|*}; fb=${rec#*|}
  usage="$TMP_ROOT/changed-1.json"; usage_json "$usage" 0.4125
  run_check "$home" "$fb" "$T0" FAKE_USAGE_JSON="$usage" >/dev/null
  usage="$TMP_ROOT/changed-2.json"; usage_json "$usage" 0.461 2026-11-19
  result=$(run_check "$home" "$fb" "$T1" FAKE_USAGE_JSON="$usage")
  out=$(output_part "$result")
  assert_contains "$out" '472.1 MB of 500 MB used (94.4%)' "a changed warning was not reported again"
  pass "storage growth past a new value reports again instead of staying silent"
}

# The documented enhanced billing response shape is read as shipped: rows are
# filtered by storage SKU, the gigabyte-hours unit is accepted in both the API
# and CSV-export spellings, and Actions plus Packages storage join one pool.
test_documented_response_fixture_is_read() {
  local rec home fb fixture result out
  rec=$(make_world fixture); home=${rec%%|*}; fb=${rec#*|}
  fixture="$ROOT/tests/fixtures/gh-user-billing-usage/gh-user-billing-usage.json"
  result=$(run_check "$home" "$fb" "$T0" FAKE_USAGE_JSON="$fixture")
  [ "$(status_part "$result")" = 0 ] || fail "fixture check failed: $(output_part "$result")"
  out=$(output_part "$result")
  assert_contains "$out" 'actions-storage: 422.4 MB of 500 MB used (84.5%) as of 2026-11-18; uploads block at 100%' \
    "the documented response shape was not read as expected"
  assert_grep $'as_of\t2026-11-18' "$home/state/.actions-storage-check" "the measured date was not recorded"
  assert_grep $'percent\t84.5' "$home/state/.actions-storage-check" "the computed percentage was not recorded"
  pass "the documented enhanced billing response fixture is read correctly"
}

test_no_storage_rows_means_zero_without_a_warning() {
  local rec home fb usage result out
  rec=$(make_world empty); home=${rec%%|*}; fb=${rec#*|}
  usage="$TMP_ROOT/empty-usage.json"; printf '{"usageItems":[]}\n' > "$usage"
  result=$(run_check "$home" "$fb" "$T0" FAKE_USAGE_JSON="$usage")
  [ "$(status_part "$result")" = 0 ] || fail "empty-usage check failed: $(output_part "$result")"
  out=$(output_part "$result")
  [ -z "$out" ] || fail "no storage usage must stay silent: $out"
  [ "$(awk -F '\t' '$1 == "storage_gb" { print $2 }' "$home/state/.actions-storage-check")" = 0 ] \
    || fail "no storage rows were not recorded as zero"
  pass "an empty usage report means zero storage and stays silent"
}

test_non_numeric_quantity_is_unusable() {
  local rec home fb usage result out
  rec=$(make_world badqty); home=${rec%%|*}; fb=${rec#*|}
  usage="$TMP_ROOT/badqty-usage.json"
  printf '{"usageItems":[{"date":"2026-11-18","product":"actions","sku":"actions_storage","quantity":"a lot","unitType":"gigabyte-hours"}]}\n' > "$usage"
  result=$(run_check "$home" "$fb" "$T0" FAKE_USAGE_JSON="$usage")
  out=$(output_part "$result")
  assert_contains "$out" 'the GitHub billing response was not usable JSON' \
    "a non-numeric storage quantity was not reported as unusable"
  pass "a non-numeric storage quantity is reported rather than read as zero"
}

test_storage_row_from_another_day_is_unusable() {
  local rec home fb usage result out
  rec=$(make_world otherday); home=${rec%%|*}; fb=${rec#*|}
  usage="$TMP_ROOT/otherday-usage.json"
  printf '{"usageItems":[{"date":"2026-11-18","product":"actions","sku":"actions_storage","quantity":3.6,"unitType":"gigabyte-hours"},{"date":"2026-11-17","product":"actions","sku":"actions_storage","quantity":3.6,"unitType":"gigabyte-hours"}]}\n' > "$usage"
  result=$(run_check "$home" "$fb" "$T0" FAKE_USAGE_JSON="$usage")
  out=$(output_part "$result")
  assert_contains "$out" 'the GitHub billing response was not usable JSON' \
    "a storage row outside the requested day was summed instead of reported as unusable"
  [ -z "$(awk -F '\t' '$1 == "storage_gb" { print $2 }' "$home/state/.actions-storage-check")" ] \
    || fail "a response spanning other days was recorded as a storage figure"
  pass "a storage row outside the requested day is reported rather than summed"
}

test_daily_gate_skips_the_probe() {
  local rec home fb usage result out log
  rec=$(make_world gate); home=${rec%%|*}; fb=${rec#*|}
  usage="$TMP_ROOT/gate-usage.json"; usage_json "$usage" 0.2
  log="$TMP_ROOT/gate-calls.log"; : > "$log"
  run_check "$home" "$fb" "$T0" FAKE_USAGE_JSON="$usage" GH_CALL_LOG="$log" >/dev/null
  : > "$log"
  result=$(run_check "$home" "$fb" "$((T0 + 1000))" FAKE_USAGE_JSON="$usage" GH_CALL_LOG="$log")
  out=$(output_part "$result")
  [ -z "$out" ] || fail "a poll inside the daily interval should stay silent: $out"
  [ ! -s "$log" ] || fail "a poll inside the daily interval still probed GitHub: $(cat "$log")"
  [ "$(awk -F '\t' '$1 == "last_eval" { print $2 }' "$home/state/.actions-storage-check")" = "$T0" ] \
    || fail "a poll inside the daily interval rewrote the record"
  pass "a poll inside the daily interval skips the network probe entirely"
}

test_missing_user_scope_is_actionable() {
  local rec home fb usage result out
  rec=$(make_world scope); home=${rec%%|*}; fb=${rec#*|}
  usage="$TMP_ROOT/scope-usage.json"; usage_json "$usage" 0.2
  result=$(run_check "$home" "$fb" "$T0" FAKE_USAGE_JSON="$usage" FAKE_SCOPE_MISSING=1)
  [ "$(status_part "$result")" = 0 ] || fail "scope-missing check failed: $(output_part "$result")"
  out=$(output_part "$result")
  assert_contains "$out" 'needs the "user" scope' "the missing token scope was not named"
  assert_contains "$out" 'gh auth refresh -h github.com -s user' "the missing scope did not carry the remedy"
  pass "a missing user scope is reported with its remedy instead of going quiet"
}

test_unusable_json_is_reported() {
  local rec home fb usage result out
  rec=$(make_world json); home=${rec%%|*}; fb=${rec#*|}
  usage="$TMP_ROOT/json-usage.json"; printf '{"unexpected":true}\n' > "$usage"
  result=$(run_check "$home" "$fb" "$T0" FAKE_USAGE_JSON="$usage")
  out=$(output_part "$result")
  assert_contains "$out" 'the GitHub billing response was not usable JSON' "an unusable billing response was not reported"
  pass "an unusable billing response is reported rather than read as zero usage"
}

test_billing_request_failure_is_reported() {
  local rec home fb usage result out
  rec=$(make_world fail); home=${rec%%|*}; fb=${rec#*|}
  usage="$TMP_ROOT/fail-usage.json"; usage_json "$usage" 0.2
  result=$(run_check "$home" "$fb" "$T0" FAKE_USAGE_JSON="$usage" FAKE_BILLING_FAIL=1)
  out=$(output_part "$result")
  assert_contains "$out" 'the GitHub billing request failed' "a failed billing request was not reported"
  pass "a failed billing request is reported instead of staying silent"
}

test_exactly_eighty_percent_warns() {
  local rec home fb usage result out
  rec=$(make_world boundary); home=${rec%%|*}; fb=${rec#*|}
  usage="$TMP_ROOT/boundary-usage.json"; usage_json "$usage" 0.390625
  result=$(run_check "$home" "$fb" "$T0" FAKE_USAGE_JSON="$usage")
  out=$(output_part "$result")
  assert_contains "$out" '400.0 MB of 500 MB used (80.0%)' "exactly 80 percent must warn"
  pass "exactly 80 percent of the allowance warns"
}

test_allowance_override_changes_the_threshold() {
  local rec home fb usage result out
  rec=$(make_world allowance); home=${rec%%|*}; fb=${rec#*|}
  usage="$TMP_ROOT/allowance-usage.json"; usage_json "$usage" 0.4125
  result=$(run_check "$home" "$fb" "$T0" FAKE_USAGE_JSON="$usage" FM_ACTIONS_STORAGE_ALLOWANCE_MB=1024)
  out=$(output_part "$result")
  [ -z "$out" ] || fail "the allowance override did not move the threshold: $out"
  usage="$TMP_ROOT/allowance-usage-2.json"; usage_json "$usage" 0.4125 2026-11-19
  result=$(run_check "$home" "$fb" "$T1" FAKE_USAGE_JSON="$usage" FM_ACTIONS_STORAGE_ALLOWANCE_MB=400)
  out=$(output_part "$result")
  assert_contains "$out" '422.4 MB of 400 MB used (105.6%)' "the allowance override was not applied to the warning"
  pass "FM_ACTIONS_STORAGE_ALLOWANCE_MB moves the warning threshold"
}

test_arm_and_disarm_manage_the_registered_check() {
  local rec home fb out
  rec=$(make_world arm); home=${rec%%|*}; fb=${rec#*|}
  out=$(PATH="$fb:$PATH" FM_HOME="$home" "$CHECK" arm 2>&1) || fail "arm failed: $out"
  assert_contains "$out" 'armed: state/actions-storage.check.sh' "arm did not report the registered shim"
  [ -f "$home/state/actions-storage.check.sh" ] || fail "arm did not write the check shim"
  [ -f "$home/state/actions-storage.check-trust" ] || fail "arm did not write the trust binding"
  assert_contains "$(cat "$home/state/actions-storage.check.sh")" 'fm-actions-storage-check.sh check' "the shim does not run this check"
  out=$(PATH="$fb:$PATH" FM_HOME="$home" "$CHECK" disarm 2>&1) || fail "disarm failed: $out"
  [ ! -e "$home/state/actions-storage.check.sh" ] || fail "disarm left the shim behind"
  [ ! -e "$home/state/actions-storage.check-trust" ] || fail "disarm left the trust binding behind"
  pass "arm registers the check shim and disarm removes it"
}

test_under_threshold_is_silent_and_records_usage
test_documented_response_fixture_is_read
test_no_storage_rows_means_zero_without_a_warning
test_non_numeric_quantity_is_unusable
test_over_threshold_reports_the_completed_day
test_request_names_the_settled_day_in_utc
test_unchanged_finding_is_deduped
test_storage_row_with_unknown_unit_is_unusable
test_storage_row_from_another_day_is_unusable
test_changed_usage_reports_again
test_daily_gate_skips_the_probe
test_missing_user_scope_is_actionable
test_unusable_json_is_reported
test_billing_request_failure_is_reported
test_exactly_eighty_percent_warns
test_allowance_override_changes_the_threshold
test_arm_and_disarm_manage_the_registered_check
