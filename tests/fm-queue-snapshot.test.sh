#!/usr/bin/env bash
# tests/fm-queue-snapshot.test.sh - behavior tests for bin/fm-queue-snapshot.sh.
# Exercises the helper only through its executable interface against a real
# tasks-axi backlog and a real data/projects.md registry: the derived
# autonomy label must match kind/hold-kind/yolo exactly, gated items must
# carry their blocked/held facts rather than being dropped, an unregistered
# project must default to captain-gated (never a guessed autonomous label),
# and dispatch_config must reflect absent/present/invalid without this
# script ever reading crew-dispatch.json's rule content itself.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-queue-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-queue-snapshot)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }

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

run_snapshot() {  # <home> [args...]
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$SNAPSHOT" "$@"
}

# 1. A ship item on a yolo=on project is autonomous-eligible; a captain-kind
#    item and a captain-kind hold are both captain-gated with the gate facts
#    (blocked/held/hold_reason) preserved rather than dropped from the row.
home=$(make_home basic)
printf '%s\n' '- demo-proj [direct-PR +yolo] - test project (added 2026-08-20)' > "$home/data/projects.md"
(
  cd "$home" || exit 1
  tasks-axi add demo-a "fix the thing" --kind ship --repo demo-proj --priority 2 >/dev/null
  tasks-axi add demo-b "captain decision on X" --kind captain --repo demo-proj >/dev/null
  tasks-axi add demo-c "blocked item" --kind ship --repo demo-proj --blocked-by demo-a >/dev/null
  tasks-axi hold demo-c --reason "waiting on demo-a" --kind captain >/dev/null
)
out=$(run_snapshot "$home")
case "$out" in
  *"count: 3"*) ;;
  *) fail "expected count: 3, got: $out" ;;
esac
case "$out" in
  *"demo-a,fix the thing,ship,demo-proj,2,no,none,no,-,-,-,direct-PR on,autonomous-eligible,"*) ;;
  *) fail "demo-a row not autonomous-eligible on yolo-on project: $out" ;;
esac
case "$out" in
  *"demo-b,captain decision on X,captain,demo-proj,-,no,none,no,-,-,-,direct-PR on,captain-gated,captain kind"*) ;;
  *) fail "demo-b row not captain-gated by kind: $out" ;;
esac
case "$out" in
  *"demo-c,blocked item,ship,demo-proj,-,yes,demo-a,yes,captain,waiting on demo-a,-,direct-PR on,captain-gated,captain kind"*) ;;
  *) fail "demo-c row missing gate facts or not captain-gated: $out" ;;
esac
case "$out" in
  *"dispatch_config: absent"*) ;;
  *) fail "expected dispatch_config: absent, got: $out" ;;
esac

# 2. A yolo=off project is captain-gated even for an ordinary ship item, and
#    an unregistered project defaults to captain-gated rather than an
#    unclear or optimistic guess.
home=$(make_home yolo-off)
printf '%s\n' '- other-proj - no yolo project (added 2026-08-20)' > "$home/data/projects.md"
(
  cd "$home" || exit 1
  tasks-axi add demo-e "no-yolo item" --kind ship --repo other-proj >/dev/null
  tasks-axi add demo-f "unregistered project item" --kind ship --repo ghost-proj >/dev/null
)
out=$(run_snapshot "$home")
case "$out" in
  *"demo-e,no-yolo item,ship,other-proj,-,no,none,no,-,-,-,no-mistakes off,captain-gated,project registry posture has yolo off"*) ;;
  *) fail "demo-e row not captain-gated on yolo-off project: $out" ;;
esac
case "$out" in
  *"demo-f,unregistered project item,ship,ghost-proj,-,no,none,no,-,-,-,no-mistakes off,captain-gated,project registry posture has yolo off"*) ;;
  *) fail "unregistered project did not default to captain-gated: $out" ;;
esac

# 3. An item with no project recorded is unclear, never guessed either way.
home=$(make_home no-project)
: > "$home/data/projects.md"
(
  cd "$home" || exit 1
  tasks-axi add demo-d "no project item" --kind docs >/dev/null
)
out=$(run_snapshot "$home")
case "$out" in
  *"demo-d,no project item,docs,-,-,no,none,no,-,-,-,n/a,unclear,no project recorded on this item"*) ;;
  *) fail "no-project item was not reported unclear: $out" ;;
esac

# 4. --limit is honored and applied before enrichment.
home=$(make_home limit)
: > "$home/data/projects.md"
(
  cd "$home" || exit 1
  tasks-axi add lim-a "one" --kind docs >/dev/null
  tasks-axi add lim-b "two" --kind docs >/dev/null
  tasks-axi add lim-c "three" --kind docs >/dev/null
)
out=$(run_snapshot "$home" --limit 2)
case "$out" in
  *"count: 2"*) ;;
  *) fail "expected count: 2 under --limit 2, got: $out" ;;
esac
case "$out" in
  *lim-c*) fail "--limit 2 unexpectedly included a third item: $out" ;;
esac

# 5. dispatch_config reflects present vs invalid crew-dispatch.json without
#    this script needing to interpret the rule content.
home=$(make_home dispatch-present)
: > "$home/data/projects.md"
printf '%s\n' '{"rules":[],"default":[{"harness":"codex"}]}' > "$home/config/crew-dispatch.json"
out=$(run_snapshot "$home")
case "$out" in
  *"dispatch_config: present"*) ;;
  *) fail "expected dispatch_config: present, got: $out" ;;
esac

home=$(make_home dispatch-invalid)
: > "$home/data/projects.md"
printf '%s\n' '{ not valid json' > "$home/config/crew-dispatch.json"
out=$(run_snapshot "$home")
case "$out" in
  *"dispatch_config: invalid"*) ;;
  *) fail "expected dispatch_config: invalid, got: $out" ;;
esac

# 6. An empty queue reports count: 0 rather than erroring.
home=$(make_home empty)
: > "$home/data/projects.md"
out=$(run_snapshot "$home")
case "$out" in
  *"count: 0"*) ;;
  *) fail "expected count: 0 for an empty queue, got: $out" ;;
esac

# 7. A missing tasks-axi on PATH fails loudly rather than reporting an empty queue.
home=$(make_home missing-tool)
: > "$home/data/projects.md"
tasks_axi_dir=$(dirname "$(command -v tasks-axi)")
filtered_path=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$tasks_axi_dir" | paste -sd: -)
out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" PATH="$filtered_path" "$SNAPSHOT" 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail "expected non-zero exit when tasks-axi is absent from PATH"
case "$out" in
  *"tasks-axi not found on PATH"*) ;;
  *) fail "missing loud tasks-axi-not-found message: $out" ;;
esac

echo "PASS fm-queue-snapshot.test.sh"
