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
#     marks a row stale; editing priority alone does not; a same-length edit
#     past the list-truncation point still marks it stale
#   - tier-escalation fixture: escalate only moves up, refuses with no
#     existing row, and appends a ledger line
#   - reconciliation fixture: gc removes a row and appends a closed ledger
#     line so a reused id never inherits a stale classification
#   - seed-from-report: parses the report's per-section tables, layers the
#     Codex-as-paced-sidecar roster onto the class rosters as sidecar=codex,
#     skips ids tasks-axi does not know about, and never re-classifies an
#     already classified row
#   - a tasks-axi read that fails outright is refused (exit 2), never
#     reported as stale
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

# 4b. Routing-digest fixture, past the truncation point: `tasks-axi list`
#     truncates title/body at ~150 chars, so a digest built from a list read
#     cannot see an edit made beyond the cut. Edit one character ~400 chars
#     into a long body, keeping the total length identical, and require the
#     row to read stale.
(cd "$home" && tasks-axi add item-long "long bodied item" --kind ship --repo demo >/dev/null)
long_prefix=$(printf 'A%.0s' $(seq 1 400))
(cd "$home" && tasks-axi update item-long --body "${long_prefix}ORIGINAL-TAIL" >/dev/null) \
  || fail "test setup: could not give item-long a long body"
run_routing "$home" set item-long pc02 || fail "set item-long should succeed"
out=$(run_routing "$home" get item-long)
assert_contains "$out" "present: pc02" "a long-bodied item classifies as present before any edit"
(cd "$home" && tasks-axi update item-long --body "${long_prefix}REPLACED-TAIL" >/dev/null) \
  || fail "test setup: could not edit item-long's body tail"
out=$(run_routing "$home" get item-long)
assert_contains "$out" "stale: pc02" \
  "a same-length edit past the list-truncation point must still invalidate the routing row"

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

# 6b. A gc that cannot take the registry lock must archive nothing: an
#     abandoned "closed" line would be counted again when the next heartbeat
#     retries the gc, over-reporting the reconciliation metric.
run_routing "$home" set item-c pc02 >/dev/null
ledger_before=$(wc -l < "$home/data/routing-ledger.tsv")
mkdir "$home/data/.backlog-routing.lock"
run_routing "$home" gc item-c 2>/dev/null; rc=$?
rmdir "$home/data/.backlog-routing.lock"
[ "$rc" -eq 2 ] || fail "gc must exit 2 when the registry lock is held, got $rc"
ledger_after=$(wc -l < "$home/data/routing-ledger.tsv")
[ "$ledger_before" -eq "$ledger_after" ] \
  || fail "a gc that could not remove the row must not have appended a closed ledger line"
assert_contains "$(run_routing "$home" list --class pc02)" "item-c" \
  "the row survives a gc that could not take the registry lock"
run_routing "$home" gc item-c || fail "the retried gc should succeed once the lock is free"
assert_grep "closed	item-c	pc02" "$home/data/routing-ledger.tsv" \
  "the retried gc appends exactly the one closed line"
[ "$(grep -c "closed	item-c	pc02" "$home/data/routing-ledger.tsv")" -eq 1 ] \
  || fail "item-c must be archived exactly once across the failed and retried gc"

# 6c. An existing-but-unreadable registry is a refusal, never an empty or
#     absent one: answering "absent" would make the /autonomous pass
#     re-classify curated rows, and rewriting from an unreadable file would
#     replace the whole registry with the single row being written.
if [ "$(id -u)" -ne 0 ]; then
  unread_home=$(make_home unreadable)
  (cd "$unread_home" && tasks-axi add keep-a "first" --kind ship --repo demo >/dev/null)
  (cd "$unread_home" && tasks-axi add keep-b "second" --kind ship --repo demo >/dev/null)
  (cd "$unread_home" && tasks-axi add keep-c "third" --kind ship --repo demo >/dev/null)
  run_routing "$unread_home" set keep-a pc02 >/dev/null
  run_routing "$unread_home" set keep-b medium >/dev/null
  registry="$unread_home/data/backlog-routing.tsv"
  chmod 000 "$registry"

  run_routing "$unread_home" set keep-c pc02 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "set against an unreadable registry must exit 2, got $rc"

  out=$(run_routing "$unread_home" get keep-a 2>/dev/null); rc=$?
  [ "$rc" -eq 2 ] || fail "get against an unreadable registry must exit 2, got $rc"
  assert_not_contains "$out" "absent" "an unreadable registry must never be reported as an absent row"

  run_routing "$unread_home" gc keep-a >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "gc against an unreadable registry must exit 2, got $rc"

  run_routing "$unread_home" list >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "list against an unreadable registry must exit 2, got $rc"

  chmod 644 "$registry"
  listed=$(run_routing "$unread_home" list)
  assert_contains "$listed" "keep-a" "the pre-existing rows survive every refused command"
  assert_contains "$listed" "keep-b" "the pre-existing rows survive every refused command"
  assert_not_contains "$listed" "keep-c" "the refused set wrote nothing"
