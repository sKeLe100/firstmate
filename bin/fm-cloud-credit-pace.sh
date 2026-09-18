#!/usr/bin/env bash
# bin/fm-cloud-credit-pace.sh - read-only pacing report for prepaid
# cloud-credit pools (DeepSeek, Gemini).
#
# Why: the captain funds one-time cloud-credit pools that must be spread over
# a fixed calendar window and does not want to check balances by hand. This
# script turns each pool's live or estimated spend into a linear-pace verdict
# so a dispatch decision can prefer an under-spent pool over one that is
# burning down early. It never mutates anything: it reads a local config,
# queries a balance endpoint and/or local token stats, and prints.
#
# Usage: fm-cloud-credit-pace.sh [--config <path>] [--now YYYY-MM-DD]
#
#   --config <path>  Budget JSON file. Default:
#                    ${FM_CONFIG_OVERRIDE:-${FM_HOME:-$PWD}/config}/cloud-credit-budgets.json
#                    (the captain-private, gitignored `config/`; see
#                    docs/examples/cloud-credit-budgets.json for the schema).
#   --now <date>     Treat this UTC date as today. Default: the current UTC
#                    date. Intended for tests and back-dated audits; ordinary
#                    runs omit it.
#
# Sources, one per pool's `source` field:
#   deepseek_api   GET https://api.deepseek.com/user/balance with
#                  `Authorization: Bearer $DEEPSEEK_API_KEY` for the live
#                  remaining balance, converted to the pool's currency at the
#                  config's fx_usd_cad when the endpoint reports USD.
#   opencode_stats Token counts from `opencode stats --models --days <elapsed>`,
#                  priced with the pool's own rates_usd_per_mtok map. This is
#                  an estimate, not ground truth: opencode's built-in cost
#                  tracker has no Gemini rate, so it reports $0.00 for those
#                  models while this script prices the real tokens.
#
# Per pool the script prints a human line and a machine line:
#   deepseek: spent 0.54 CAD of 20.00 CAD (2.7% used), 29 days left, expected ~0.67 CAD by now -> on-pace
#   pool=deepseek verdict=on-pace total_cad=20.00 spent_cad=0.54 remaining_cad=19.46 expected_cad=0.67 days_left=29 daily_allowance_cad=0.67 exhausted=false
#
# Verdict is `ahead` when spend is more than 20% above the linear pace,
# `behind` when more than 20% below, and `on-pace` otherwise. A pool whose
# source could not be read prints `verdict=unknown` with a `note=` field.
#
# Exit 0 normally. A pool projected to run dry more than 5 days before its
# window ends - or already exhausted - prints a `WARN:` line; that is the only
# case meant to reach the captain, and the caller decides what to do with it.
#
# Pure pacing arithmetic lives in fm_credit_pace_fields / fm_credit_pace_warn
# and is unit-tested directly by tests/fm-cloud-credit-pace.test.sh. This
# script is sourced by that test, so main is guarded against sourcing.
set -euo pipefail

usage() {
  sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'
}

# fm_credit_epoch_day <YYYY-MM-DD> -> integer days since Unix epoch (UTC).
# Prints the day number on stdout; returns 1 with a message on bad input.
fm_credit_epoch_day() {
  local d="$1" e
  case "$d" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) printf 'fm-cloud-credit-pace: invalid date: %s\n' "$d" >&2; return 1 ;;
  esac
  e="$(date -u -d "$d" +%s 2>/dev/null)" ||
    { printf 'fm-cloud-credit-pace: cannot parse date: %s\n' "$d" >&2; return 1; }
  printf '%s\n' "$((e / 86400))"
}

# fm_credit_pace_fields <total_cad> <window_days> <elapsed_days> <spent_cad>
# Pure arithmetic. Prints one machine line; no I/O, no config, no network.
fm_credit_pace_fields() {
  awk -v total="$1" -v wd="$2" -v ed="$3" -v spent="$4" '
    function r2(x) { return sprintf("%.2f", x) }
    BEGIN {
      if (wd < 0) wd = 0
      if (ed < 0) ed = 0
      if (ed > wd) ed = wd
      remaining = total - spent
      days_left = wd - ed
      if (days_left < 0) days_left = 0
      expected = (wd > 0) ? total * ed / wd : 0
      allowance = (days_left > 0) ? remaining / days_left : remaining
      verdict = "on-pace"
      if (expected > 0 && spent > expected * 1.2) verdict = "ahead"
      else if (expected > 0 && spent < expected * 0.8) verdict = "behind"
      exhausted = (remaining <= 0) ? "true" : "false"
      printf "verdict=%s total_cad=%s spent_cad=%s remaining_cad=%s expected_cad=%s days_left=%d daily_allowance_cad=%s exhausted=%s\n", \
        verdict, r2(total), r2(spent), r2(remaining), r2(expected), days_left, r2(allowance), exhausted
    }'
}

