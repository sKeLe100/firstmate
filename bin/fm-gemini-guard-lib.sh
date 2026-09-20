#!/usr/bin/env bash
# fm-gemini-guard-lib.sh - the ONE owner of firstmate's deterministic Gemini
# dispatch and quota-safety guard.
#
# This file is sourced by scripts and has no side effects on source. The
# captain's Gemini routing and quota rules (data/captain.md "GEMINI ROUTING",
# "GEMINI PREFLIGHT AND LOOP POLICY", "PROVIDER SESSION CAPS", and "PROVIDER
# ACCOUNTING") are agent-readable policy; this library is the executable,
# deterministic enforcement of them, so a Gemini dispatch that violates the
# rules fails closed here instead of relying on the orchestrator's memory.
#
# One owner: the allowed-model list, the senior/medium/economy pin mapping, the
# input-size bound, the session cap, the preflight composition, and the
# before-launch accounting baseline live here and nowhere else. bin/fm-spawn.sh
# calls the preflight at its dispatch owner (the launch that otherwise
# accepts an arbitrary model); bin/fm-classify-lib.sh owns the bounded
# provider-error loop classification that turns repeated RESOURCE_EXHAUSTED or
# quota responses into a terminal hold. Harness and quota catalog facts stay
# with bin/fm-harness.sh and bin/fm-quota-axi-lib.sh; this file reads those
# surfaces and never restates their content.
#
# The three pinned Gemini models (data/captain.md "GEMINI ROUTING"):
#   senior  - gemini-openai/gemini-3.8-flash     (senior/high-complexity only)
#   medium  - gemini-openai/gemini-3.7-flash     (standard agentic/coding)
#   economy - gemini-openai/gemini-3.5-flash-lite (investigation/fast/mechanical)
# Gemini 3.1 Pro is prohibited everywhere, and no moving alias (gemini-flash-
# latest, gemini-pro-latest) or sibling model (regular 3.5 Flash, a google/
# variant) may substitute for a pin. As of the 2026-09-20 live OpenCode catalog
# check the exact 3.7 Flash and 3.5 Flash-Lite pins are NOT exposed, so those
# two tiers currently have no launchable Gemini candidate and must refuse
# rather than silently fall back to another Gemini model.
#
# The guard is scoped to the opencode and gemini harnesses: the wired
# gemini-openai provider routes through opencode, and the native gemini CLI is
# the only other harness that names a gemini model. agy (Antigravity) is a
# distinct product whose own catalog is validated by agy_model_validate in
# bin/fm-spawn.sh, so this guard deliberately does not touch it. A non-Gemini
# model passes through untouched.

FM_GEMINI_SENIOR_MODEL='gemini-openai/gemini-3.8-flash'
FM_GEMINI_MEDIUM_MODEL='gemini-openai/gemini-3.7-flash'
FM_GEMINI_ECONOMY_MODEL='gemini-openai/gemini-3.5-flash-lite'
FM_GEMINI_SESSION_CAP=2
# Conservative input-token bound for the economy Flash-Lite pin. This is a
# fail-closed guard against sending an oversized context into the economy lane,
# not a claim about the model's true context window; override it with
# FM_GEMINI_FLASH_LITE_MAX_INPUT_TOKENS when the catalog establishes a real one.
FM_GEMINI_FLASH_LITE_MAX_INPUT_TOKENS_DEFAULT=128000

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

# fm_gemini_model_is_gemini <model>
#   0 when the model's basename names a Gemini model, regardless of provider
#   prefix: gemini-openai/gemini-3.8-flash, google/gemini-3.5-flash, and
#   openrouter/google/gemini-3.1-pro-preview all qualify because the last path
#   segment starts with `gemini`.
fm_gemini_model_is_gemini() {
  local model=${1:-} base
  [ -n "$model" ] || return 1
  base=${model##*/}
  base=${base,,}
  case "$base" in
    gemini|gemini-*|gemini_*) return 0 ;;
  esac
  return 1
}

# fm_gemini_model_class <model> -> prohibited|senior|medium|economy|other-gemini|not-gemini
#   prohibited    Gemini 3.1 Pro in any provider prefix (and any -preview or
#                 -customtools suffix).
#   senior        the exact senior pin.
#   medium        the exact medium pin.
#   economy       the exact economy pin.
#   other-gemini  any other Gemini model (a moving alias, regular 3.5 Flash, a
#                 google/ or openrouter/ sibling) that must not substitute.
#   not-gemini    anything that is not a Gemini model.
fm_gemini_model_class() {
  local model=${1:-} lc base
  fm_gemini_model_is_gemini "$model" || { printf 'not-gemini'; return 0; }
  lc=${model,,}
  base=${lc##*/}
  case "$base" in
    gemini-3.1-pro|gemini-3.1-pro-*|gemini-3.1pro|gemini-3.1pro-*)
      printf 'prohibited'
      return 0
      ;;
  esac
  case "$lc" in
    "$FM_GEMINI_SENIOR_MODEL") printf 'senior'; return 0 ;;
    "$FM_GEMINI_MEDIUM_MODEL") printf 'medium'; return 0 ;;
    "$FM_GEMINI_ECONOMY_MODEL") printf 'economy'; return 0 ;;
  esac
  printf 'other-gemini'
}

