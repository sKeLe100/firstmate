#!/usr/bin/env bash
# tests/fm-dispatch-quota-cap.test.sh - the durable refill design's quota
# fixture (data/backlog-triage-durable-plan/report.md test seam 7) plus the
# per-account 5-hour runway admission rule (report section 5 of
# data/claude-5h-window-system/report.md): the base cap of 3 becomes 2 or 1
# under the documented ladder, a bound account with projected exhaustion
# before its reset caps new lanes at 0, under 40% caps at 1, an unavailable
# reading is tight rather than headroom, and a Codex weekly window is found
# by kind or id without refusing a missing optional provider. Exercised only
# through bin/fm-dispatch-quota-cap.sh against injected quota-axi documents.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-dispatch-quota-cap.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-quota-cap)

mk_home() {  # <name>
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/config" "$h/state"
  printf '%s' "$h"
}

# quota_doc <name> <five_pct> <hours-until-reset> <week-status> <week-burn>
#           <codex-status> [<five-status> <five-burn> <projected-hours>
#           <codex-id> <claude-status>]
quota_doc() {
  local f="$TMP_ROOT/$1.json"
  python3 - "$f" "$2" "$3" "$4" "$5" "$6" "${7:-behind}" "${8:-0.5}" \
    "${9:-}" "${10:-weekly}" "${11:-fresh}" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
f, five_pct, hours, wstatus, wburn, cstatus, fstatus, fburn, projected, codex_id, claude_status = sys.argv[1:]
gen = datetime(2026, 9, 14, 12, 0, tzinfo=timezone.utc)
resets = gen + timedelta(hours=float(hours))
five_pace = {"status": fstatus, "burnMultiple": float(fburn)}
if projected:
    five_pace["projectedExhaustedAt"] = (
        gen + timedelta(hours=float(projected))
    ).isoformat().replace("+00:00", "Z")
providers = [
    {"provider": "claude", "windows": [
        {"id": "five_hour", "kind": "session", "resetsAt": resets.isoformat(),
         "percentRemaining": float(five_pct), "pace": five_pace},
        {"id": "seven_day", "kind": "weekly", "percentRemaining": 80,
         "pace": {"status": wstatus, "burnMultiple": float(wburn)}},
    ], "state": {"status": claude_status}},
]
if codex_id != "none":
    providers.append(
        {"provider": "codex", "windows": [
            {"id": codex_id, "kind": "weekly" if codex_id == "weekly" else "unknown",
             "percentRemaining": 50,
             "pace": {"status": cstatus, "burnMultiple": 1.0}},
        ]})
doc = {
    "generatedAt": gen.isoformat().replace("+00:00", "Z"),
    "schemaVersion": 5,
    "providers": providers,
}
json.dump(doc, open(f, "w"))
PY
  printf '%s' "$f"
}

run_cap() {  # <home> <doc> [extra args...]
  local home=$1 doc=$2
  shift 2
  FM_HOME="$home" "$HELPER" --quota-json "$doc" "$@"
}

mk_lane() {  # <home> <task-id> <harness> <kind> <account>
  cat > "$1/state/$2.meta" <<META
harness=$3
kind=$4
account=$5
META
}

home=$(mk_home default)

# 1. No pressure anywhere: base 3 stays 3 and Codex may spawn.
out=$(run_cap "$home" "$(quota_doc calm 80 4 behind 0.8 behind)") || fail "calm quota must succeed: $out"
assert_contains "$out" "effective_cap: 3" "no ladder row applies: base cap 3 stands, got: $out"
assert_contains "$out" "codex_spawn: yes" "Codex behind pace may spawn, got: $out"
assert_contains "$out" "claude_runway_cap: none" "a healthy account has no runway cap, got: $out"
assert_contains "$out" "claude_runway_block: no" "a healthy account admits a lane, got: $out"

# 2. five_hour below 40% remaining caps implementing lanes at 1 on that
# account, which is also the effective cap (the older 25% row is subsumed).
out=$(run_cap "$home" "$(quota_doc low5h 20 4 behind 0.8 behind)") || fail "low five-hour quota must succeed"
assert_contains "$out" "effective_cap: 1" "five_hour < 40% lowers the cap to 1, got: $out"
assert_contains "$out" "claude_runway_cap: 1" "under 40% caps the account at one lane, got: $out"
assert_contains "$out" "claude_runway_block: no" "an under-40% account still admits its first lane, got: $out"

# 3. Weekly pace ahead with burnMultiple > 1.5: base 3 becomes 1.
out=$(run_cap "$home" "$(quota_doc ahead 80 4 ahead 2.4 behind)") || fail "ahead-of-pace quota must succeed"
assert_contains "$out" "effective_cap: 1" "seven_day ahead with burn > 1.5 lowers the cap to 1, got: $out"

# 3b. Weekly ahead but burnMultiple at or under 1.15 does not trip a pace row.
out=$(run_cap "$home" "$(quota_doc mild 80 4 ahead 1.1 behind)") || fail "mildly-ahead quota must succeed"
assert_contains "$out" "effective_cap: 3" "seven_day ahead with burn <= 1.15 leaves the cap at 3, got: $out"

