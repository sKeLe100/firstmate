#!/usr/bin/env bash
# tests/fm-pc02-churn-e2e.test.sh - end-to-end churn fixture from
# data/backlog-triage-durable-plan/report.md's test seams list: "simulate
# three consecutive PC02 teardowns and verify three different ordered tasks
# are claimed without a captain interaction."
#
# Drives the real bin/fm-queue-snapshot.sh, bin/fm-backlog-routing.sh, and
# bin/fm-pc02-fair-order.sh together against one real tasks-axi backlog, in
# the same shape the /autonomous pass's step 9 would use them: pick the
# fair-order head, simulate that task's dispatch-and-teardown by gc'ing its
# routing row and marking its backlog item done, then re-run. Also proves a
# dependency clears automatically: the second item's completion unblocks a
# third that could not have dispatched at pass 1.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTING="$ROOT/bin/fm-backlog-routing.sh"
FAIR_ORDER="$ROOT/bin/fm-pc02-fair-order.sh"
TMP_ROOT=$(fm_test_tmproot fm-pc02-churn-e2e)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

home="$TMP_ROOT/churn"
mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
printf '%s\n' '- demo [direct-PR +yolo] - test project (added 2026-08-20)' > "$home/data/projects.md"

(cd "$home" && tasks-axi add churn-a "first bounded item" --kind ship --repo demo >/dev/null)
(cd "$home" && tasks-axi add churn-b "second bounded item" --kind ship --repo demo >/dev/null)
(cd "$home" && tasks-axi add churn-c "depends on churn-b" --kind ship --repo demo --blocked-by churn-b >/dev/null)

for id in churn-a churn-b churn-c; do
  FM_HOME="$home" "$ROUTING" set "$id" pc02 >/dev/null
done

teardown_head() {  # dispatches (simulated) and tears down the fair-order head
  local head
  head=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$FAIR_ORDER" | head -n1)
  [ -n "$head" ] || fail "expected a dispatchable head, got none"
  # "done" below is tasks-axi's own subcommand, not the bash loop keyword.
  # shellcheck disable=SC1010
  (cd "$home" && tasks-axi done "$head" >/dev/null) || fail "could not mark $head done"
  FM_HOME="$home" "$ROUTING" gc "$head" >/dev/null || fail "could not gc $head's routing row"
  printf '%s\n' "$head"
}

# churn-c is blocked by churn-b, so pass 1 can only offer churn-a or churn-b.
claimed1=$(teardown_head)
case "$claimed1" in
  churn-a|churn-b) ;;
  *) fail "pass 1 claimed an unexpected task: $claimed1" ;;
esac

# Pass 2 claims the other of {churn-a, churn-b}; churn-c is still blocked
# unless churn-b was already claimed.
claimed2=$(teardown_head)
case "$claimed2" in
  churn-a|churn-b) ;;
  *) fail "pass 2 claimed an unexpected task: $claimed2" ;;
esac
[ "$claimed2" != "$claimed1" ] || fail "pass 2 re-claimed the same task as pass 1: $claimed2"

# Once both churn-a and churn-b are done, churn-b's completion has cleared
# churn-c's dependency: tasks-axi itself resolves blocked_by against closed
# state, so no manual re-triage is needed for churn-c to become
# gate=dispatchable and read as the pass-3 fair-order head.
claimed3=$(teardown_head)
[ "$claimed3" = churn-c ] || fail "pass 3 should have claimed churn-c once its dependency cleared, got: $claimed3"

# All three claims are distinct: no task was dispatched twice.
seen="$claimed1 $claimed2 $claimed3"
for t in churn-a churn-b churn-c; do
  case " $seen " in
    *" $t "*) ;;
    *) fail "task $t was never claimed across the three passes: $seen" ;;
  esac
done

# A fourth pass finds nothing left to offer.
out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$FAIR_ORDER")
[ -z "$out" ] || fail "pass 4 should offer nothing once all three tasks are claimed, got: $out"

pass "end-to-end PC02 churn: three consecutive teardowns claim three distinct, correctly-sequenced tasks"
