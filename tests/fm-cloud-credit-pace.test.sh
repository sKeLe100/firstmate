#!/usr/bin/env bash
# tests/fm-cloud-credit-pace.test.sh - tests for bin/fm-cloud-credit-pace.sh.
# The pacing arithmetic, the 20%-band verdict, the warped early-exhaustion
# warning, currency conversion, and the opencode token-table parser are
# exercised directly; the live balance and token-stat calls are replaced with
# fixture curl/opencode binaries so the suite stays offline and deterministic.
set -uo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN="$ROOT/bin/fm-cloud-credit-pace.sh"
TMP_ROOT=$(fm_test_tmproot fm-cloud-credit-pace)

# Source the production script for its pure helpers; main is guarded against
# sourcing. Drop errexit afterward so a failing assertion reports instead of
# aborting the run at the first command substitution.
# shellcheck disable=SC1090
. "$BIN"
set +e

# --- pacing fields: verdict bands, expected spend, allowance ----------------

out=$(fm_credit_pace_fields 20 30 10 6.67)
assert_contains "$out" "verdict=on-pace" "linear spend is on-pace"
assert_contains "$out" "total_cad=20.00" "total is echoed"
assert_contains "$out" "expected_cad=6.67" "expected spend is linear"
assert_contains "$out" "spent_cad=6.67" "spent is echoed"
assert_contains "$out" "remaining_cad=13.33" "remaining is total minus spent"
assert_contains "$out" "days_left=20" "days_left counts down from window"
assert_contains "$out" "daily_allowance_cad=0.67" "allowance divides remaining by days left"
assert_contains "$out" "exhausted=false" "an unspent balance is not exhausted"

out=$(fm_credit_pace_fields 20 30 10 12)
assert_contains "$out" "verdict=ahead" "80% over expected spend is ahead"

out=$(fm_credit_pace_fields 20 30 10 2)
assert_contains "$out" "verdict=behind" "well under expected spend is behind"

out=$(fm_credit_pace_fields 20 30 10 8.00)
assert_contains "$out" "verdict=on-pace" "exactly 20% over expected is still on-pace"

out=$(fm_credit_pace_fields 20 30 10 8.01)
assert_contains "$out" "verdict=ahead" "just over 20% over expected is ahead"

out=$(fm_credit_pace_fields 20 30 0 5)
assert_contains "$out" "expected_cad=0.00" "zero elapsed days has no expected spend"
assert_contains "$out" "verdict=on-pace" "zero elapsed days cannot be judged"

out=$(fm_credit_pace_fields 20 30 40 5)
assert_contains "$out" "days_left=0" "elapsed days clamp at the window length"

out=$(fm_credit_pace_fields 20 30 30 25)
assert_contains "$out" "exhausted=true" "spending past the total is exhausted"
assert_contains "$out" "remaining_cad=-5.00" "overspend shows as negative remaining"
assert_contains "$out" "days_left=0" "a finished window has no days left"

# --- early-exhaustion warning ----------------------------------------------

out=$(fm_credit_pace_warn deepseek 2 18 10 20 2026-10-17)
assert_contains "$out" "WARN: pool=deepseek" "a pool running dry early warns"
assert_contains "$out" "2026-10-17" "the warning names the window end"

out=$(fm_credit_pace_warn deepseek 13.33 6.67 10 20 2026-10-17)
assert_equals "" "$out" "an on-pace pool does not warn"

out=$(fm_credit_pace_warn deepseek 0 20 10 20 2026-10-17)
assert_contains "$out" "exhausted" "an exhausted pool warns"

out=$(fm_credit_pace_warn deepseek 20 0 10 20 2026-10-17)
assert_equals "" "$out" "a pool with no spend never warns"

# --- dates, conversion, percent --------------------------------------------

assert_equals "1" "$(( $(fm_credit_epoch_day 2026-09-18) - $(fm_credit_epoch_day 2026-09-17) ))" \
  "adjacent dates differ by one day"

fm_credit_epoch_day "not-a-date" >/dev/null 2>&1
[ $? -eq 1 ] || fail "an invalid date must fail"

assert_equals "13.70" "$(fm_credit_pace_convert 10 USD 1.37)" "USD converts at the FX rate"
assert_equals "10.00" "$(fm_credit_pace_convert 10 CAD 1.37)" "CAD passes through unconverted"
assert_equals "25.0" "$(fm_credit_pace_percent 20 5)" "percent is spent over total"
assert_equals "0.0" "$(fm_credit_pace_percent 0 5)" "a zero total cannot divide"

# --- opencode token-table parsing and Gemini pricing ------------------------

stats=$(cat <<'TXT'
┌────────────────────────────────────────────────────────┐
│                      MODEL USAGE                       │
├────────────────────────────────────────────────────────┤
│ gemini-openai/gemini-3.8-flash                         │
│  Messages                                            6 │
│  Input Tokens                                    56.6K │
│  Output Tokens                                     915 │
│  Cache Read                                      12.2K │
│  Cost                                          $0.0000 │
├────────────────────────────────────────────────────────┤
│ gemini-openai/gemini-3.1-pro-preview                   │
│  Messages                                            2 │
│  Input Tokens                                      1.0M │
│  Output Tokens                                   100.0K │
│  Cost                                          $0.0000 │
└────────────────────────────────────────────────────────┘
TXT
)

out=$(printf '%s\n' "$stats" | fm_credit_opencode_tokens)
assert_contains "$out" "model=gemini-openai/gemini-3.8-flash input=56600 output=915" \
  "K-suffixed flash tokens expand"
assert_contains "$out" "model=gemini-openai/gemini-3.1-pro-preview input=1000000 output=100000" \
  "M-suffixed pro tokens expand"