# 4. five_hour at or under 15% remaining: base 3 becomes 1.
out=$(run_cap "$home" "$(quota_doc floor 15 4 behind 0.8 behind)") || fail "floor quota must succeed"
assert_contains "$out" "effective_cap: 1" "five_hour <= 15% lowers the cap to 1, got: $out"

# 5. Late in the window with spend on pace: no throttle, usage rides out the window.
out=$(run_cap "$home" "$(quota_doc late 80 2 behind 0.8 behind)") || fail "late-window quota must succeed"
assert_contains "$out" "effective_cap: 3" "an on-pace late window keeps the base cap, got: $out"

# 5b. five_hour pace ahead past its first 30 minutes: > 1.15 caps at 2, > 1.5 at 1.
out=$(run_cap "$home" "$(quota_doc five-warm 80 3 behind 0.8 behind ahead 1.3)") || fail "five-warm quota must succeed"
assert_contains "$out" "effective_cap: 2" "five_hour burn 1.3 caps at 2, got: $out"
assert_contains "$out" "claude_pace: 1.30" "the pace line reports the burn used, got: $out"
out=$(run_cap "$home" "$(quota_doc five-hot 80 3 behind 0.8 behind ahead 1.8)") || fail "five-hot quota must succeed"
assert_contains "$out" "effective_cap: 1" "five_hour burn 1.8 caps at 1, got: $out"

# 5c. five_hour pace inside the first 30 minutes is ignored as early noise.
out=$(run_cap "$home" "$(quota_doc five-early 80 4.75 behind 0.8 behind ahead 3.0)") || fail "five-early quota must succeed"
assert_contains "$out" "effective_cap: 3" "early-window five_hour pace is ignored, got: $out"
assert_contains "$out" "claude_pace: 0.00" "no pace row applied, got: $out"

# 5d. Weekly pace ahead between 1.15 and 1.5 caps at 2.
out=$(run_cap "$home" "$(quota_doc week-warm 80 4 ahead 1.3 behind)") || fail "week-warm quota must succeed"
assert_contains "$out" "effective_cap: 2" "seven_day burn 1.3 caps at 2, got: $out"

# 6. Codex weekly pace ahead yields no Codex spawn, independent of the Claude cap.
out=$(run_cap "$home" "$(quota_doc codex-ahead 80 4 behind 0.8 ahead)") || fail "codex-ahead quota must succeed"
assert_contains "$out" "effective_cap: 3" "Codex pace never changes the Claude cap, got: $out"
assert_contains "$out" "codex_spawn: no" "Codex ahead of weekly pace yields no Codex spawn, got: $out"

# 6b. quota-axi names the Codex window `window:720h` now: the lookup must find
# it by duration, not only by the old `weekly` id.
out=$(run_cap "$home" "$(quota_doc codex-720h 80 4 behind 0.8 ahead '' '' '' window:720h)") || fail "codex window:720h must succeed"
assert_contains "$out" "codex_spawn: no" "a window:720h Codex window is found for the pace row, got: $out"

# 6c. A missing optional Codex provider or window is not a gate failure.
out=$(run_cap "$home" "$(quota_doc codex-missing 80 4 behind 0.8 behind '' '' '' none)") || fail "missing codex window must not refuse the gate: $out"
assert_contains "$out" "codex_spawn: yes" "a missing Codex window leaves the sidecar available, got: $out"
assert_contains "$out" "effective_cap: 3" "a missing Codex window leaves the Claude cap alone, got: $out"

# 7. config/dispatch-cap is the base the ladder reduces from.
cfg_home=$(mk_home configured)
printf '2\n' > "$cfg_home/config/dispatch-cap"
out=$(run_cap "$cfg_home" "$(quota_doc cfg-calm 80 4 behind 0.8 behind)") || fail "configured base must succeed"
assert_contains "$out" "effective_cap: 2" "a configured base of 2 stands with no pressure, got: $out"
out=$(run_cap "$cfg_home" "$(quota_doc cfg-floor 10 4 behind 0.8 behind)") || fail "configured base under the floor must succeed"
assert_contains "$out" "effective_cap: 1" "the ladder still reduces a configured base of 2 to 1, got: $out"

# 8. Malformed input is refused (exit 2); an unavailable reading is not.
printf 'three\n' > "$cfg_home/config/dispatch-cap"
run_cap "$cfg_home" "$(quota_doc cfg-bad 80 4 behind 0.8 behind)" >/dev/null 2>&1
[ $? -eq 2 ] || fail "a malformed config/dispatch-cap must exit 2"
printf '{"schemaVersion": 4, "providers": []}\n' > "$TMP_ROOT/old-schema.json"
run_cap "$home" "$TMP_ROOT/old-schema.json" >/dev/null 2>&1
[ $? -eq 2 ] || fail "an unexpected quota schema must exit 2"
python3 - "$TMP_ROOT/no-claude.json" <<'PY'
import json, sys
json.dump({"generatedAt": "2026-09-14T12:00:00Z", "schemaVersion": 5,
           "providers": [{"provider": "codex", "windows": []}]}, open(sys.argv[1], "w"))