# fm_gemini_model_prohibited <model>
#   0 when the model is prohibited Gemini 3.1 Pro.
fm_gemini_model_prohibited() {
  [ "$(fm_gemini_model_class "${1:-}")" = prohibited ]
}

# fm_gemini_estimate_input_tokens <file> -> token count
#   A conservative estimate (ceil(bytes/4)) of the input a launch brief would
#   send, so an oversized economy-lane context is rejected before dispatch
#   rather than discovered as a provider error. An unreadable or empty file
#   estimates zero; the caller still owns whether zero is acceptable.
fm_gemini_estimate_input_tokens() {
  local file=${1:-} bytes
  [ -r "$file" ] || { printf '0'; return 0; }
  bytes=$(wc -c < "$file" 2>/dev/null) || bytes=0
  case "$bytes" in
    ''|*[!0-9]*) printf '0'; return 0 ;;
    0) printf '0'; return 0 ;;
  esac
  printf '%s' "$(( (bytes + 3) / 4 ))"
}

# fm_gemini_input_tokens_ok <model> <tokens>
#   0 unless the model is the economy Flash-Lite pin and <tokens> exceeds the
#   bound, in which case the oversized context is rejected.
fm_gemini_input_tokens_ok() {
  local model=${1:-} tokens=${2:-0} max
  [ "$(fm_gemini_model_class "$model")" = economy ] || return 0
  max=${FM_GEMINI_FLASH_LITE_MAX_INPUT_TOKENS:-$FM_GEMINI_FLASH_LITE_MAX_INPUT_TOKENS_DEFAULT}
  case "$max" in ''|*[!0-9]*) max=$FM_GEMINI_FLASH_LITE_MAX_INPUT_TOKENS_DEFAULT ;; esac
  case "$tokens" in ''|*[!0-9]*) return 0 ;; esac
  [ "$tokens" -le "$max" ]
}

# fm_gemini_session_cap_ok <count> [cap]
#   0 when <count> live Gemini-family sessions is under the cap (default 2),
#   so a third concurrent Gemini session is refused until a slot clears.
fm_gemini_session_cap_ok() {
  local count=${1:-0} cap=${2:-$FM_GEMINI_SESSION_CAP}
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$cap" in ''|*[!0-9]*|0) cap=$FM_GEMINI_SESSION_CAP ;; esac
  [ "$count" -lt "$cap" ]
}

# fm_gemini_catalog_has <catalog> <model>
#   0 when the exact <model> id appears as its own line in <catalog>, the
#   one-model-per-line listing `opencode models` prints. An unsupported exact
#   pin (gemini-openai/gemini-3.7-flash and gemini-openai/gemini-3.5-flash-lite
#   are currently absent) therefore refuses, and no alias or sibling matches.
fm_gemini_catalog_has() {
  local catalog=${1:-} model=${2:-}
  [ -n "$model" ] || return 1
  printf '%s\n' "$catalog" | grep -qxF -- "$model"
}

# fm_gemini_auth_ok <auth-listing>
#   0 when the `opencode auth list` listing shows a Google/Gemini credential
#   surface (the Google credential line or a GEMINI_API_KEY environment
#   variable). A missing listing is unverified authentication, never healthy.
fm_gemini_auth_ok() {
  local listing=${1:-}
  [ -n "$listing" ] || return 1
  printf '%s\n' "$listing" | grep -Eqi 'google|gemini' >/dev/null
}

