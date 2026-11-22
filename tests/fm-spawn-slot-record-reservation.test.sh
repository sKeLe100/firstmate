#!/usr/bin/env bash
# Regression tests for fm-spawn's Treehouse slot reservation.
#
# A pooled worktree keeps belonging to its task after the task's pane closes or
# its worker exits: the task record still names it, and a parked or shelved task
# deliberately keeps its isolated copy. Treehouse's interactive acquire carries
# only a process lease, so the pool reads that slot as free and can hand it to a
# new task, leaving two live records naming one slot. The spawn must lease every
# slot another task record still names out of its own acquisition, while a stale
# record for the spawning task itself must not strand a lease on a slot it no
# longer holds.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-slot-record-reservation)

# Two-slot originless pool at <case>/slots/<n>/project, with the pool state file
# beside the slots and the shape fm-spawn validates before leasing.
#
# make_pool_case <name>: echoes the record fields its reader consumes.
make_pool_case() {  # <name>
  local name=$1 case_dir home project fakebin initial slot_root
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  slot_root="$case_dir/slots"
  fakebin=$(fm_fakebin "$case_dir/fake")

  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  initial=$(git -C "$project" rev-parse HEAD)

  mkdir -p "$slot_root/1" "$slot_root/2"
  git -C "$project" worktree add --quiet --detach "$slot_root/1/project" "$initial"
  git -C "$project" worktree add --quiet --detach "$slot_root/2/project" "$initial"
  printf '{"worktrees":[{"name":"1","path":"%s"},{"name":"2","path":"%s"}]}\n' \
    "$slot_root/1/project" "$slot_root/2/project" > "$slot_root/treehouse-state.json"

  printf '%s\n' "$case_dir|$home|$project|$fakebin|$slot_root"
}

read_pool_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR FAKEBIN_DIR SLOT_ROOT <<EOF
$1
EOF
}

run_spawn() {  # <id> [fm-spawn args...]
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$SLOT_ROOT/1/project" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" --model big-model --effort high "$@"
}

# A stateful Treehouse stand-in: `status --json` reports both slots with their
# durable lease state, `lease` records a slot as leased, and the terminal stub's
# `treehouse get` enters the lowest slot with no live window and no lease. That
# is the real acquire rule this invariant has to change: absent the reservation,
# the kept record's slot is the one a fresh spawn would be handed.
install_slot_world() {  # <fakebin> <world-dir> <slot-root>
  local fakebin=$1 world=$2 slots=$3
  mkdir -p "$world"
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
set -u
slots='$slots'
leases="\$slots/.leases"
SH
  cat >> "$fakebin/treehouse" <<'SH'
leased_name() {  # <name>
  [ -f "$leases" ] || return 1
  awk -F'\t' -v n="$1" '$1 == n { found = 1 } END { exit !found }' "$leases" 2>/dev/null
}
case "${1:-}" in
  status)
    [ ! -e "$slots/.status-fails" ] || { echo "treehouse status: pool unreadable" >&2; exit 1; }
    [ ! -e "$slots/.status-garbage" ] || { printf '{"worktrees":[]}\n'; exit 0; }
    first=1
    printf '['
    for slot in "$slots"/*/project; do
      [ -e "$slot" ] || continue
      name=$(basename "$(dirname "$slot")")
      if leased_name "$name"; then
        holder=$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' "$leases" 2>/dev/null)
        lease="lease-$name"
        leased_at='"2026-11-22T10:00:00Z"'
      else
        holder=
        lease=
        leased_at=null
      fi
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"name":"%s","path":"%s","status":"available","branch":"","flavor":"git","lease_id":"%s","lease_holder":"%s","leased_at":%s,"processes":[]}' \
        "$name" "$slot" "$lease" "$holder" "$leased_at"
    done
    printf ']\n'
    ;;
  lease)
    if [ "${2:-}" = --help ]; then
      [ ! -e "$slots/.no-lease-command" ] || { echo 'unknown command "lease"' >&2; exit 1; }
      exit 0
    fi
    name=${2:-}
    shift 2 2>/dev/null || shift "$#"
    holder=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --lease-holder) holder=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$name" ] || { echo "treehouse lease: missing worktree name" >&2; exit 2; }
    [ ! -e "$slots/.lease-fails" ] || { echo "treehouse lease: cannot lease" >&2; exit 1; }
    if leased_name "$name"; then
      echo "worktree $name is already leased" >&2
      exit 1
    fi
    printf '%s\t%s\n' "$name" "$holder" >> "$leases"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"

  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
world='$world'
slots='$slots'
leases="\$slots/.leases"
SH
  cat >> "$fakebin/tmux" <<'SH'
window_name() {  # <target>
  local t=${1#=}
  t=${t#*:}
  t=${t#=}
  case "$t" in
    @*) grep -lxF -- "$t" "$world"/*.id 2>/dev/null | head -n 1 | sed 's|.*/||; s|\.id$||' ;;
    *) printf '%s' "$t" ;;
  esac
}
leased_name() {  # <name>
  [ -f "$leases" ] || return 1
  awk -F'\t' -v n="$1" '$1 == n { found = 1 } END { exit !found }' "$leases" 2>/dev/null
}
target= name= cwd= fmt= text=
cmd=${1:-}
[ "$#" -eq 0 ] || shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    -t) target=$2; shift 2 ;;
    -n) name=$2; shift 2 ;;
    -c) cwd=$2; shift 2 ;;
    -F) fmt=$2; shift 2 ;;
    -*) shift ;;
    *) text="$text${text:+ }$1"; shift ;;
  esac