PY
run_cap "$home" "$TMP_ROOT/no-claude.json" >/dev/null 2>&1
[ $? -eq 2 ] || fail "a document without the claude five_hour window must exit 2"

# 9. Projected exhaustion before the reset plus 20 minutes caps new lanes at 0.
# 89% left with the projection an hour before the reset is the 2026-11-19 case
# the old 25% row could not see.
out=$(run_cap "$home" "$(quota_doc projected 89 4 behind 0.8 behind '' '' 3)") || fail "projected-exhaustion quota must succeed"
assert_contains "$out" "claude_runway_cap: 0" "a projection before the reset caps at 0, got: $out"
assert_contains "$out" "claude_runway_block: yes" "cap 0 blocks a new lane, got: $out"
assert_contains "$out" "effective_cap: 0" "the runway cap is folded into the effective cap, got: $out"
assert_contains "$out" "projected exhaustion" "the reason names projected exhaustion, got: $out"

# 9b. A projection after the reset is not projected exhaustion.
out=$(run_cap "$home" "$(quota_doc projected-late 89 4 behind 0.8 behind '' '' 5)") || fail "late projection must succeed"
assert_contains "$out" "claude_runway_cap: none" "a projection after the reset leaves the account healthy, got: $out"
assert_contains "$out" "claude_runway_block: no" "a healthy projection admits a lane, got: $out"

# 9c. A projection exactly at resetsAt + 20m is not before it.
out=$(run_cap "$home" "$(quota_doc projected-edge 89 4 behind 0.8 behind '' '' 4.3333333333333333)") || fail "edge projection must succeed"
assert_contains "$out" "claude_runway_cap: none" "a projection at the reset+20m boundary is not early, got: $out"

# 10. Under 40% with a live Claude lane on that account blocks the next one;
# the lane count excludes secondmates and other harnesses.
tight=$(quota_doc lanes 30 4 behind 0.8 behind)
out=$(run_cap "$home" "$tight") || fail "no lane must admit the first lane: $out"
assert_contains "$out" "claude_lanes: 0" "no live lane configured, got: $out"
assert_contains "$out" "claude_runway_block: no" "the first lane is admitted, got: $out"
mk_lane "$home" other-1 claude ship ordinary
out=$(run_cap "$home" "$tight") || fail "one live lane must still report: $out"
assert_contains "$out" "claude_lanes: 1" "the live Claude ship is counted, got: $out"
assert_contains "$out" "claude_runway_block: yes" "one live lane at cap 1 blocks a second, got: $out"
mk_lane "$home" mate-1 claude secondmate ordinary
mk_lane "$home" other-2 codex ship ordinary
out=$(run_cap "$home" "$tight") || fail "exempt records must still report: $out"
assert_contains "$out" "claude_lanes: 1" "secondmates and non-Claude harnesses hold no counted lane, got: $out"

# 10b. The lane count is per account: a lane on another account does not block.
path_home=$(mk_home path-account)
mk_lane "$path_home" other-3 claude ship /tmp/other-account
out=$(run_cap "$path_home" "$tight" --claude-account /tmp/worker-account) || fail "account-scoped count must succeed: $out"
assert_contains "$out" "claude_account: /tmp/worker-account" "the bound account is reported, got: $out"
assert_contains "$out" "claude_lanes: 0" "a lane on a different account is not counted, got: $out"
assert_contains "$out" "claude_runway_block: no" "another account's lane does not block this one, got: $out"

# 11. An unavailable or rate-limited reading is tight (cap 1), never headroom
# and never a gate failure.
out=$(run_cap "$home" "$(quota_doc auth 80 4 behind 0.8 behind '' '' '' '' auth_required)") || fail "auth_required must not refuse the gate: $out"
assert_contains "$out" "claude_runway_cap: 1" "an unavailable reading is tight, got: $out"
assert_contains "$out" "quota reading unavailable" "the reason discloses the unavailable reading, got: $out"
assert_contains "$out" "effective_cap: 1" "an unavailable reading tightens the effective cap, got: $out"
mk_lane "$home" other-4 claude ship ordinary
out=$(run_cap "$home" "$(quota_doc auth2 80 4 behind 0.8 behind '' '' '' '' auth_required)") || fail "auth_required with a lane must report: $out"
assert_contains "$out" "claude_runway_block: yes" "an unavailable reading blocks a second lane, got: $out"
rm -f "$home/state/other-4.meta"

# 11b. A live run whose configured account is unreadable still reads as tight.
missing_home=$(mk_home missing-account)
printf '/definitely/not/a/claude/root\n' > "$missing_home/config/claude-account"
run_cap "$missing_home" "$(quota_doc missing 80 4 behind 0.8 behind)" >/dev/null 2>&1
[ $? -eq 2 ] || fail "an invalid config/claude-account must refuse rather than guess an account"

pass "fm-dispatch-quota-cap.sh: quota ladder, per-account runway, and Codex pace gate"