# fm_gemini_quota_ok <quota-json>
#   0 only when quota-axi's schema-v5 JSON has a Gemini-family provider row
#   (google, gemini, or gemini-openai) with known semantics and at least one
#   known window whose effectivePercentRemaining is positive. An absent row,
#   unknown semantics, or an exhausted window is unverified quota, so the
#   launch refuses until the current incident is positively verified cleared.
fm_gemini_quota_ok() {
  local json=${1:-}
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s\n' "$json" | jq -e '
    any(.providers[]?;
      (((.provider // "") | ascii_downcase) | test("^(google|gemini|gemini-openai)$")) and
      ((.quotaSemantics.status // "unknown") == "known") and
      any(.quotaSemantics.effectiveAvailability[]?;
        (.status == "known") and ((.effectivePercentRemaining // 0) > 0))
    )
  ' >/dev/null 2>&1
}

# fm_gemini_write_baseline <state-dir> <task-id> <harness> <model> <tokens> <quota-json>
#   Writes the before-launch accounting baseline and returns 0, or refuses (1)
#   when the record cannot be written. The record is the first half of the
#   captain's before/after accounting; the matching after-launch capture is
#   owned by the completion/interrupt path and reads this file back. The raw
#   quota snapshot is stored beside the record so the delta can be re-derived.
fm_gemini_write_baseline() {
  local state=${1:-} id=${2:-} harness=${3:-} model=${4:-} tokens=${5:-0} quota=${6:-}
  local record quota_path now provider quota_source quota_available
  record="$state/$id.gemini-baseline"
  quota_path="$state/$id.gemini-baseline.quota.json"
  provider=${model%%/*}
  [ -n "$provider" ] || provider=unknown
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || now=unknown
  if [ -n "$quota" ]; then
    quota_source='quota-axi'
  else
    quota_source='unknown'
  fi
  if fm_gemini_quota_ok "$quota"; then
    quota_available=true
  else
    quota_available=false
  fi
  {
    printf 'provider=%s\n' "$provider"
    printf 'harness=%s\n' "$harness"
    printf 'model=%s\n' "$model"
    printf 'started_at=%s\n' "$now"
    printf 'input_tokens=%s\n' "$tokens"
    printf 'quota_source=%s\n' "$quota_source"
    printf 'quota_available=%s\n' "$quota_available"
  } > "$record" 2>/dev/null || {
    echo "error: could not write the Gemini before-launch accounting baseline to $record" >&2
    return 1
  }
  if [ -n "$quota" ]; then
    printf '%s\n' "$quota" > "$quota_path" 2>/dev/null || {
      echo "error: could not write the Gemini quota snapshot to $quota_path" >&2
      return 1
    }
  fi
  return 0
}

# fm_gemini_preflight <harness> <model> <state-dir> <task-id> [input-tokens]
#   The fail-closed preflight for a Gemini dispatch. Returns 0 (allow) or 1
#   (refuse, with the reason on stderr). A non-Gemini model, or a non-Gemini
#   harness, returns 0 immediately so unaffected launches pass untouched.
#
#   Order: model allowlist (prohibited / other-gemini / senior assertion),
#   input-size rejection, then - for the opencode harness only, where the
#   gemini-openai provider actually routes - exact catalog support, positive
#   authentication, positive quota, and the before-launch accounting baseline.
#   External commands are injectable for tests via FM_GEMINI_OPENCODE_BIN and
#   FM_GEMINI_QUOTA_AXI_BIN, and bounded via FM_GEMINI_*_TIMEOUT seconds.
fm_gemini_preflight() {
  local harness=${1:-} model=${2:-} state=${3:-} id=${4:-} tokens=${5:-0}
  local class listing auth quota bound bin quota_bin
  fm_gemini_model_is_gemini "$model" || return 0
  case "$harness" in
    opencode|gemini) ;;
    *) return 0 ;;
  esac
  class=$(fm_gemini_model_class "$model")
  case "$class" in
    not-gemini) return 0 ;;
    prohibited)
      echo "error: Gemini 3.1 Pro is prohibited everywhere; refusing to launch '$model'" >&2
      return 1
      ;;
    other-gemini)
      echo "error: '$model' is not an allowed Gemini pin; use the exact $FM_GEMINI_SENIOR_MODEL (senior), $FM_GEMINI_MEDIUM_MODEL (medium), or $FM_GEMINI_ECONOMY_MODEL (economy), never a moving alias or another Gemini model as a silent substitute" >&2
      return 1
      ;;
    senior)
      [ "${FM_GEMINI_SENIOR:-0}" = 1 ] || {
        echo "error: $FM_GEMINI_SENIOR_MODEL is senior/high-complexity routing only; assert a senior dispatch with FM_GEMINI_SENIOR=1" >&2
        return 1
      }
      ;;
  esac
  if ! fm_gemini_input_tokens_ok "$model" "$tokens"; then
    echo "error: oversized Flash-Lite input ($tokens estimated tokens) exceeds the $FM_GEMINI_FLASH_LITE_MAX_INPUT_TOKENS_DEFAULT-token bound; reject instead of sending it" >&2
    return 1
  fi
  [ "$harness" = opencode ] || return 0
  bin=${FM_GEMINI_OPENCODE_BIN:-opencode}
  bound=${FM_GEMINI_CATALOG_TIMEOUT:-15}
  case "$bound" in ''|*[!0-9]*|0) bound=15 ;; esac
  listing=$(fm_run_timed "$bound" "$bin" models 2>/dev/null </dev/null) || listing=
  if [ -z "$listing" ] || ! fm_gemini_catalog_has "$listing" "$model"; then
    echo "error: '$model' is not exactly listed by 'opencode models'; the exact pin is unsupported in the current catalog and no moving alias or sibling may substitute" >&2
    return 1
  fi
  auth=$(fm_run_timed "$bound" "$bin" auth list 2>/dev/null </dev/null) || auth=
  if ! fm_gemini_auth_ok "$auth"; then
    echo "error: Gemini authentication is not positively verified ('opencode auth list' shows no Google/Gemini credential)" >&2
    return 1
  fi
  quota_bin=${FM_GEMINI_QUOTA_AXI_BIN:-quota-axi}
  quota=$(fm_run_timed "$bound" "$quota_bin" --json 2>/dev/null </dev/null) || quota=
  if ! fm_gemini_quota_ok "$quota"; then
    echo "error: Gemini quota availability is not positively verified (no healthy Gemini-family provider row in quota-axi); refusing to launch until the current quota incident is positively verified cleared" >&2
    return 1
  fi
  if ! fm_gemini_write_baseline "$state" "$id" "$harness" "$model" "$tokens" "$quota"; then
    return 1
  fi
  return 0
}
