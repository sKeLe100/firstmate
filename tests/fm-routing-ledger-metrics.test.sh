#!/usr/bin/env bash
# tests/fm-routing-ledger-metrics.test.sh - behavior tests for
# bin/fm-routing-ledger-metrics.sh, the ledger-metric test seam named in
# data/backlog-triage-durable-plan/report.md's test seams list.
#
# Drives the real bin/fm-backlog-routing.sh to produce ledger events (never
# hand-writes the ledger file), then verifies opened/closed/reopened/
# gross-per-day/net-per-day/median-cycle-time reconcile to those raw
# transitions, and that pc02_idle_pct reports "unavailable" without
# --occupancy and a real percentage with one, and that an unusable --since
# or --occupancy argument is refused with exit 2.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTING="$ROOT/bin/fm-backlog-routing.sh"
METRICS="$ROOT/bin/fm-routing-ledger-metrics.sh"
TMP_ROOT=$(fm_test_tmproot fm-routing-ledger-metrics)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  printf '%s\n' "$home"
}

# 1. Empty/absent ledger reports all-zero counts and "unavailable" rates
#    rather than erroring.
home=$(make_home empty)
out=$(FM_HOME="$home" "$METRICS") || fail "metrics must succeed on an absent ledger"
assert_contains "$out" "opened: 0" "absent ledger reports opened: 0"
assert_contains "$out" "median_cycle_time_seconds: unavailable" "absent ledger reports unavailable median cycle time"
assert_contains "$out" "pc02_idle_pct: unavailable" "no --occupancy given reports unavailable idle pct"
assert_contains "$out" "gross_per_day: unavailable" "an absent ledger has no observed window, so no rate"
assert_contains "$out" "net_per_day: unavailable" "an absent ledger has no observed window, so no rate"

# 2. opened/closed/reopened reconcile to raw classified/closed transitions,
#    including a reopen (classified again after a prior close).
home=$(make_home transitions)
(cd "$home" && tasks-axi add item-a "a" --kind ship --repo demo >/dev/null)
(cd "$home" && tasks-axi add item-b "b" --kind ship --repo demo >/dev/null)
FM_HOME="$home" "$ROUTING" set item-a pc02 >/dev/null
FM_HOME="$home" "$ROUTING" set item-b pc02 >/dev/null
FM_HOME="$home" "$ROUTING" gc item-a >/dev/null
FM_HOME="$home" "$ROUTING" set item-a pc02 >/dev/null   # reopened
out=$(FM_HOME="$home" "$METRICS") || fail "metrics should succeed"
assert_contains "$out" "opened: 2" "2 ids entered the registry (item-a, item-b)"
assert_contains "$out" "closed: 1" "1 closed event"
assert_contains "$out" "reopened: 1" "item-a's second classification counts as reopened"

# 2b. Re-writing a row that is still open (correcting its purpose) is not a
#     new entry into the registry: opened counts ids, not writes.
FM_HOME="$home" "$ROUTING" set item-b pc02 --purpose "corrected" >/dev/null
out=$(FM_HOME="$home" "$METRICS") || fail "metrics should succeed after a corrective re-set"
assert_contains "$out" "opened: 2" "re-classifying an already-open row must not raise opened"
assert_contains "$out" "reopened: 1" "a corrective re-set of an open row is not a reopen"

# 2c. net_per_day counts every arrival into the registry, first or repeat:
#     over a fixed one-day window with 2 first entries, 1 reopen and 1 close,
#     net inflow is +2, so the net rate is -2.00 per day.
home=$(make_home net-rate)
now=$(date -u +%s)
since=$((now - 86400))
cat > "$home/data/routing-ledger.tsv" <<EOF
$since	classified	net-a	pc02
$since	classified	net-b	pc02
$((now - 43200))	closed	net-a	pc02
$((now - 43200))	classified	net-a	pc02
EOF
out=$(FM_HOME="$home" "$METRICS" --since "$since") || fail "metrics should succeed over a fixed window"
assert_contains "$out" "opened: 2" "two ids entered the registry"
assert_contains "$out" "reopened: 1" "net-a re-entered after its close"
assert_contains "$out" "gross_per_day: 1.00" "one close over a one-day window"
assert_contains "$out" "net_per_day: -2.00" \
  "a reopen is an arrival: net must be (closed - opened - reopened) per day, got: $out"

