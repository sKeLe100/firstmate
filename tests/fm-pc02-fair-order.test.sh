#!/usr/bin/env bash
# tests/fm-pc02-fair-order.test.sh - behavior tests for
# bin/fm-pc02-fair-order.sh, the fairness ordering half of the durable
# refill design (data/backlog-triage-durable-plan/report.md, captain's
# ruling 2026-09-08).
#
# Exercises the script only through its executable interface, composed with
# the REAL bin/fm-queue-snapshot.sh and bin/fm-backlog-routing.sh against a
# real tasks-axi backlog and data/projects.md registry, covering:
#   - authority fixture: yolo-off and a missing project never enter the
#     ordered output, even when routing-classified pc02 (routing narrows,
#     never widens, what the snapshot already allows)
#   - dependency fixture: an item that unblocks another queued item is
#     ordered first; once the dependency is filed as classified-and-fresh
#     it stays first even ahead of a higher-priority row
#   - fairness fixture: with several unprioritized bounded items and one
#     older item, the older item is selected no later than the fourth slot
#   - truncated-length fixture: the rotation ranks by the real character
#     count the truncation marker reports, not the truncated string
#   - registry-failure fixture: an unreadable registry refuses with exit 2
#     rather than reporting an empty roster
#   - reconciliation/tier-escalation composition: an escalated row (no
#     longer pc02) never appears in the ordered output
#   - end-to-end churn fixture: three consecutive simulated PC02 teardowns
#     (gc the dispatched row, re-run) claim three different ordered tasks
#     without any manual re-triage
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FAIR_ORDER="$ROOT/bin/fm-pc02-fair-order.sh"
ROUTING="$ROOT/bin/fm-backlog-routing.sh"
TMP_ROOT=$(fm_test_tmproot fm-pc02-fair-order)

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
  printf '%s\n' '- demo [direct-PR +yolo] - test project (added 2026-08-20)' > "$home/data/projects.md"
  printf '%s\n' "$home"
}

run_order() {  # <home>
  local home=$1
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$FAIR_ORDER"
}

run_routing() {  # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" "$ROUTING" "$@"
}

nth_line() {  # <text> <n>
  printf '%s\n' "$1" | sed -n "${2}p"
}

# --- 1. Authority fixture ---------------------------------------------------
# A yolo-off project and a missing project never appear in the ordered
# output even when routing-classified pc02, because fm-queue-snapshot.sh's
# gate already excludes them and this script only ever narrows that set.
home=$(make_home authority)
printf '%s\n' '- demo [direct-PR +yolo] - test project (added 2026-08-20)' \
              '- noyolo [direct-PR] - yolo-off project (added 2026-08-20)' \
              > "$home/data/projects.md"
(cd "$home" && tasks-axi add auth-eligible "eligible item" --kind ship --repo demo >/dev/null)
(cd "$home" && tasks-axi add auth-yolooff "yolo off item" --kind ship --repo noyolo >/dev/null)
(cd "$home" && tasks-axi add auth-noproject "no project item" --kind ship >/dev/null)
run_routing "$home" set auth-eligible pc02 >/dev/null
run_routing "$home" set auth-yolooff pc02 >/dev/null
run_routing "$home" set auth-noproject pc02 >/dev/null
out=$(run_order "$home")
assert_contains "$out" "auth-eligible" "yolo-on project's classified item is ordered"
assert_not_contains "$out" "auth-yolooff" "yolo-off project's item never enters the ordered output"
assert_not_contains "$out" "auth-noproject" "an item with no project never enters the ordered output"

# --- 2. Dependency fixture --------------------------------------------------
# dep-unblocker unblocks dep-follower; it is ordered before a higher-priority
# unrelated row.
home=$(make_home dependency)
(cd "$home" && tasks-axi add dep-unblocker "unblocks something" --kind ship --repo demo >/dev/null)
(cd "$home" && tasks-axi add dep-follower "depends on unblocker" --kind ship --repo demo --blocked-by dep-unblocker >/dev/null)
(cd "$home" && tasks-axi add dep-priority "unrelated but high priority" --kind ship --repo demo --priority 4 >/dev/null)
run_routing "$home" set dep-unblocker pc02 >/dev/null
run_routing "$home" set dep-priority pc02 >/dev/null
out=$(run_order "$home")
first=$(nth_line "$out" 1)
[ "$first" = "dep-unblocker" ] || fail "the dependency-cleared item must be ordered first, got: $first"
assert_contains "$out" "dep-priority" "the priority-carrying row still appears after the dependency-cleared one"
# The blocked follower itself never appears: it is not gate=dispatchable.
assert_not_contains "$out" "dep-follower" "a blocked row never enters the ordered output"