fi

# 6d. A tasks-axi read that fails outright is a refusal (exit 2), never a
#     "stale" verdict: `stale:` would drop every PC02 candidate from
#     fm-pc02-fair-order.sh silently and send curated rows to routing
#     review. NOT_FOUND (the item left the backlog) still reads stale.
shim_dir="$TMP_ROOT/shim"
mkdir -p "$shim_dir"
real_tasks_axi=$(command -v tasks-axi)
cat > "$shim_dir/tasks-axi" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = show ]; then
  case "\${FM_TEST_SHOW_MODE:-}" in
    crash) echo "boom" >&2; exit 1 ;;
    notfound) printf 'error: "Task not found"\ncode: NOT_FOUND\n'; exit 1 ;;
  esac
fi
exec "$real_tasks_axi" "\$@"
EOF
chmod +x "$shim_dir/tasks-axi"
run_routing "$home" set item-b pc02 >/dev/null
out=$(PATH="$shim_dir:$PATH" FM_TEST_SHOW_MODE=crash run_routing "$home" get item-b 2>/dev/null); rc=$?
[ "$rc" -eq 2 ] || fail "get must exit 2 when tasks-axi show fails outright, got $rc: $out"
assert_not_contains "$out" "stale" "a failed tasks-axi read must never be reported as stale"
PATH="$shim_dir:$PATH" FM_TEST_SHOW_MODE=crash run_routing "$home" set item-b pc02 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "set must exit 2 when tasks-axi show fails outright, got $rc"
out=$(PATH="$shim_dir:$PATH" FM_TEST_SHOW_MODE=notfound run_routing "$home" get item-b); rc=$?
[ "$rc" -eq 0 ] || fail "get on an item tasks-axi no longer knows must exit 0, got $rc"
assert_contains "$out" "stale: pc02" "an item that left the backlog reads stale, not refused"

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
(cd "$seed_home" && tasks-axi add seed-codex-only "known codex-only item" --kind ship --repo demo >/dev/null)
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

#### Codex-as-paced-sidecar roster

| Item | Why Codex sidecar | Gate |
|---|---|---|
| `seed-medium-item` | Medium-class, Codex runtime familiarity useful. | D |
| `seed-codex-only` | Medium-class, listed only here. | D |
| `seed-senior-item` | Senior-class only if selected; never downgrade its class. | D; also listed senior |
EOF
out=$(run_routing "$seed_home" seed-from-report "$fixture_report") || fail "seed-from-report should succeed"
assert_contains "$out" "seeded: 6" "seed-from-report seeds 3 class rows plus 3 sidecar annotations"
assert_contains "$out" "skipped: 1" "seed-from-report skips the 1 unknown id"
assert_contains "$(run_routing "$seed_home" get seed-pc02-item)" "present: pc02 -" "pc02 section seeds class pc02 with no sidecar"
assert_contains "$(run_routing "$seed_home" get seed-medium-item)" "present: medium codex" "the Codex roster adds sidecar=codex without changing the medium class"
assert_contains "$(run_routing "$seed_home" get seed-senior-item)" "present: senior codex" "a cross-referenced senior row keeps senior and gains the sidecar"
assert_contains "$(run_routing "$seed_home" get seed-codex-only)" "present: medium codex" "an id listed only in the Codex roster seeds as medium with sidecar=codex"

# Re-running the seed must not touch an already-classified row (it would
# have re-classified item silently otherwise, corrupting a curated class).
run_routing "$seed_home" set seed-pc02-item senior --purpose "manually corrected" >/dev/null
out=$(run_routing "$seed_home" seed-from-report "$fixture_report") || fail "re-seed should succeed"
assert_contains "$out" "seeded: 0" "re-seed re-classifies nothing: every known id is already classified"
assert_contains "$(run_routing "$seed_home" get seed-pc02-item)" "present: senior" "already-classified row survives re-seeding unchanged"
assert_contains "$(run_routing "$seed_home" list --class medium)" "seed-medium-item	medium	codex" \
  "re-seeding leaves an already-annotated sidecar row untouched"

pass "fm-backlog-routing.sh behavior"