# fm_credit_pace_warn <pool> <remaining_cad> <spent_cad> <elapsed_days> <days_left> <window_end>
# Prints a WARN line only when a pool is exhausted or projected to run dry
# more than 5 days before its window ends; silent otherwise. This is the only
# captain-facing case; ordinary pacing is routine and prints nothing.
fm_credit_pace_warn() {
  awk -v pool="$1" -v remaining="$2" -v spent="$3" -v ed="$4" -v days_left="$5" -v end="$6" '
    BEGIN {
      if (remaining <= 0) {
        printf "WARN: pool=%s exhausted at or before %s\n", pool, end
        exit 0
      }
      if (ed <= 0 || spent <= 0) exit 0
      burn = spent / ed
      dte = remaining / burn
      if (dte < days_left - 5)
        printf "WARN: pool=%s projected to exhaust %.1f days before %s (burn %.2f CAD/day, %.2f CAD left, ~%.0f days runway)\n", \
          pool, days_left - dte, end, burn, remaining, dte
    }'
}

# fm_credit_pace_human <pool> <percent_used> <machine_line_fields...>
# Renders the human line from the same numbers the machine line carries.
fm_credit_pace_human() {
  local pool="$1" pct="$2" fields="$3"
  awk -v pool="$pool" -v pct="$pct" '
    {
      for (i = 1; i <= NF; i++) {
        split($i, kv, "=")
        v[kv[1]] = kv[2]
      }
      printf "%s: spent %s CAD of %s CAD (%s%% used), %s days left, expected ~%s CAD by now -> %s\n", \
        pool, v["spent_cad"], v["total_cad"], pct, v["days_left"], v["expected_cad"], v["verdict"]
    }
  ' <<<"$fields"
}

# fm_credit_pace_percent <total_cad> <spent_cad> -> one-decimal percent.
fm_credit_pace_percent() {
  awk -v t="$1" -v s="$2" 'BEGIN { if (t <= 0) printf "0.0"; else printf "%.1f", 100 * s / t }'
}

# fm_credit_pace_convert <amount> <from_currency> <fx_usd_cad> -> CAD amount.
fm_credit_pace_convert() {
  awk -v a="$1" -v c="$2" -v fx="$3" 'BEGIN { printf "%.2f", (c == "USD") ? a * fx : a }'
}

# fm_credit_opencode_tokens
# Reads `opencode stats --models` text on stdin; prints one line per model:
#   model=<name> input=<tokens> output=<tokens>
# Token counts carry K/M/B suffixes in the table and are expanded here.
fm_credit_opencode_tokens() {
  awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function num(s,   u) {
      s = trim(s); u = 1
      if (s ~ /[Kk]$/) { u = 1000; s = substr(s, 1, length(s) - 1) }
      else if (s ~ /[Mm]$/) { u = 1000000; s = substr(s, 1, length(s) - 1) }
      else if (s ~ /[GgBb]$/) { u = 1000000000; s = substr(s, 1, length(s) - 1) }
      return (s + 0) * u
    }
    /│/ {
      line = $0; gsub(/│/, "", line)
      if (line ~ /^  /) {
        t = trim(line)
        if (t ~ /^Input Tokens/) { v = t; sub(/^Input Tokens[ \t]+/, "", v); in_tok[cur] = num(v) }
        else if (t ~ /^Output Tokens/) { v = t; sub(/^Output Tokens[ \t]+/, "", v); out_tok[cur] = num(v) }
      } else {
        t = trim(line)
        if (t != "") cur = t
      }
    }
    END { for (m in in_tok) printf "model=%s input=%d output=%d\n", m, in_tok[m], out_tok[m] + 0 }
  '
}