done
case "$cmd" in
  display-message)
    case "$text" in
      *pane_current_path*) cat "$world/$(window_name "$target").path" 2>/dev/null ;;
      *) printf 'firstmate\n' ;;
    esac
    ;;
  list-windows)
    for f in "$world"/*.id; do [ -e "$f" ] || continue; f=${f##*/}; printf '%s\n' "${f%.id}"; done
    ;;
  new-window)
    n=$(( $(cat "$world/.next" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$n" > "$world/.next"
    printf '@%s\n' "$n" > "$world/$name.id"
    printf '%s\n' "$cwd" > "$world/$name.path"
    printf '@%s\n' "$n"
    ;;
  kill-window)
    w=$(window_name "$target")
    rm -f "$world/$w.id" "$world/$w.path"
    ;;
  send-keys)
    if [ "$text" = "treehouse get Enter" ]; then
      w=$(window_name "$target")
      for slot in "$slots"/*/project; do
        [ -e "$slot" ] || continue
        grep -qxF -- "$slot" "$world"/*.path 2>/dev/null && continue
        leased_name "$(basename "$(dirname "$slot")")" && continue
        printf '%s\n' "$slot" > "$world/$w.path"
        break
      done
    fi
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

seed_kept_record() {  # <home> <id> <worktree>
  local home=$1 id=$2 wt=$3
  mkdir -p "$home/state"
  cat > "$home/state/$id.meta" <<META
window=absent:$id
endpoint_task_id=$id
worktree=$wt
project=$home
harness=codex
kind=scout
META
}

# The kept, paneless record still names slot 1. A fresh spawn used to be handed
# exactly that slot; it must now be reserved out of the acquisition and land on
# slot 2, with slot 1's copy untouched.
test_kept_record_reserves_its_slot_from_a_fresh_spawn() {
  local rec id out status before
  id='slot-reserve-new-r1'
  rec=$(make_pool_case reserve)
  read_pool_case "$rec"
  mkdir -p "$HOME_DIR/data/$id"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  seed_kept_record "$HOME_DIR" 'kept-scout' "$SLOT_ROOT/1/project"
  install_slot_world "$FAKEBIN_DIR" "$CASE_DIR/tmux-world" "$SLOT_ROOT"
  before=$(git -C "$SLOT_ROOT/1/project" rev-parse HEAD)

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a fresh spawn beside a kept record's slot should launch"$'\n'"$out"
  assert_grep "worktree=$SLOT_ROOT/2/project" "$HOME_DIR/state/$id.meta" \
    "the fresh spawn was handed the kept record's slot instead of a different one"
  grep -Fxq -- $'1\tkept-scout' "$SLOT_ROOT/.leases" 2>/dev/null \
    || fail "the kept record's slot was not reserved: $(cat "$SLOT_ROOT/.leases" 2>/dev/null)"
  [ ! -e "$SLOT_ROOT/1/.fm-slot-owner" ] \
    || fail "the fresh spawn claimed the kept record's slot"
  grep -Fxq -- "task=$id" "$SLOT_ROOT/2/.fm-slot-owner" 2>/dev/null \
    || fail "the fresh spawn did not claim the slot it actually took"
  [ "$(git -C "$SLOT_ROOT/1/project" rev-parse HEAD)" = "$before" ] \
    || fail "the fresh spawn moved the kept record's copy"
  pass "a kept record's pool slot is reserved out of a fresh spawn's acquisition"
}

# Control for the case above: with no kept record, the same world hands the
# fresh spawn the lowest slot, so the reservation really is what moved it.
test_without_a_kept_record_the_lowest_slot_is_still_handed_out() {
  local rec id out status
  id='slot-reserve-control-r1'
  rec=$(make_pool_case control)
  read_pool_case "$rec"
  mkdir -p "$HOME_DIR/data/$id"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  install_slot_world "$FAKEBIN_DIR" "$CASE_DIR/tmux-world" "$SLOT_ROOT"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a fresh spawn with no kept records should launch"$'\n'"$out"
  assert_grep "worktree=$SLOT_ROOT/1/project" "$HOME_DIR/state/$id.meta" \
    "the control spawn did not take the lowest free slot, so the reservation case proves nothing"
  [ ! -s "$SLOT_ROOT/.leases" ] || fail "the control spawn reserved a slot it was free to take"
  pass "without a kept record the pool still hands out its lowest free slot"
}

# A stale record for the spawning task itself must not reserve a slot: the
# fresh spawn republishes that record, so reserving would strand a lease on a
# slot the task no longer holds and push it to a higher slot for nothing.
test_a_stale_record_for_the_spawning_task_does_not_reserve_its_slot() {
  local rec id out status
  id='slot-reserve-self-r1'
  rec=$(make_pool_case self)
  read_pool_case "$rec"
  mkdir -p "$HOME_DIR/data/$id"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  seed_kept_record "$HOME_DIR" "$id" "$SLOT_ROOT/1/project"
  install_slot_world "$FAKEBIN_DIR" "$CASE_DIR/tmux-world" "$SLOT_ROOT"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a fresh spawn over its own stale record should launch"$'\n'"$out"
  assert_grep "worktree=$SLOT_ROOT/1/project" "$HOME_DIR/state/$id.meta" \
    "the spawn's own record reserved the slot it was free to take"
  [ ! -s "$SLOT_ROOT/.leases" ] \
    || fail "the spawn stranded a lease on its own stale record's slot: $(cat "$SLOT_ROOT/.leases")"
  pass "a stale record for the spawning task does not reserve its own slot"
}

test_kept_record_reserves_its_slot_from_a_fresh_spawn
test_without_a_kept_record_the_lowest_slot_is_still_handed_out
test_a_stale_record_for_the_spawning_task_does_not_reserve_its_slot

# Each failure to read or lease the pool must refuse the spawn rather than
# acquire blind: the kept record's slot could otherwise be reissued.
test_pool_failures_refuse_the_spawn() {  # <case> <marker> <message>
  local case_name=$1 marker=$2 msg=$3 rec id out status
  id="slot-reserve-$case_name-r1"
  rec=$(make_pool_case "$case_name")
  read_pool_case "$rec"
  mkdir -p "$HOME_DIR/data/$id"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  seed_kept_record "$HOME_DIR" 'kept-scout' "$SLOT_ROOT/1/project"
  install_slot_world "$FAKEBIN_DIR" "$CASE_DIR/tmux-world" "$SLOT_ROOT"
  : > "$SLOT_ROOT/$marker"

  out=$(run_spawn "$id" --scout 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "$case_name: the spawn launched despite the pool failure"$'\n'"$out"
  case "$out" in
    *"$msg"*) ;;
    *) fail "$case_name: refusal did not name the pool failure"$'\n'"$out" ;;
  esac
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "$case_name: a refused spawn published a task record"
  pass "$case_name refuses the spawn"
}

test_pool_failures_refuse_the_spawn status-fails .status-fails 'could not read the Treehouse pool'
test_pool_failures_refuse_the_spawn status-garbage .status-garbage 'is unreadable'
test_pool_failures_refuse_the_spawn lease-fails .lease-fails 'could not reserve Treehouse pool slot 1'

# An older Treehouse (v2.0.1, the CI pin) has no `lease` subcommand and no
# `status --json`; the reservation is skipped with a warning, not a refusal.
test_old_treehouse_without_lease_still_spawns() {
  local id=slot-reserve-old-treehouse-r1 rec out status
  rec=$(make_pool_case old-treehouse)
  read_pool_case "$rec"
  mkdir -p "$HOME_DIR/data/$id"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  seed_kept_record "$HOME_DIR" 'kept-scout' "$SLOT_ROOT/1/project"
  install_slot_world "$FAKEBIN_DIR" "$CASE_DIR/tmux-world" "$SLOT_ROOT"
  : > "$SLOT_ROOT/.no-lease-command"
  : > "$SLOT_ROOT/.status-fails"

  out=$(run_spawn "$id" --scout 2>&1)
  status=$?
  expect_code 0 "$status" "a treehouse without lease must not refuse the spawn"$'\n'"$out"
  case "$out" in
    *"has no 'lease' subcommand"*) ;;
    *) fail "the skipped reservation was not warned about"$'\n'"$out" ;;
  esac
  pass "a treehouse without a lease subcommand skips reservation and still spawns"
}

test_old_treehouse_without_lease_still_spawns

printf '# all fm-spawn-slot-record-reservation tests passed\n'
