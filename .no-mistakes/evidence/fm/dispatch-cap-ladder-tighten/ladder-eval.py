#!/usr/bin/env python3
"""Executable model of the dispatch-cap quota ladder as documented in
docs/configuration.md > "Concurrent autonomous dispatch cap and quota ladder"
(captain ruling 2026-09-02). Effective cap = tightest cap any applicable row yields."""
import json, sys
from datetime import datetime, timezone

def parse(ts): return datetime.fromisoformat(ts.replace("Z", "+00:00"))

def effective_cap(snap, base=3):
    p = {w["id"]: w for w in snap["providers"][0]["windows"]}
    fh, wk = p["five_hour"], p["seven_day"]
    gen = parse(snap["generatedAt"])
    caps, why = [base], ["base cap %d" % base]

    # percent-remaining dimension
    if fh["percentRemaining"] <= 15:
        caps.append(1); why.append("percentRemaining %d <= 15 -> cap 1" % fh["percentRemaining"])
    elif fh["percentRemaining"] < 25 or (wk["pace"]["status"] == "ahead" and wk["pace"]["burnMultiple"] > 1.5):
        caps.append(2); why.append("percentRemaining < 25 or weekly ahead-of-pace burn > 1.5 -> cap 2")
    else:
        why.append("percentRemaining %d >= 25, no weekly pressure -> base cap" % fh["percentRemaining"])

    # elapsed-time-in-window dimension: derived from remaining time to resetsAt
    hrs_left = (parse(fh["resetsAt"]) - gen).total_seconds() / 3600.0
    if hrs_left >= 2.5:
        caps.append(3); why.append("%.2fh left >= 2.5h -> at/before 2.5h mark -> ceiling 3 (2-3 sessions)" % hrs_left)
    else:
        caps.append(2); why.append("%.2fh left < 2.5h -> past 2.5h mark -> ceiling 2 (1-2 sessions)" % hrs_left)

    return min(caps), why

def snap(pct, hrs_left, weekly_pct=52, burn=1.0, status="behind"):
    gen = datetime(2026, 9, 8, 12, 0, tzinfo=timezone.utc)
    return {"generatedAt": gen.isoformat().replace("+00:00", "Z"), "schemaVersion": 5, "providers": [{"windows": [
        {"id": "five_hour", "resetsAt": (gen.timestamp() + hrs_left * 3600) and
         datetime.fromtimestamp(gen.timestamp() + hrs_left * 3600, timezone.utc).isoformat(),
         "percentRemaining": pct, "pace": {"status": "behind", "burnMultiple": 1.0}},
        {"id": "seven_day", "resetsAt": gen.isoformat(), "percentRemaining": weekly_pct,
         "pace": {"status": status, "burnMultiple": burn}}]}]}

CASES = [
    ("fresh window, 0.5h in (4.5h left), plenty of quota", snap(82, 4.5), 3),
    ("exactly at the 2.5h mark (2.5h left)",               snap(82, 2.5), 3),
    ("just past the 2.5h mark (2.49h left)",               snap(82, 2.49), 2),
    ("late window, 0.5h left",                            snap(82, 0.5), 2),
    ("early window but percentRemaining 16 (old floor)",   snap(16, 4.5), 2),
    ("early window, percentRemaining 15 (NEW <=15 floor)", snap(15, 4.5), 1),
    ("early window, percentRemaining 10 (old <10 floor)",  snap(10, 4.5), 1),
    ("weekly ahead-of-pace burn 2.3, early window",        snap(82, 4.5, burn=2.34, status="ahead"), 2),
]

fail = 0
print("=== Documented dispatch-cap ladder, evaluated (base cap 3) ===\n")
for name, s, expected in CASES:
    got, why = effective_cap(s)
    ok = got == expected
    fail += not ok
    print(f"[{'OK ' if ok else 'FAIL'}] {name}\n        effective cap = {got} (expected {expected})")
    for w in why: print(f"          - {w}")
    print()

live = json.load(open(sys.argv[1])) if len(sys.argv) > 1 else None
if live:
    got, why = effective_cap(live)
    print("=== Live quota-axi --json snapshot ===")
    print(f"  generatedAt {live['generatedAt']}  ->  effective cap = {got}")
    for w in why: print(f"    - {w}")
sys.exit(1 if fail else 0)
