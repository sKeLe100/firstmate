#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-runway-admit.sh, the admission check a
# Claude gate-agent wrapper calls before starting a no-mistakes gate step
# (data/claude2-5h-drain-scout/report.md, option D). It reuses
# bin/fm-dispatch-quota-cap.sh's runway reading: a real exhausted or
# under-40% account refuses with exit 75, an unavailable reading admits with a
# note, an unevaluable document admits with a warning, and the decision is
# cached per account for a short TTL so repeated gate starts do not hammer the
# rate-limited quota endpoint. Every case uses the FM_DISPATCH_QUOTA_JSON
# fixture seam, so no test reaches the network.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-claude-runway-admit.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-runway-admit)

mk_home() {  # <name>
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/config" "$h/state"
  printf '%s' "$h"
}

quota_doc() {  # <name> <five_pct> <hours> <projected_hours|empty> [status]
  local f="$TMP_ROOT/$1.json"
  python3 - "$f" "$2" "$3" "${4:-}" "${5:-fresh}" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
f, pct, hours, projected, status = sys.argv[1:]
gen = datetime(2026, 9, 14, 12, 0, tzinfo=timezone.utc)
resets = gen + timedelta(hours=float(hours))
pace = {"status": "behind", "burnMultiple": 0.4}
if projected:
    pace["projectedExhaustedAt"] = (
        gen + timedelta(hours=float(projected))
    ).isoformat().replace("+00:00", "Z")
json.dump({
    "generatedAt": gen.isoformat().replace("+00:00", "Z"),
    "schemaVersion": 5,
    "providers": [
        {"provider": "claude", "state": {"status": status}, "windows": [
            {"id": "five_hour", "kind": "session", "resetsAt": resets.isoformat(),
             "percentRemaining": float(pct), "pace": pace},
            {"id": "seven_day", "kind": "weekly", "percentRemaining": 80,
             "pace": {"status": "behind", "burnMultiple": 0.4}},
        ]},
        {"provider": "codex", "windows": [
            {"id": "window:720h", "kind": "unknown", "percentRemaining": 50,
             "pace": {"status": "behind", "burnMultiple": 1.0}},
        ]},
    ],
}, open(f, "w"))
PY
  printf '%s' "$f"
}

run_admit() {  # <home> <doc> [extra args...]
  local home=$1 doc=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$HELPER" --quota-json "$doc" --claude-account ordinary "$@" 2>&1
}

home=$(mk_home default)

# 1. A healthy window admits silently and caches the admit.
out=$(run_admit "$home" "$(quota_doc healthy 80 4)")
rc=$?
expect_code 0 "$rc" "a healthy account must admit: $out"
[ -z "$out" ] || fail "a healthy admit must be silent, got: $out"
cached=0
for cache_path in "$home"/state/claude-runway-admit.*.cache; do
  [ -e "$cache_path" ] && cached=1
done
[ "$cached" -eq 1 ] || fail "no cache file was written: $(ls "$home/state")"

# 2. An exhausted window refuses with exit 75 and names the account and reason.
home=$(mk_home exhausted)
out=$(run_admit "$home" "$(quota_doc exhausted 0 4)")
rc=$?
expect_code 75 "$rc" "an exhausted five-hour window must refuse: $out"
assert_contains "$out" "account ordinary" "the refusal must name the account: $out"
assert_contains "$out" "exhausted" "the refusal must carry the reason: $out"
[ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] \
  || fail "a refusal must be exactly one stderr line, got: $out"

# 3. Projected exhaustion materially before the reset refuses even at high
# remaining, the 2026-11-19 failure case. The reason labels it an estimate.
home=$(mk_home projected)
out=$(run_admit "$home" "$(quota_doc projected 89 4 3)")
rc=$?
expect_code 75 "$rc" "projected exhaustion must refuse: $out"
assert_contains "$out" "est. exhaustion" "the reason must label the projection as an estimate: $out"

# 4. A real reading under 40% is below the existing runway threshold.
home=$(mk_home tight)
out=$(run_admit "$home" "$(quota_doc tight 30 4)")
rc=$?
expect_code 75 "$rc" "a real under-40% reading must refuse: $out"
assert_contains "$out" "30% left" "the refusal must carry the reading: $out"

# 5. An unavailable or rate-limited reading admits, with the disclosure on
# stderr, so a quota outage never stops every check.
home=$(mk_home unavailable)
out=$(run_admit "$home" "$(quota_doc unavailable 80 4 '' auth_required)")
rc=$?
expect_code 0 "$rc" "an unavailable reading must admit: $out"
assert_contains "$out" "quota reading unavailable" "the admit must disclose the reading: $out"
assert_contains "$out" "account ordinary" "the admit note must name the account: $out"

# 6. An admit cached for the TTL survives a subsequent tight reading.
home=$(mk_home cache-admit)
out=$(run_admit "$home" "$(quota_doc cache-admit-healthy 80 4)" --ttl 120)
rc=$?
expect_code 0 "$rc" "the first healthy call must admit: $out"
out=$(run_admit "$home" "$(quota_doc cache-admit-tight 0 4)" --ttl 120)
rc=$?
expect_code 0 "$rc" "a cached admit must outlive the tight reading: $out"
out=$(run_admit "$home" "$(quota_doc cache-admit-tight 0 4)" --ttl 0)
rc=$?
expect_code 75 "$rc" "TTL 0 must bypass the cached admit: $out"

# 7. A refusal cached for the TTL survives a subsequent healthy reading.
home=$(mk_home cache-refuse)
out=$(run_admit "$home" "$(quota_doc cache-refuse-tight 0 4)" --ttl 120)
rc=$?
expect_code 75 "$rc" "the first exhausted call must refuse: $out"
out=$(run_admit "$home" "$(quota_doc cache-refuse-healthy 80 4)" --ttl 120)
rc=$?
expect_code 75 "$rc" "a cached refusal must outlive the healthy reading: $out"
out=$(run_admit "$home" "$(quota_doc cache-refuse-healthy 80 4)" --ttl 0)
rc=$?
expect_code 0 "$rc" "TTL 0 must bypass the cached refusal: $out"

# 8. The cache is per account.
home=$(mk_home cache-per-account)
run_admit "$home" "$(quota_doc acct-a 0 4)" --claude-account /tmp/account-a --ttl 120 >/dev/null 2>&1
rc=$?
expect_code 75 "$rc" "account A must refuse"
out=$(run_admit "$home" "$(quota_doc acct-b 80 4)" --claude-account /tmp/account-b --ttl 120)
rc=$?
expect_code 0 "$rc" "a different account must not inherit the refusal: $out"

# 9. The opt-out env var bypasses the check entirely.
home=$(mk_home opt-out)
out=$(FM_CLAUDE_RUNWAY_ADMIT=0 run_admit "$home" "$(quota_doc opt-out 0 4)")
rc=$?
expect_code 0 "$rc" "FM_CLAUDE_RUNWAY_ADMIT=0 must admit: $out"
[ -z "$out" ] || fail "an opt-out must be silent, got: $out"

# 10. A document the cap script cannot evaluate admits with a warning rather
# than blocking every gate step.
home=$(mk_home malformed)
printf '{"schemaVersion": 4, "providers": []}\n' > "$TMP_ROOT/malformed.json"
out=$(run_admit "$home" "$TMP_ROOT/malformed.json")
rc=$?
expect_code 0 "$rc" "an unevaluable document must admit: $out"
assert_contains "$out" "could not be evaluated" "the admit must disclose the failure: $out"

pass "fm-claude-runway-admit.sh: gate-agent runway admission, outage admit, and per-account cache"
