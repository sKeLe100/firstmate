#!/usr/bin/env bash
# tests/fm-backlog-routing.test.sh - behavior tests for
# bin/fm-backlog-routing.sh, the durable PC02/medium/senior routing registry
# for the /autonomous pass's refill step (data/backlog-triage-durable-plan/
# report.md, captain's ruling 2026-09-08).
#
# Exercises the registry only through its executable interface against a
# real tasks-axi backlog, covering:
#   - set/get round-trip and the sidecar/risk/purpose fields
#   - routing-digest invalidation fixture: editing title/body/kind/repo
#     marks a row stale; editing priority alone does not
#   - tier-escalation fixture: escalate only moves up, refuses with no
#     existing row, and appends a ledger line
#   - reconciliation fixture: gc removes a row and appends a closed ledger
#     line so a reused id never inherits a stale classification
#   - seed-from-report: parses the report's per-section tables, skips ids
#     tasks-axi does not know about, and never re-classifies an already
#     classified row
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTING="$ROOT/bin/fm-backlog-routing.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-routing)

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

run_routing() {  # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" "$ROUTING" "$@"
}

# 1. set/get round-trip: present line carries class/sidecar/risk/purpose.
home=$(make_home basic)
(cd "$home" && tasks-axi add item-a "fix the thing" --kind ship --repo demo >/dev/null)
run_routing "$home" set item-a pc02 --sidecar codex --risk low --purpose "mechanical fix" \
  || fail "set should succeed for a known item"
out=$(run_routing "$home" get item-a) || fail "get should exit 0 for a present, fresh row"
assert_contains "$out" "present: pc02 codex low mechanical fix" "get reports the full classification"

# 2. get on an unclassified item reports absent and exits 1.
(cd "$home" && tasks-axi add item-b "another item" --kind ship --repo demo >/dev/null)
out=$(run_routing "$home" get item-b); rc=$?
[ "$rc" -eq 1 ] || fail "get on an unclassified item must exit 1, got $rc"
assert_contains "$out" "absent" "unclassified item reports absent"

# 3. set refuses an invalid class.
if run_routing "$home" set item-b bogus 2>/dev/null; then
  fail "set must refuse an invalid class"
fi

# 4. Routing-digest fixture: editing the title invalidates the row; editing
#    priority alone does not.
run_routing "$home" set item-b pc02 || fail "set item-b should succeed"
(cd "$home" && tasks-axi update item-b --title "another item RENAMED" >/dev/null) \
  || fail "test setup: could not rename item-b to exercise digest invalidation"
out=$(run_routing "$home" get item-b)
assert_contains "$out" "stale: pc02" "editing the title marks the row stale"

run_routing "$home" set item-b pc02 || fail "re-set item-b after title change"
(cd "$home" && tasks-axi update item-b --priority 3 >/dev/null) \
  || fail "test setup: could not set priority on item-b"
out=$(run_routing "$home" get item-b)
case "$out" in
  "stale:"*) fail "editing priority alone must not invalidate the routing row (source_digest excludes priority): got '$out'" ;;
esac

# 5. Tier-escalation fixture: escalate moves class up, keeps sidecar,
#    refuses a downgrade, and refuses an id with no existing row.
run_routing "$home" set item-a pc02 --sidecar codex || fail "re-set item-a"
run_routing "$home" escalate item-a medium --reason "one PC02 failure" \
  || fail "escalate should succeed moving pc02 -> medium"
out=$(run_routing "$home" get item-a)
assert_contains "$out" "present: medium codex" "escalate preserves sidecar and updates class"

if run_routing "$home" escalate item-a pc02 --reason "trying to downgrade" 2>/dev/null; then
  fail "escalate must refuse a downgrade back toward pc02"
fi

(cd "$home" && tasks-axi add item-c "never classified" --kind ship --repo demo >/dev/null)
if run_routing "$home" escalate item-c senior --reason "no prior row" 2>/dev/null; then
  fail "escalate must refuse an id with no existing routing row"