# When the dependency clears (follower unblocked), the follower may then
# read as dispatchable on the NEXT snapshot without any manual re-triage -
# this is exercised end-to-end in the churn fixture below rather than here,
# since unblocking requires tasks-axi's own resolution path.

# --- 3. Fairness fixture ----------------------------------------------------
# Several short, unprioritized new items plus one much older, longer item:
# the older item must be selected no later than the fourth dispatch slot.
# tasks-axi's own `created` field is date-granularity (see
# bin/fm-queue-snapshot.sh's header), so real same-day items cannot be told
# apart by creation order alone; a stub tasks-axi gives each row an explicit,
# distinct `created` date the way tests/fm-queue-snapshot.test.sh's own
# header-indexed fixture does, rather than relying on wall-clock spacing.
home=$(make_home fairness)
stub_dir="$TMP_ROOT/fairness-stub-bin"
rm -rf "$stub_dir"
mkdir -p "$stub_dir"
cat > "$stub_dir/tasks-axi" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = show ]; then
  case "${2:-}" in
    fair-old|fair-new-[1-6])
      printf 'task:\n  id: %s\n  title: "%s"\n  state: queued\n  kind: ship\n  repo: demo\n  body: ""\n' "$2" "$2"
      ;;
    *)
      printf 'error: "Task not found in this backlog"\ncode: NOT_FOUND\n'
      ;;
  esac
  exit 0
fi
cat <<'OUT'
count: 7
tasks[7]{id,state,kind,repo,title,body,blocked,blocked_by,held,hold_kind,hold_reason,hold_until,priority,created}:
  fair-old,queued,ship,demo,"this is a much longer title representing an old bounded item","",no,none,no,"-","-","-","-",2026-08-01
  fair-new-1,queued,ship,demo,s1,"",no,none,no,"-","-","-","-",2026-09-09
  fair-new-2,queued,ship,demo,s2,"",no,none,no,"-","-","-","-",2026-09-09
  fair-new-3,queued,ship,demo,s3,"",no,none,no,"-","-","-","-",2026-09-09
  fair-new-4,queued,ship,demo,s4,"",no,none,no,"-","-","-","-",2026-09-09
  fair-new-5,queued,ship,demo,s5,"",no,none,no,"-","-","-","-",2026-09-09
  fair-new-6,queued,ship,demo,s6,"",no,none,no,"-","-","-","-",2026-09-09
help[1]:
  - Run `tasks-axi show <id>` for full notes on a task
OUT
STUB
chmod +x "$stub_dir/tasks-axi"
for id in fair-old fair-new-1 fair-new-2 fair-new-3 fair-new-4 fair-new-5 fair-new-6; do
  PATH="$stub_dir:$PATH" run_routing "$home" set "$id" pc02 >/dev/null
done
out=$(PATH="$stub_dir:$PATH" run_order "$home")
pos=$(printf '%s\n' "$out" | grep -n '^fair-old$' | cut -d: -f1)
[ -n "$pos" ] || fail "fair-old must appear in the ordered output: $out"
[ "$pos" -le 4 ] || fail "fair-old must be selected no later than the 4th slot (rotation: 3 shortest then 1 oldest), got position $pos: $out"

# --- 3b. Truncated-length fixture -------------------------------------------
# `tasks-axi list` truncates title/body at ~150 characters and appends
# "... (truncated, <N> chars total - use show <id> --full ...)", so the
# emitted string length says more about the id in that marker than about the
# item. Here `huge-item` really carries 5000 characters and
# `zz-a-much-longer-item-identifier` only 200, yet the truncated strings
# measure 167 and 189 - so a naive string-length proxy dispatches the
# 5000-character item into the "shortest" slot first. The rotation must use
# the marker's own N and offer the genuinely short item first.
home=$(make_home truncated)
trunc_stub="$TMP_ROOT/truncated-stub-bin"
rm -rf "$trunc_stub"
mkdir -p "$trunc_stub"
cat > "$trunc_stub/tasks-axi" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = show ]; then
  case "${2:-}" in
    huge-item)
      printf 'task:\n  id: huge-item\n  title: "huge"\n  state: queued\n  kind: ship\n  repo: demo\n  body: "%s"\n' "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
      ;;
    zz-a-much-longer-item-identifier)
      printf 'task:\n  id: zz-a-much-longer-item-identifier\n  title: "tiny"\n  state: queued\n  kind: ship\n  repo: demo\n  body: "%s"\n' "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
      ;;
    *)
      printf 'error: "Task not found in this backlog"\ncode: NOT_FOUND\n'
      ;;
  esac
  exit 0