# fm_credit_gemini_usd <stats_text> <rates_json>
# Prices parsed Gemini token counts with the pool's per-model USD/1M rates.
fm_credit_gemini_usd() {
  local stats="$1" rates="$2" total="0" line model input output rate inr outr
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    model="${line#model=}"; model="${model%% *}"
    input="${line#*input=}"; input="${input%% *}"
    output="${line##*output=}"
    rate="$(jq -r --arg m "$model" '
      to_entries[]
      | select(.key as $k | $m | endswith($k))
      | "\(.value.input) \(.value.output)"' <<<"$rates" 2>/dev/null | head -1)"
    [ -n "$rate" ] || continue
    inr="${rate%% *}"; outr="${rate##* }"
    total="$(awk -v t="$total" -v i="$input" -v o="$output" -v ir="$inr" -v orate="$outr" \
      'BEGIN { printf "%.6f", t + (i * ir + o * orate) / 1000000 }')"
  done < <(printf '%s\n' "$stats" | fm_credit_opencode_tokens)
  printf '%s\n' "$total"
}

# fm_credit_deepseek_remaining <fx_usd_cad> [<balance_currency_override>]
# Prints "<remaining_cad> <note>" from the live balance endpoint, or returns 1
# with a note on stdout when the key is absent or the endpoint is unusable.
# The endpoint's own currency is honored unless the pool config overrides it
# (a pool funded nominally in CAD while the endpoint labels the same number
# USD sets balance_currency to CAD, which skips the conversion).
fm_credit_deepseek_remaining() {
  local fx="$1" force_cur="${2:-}" key="${DEEPSEEK_API_KEY:-}" resp bal bcur cur note
  if [ -z "$key" ]; then
    printf '0.00 DEEPSEEK_API_KEY not set\n'
    return 1
  fi
  if ! resp="$(curl -fsS -m 20 -H "Authorization: Bearer $key" \
    https://api.deepseek.com/user/balance 2>/dev/null)"; then
    printf '0.00 balance query failed\n'
    return 1
  fi
  bal="$(jq -r '.balance_infos[0].total_balance // empty' <<<"$resp" 2>/dev/null)" || bal=""
  bcur="$(jq -r '.balance_infos[0].currency // empty' <<<"$resp" 2>/dev/null)" || bcur=""
  if [ -z "$bal" ] || [ -z "$bcur" ]; then
    printf '0.00 malformed balance response\n'
    return 1
  fi
  if [ -n "$force_cur" ] && [ "$force_cur" != "$bcur" ]; then
    cur="$force_cur"
    note="live balance ${bal} ${bcur} (treated as ${force_cur})"
  else
    cur="$bcur"
    note="live balance ${bal} ${bcur}"
  fi
  printf '%s %s\n' "$(fm_credit_pace_convert "$bal" "$cur" "$fx")" "$note"
}

# fm_credit_pool_spent <pool_json> <total_cad> <elapsed_days> <fx>
# Prints "<spent_cad> <note>", or "unknown <note>" when the source cannot be read.
fm_credit_pool_spent() {
  local pj="$1" total_cad="$2" elapsed="$3" fx="$4"
  local src rates stats rem note bcur_override
  src="$(jq -r '.source' <<<"$pj")"
  case "$src" in
    deepseek_api)
      bcur_override="$(jq -r '.balance_currency // ""' <<<"$pj")"
      if rem="$(fm_credit_deepseek_remaining "$fx" "$bcur_override")"; then
        note="${rem#* }"
        printf '%s %s\n' "$(awk -v t="$total_cad" -v r="${rem%% *}" 'BEGIN { printf "%.2f", t - r }')" "$note"
      else
        note="${rem#* }"
        printf 'unknown %s\n' "$note"
      fi
      ;;
    opencode_stats)
      rates="$(jq -c '.rates_usd_per_mtok // {}' <<<"$pj")"
      if ! command -v opencode >/dev/null 2>&1; then
        printf 'unknown opencode not found\n'
        return 0
      fi
      stats="$(opencode stats --models --days "$((elapsed + 1))" 2>/dev/null || true)"
      if [ -z "$stats" ]; then
        printf 'unknown opencode stats returned nothing\n'
        return 0
      fi
      printf '%s estimated from opencode token stats\n' \
        "$(fm_credit_pace_convert "$(fm_credit_gemini_usd "$stats" "$rates")" USD "$fx")"
      ;;
    *)
      printf 'unknown unsupported source: %s\n' "$src"
      ;;
  esac
}