fi

# 6. Reconciliation fixture: gc removes the row and appends a closed ledger
#    line; a reused id starts unclassified again (never inherits the old row).
run_routing "$home" gc item-a || fail "gc should succeed"
out=$(run_routing "$home" get item-a); rc=$?
[ "$rc" -eq 1 ] || fail "gc'd item must read back as absent"
assert_contains "$out" "absent" "gc'd item reads absent"
assert_grep "closed	item-a	medium" "$home/data/routing-ledger.tsv" \
  "gc appends a closed ledger line carrying the pre-removal class"

# gc on an already-absent id is a no-op, not an error.
run_routing "$home" gc item-a || fail "gc on an absent row must be a no-op, not an error"

# 7. list filters by class and never validates freshness itself.
run_routing "$home" set item-b pc02 >/dev/null
run_routing "$home" set item-c senior >/dev/null
listed=$(run_routing "$home" list --class pc02)
assert_contains "$listed" "item-b" "list --class pc02 includes item-b"
assert_not_contains "$listed" "item-c" "list --class pc02 excludes a senior row"

# 8. Ledger accumulates classified/escalated/closed events in order.
assert_grep "classified	item-b" "$home/data/routing-ledger.tsv" "ledger records classified events"

# 9. seed-from-report: parses the report's per-section tables against a
#    small fixture report mirroring the real shape, skips ids tasks-axi
#    does not know, and never re-classifies an already-seeded row.
seed_home=$(make_home seed)
(cd "$seed_home" && tasks-axi add seed-pc02-item "known pc02 item" --kind ship --repo demo >/dev/null)
(cd "$seed_home" && tasks-axi add seed-medium-item "known medium item" --kind ship --repo demo >/dev/null)
(cd "$seed_home" && tasks-axi add seed-senior-item "known senior item" --kind ship --repo demo >/dev/null)
fixture_report="$TMP_ROOT/fixture-report.md"
cat > "$fixture_report" <<'EOF'
# Fixture report

#### PC02-first roster

| Item | Why this tier | Gate |
|---|---|---|
| `seed-pc02-item` | Bounded mechanical fix. | D |
| `seed-unknown-item` | Not present in this test's backlog. | D |

#### Medium / standard cloud roster

| Item | Why this tier | Gate |
|---|---|---|
| `seed-medium-item` | Ordinary bounded implementation. | D |

#### Senior roster

| Item | Why this tier | Gate |
|---|---|---|
| `seed-senior-item` | Architecture decision. | D |
EOF
out=$(run_routing "$seed_home" seed-from-report "$fixture_report") || fail "seed-from-report should succeed"
assert_contains "$out" "seeded: 3" "seed-from-report seeds exactly the 3 known ids"
assert_contains "$out" "skipped: 1" "seed-from-report skips the 1 unknown id"
assert_contains "$(run_routing "$seed_home" get seed-pc02-item)" "present: pc02" "pc02 section seeds class pc02"
assert_contains "$(run_routing "$seed_home" get seed-medium-item)" "present: medium" "medium section seeds class medium"
assert_contains "$(run_routing "$seed_home" get seed-senior-item)" "present: senior" "senior section seeds class senior"

# Re-running the seed must not touch an already-classified row (it would
# have re-classified item silently otherwise, corrupting a curated class).
run_routing "$seed_home" set seed-pc02-item senior --purpose "manually corrected" >/dev/null
out=$(run_routing "$seed_home" seed-from-report "$fixture_report") || fail "re-seed should succeed"
assert_contains "$out" "seeded: 0" "re-seed re-classifies nothing: every known id is already classified"
assert_contains "$(run_routing "$seed_home" get seed-pc02-item)" "present: senior" "already-classified row survives re-seeding unchanged"

pass "fm-backlog-routing.sh behavior"