# 2d. --since counts only events inside the window but judges each id
#     against its whole history: a corrective re-set inside the window of
#     an id classified before it is neither opened nor reopened, and a
#     re-entry inside the window after a close before it is a reopen.
home=$(make_home carry-over)
now=$(date -u +%s)
since=$((now - 7 * 86400))
cat > "$home/data/routing-ledger.tsv" <<EOF
$((now - 10 * 86400))	classified	carry-a	pc02
$((now - 10 * 86400))	classified	carry-b	pc02
$((now - 9 * 86400))	closed	carry-b	pc02
$((now - 86400))	classified	carry-a	pc02
$((now - 86400))	classified	carry-b	pc02
$((now - 3600))	classified	carry-c	pc02
EOF
out=$(FM_HOME="$home" "$METRICS" --since "$since") || fail "metrics should succeed with carry-over history"
assert_contains "$out" "opened: 1" "only carry-c first entered the registry inside the window, got: $out"
assert_contains "$out" "reopened: 1" "carry-b re-entered inside the window after a close before it, got: $out"
assert_contains "$out" "closed: 0" "the close before the window is not counted, got: $out"

# 3. Median cycle time reconciles to the actual epoch delta between an id's
#    first classified event and its closed event, using an injected ledger
#    with controlled timestamps (the routing script's own epoch_now has
#    second granularity, too coarse to assert an exact delta from real
#    calls a few tests apart).
home=$(make_home cycle-time)
mkdir -p "$home/data"
now=$(date -u +%s)
cat > "$home/data/routing-ledger.tsv" <<EOF
$((now - 300))	classified	cyc-a	pc02
$((now - 100))	closed	cyc-a	pc02
$((now - 600))	classified	cyc-b	pc02
$((now - 200))	closed	cyc-b	pc02
EOF
out=$(FM_HOME="$home" "$METRICS") || fail "metrics should succeed on an injected ledger"
# cyc-a: 200s, cyc-b: 400s -> median 300
assert_contains "$out" "median_cycle_time_seconds: 300" "median cycle time reconciles to the injected deltas: $out"

# 4. pc02_idle_pct reflects an --occupancy samples file.
occ_file="$TMP_ROOT/occupancy.tsv"
cat > "$occ_file" <<'EOF'
1000 free
1001 free
1002 occupied
1003 free
EOF
out=$(FM_HOME="$home" "$METRICS" --occupancy "$occ_file") || fail "metrics with --occupancy should succeed"
assert_contains "$out" "pc02_idle_pct: 75.0" "3 of 4 samples free reconciles to 75.0%"

# 5. Unusable arguments are refused with exit 2, never silently reported as
#    "unavailable" (a typo in --occupancy would otherwise be indistinguishable
#    from omitting the flag).
if out=$(FM_HOME="$home" "$METRICS" --occupancy "$TMP_ROOT/no-such-occupancy.tsv" 2>/dev/null); then
  fail "a nonexistent --occupancy path must be refused, got: $out"
fi
FM_HOME="$home" "$METRICS" --occupancy "$TMP_ROOT/no-such-occupancy.tsv" >/dev/null 2>&1
[ $? -eq 2 ] || fail "a nonexistent --occupancy path must exit 2"

if out=$(FM_HOME="$home" "$METRICS" --since yesterday 2>/dev/null); then
  fail "a non-integer --since must be refused, got: $out"
fi
FM_HOME="$home" "$METRICS" --since yesterday >/dev/null 2>&1
[ $? -eq 2 ] || fail "a non-integer --since must exit 2 (usage error), not 1"

pass "fm-routing-ledger-metrics.sh behavior"