rates='{"gemini-3.8-flash":{"input":0.75,"output":3.75},"gemini-3.1-pro-preview":{"input":2.0,"output":12.0}}'
assert_equals "3.245881" "$(fm_credit_gemini_usd "$stats" "$rates")" \
  "gemini tokens are priced at the per-model rates"

# --- end-to-end with fixture curl/opencode ---------------------------------

printf '%s\n' "$stats" > "$TMP_ROOT/opencode-stats.txt"
fake=$(fm_fakebin "$TMP_ROOT")
cat > "$fake/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"19.46","granted_balance":"0.00","topped_up_balance":"19.46"}]}'
SH
cat > "$fake/opencode" <<SH
#!/usr/bin/env bash
cat "$TMP_ROOT/opencode-stats.txt"
SH
chmod +x "$fake/curl" "$fake/opencode"

cat > "$TMP_ROOT/budgets.json" <<'JSON'
{
  "fx_usd_cad": 1.37,
  "pools": [
    {
      "id": "deepseek",
      "total": 20.0,
      "currency": "CAD",
      "balance_currency": "CAD",
      "window_start": "2026-09-17",
      "window_end": "2026-10-17",
      "source": "deepseek_api"
    },
    {
      "id": "gemini",
      "total": 25.0,
      "currency": "CAD",
      "window_start": "2026-09-17",
      "window_end": "2026-10-17",
      "source": "opencode_stats",
      "rates_usd_per_mtok": {
        "gemini-3.8-flash": { "input": 0.75, "output": 3.75 },
        "gemini-3.1-pro-preview": { "input": 2.0, "output": 12.0 }
      }
    }
  ]
}
JSON

out=$(PATH="$fake:$PATH" DEEPSEEK_API_KEY=test "$BIN" --config "$TMP_ROOT/budgets.json" --now 2026-09-18 2>&1)
code=$?
assert_equals "0" "$code" "a full run exits zero"
assert_contains "$out" "pool=deepseek verdict=on-pace total_cad=20.00 spent_cad=0.54 remaining_cad=19.46" \
  "deepseek balance is read and paced"
assert_contains "$out" "treated as CAD" "the balance_currency override is reported"
assert_contains "$out" "pool=gemini verdict=ahead total_cad=25.00 spent_cad=4.45" \
  "gemini spend is estimated and priced"

# A pool whose source is unsupported degrades to verdict=unknown, not a crash.
cat > "$TMP_ROOT/bogus.json" <<'JSON'
{
  "fx_usd_cad": 1.37,
  "pools": [
    { "id": "mystery", "total": 5.0, "currency": "CAD",
      "window_start": "2026-09-17", "window_end": "2026-10-17",
      "source": "bogus" }
  ]
}
JSON
out=$(PATH="$fake:$PATH" "$BIN" --config "$TMP_ROOT/bogus.json" --now 2026-09-18 2>&1)
assert_contains "$out" "pool=mystery verdict=unknown" "an unsupported source is reported unknown"

out=$(PATH="$fake:$PATH" DEEPSEEK_API_KEY=test "$BIN" --config "$TMP_ROOT/missing.json" 2>&1)
code=$?
assert_equals "1" "$code" "a missing config file fails"
assert_contains "$out" "no budgets config" "the failure names the missing config"

printf '%s\n' '{"pools": []}' > "$TMP_ROOT/empty.json"
out=$("$BIN" --config "$TMP_ROOT/empty.json" 2>&1)
code=$?
assert_equals "1" "$code" "an empty pools array fails"
assert_contains "$out" "malformed config" "the failure names the malformed config"

# A pool missing a required field (here: total) refuses with a diagnostic
# instead of silently pricing at zero.
cat > "$TMP_ROOT/invalid-pool.json" <<'JSON'
{
  "fx_usd_cad": 1.37,
  "pools": [
    { "id": "deepseek", "currency": "CAD",
      "window_start": "2026-09-17", "window_end": "2026-10-17",
      "source": "deepseek_api" }
  ]
}
JSON
out=$(PATH="$fake:$PATH" DEEPSEEK_API_KEY=test "$BIN" --config "$TMP_ROOT/invalid-pool.json" --now 2026-09-18 2>&1)
code=$?
assert_equals "1" "$code" "a pool missing a required field fails"
assert_contains "$out" "missing/invalid required fields" "the failure names the invalid pool"
assert_contains "$out" "deepseek" "the failure identifies which pool is invalid"

# A Gemini stats model absent from rates_usd_per_mtok is flagged, not priced
# at zero, so it cannot silently suppress the early-exhaustion WARN.
cat > "$TMP_ROOT/unpriced.json" <<'JSON'
{
  "fx_usd_cad": 1.37,
  "pools": [
    {
      "id": "gemini",
      "total": 25.0,
      "currency": "CAD",
      "window_start": "2026-09-17",
      "window_end": "2026-10-17",
      "source": "opencode_stats",
      "rates_usd_per_mtok": {
        "gemini-3.8-flash": { "input": 0.75, "output": 3.75 }
      }
    }
  ]
}
JSON
out=$(PATH="$fake:$PATH" "$BIN" --config "$TMP_ROOT/unpriced.json" --now 2026-09-18 2>&1)
code=$?
assert_equals "0" "$code" "an unpriced Gemini model does not fail the run"
assert_contains "$out" "WARN unpriced models excluded from spend: gemini-openai/gemini-3.1-pro-preview" \
  "the human line flags the unpriced model instead of pricing it at zero"
assert_contains "$out" "unpriced_models=gemini-openai/gemini-3.1-pro-preview" \
  "the machine line carries the unpriced_models field"