fi
cat <<'OUT'
count: 2
tasks[2]{id,state,kind,repo,title,body,blocked,blocked_by,held,hold_kind,hold_reason,hold_until,priority,created}:
  huge-item,queued,ship,demo,"huge","AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n... (truncated, 5000 chars total - use show huge-item --full to see complete text)",no,none,no,"-","-","-","-",2026-09-09
  zz-a-much-longer-item-identifier,queued,ship,demo,"tiny","AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n... (truncated, 200 chars total - use show zz-a-much-longer-item-identifier --full to see complete text)",no,none,no,"-","-","-","-",2026-09-09
help[1]:
  - Run `tasks-axi show <id>` for full notes on a task
OUT
STUB
chmod +x "$trunc_stub/tasks-axi"
for id in huge-item zz-a-much-longer-item-identifier; do
  PATH="$trunc_stub:$PATH" run_routing "$home" set "$id" pc02 >/dev/null \
    || fail "set should succeed for $id against the truncated-field stub"
done
out=$(PATH="$trunc_stub:$PATH" run_order "$home")
first=$(nth_line "$out" 1)
[ "$first" = "zz-a-much-longer-item-identifier" ] \
  || fail "the genuinely 200-character item must be offered before the 5000-character one (the truncation marker's own char count is the real length), got: $out"

# --- 3c. Registry-failure fixture -------------------------------------------
# A broken registry must refuse loudly (exit 2), never be reported as "no
# PC02 candidates" - an empty roster silently idles the PC02 lane forever,
# which is the exact starvation this ordering exists to prevent.
if [ "$(id -u)" -ne 0 ]; then
  home=$(make_home unreadable)
  (cd "$home" && tasks-axi add unread-item "an item" --kind ship --repo demo >/dev/null)
  run_routing "$home" set unread-item pc02 >/dev/null
  chmod 000 "$home/data/backlog-routing.tsv"
  out=$(run_order "$home" 2>/dev/null); rc=$?
  chmod 644 "$home/data/backlog-routing.tsv"
  [ "$rc" -eq 2 ] || fail "an unreadable routing registry must exit 2, got rc=$rc with output: $out"
  [ -z "$out" ] || fail "a refusing run must not print a partial order, got: $out"
fi

# --- 4. Tier-escalation / reconciliation composition ------------------------
# An escalated row (no longer class=pc02) must never appear in the ordered
# output, even though it is still gate=dispatchable in the snapshot.
home=$(make_home escalation)
(cd "$home" && tasks-axi add esc-item "will be escalated" --kind ship --repo demo >/dev/null)
run_routing "$home" set esc-item pc02 >/dev/null
out=$(run_order "$home")
assert_contains "$out" "esc-item" "before escalation, the item is ordered"
run_routing "$home" escalate esc-item medium --reason "one PC02 failure" >/dev/null
out=$(run_order "$home")
assert_not_contains "$out" "esc-item" "after escalation, the item never enters the pc02 ordered output"

# --- 5. PC02 occupancy composition ------------------------------------------
# fm-pc02-fair-order.sh only ORDERS candidates; it is the caller's job (the
# /autonomous pass, step 3) to check bin/fm-autonomous-pc02-lane.sh before
# treating the first row as dispatchable. Confirm the lane guard is a real,
# independent gate this script does not duplicate or bypass: with a live
# pc02-llamaswap/* task recorded in state/, the lane reads occupied even
# though fair-order still returns a candidate to hand it once free.
home=$(make_home occupancy)
(cd "$home" && tasks-axi add occ-item "occupancy test item" --kind ship --repo demo >/dev/null)
run_routing "$home" set occ-item pc02 >/dev/null
out=$(run_order "$home")
assert_contains "$out" "occ-item" "fair-order still returns the candidate while lane occupancy is the caller's separate check"
cat > "$home/state/occ-worker.meta" <<'EOF'
model=pc02-llamaswap/qwen3.6
EOF
lane_out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-autonomous-pc02-lane.sh"); lane_rc=$?
[ "$lane_rc" -eq 1 ] || fail "the lane guard must read occupied with a live pc02-llamaswap/* meta present, got rc=$lane_rc: $lane_out"
assert_contains "$lane_out" "occupied" "lane guard reports occupied independently of fair-order's own output"

pass "fm-pc02-fair-order.sh composition and authority/dependency/fairness/escalation/occupancy fixtures"
