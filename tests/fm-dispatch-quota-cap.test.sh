#!/usr/bin/env bash
# tests/fm-dispatch-quota-cap.test.sh - the durable refill design's quota
# fixture (data/backlog-triage-durable-plan/report.md test seam 7): the
# base cap of 3 becomes 2 or 1 under the documented ladder, and a Codex
# weekly pace that is ahead yields no Codex spawn. Exercised only through
# bin/fm-dispatch-quota-cap.sh against injected quota-axi documents.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-dispatch-quota-cap.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-quota-cap)

mk_home() {  # <name>
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/config"
  printf '%s' "$h"
}

# quota_doc <name> <five_pct> <hours-until-reset> <week-status> <week-burn> <codex-status>
quota_doc() {
  local f="$TMP_ROOT/$1.json"
  python3 - "$f" "$2" "$3" "$4" "$5" "$6" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
f, five_pct, hours, wstatus, wburn, cstatus = sys.argv[1:]
gen = datetime(2026, 9, 14, 12, 0, tzinfo=timezone.utc)
resets = gen + timedelta(hours=float(hours))
doc = {
    "generatedAt": gen.isoformat().replace("+00:00", "Z"),
    "schemaVersion": 5,
    "providers": [
        {"provider": "claude", "windows": [
            {"id": "five_hour", "kind": "session", "resetsAt": resets.isoformat(),
             "percentRemaining": float(five_pct),
             "pace": {"status": "behind", "burnMultiple": 0.5}},
            {"id": "seven_day", "kind": "weekly", "percentRemaining": 80,
             "pace": {"status": wstatus, "burnMultiple": float(wburn)}},
        ]},
        {"provider": "codex", "windows": [
            {"id": "weekly", "kind": "weekly", "percentRemaining": 50,
             "pace": {"status": cstatus, "burnMultiple": 1.0}},
        ]},
    ],
}
json.dump(doc, open(f, "w"))
PY
  printf '%s' "$f"
}

run_cap() {  # <home> <doc>
  FM_HOME="$1" "$HELPER" --quota-json "$2"
}

home=$(mk_home default)

# 1. No pressure anywhere: base 3 stays 3 and Codex may spawn.
out=$(run_cap "$home" "$(quota_doc calm 80 4 behind 0.8 behind)") || fail "calm quota must succeed: $out"
assert_contains "$out" "effective_cap: 3" "no ladder row applies: base cap 3 stands, got: $out"
assert_contains "$out" "codex_spawn: yes" "Codex behind pace may spawn, got: $out"

# 2. five_hour below 25% remaining: base 3 becomes 2.
out=$(run_cap "$home" "$(quota_doc low5h 20 4 behind 0.8 behind)") || fail "low five-hour quota must succeed"
assert_contains "$out" "effective_cap: 2" "five_hour < 25% lowers the cap to 2, got: $out"

# 3. Weekly pace ahead with burnMultiple > 1.5: base 3 becomes 2.
out=$(run_cap "$home" "$(quota_doc ahead 80 4 ahead 2.4 behind)") || fail "ahead-of-pace quota must succeed"
assert_contains "$out" "effective_cap: 2" "seven_day ahead with burn > 1.5 lowers the cap to 2, got: $out"

# 3b. Weekly ahead but burnMultiple at or under 1.5 does not trip that row.
out=$(run_cap "$home" "$(quota_doc mild 80 4 ahead 1.2 behind)") || fail "mildly-ahead quota must succeed"
assert_contains "$out" "effective_cap: 3" "seven_day ahead with burn <= 1.5 leaves the cap at 3, got: $out"

# 4. five_hour at or under 15% remaining: base 3 becomes 1.
out=$(run_cap "$home" "$(quota_doc floor 15 4 behind 0.8 behind)") || fail "floor quota must succeed"
assert_contains "$out" "effective_cap: 1" "five_hour <= 15% lowers the cap to 1, got: $out"

# 5. Past the 2.5-hour mark of the window (less than 2.5h to reset): ceiling 2.
out=$(run_cap "$home" "$(quota_doc late 80 2 behind 0.8 behind)") || fail "late-window quota must succeed"
assert_contains "$out" "effective_cap: 2" "under 2.5h until resetsAt caps at 2, got: $out"

# 6. Codex weekly pace ahead yields no Codex spawn, independent of the Claude cap.
out=$(run_cap "$home" "$(quota_doc codex-ahead 80 4 behind 0.8 ahead)") || fail "codex-ahead quota must succeed"
assert_contains "$out" "effective_cap: 3" "Codex pace never changes the Claude cap, got: $out"
assert_contains "$out" "codex_spawn: no" "Codex ahead of weekly pace yields no Codex spawn, got: $out"

# 7. config/dispatch-cap is the base the ladder reduces from.
cfg_home=$(mk_home configured)
printf '2\n' > "$cfg_home/config/dispatch-cap"
out=$(run_cap "$cfg_home" "$(quota_doc cfg-calm 80 4 behind 0.8 behind)") || fail "configured base must succeed"
assert_contains "$out" "effective_cap: 2" "a configured base of 2 stands with no pressure, got: $out"
out=$(run_cap "$cfg_home" "$(quota_doc cfg-floor 10 4 behind 0.8 behind)") || fail "configured base under the floor must succeed"
assert_contains "$out" "effective_cap: 1" "the ladder still reduces a configured base of 2 to 1, got: $out"

# 8. Unmeasurable quota is refused (exit 2), never read as headroom.
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

pass "fm-dispatch-quota-cap.sh: quota ladder and Codex pace gate"