main() {
  local config_path="" now=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config)
        [ "$#" -ge 2 ] || { echo "fm-cloud-credit-pace: --config requires a path" >&2; return 2; }
        config_path="$2"; shift 2 ;;
      --now)
        [ "$#" -ge 2 ] || { echo "fm-cloud-credit-pace: --now requires YYYY-MM-DD" >&2; return 2; }
        now="$2"; shift 2 ;;
      --help|-h) usage; return 0 ;;
      *) echo "fm-cloud-credit-pace: unknown argument: $1" >&2; return 2 ;;
    esac
  done

  config_path="${config_path:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-$PWD}/config}/cloud-credit-budgets.json}"
  if [ ! -f "$config_path" ]; then
    echo "fm-cloud-credit-pace: no budgets config at $config_path" >&2
    echo "fm-cloud-credit-pace: create it from docs/examples/cloud-credit-budgets.json" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || { echo "fm-cloud-credit-pace: jq is required" >&2; return 1; }
  if ! jq -e '.pools | type == "array" and length > 0' "$config_path" >/dev/null 2>&1; then
    echo "fm-cloud-credit-pace: malformed config (need a non-empty pools array): $config_path" >&2
    return 1
  fi

  local fx today now_day
  fx="$(jq -r '.fx_usd_cad // 1.37' "$config_path")"
  today="${now:-$(date -u +%Y-%m-%d)}"
  now_day="$(fm_credit_epoch_day "$today")" || return 1

  local pool_json id total currency ws we src total_cad start_day end_day window_days elapsed
  while IFS= read -r pool_json; do
    [ -n "$pool_json" ] || continue
    id="$(jq -r '.id' <<<"$pool_json")"
    total="$(jq -r '.total' <<<"$pool_json")"
    currency="$(jq -r '.currency // "CAD"' <<<"$pool_json")"
    ws="$(jq -r '.window_start' <<<"$pool_json")"
    we="$(jq -r '.window_end' <<<"$pool_json")"
    src="$(jq -r '.source' <<<"$pool_json")"

    total_cad="$(fm_credit_pace_convert "$total" "$currency" "$fx")"
    start_day="$(fm_credit_epoch_day "$ws")" || return 1
    end_day="$(fm_credit_epoch_day "$we")" || return 1
    window_days="$((end_day - start_day))"
    elapsed="$((now_day - start_day))"

    local spent_raw spent_cad note
    spent_raw="$(fm_credit_pool_spent "$pool_json" "$total_cad" "$elapsed" "$fx")"
    spent_cad="${spent_raw%% *}"
    note="${spent_raw#* }"

    if [ "$spent_cad" = "unknown" ]; then
      printf '%s: spend unknown (%s)\n' "$id" "$note"
      printf 'pool=%s verdict=unknown note=%s\n' "$id" "${note// /_}"
      continue
    fi

    local fields pct human
    fields="$(fm_credit_pace_fields "$total_cad" "$window_days" "$elapsed" "$spent_cad")"
    pct="$(fm_credit_pace_percent "$total_cad" "$spent_cad")"
    human="$(fm_credit_pace_human "$id" "$pct" "$fields")"
    printf '%s [%s]\n' "$human" "$note"
    printf 'pool=%s %s\n' "$id" "$fields"

    local remaining days_left end_human
    remaining="$(awk '{for(i=1;i<=NF;i++){split($i,kv,"="); if(kv[1]=="remaining_cad") print kv[2]}}' <<<"$fields")"
    days_left="$(awk '{for(i=1;i<=NF;i++){split($i,kv,"="); if(kv[1]=="days_left") print kv[2]}}' <<<"$fields")"
    end_human="$(date -u -d "@$((end_day * 86400))" +%Y-%m-%d 2>/dev/null || printf '%s' "$we")"
    fm_credit_pace_warn "$id" "$remaining" "$spent_cad" "$elapsed" "$days_left" "$end_human"
  done < <(jq -c '.pools[]' "$config_path")

  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
