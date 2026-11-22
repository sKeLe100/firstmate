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
#           <codex-id> <claude-status> <projection-confidence>]
quota_doc() {
  local f="$TMP_ROOT/$1.json"
  python3 - "$f" "$2" "$3" "$4" "$5" "$6" "${7:-behind}" "${8:-0.5}" \
    "${9:-}" "${10:-weekly}" "${11:-fresh}" "${12:-}" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
f, five_pct, hours, wstatus, wburn, cstatus, fstatus, fburn, projected, codex_id, claude_status, confidence = sys.argv[1:]
gen = datetime(2026, 9, 14, 12, 0, tzinfo=timezone.utc)
resets = gen + timedelta(hours=float(hours))
five_pace = {"status": fstatus, "burnMultiple": float(fburn)}
if projected:
    five_pace["projectedExhaustedAt"] = (
        gen + timedelta(hours=float(projected))
    ).isoformat().replace("+00:00", "Z")
if confidence:
    five_pace["projectionConfidence"] = confidence
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

# fresh_doc <name> <five-pct> <seven-pct> <five-used|omit> <seven-status>
#           [<five-pace-status|none>]
# A claude five_hour row with NO resetsAt, quota-axi's shape for a window
# whose countdown has not started: 100% remaining, zero usage, unknown pace.
# seven_day is a readable weekly row so the fresh-window exemption can apply.
fresh_doc() {
  local f="$TMP_ROOT/$1.json"
  python3 - "$f" "$2" "$3" "$4" "$5" "${6:-none}" <<'PY'
import json, sys
from datetime import datetime, timezone
f, five_pct, seven_pct, five_used, seven_status, five_pace = sys.argv[1:]
gen = datetime(2026, 9, 14, 12, 0, tzinfo=timezone.utc).isoformat().replace("+00:00", "Z")
five = {"id": "five_hour", "kind": "session", "percentRemaining": float(five_pct)}
if five_used != "omit":
    five["percentUsed"] = float(five_used)
if five_pace != "none":
    five["pace"] = {"status": five_pace}
seven = {"id": "seven_day", "kind": "weekly",
         "resetsAt": "2026-09-18T12:00:00Z",
         "percentRemaining": float(seven_pct),
         "pace": {"status": seven_status, "burnMultiple": 0.8}}
doc = {"generatedAt": gen, "schemaVersion": 5,
       "providers": [{"provider": "claude", "state": {"status": "fresh"},
                      "windows": [five, seven]}]}
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
assert_contains "$out" "claude_reading: available" "a healthy reading is reported available, got: $out"
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

# 9. Projected exhaustion materially before the reset caps new lanes at 0.
# 89% left with the projection an hour before the reset is the 2026-11-19 case
# the old 25% row could not see. The projection is reported as an estimate.
out=$(run_cap "$home" "$(quota_doc projected 89 4 behind 0.8 behind '' '' 3 '' '' established)") || fail "projected-exhaustion quota must succeed"
assert_contains "$out" "claude_runway_cap: 0" "a projection before the reset caps at 0, got: $out"
assert_contains "$out" "claude_runway_block: yes" "cap 0 blocks a new lane, got: $out"
assert_contains "$out" "effective_cap: 0" "the runway cap is folded into the effective cap, got: $out"
assert_contains "$out" "est. exhaustion" "the reason labels the projection as an estimate, got: $out"
assert_contains "$out" "claude_exhaustion_estimate: est. 2026-09-14T15:00:00+00:00" "the forecast line is labelled est., got: $out"
assert_contains "$out" "claude_five_hour_percent_remaining: 89" "the five-hour fact is printed, got: $out"
assert_contains "$out" "claude_five_hour_resets_at: 2026-09-14T16:00:00+00:00" "the five-hour reset fact is printed, got: $out"
assert_contains "$out" "claude_seven_day_percent_remaining: 80" "the weekly fact is printed, got: $out"
assert_contains "$out" "claude_read_at: 2026-09-14T12:00:00+00:00" "the read time is printed, got: $out"

# 9a. An account burning exactly on pace projects exhaustion at the reset and
# must keep the base cap: on-pace spend rides out the window.
out=$(run_cap "$home" "$(quota_doc on-pace 83 4 behind 0.8 behind '' '' 4.05 '' '' established)") || fail "on-pace projection must succeed"
assert_contains "$out" "claude_runway_cap: none" "an on-pace projection at the reset does not block, got: $out"
assert_contains "$out" "claude_runway_block: no" "an on-pace lane is admitted, got: $out"
assert_contains "$out" "effective_cap: 3" "on-pace spend keeps the base cap, got: $out"
assert_contains "$out" "claude_runway_reason: healthy: 83% left, est. exhaustion" "the on-pace readout keeps the facts and labels the forecast, got: $out"

# 9b. A projection after the reset is not projected exhaustion.
out=$(run_cap "$home" "$(quota_doc projected-late 89 4 behind 0.8 behind '' '' 5 '' '' established)") || fail "late projection must succeed"
assert_contains "$out" "claude_runway_cap: none" "a projection after the reset leaves the account healthy, got: $out"
assert_contains "$out" "claude_runway_block: no" "a healthy projection admits a lane, got: $out"

# 9c. A projection exactly at resetsAt - 20m is not strictly before it.
out=$(run_cap "$home" "$(quota_doc projected-edge 89 4 behind 0.8 behind '' '' 3.6666666666666665 '' '' established)") || fail "edge projection must succeed"
assert_contains "$out" "claude_runway_cap: none" "a projection at the reset-20m boundary is not early, got: $out"

# 9d. A projection flagged early swings by hours and is never used, even when
# it lands far before the reset.
out=$(run_cap "$home" "$(quota_doc projected-early 89 4 behind 0.8 behind '' '' 1 '' '' early)") || fail "early projection must succeed"
assert_contains "$out" "claude_runway_cap: none" "an early projection does not block, got: $out"
assert_contains "$out" "claude_runway_block: no" "an early projection admits a lane, got: $out"
assert_contains "$out" "effective_cap: 3" "an early projection keeps the base cap, got: $out"
assert_contains "$out" "claude_exhaustion_estimate: -" "the early projection is omitted from the forecast line, got: $out"
assert_contains "$out" "projection omitted (early)" "the reason says the early projection is omitted, got: $out"

# 9e. A document carrying early confidence only on the five_hour-bound runway
# still omits the projection; read time prefers state.refreshedAt.
python3 - "$TMP_ROOT/projected-early.json" "$TMP_ROOT/runway-early.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
c = d["providers"][0]
del c["windows"][0]["pace"]["projectionConfidence"]
c["state"]["refreshedAt"] = "2026-09-14T11:00:00Z"
c["quotaSemantics"] = {"effectiveAvailability": [
    {"scope": "all_models", "runway": {"limitingWindowIds": ["five_hour"], "projectionConfidence": "early"}}]}
json.dump(d, open(sys.argv[2], "w"))
PY
out=$(run_cap "$home" "$TMP_ROOT/runway-early.json") || fail "runway-early must succeed"
assert_contains "$out" "claude_runway_cap: none" "runway-carried early confidence does not block, got: $out"
assert_contains "$out" "claude_exhaustion_estimate: -" "runway-carried early projection is omitted, got: $out"
assert_contains "$out" "claude_read_at: 2026-09-14T11:00:00+00:00" "read time prefers refreshedAt, got: $out"

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
assert_contains "$out" "claude_reading: unavailable" "an unavailable reading is reported unavailable, got: $out"
assert_contains "$out" "claude_runway_cap: 1" "an unavailable reading is tight, got: $out"
assert_contains "$out" "quota reading unavailable" "the reason discloses the unavailable reading, got: $out"
assert_contains "$out" "effective_cap: 1" "an unavailable reading tightens the effective cap, got: $out"
mk_lane "$home" other-4 claude ship ordinary
out=$(run_cap "$home" "$(quota_doc auth2 80 4 behind 0.8 behind '' '' '' '' auth_required)") || fail "auth_required with a lane must report: $out"
assert_contains "$out" "claude_runway_block: yes" "an unavailable reading blocks a second lane, got: $out"
rm -f "$home/state/other-4.meta"

# 10c. A record with a recorded PR handoff is no longer an implementing lane.
pr_home=$(mk_home pr-handoff)
mk_lane "$pr_home" done-1 claude ship ordinary
printf 'pr=https://example.test/pr/1\n' >> "$pr_home/state/done-1.meta"
out=$(run_cap "$pr_home" "$tight") || fail "pr handoff count must succeed: $out"
assert_contains "$out" "claude_lanes: 0" "a record with pr= is not counted, got: $out"
assert_contains "$out" "claude_runway_block: no" "a handed-off lane does not block a new one, got: $out"

# 11a. A fixture row that is rate limited with no five_hour window is tight, not a refusal.
rl_doc=$(mktemp)
printf '%s' '{"schemaVersion":5,"providers":[{"provider":"claude","state":{"status":"rate_limited"},"windows":[]}]}' > "$rl_doc"
out=$(run_cap "$home" "$rl_doc") || fail "rate_limited fixture without windows must not refuse: $out"
assert_contains "$out" "claude_runway_cap: 1" "rate-limited fixture is tight, got: $out"
rm -f "$rl_doc"

# 11b. A live run whose configured account is unreadable still reads as tight.
missing_home=$(mk_home missing-account)
printf '/definitely/not/a/claude/root\n' > "$missing_home/config/claude-account"
run_cap "$missing_home" "$(quota_doc missing 80 4 behind 0.8 behind)" >/dev/null 2>&1
[ $? -eq 2 ] || fail "an invalid config/claude-account must refuse rather than guess an account"

# 12. Several declared accounts (config/claude-accounts): every entry is
# evaluated separately and the effective cap sums them under the base cap.
# snap_line <account> <quota-doc> prints one --snapshots line.
snap_line() {
  python3 -c 'import json,sys; print(json.dumps({"account": sys.argv[1], "root": sys.argv[1], "snapshot": json.load(open(sys.argv[2]))}))' "$1" "$2"
}
multi_home=$(mk_home multi)
snaps="$TMP_ROOT/multi.jsonl"
{
  snap_line /acct/one "$(quota_doc multi-exhausted 0 4 behind 0.8 behind exhausted_now 2.0)"
  snap_line /acct/two "$(quota_doc multi-healthy 80 4 behind 0.8 behind)"
} > "$snaps"

# 12a. One exhausted and one healthy account: capacity stays open and names
# the healthy account, while the exhausted one reports cap 0.
out=$(FM_HOME="$multi_home" "$HELPER" --accounts-jsonl "$snaps") || fail "multi-account evaluation must succeed: $out"
assert_contains "$out" "effective_cap: 3" "a healthy second account keeps the base cap open, got: $out"
assert_contains "$out" "claude_accounts: 2" "both declared accounts are reported, got: $out"
assert_contains "$out" "claude_headroom_accounts: /acct/two" "the healthy account is named as headroom, got: $out"
assert_contains "$out" "claude_account_row: /acct/one  cap=0  lanes=0  runway_cap=0  runway_block=yes" "the exhausted account caps at 0, got: $out"
assert_contains "$out" "claude_account_row: /acct/two  cap=3  lanes=0  runway_cap=none  runway_block=no" "the healthy account keeps the base cap, got: $out"
assert_not_contains "$out" "claude_runway_block:" "the single-account lines are not printed for several accounts, got: $out"

# 12b. Lanes count per account, and the sum never exceeds the base cap.
{
  snap_line /acct/one "$(quota_doc multi-low 30 4 behind 0.8 behind)"
  snap_line /acct/two "$(quota_doc multi-healthy2 80 4 behind 0.8 behind)"
} > "$TMP_ROOT/multi-low.jsonl"
mk_lane "$multi_home" lane-one claude ship /acct/one
out=$(FM_HOME="$multi_home" "$HELPER" --accounts-jsonl "$TMP_ROOT/multi-low.jsonl") || fail "multi-account lanes must succeed: $out"
assert_contains "$out" "effective_cap: 3" "1 + 3 is held to the base cap of 3, got: $out"
assert_contains "$out" "claude_account_row: /acct/one  cap=1  lanes=1  runway_cap=1  runway_block=yes" "the under-40% account is full with its one lane, got: $out"
assert_contains "$out" "claude_headroom_accounts: /acct/two" "only the account with a free slot is headroom, got: $out"
rm -f "$multi_home/state/lane-one.meta"

# 12c. An account whose read failed is tight, never headroom and never a refusal.
{
  snap_line /acct/one "$(quota_doc multi-exhausted2 0 4 behind 0.8 behind exhausted_now 2.0)"
  printf '%s\n' '{"account":"/acct/two","root":"/acct/two","error":"quota-axi could not read this account"}'
} > "$TMP_ROOT/multi-error.jsonl"
out=$(FM_HOME="$multi_home" "$HELPER" --accounts-jsonl "$TMP_ROOT/multi-error.jsonl") || fail "a failed account read must not refuse: $out"
assert_contains "$out" "effective_cap: 1" "an exhausted plus an unread account caps at 1, got: $out"
assert_contains "$out" "claude_account_row: /acct/two  cap=1  lanes=0  runway_cap=1  runway_block=no  reading=unavailable" "the unread account is tight, got: $out"

# 12d. The live path reads config/claude-accounts through
# bin/fm-claude-account-quota.sh, one isolated read per declared root.
live_home=$(mk_home multi-live)
fakebin="$TMP_ROOT/multi-fakebin"
mkdir -p "$fakebin" "$TMP_ROOT/root-one" "$TMP_ROOT/root-two"
# live_root <doc> <dest>: a real profile-only read carries quotaSemantics,
# which bin/fm-claude-account-quota.sh validates, so the fixture does too.
live_root() {
  python3 - "$1" "$2" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["providers"] = [p for p in doc["providers"] if p["provider"] == "claude"]
for p in doc["providers"]:
    pct = p["windows"][0]["percentRemaining"]
    p["quotaSemantics"] = {"status": "known", "effectiveAvailability": [
        {"scope": "all_models", "status": "known", "effectivePercentRemaining": pct,
         "runway": {"status": "exhausted_now" if pct <= 0 else "through_reset"}}]}
json.dump(doc, open(sys.argv[2], "w"))
PY
}
live_root "$(quota_doc live-exhausted 0 4 behind 0.8 behind exhausted_now 2.0)" "$TMP_ROOT/root-one/quota.json"
live_root "$(quota_doc live-healthy 71 4 behind 0.8 behind)" "$TMP_ROOT/root-two/quota.json"
cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
case " $* " in *" --provider codex "*) exit 1 ;; esac
[ -f "${CLAUDE_CONFIG_DIR:-/nonexistent}/quota.json" ] || exit 1
cat "$CLAUDE_CONFIG_DIR/quota.json"
SH
chmod +x "$fakebin/quota-axi"
printf '%s\n%s\n' "$TMP_ROOT/root-one" "$TMP_ROOT/root-two" > "$live_home/config/claude-accounts"
out=$(PATH="$fakebin:$PATH" FM_HOME="$live_home" "$HELPER") || fail "the live multi-account read must succeed: $out"
assert_contains "$out" "effective_cap: 3" "the live healthy account keeps capacity open, got: $out"
assert_contains "$out" "claude_headroom_accounts: $TMP_ROOT/root-two" "the live healthy account is named, got: $out"
assert_contains "$out" "claude_account_row: $TMP_ROOT/root-two  cap=3  lanes=0  runway_cap=none  runway_block=no  reading=available  five_hour_percent_remaining=71" "the live healthy row carries its own reading, got: $out"

# 12e. An explicit --claude-account still evaluates that one account, as
# bin/fm-spawn.sh and bin/fm-claude-runway-admit.sh call it.
out=$(PATH="$fakebin:$PATH" FM_HOME="$live_home" "$HELPER" --claude-account "$TMP_ROOT/root-one") || fail "an explicit account must succeed: $out"
assert_contains "$out" "claude_account: $TMP_ROOT/root-one" "an explicit account stays single-account, got: $out"
assert_contains "$out" "claude_runway_block: yes" "the explicit exhausted account blocks, got: $out"
assert_not_contains "$out" "claude_accounts:" "an explicit account prints no multi-account lines, got: $out"

# 12f. The list together with the single pin refuses, as every launch does.
printf 'ordinary\n' > "$live_home/config/claude-account"
PATH="$fakebin:$PATH" FM_HOME="$live_home" "$HELPER" >/dev/null 2>&1
[ $? -eq 2 ] || fail "config/claude-accounts with config/claude-account must refuse"

# 12g. No list: the output keys are exactly the single-account set, unchanged.
out=$(run_cap "$home" "$(quota_doc nolist 80 4 behind 0.8 behind)") || fail "list-less home must succeed: $out"
keys=$(printf '%s\n' "$out" | sed 's/:.*//' | tr '\n' ' ')
[ "$keys" = "effective_cap codex_spawn claude_pace claude_account claude_reading claude_five_hour_percent_remaining claude_five_hour_resets_at claude_seven_day_percent_remaining claude_seven_day_resets_at claude_read_at claude_exhaustion_estimate claude_lanes claude_runway_cap claude_runway_block claude_runway_reason " ] \
  || fail "a home with no list keeps the single-account output, got keys: $keys"

# 13. A fresh account whose five_hour countdown has not started reports 100%
# with no reset; a readable, healthy week makes that full headroom, not an
# unreadable reading. This is the account #2 refusal the rule must not repeat.
out=$(run_cap "$home" "$(fresh_doc unstarted 100 80 omit behind)") || fail "unstarted five-hour window must succeed: $out"
assert_contains "$out" "claude_reading: available" "an unstarted five-hour window is a real reading, got: $out"
assert_contains "$out" "claude_five_hour_resets_at: -" "the unstarted window has no reset fact, got: $out"
assert_contains "$out" "claude_runway_cap: none" "an unstarted five-hour window is full headroom, got: $out"
assert_contains "$out" "claude_runway_block: no" "an unstarted five-hour window admits a lane, got: $out"
assert_contains "$out" "effective_cap: 3" "an unstarted window does not tighten the base cap, got: $out"
assert_contains "$out" "five-hour window not started" "the reason names the not-yet-started window, got: $out"

# 13a. quota-axi may publish an explicit zero percentUsed instead of omitting it.
out=$(run_cap "$home" "$(fresh_doc unstarted-zero 100 80 0 behind)") || fail "explicit zero usage must succeed: $out"
assert_contains "$out" "claude_runway_cap: none" "explicit zero usage is still an unstarted window, got: $out"
assert_contains "$out" "claude_runway_block: no" "explicit zero usage admits a lane, got: $out"

# 13b. The week is the only bound that can refuse while the five-hour window
# has not started; an exhausted week blocks even the first lane.
out=$(run_cap "$home" "$(fresh_doc unstarted-week0 100 0 omit behind)") || fail "unstarted with exhausted week must succeed: $out"
assert_contains "$out" "claude_runway_cap: 0" "an exhausted week while unstarted blocks, got: $out"
assert_contains "$out" "claude_runway_block: yes" "the exhausted week blocks the first lane, got: $out"
assert_contains "$out" "effective_cap: 0" "the exhausted week zeroes the effective cap, got: $out"

# 13c. A missing reset with nonzero usage is a data gap, not "not yet started",
# and is refused rather than read as headroom.
run_cap "$home" "$(fresh_doc gap-reset 100 80 5 behind)" >/dev/null 2>&1
[ $? -eq 2 ] || fail "a missing reset with nonzero usage must be refused, not exempted"

# 13e. A failed fetch (provider status unavailable, no windows) stays tight.
fetch_doc=$(mktemp)
printf '%s' '{"schemaVersion":5,"providers":[{"provider":"claude","state":{"status":"unavailable"},"windows":[]}]}' > "$fetch_doc"
out=$(run_cap "$home" "$fetch_doc") || fail "a failed fetch must not refuse the gate: $out"
assert_contains "$out" "claude_reading: unavailable" "a failed fetch is unavailable, got: $out"
assert_contains "$out" "claude_runway_cap: 1" "a failed fetch stays tight, got: $out"
mk_lane "$home" fetch-1 claude ship ordinary
out=$(run_cap "$home" "$fetch_doc") || fail "a failed fetch with a lane must report: $out"
assert_contains "$out" "claude_runway_block: yes" "a failed fetch blocks a new lane, got: $out"
rm -f "$fetch_doc" "$home/state/fetch-1.meta"

pass "fm-dispatch-quota-cap.sh: quota ladder, per-account runway, and Codex pace gate"
