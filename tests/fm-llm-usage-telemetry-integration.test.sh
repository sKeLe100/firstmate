#!/usr/bin/env bash
# tests/fm-llm-usage-telemetry-integration.test.sh - end-to-end regressions
# proving the firstmate-side LLM usage telemetry archive
# (docs/llm-usage-telemetry.md, bin/fm-llm-usage-lib.sh) is actually wired
# into real fm-spawn.sh, fm-control.sh relaunch, and fm-teardown.sh runs,
# not merely unit-tested in isolation:
#   1. A fresh ship spawn's purpose= lands in the task's own meta AND a
#      "dispatch" archive record.
#   2. A fresh spawn given --redelegated-from/--redelegation-reason records a
#      "delegation" archive record naming the issue and both models.
#   3. A real fm-control.sh relaunch (harness switch) records a "delegation"
#      archive record, reusing the relaunch's own required --note as reason.
#   4. A real fm-teardown.sh run records an "outcome" archive record, landed
#      on the ordinary path and abandoned on --force.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
CONTROL="$ROOT/bin/fm-control.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-llm-usage-integration)

require_python3() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required by this test to validate JSONL output"
}

archive_records() {  # <home> -> prints each JSONL line's event_type<TAB>whole-line
  local home=$1
  [ -f "$home/data/llm-usage/firstmate.jsonl" ] || return 0
  cat "$home/data/llm-usage/firstmate.jsonl"
}

field() {  # <json-line> <field> -> prints the field's string value (python3-backed)
  python3 -c '
import json, sys
obj = json.loads(sys.argv[1])
print(obj.get(sys.argv[2], ""))
' "$1" "$2"
}

# --- fixed fake tmux: enough for spawn, relaunch, and teardown -------------

make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) cat "$D/becomes" > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command" 2>/dev/null; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd" 2>/dev/null; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  new-window|new-session|has-session|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cp "$fb/gh-axi" "$fb/gh"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/treehouse" "$fb/gh-axi" "$fb/gh" "$fb/no-mistakes"
}

# --- 1 & 2: fresh spawn dispatch + redelegation ----------------------------

test_fresh_spawn_records_purpose_in_meta_and_dispatch_event() {
  local dir home proj wt out task_id line
  dir="$TMP_ROOT/spawn-purpose-$RANDOM"
  home="$dir/home"; proj="$dir/proj"; wt="$dir/wt"
  mkdir -p "$home/state" "$home/data" "$dir/fake"
  make_tmux_stub "$dir"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  fm_git_worktree "$proj" "$wt" "task-spawn-purpose"
  task_id=spawn-purpose
  mkdir -p "$home/data/$task_id"
  printf '# brief\n\nDo the thing.\n' > "$home/data/$task_id/brief.md"
  printf '%s' "$wt" > "$dir/fake/cwd"

  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$task_id" "$proj" --mode no-mistakes --yolo off --purpose code \
      --harness claude 2>&1)
  local rc=$?
  [ "$rc" -eq 0 ] || fail "spawn failed: $out"

  [ "$(grep '^purpose=' "$home/state/$task_id.meta" | tail -1 | cut -d= -f2-)" = code ] \
    || fail "the task's own meta should record purpose=code: $(cat "$home/state/$task_id.meta")"

  require_python3
  local found=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(field "$line" event_type)" = dispatch ] || continue
    [ "$(field "$line" task_id)" = "$task_id" ] || continue
    [ "$(field "$line" purpose)" = code ] || fail "dispatch record has wrong purpose: $line"
    [ "$(field "$line" harness)" = claude ] || fail "dispatch record has wrong harness: $line"
    found=1
  done < <(archive_records "$home")
  [ "$found" -eq 1 ] || fail "no dispatch record was written for a real fm-spawn.sh run"
  pass "fm-spawn.sh: a real spawn records purpose in the task's own meta and in a dispatch archive record"
}

test_fresh_spawn_with_redelegation_records_delegation_event() {
  local dir home proj out prior_id new_id line
  dir="$TMP_ROOT/spawn-redelegate-$RANDOM"
  home="$dir/home"
  mkdir -p "$home/state" "$home/data" "$dir/fake"
  make_tmux_stub "$dir"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"

  prior_id=prior-attempt
  {
    echo "harness=codex"
    echo "model=default"
    echo "kind=ship"
  } > "$home/state/$prior_id.meta"

  new_id=redelegated-attempt
  fm_git_worktree "$dir/proj" "$dir/wt" "task-$new_id"
  mkdir -p "$home/data/$new_id"
  printf '# brief\n\nRetry with a different model.\n' > "$home/data/$new_id/brief.md"
  printf '%s' "$dir/wt" > "$dir/fake/cwd"

  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$new_id" "$dir/proj" --mode no-mistakes --yolo off \
      --harness claude --purpose code \
      --redelegated-from "$prior_id" \
      --redelegation-reason "codex looped on the same edit three times" 2>&1)
  local rc=$?
  [ "$rc" -eq 0 ] || fail "redelegated spawn failed: $out"

  require_python3
  local found_dispatch=0 found_delegation=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$(field "$line" event_type)" = dispatch ]; then
      [ "$(field "$line" task_id)" = "$new_id" ] || continue
      [ "$(field "$line" from_task_id)" = "$prior_id" ] || fail "dispatch record missing from_task_id: $line"
      [ "$(field "$line" harness)" = claude ] || fail "dispatch record has wrong harness: $line"
      [ "$(field "$line" purpose)" = code ] || fail "dispatch record has wrong purpose: $line"
      found_dispatch=1
    elif [ "$(field "$line" event_type)" = delegation ]; then
      [ "$(field "$line" task_id)" = "$new_id" ] || continue
      [ "$(field "$line" from_task_id)" = "$prior_id" ] || fail "delegation record missing from_task_id: $line"
      [ "$(field "$line" from_harness)" = codex ] || fail "delegation record has wrong from_harness: $line"
      [ "$(field "$line" to_harness)" = claude ] || fail "delegation record has wrong to_harness: $line"
      [ "$(field "$line" reason)" = "codex looped on the same edit three times" ] \
        || fail "delegation record has wrong reason: $line"
      found_delegation=1
    fi
  done < <(archive_records "$home")
  [ "$found_dispatch" -eq 1 ] || fail "no dispatch record with from_task_id was written for a real redelegated fm-spawn.sh run"
  [ "$found_delegation" -eq 1 ] || fail "no delegation record was written for a real redelegated fm-spawn.sh run"
  pass "fm-spawn.sh: a real redelegated spawn records from_task_id in both dispatch and delegation events"
}

test_fresh_spawn_without_redelegation_omits_from_task_id() {
  local dir home proj out task_id line
  dir="$TMP_ROOT/spawn-ordinary-$RANDOM"
  home="$dir/home"
  mkdir -p "$home/state" "$home/data" "$dir/fake"
  make_tmux_stub "$dir"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"

  task_id=ordinary-spawn
  fm_git_worktree "$dir/proj" "$dir/wt" "task-$task_id"
  mkdir -p "$home/data/$task_id"
  printf '# brief\n\nDo the thing.\n' > "$home/data/$task_id/brief.md"
  printf '%s' "$dir/wt" > "$dir/fake/cwd"

  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$task_id" "$dir/proj" --mode no-mistakes --yolo off \
      --harness claude --purpose review 2>&1)
  local rc=$?
  [ "$rc" -eq 0 ] || fail "ordinary spawn failed: $out"

  require_python3
  local found=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(field "$line" event_type)" = dispatch ] || continue
    [ "$(field "$line" task_id)" = "$task_id" ] || continue
    local from_id
    from_id=$(field "$line" from_task_id)
    [ -z "$from_id" ] || fail "dispatch record should not have from_task_id for an ordinary spawn: $line"
    [ "$(field "$line" purpose)" = review ] || fail "dispatch record has wrong purpose: $line"
    found=1
  done < <(archive_records "$home")
  [ "$found" -eq 1 ] || fail "no dispatch record was written for an ordinary fm-spawn.sh run"
  pass "fm-spawn.sh: a fresh spawn without --redelegated-from omits from_task_id from its dispatch record"
}

test_fresh_spawn_rejects_path_traversal_redelegated_from() {
  local dir home out rc new_id secret
  dir="$TMP_ROOT/spawn-redelegate-unsafe-$RANDOM"
  home="$dir/home"
  mkdir -p "$home/state" "$home/data" "$dir/fake"
  make_tmux_stub "$dir"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"

  secret="$dir/secret.meta"
  printf 'harness=stolen\nmodel=stolen-model\n' > "$secret"

  new_id=unsafe-attempt
  fm_git_worktree "$dir/proj" "$dir/wt" "task-$new_id"
  mkdir -p "$home/data/$new_id"
  printf '# brief\n\nRetry.\n' > "$home/data/$new_id/brief.md"
  printf '%s' "$dir/wt" > "$dir/fake/cwd"

  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$new_id" "$dir/proj" --mode no-mistakes --yolo off \
      --harness claude \
      --redelegated-from "../../$(basename "$dir")/secret" \
      --redelegation-reason "traversal attempt" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "fm-spawn.sh accepted a path-traversing --redelegated-from: $out"
  case "$out" in
    *"--redelegated-from"*) : ;;
    *) fail "refusal did not name the offending flag: $out" ;;
  esac
  if [ -f "$home/data/llm-usage/firstmate.jsonl" ] \
    && grep -q stolen-model "$home/data/llm-usage/firstmate.jsonl"; then
    fail "an out-of-state meta file leaked into the archive"
  fi
  pass "fm-spawn.sh: a path-traversing --redelegated-from is refused before any meta is read"
}

# --- 3: real fm-control.sh relaunch -----------------------------------------

test_real_relaunch_records_delegation_event() {
  local dir home proj wt out task_id line
  dir="$TMP_ROOT/relaunch-$RANDOM"
  home="$dir/home"
  mkdir -p "$home/state" "$home/data" "$dir/fake"
  make_tmux_stub "$dir"
  task_id=relaunch-t1
  fm_git_worktree "$dir/proj" "$dir/wt" "task-$task_id"
  mkdir -p "$home/data/$task_id"
  printf '# brief for %s\n\nDo the thing.\n' "$task_id" > "$home/data/$task_id/brief.md"
  {
    echo "window=fmses:fm-$task_id"
    echo "endpoint_task_id=$task_id"
    echo "worktree=$dir/wt"
    echo "project=$dir/proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$task_id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$task_id.meta"
  printf '%s\n' "fm-$task_id" > "$dir/fake/windows"
  printf '%s' "$dir/wt" > "$dir/fake/cwd"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'codex' > "$dir/fake/becomes"

  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$task_id" relaunch --harness codex \
      --note "claude produced a broken patch three times in a row" 2>&1)
  local rc=$?
  [ "$rc" -eq 0 ] || fail "relaunch failed: $out"

  require_python3
  local found=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(field "$line" event_type)" = delegation ] || continue
    [ "$(field "$line" task_id)" = "$task_id" ] || continue
    [ "$(field "$line" from_harness)" = claude ] || fail "delegation record has wrong from_harness: $line"
    [ "$(field "$line" to_harness)" = codex ] || fail "delegation record has wrong to_harness: $line"
    [ "$(field "$line" reason)" = "claude produced a broken patch three times in a row" ] \
      || fail "delegation record did not reuse the relaunch note as reason: $line"
    found=1
  done < <(archive_records "$home")
  [ "$found" -eq 1 ] || fail "no delegation record was written for a real fm-control.sh relaunch"
  grep -q '^relaunched=true$' "$home/state/$task_id.control-relaunch" \
    || fail "a completed relaunch should record relaunched=true in its durable journal"
  pass "fm-control.sh relaunch: a real harness switch records the delegation chain, reusing --note as reason"
}

test_rolled_back_relaunch_journal_does_not_claim_a_relaunch() {
  local dir home out task_id
  dir="$TMP_ROOT/relaunch-rollback-$RANDOM"
  home="$dir/home"
  mkdir -p "$home/state" "$home/data" "$dir/fake"
  make_tmux_stub "$dir"
  task_id=relaunch-t2
  fm_git_worktree "$dir/proj" "$dir/wt" "task-$task_id"
  mkdir -p "$home/data/$task_id"
  printf '# brief for %s\n\nDo the thing.\n' "$task_id" > "$home/data/$task_id/brief.md"
  {
    echo "window=fmses:fm-$task_id"
    echo "endpoint_task_id=$task_id"
    echo "worktree=$dir/wt"
    echo "project=$dir/proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$task_id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$task_id.meta"
  printf '%s\n' "fm-$task_id" > "$dir/fake/windows"
  printf '%s' "$dir/wt" > "$dir/fake/cwd"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  # The replacement agent never comes up, so the relaunch is rolled back after
  # its journal already exists.
  printf 'zsh' > "$dir/fake/becomes"

  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$task_id" relaunch --harness codex \
      --note "trying codex" 2>&1)
  local rc=$?
  [ "$rc" -ne 0 ] || fail "the relaunch should have failed when the replacement never came up: $out"
  [ -f "$home/state/$task_id.control-relaunch" ] \
    || fail "expected the rolled-back relaunch to leave its durable journal behind"
  grep -q '^relaunched=true$' "$home/state/$task_id.control-relaunch" \
    && fail "a rolled-back relaunch must not record relaunched=true in its journal"
  pass "fm-control.sh relaunch: a rolled-back relaunch leaves a journal that does not claim a relaunch happened"
}

# --- 4: real fm-teardown.sh -------------------------------------------------

make_teardown_case() {  # <name> -> echoes case dir with a landed, local-only, fork-remote ship task
  local name=$1 dir home proj wt task_id=task-x1
  dir="$TMP_ROOT/$name-$RANDOM"
  home="$dir/home"
  mkdir -p "$home/state" "$home/config" "$home/data" "$dir/fakebin"
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cp "$dir/fakebin/gh-axi" "$dir/fakebin/gh"
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fakebin/treehouse" "$dir/fakebin/tmux" "$dir/fakebin/gh-axi" "$dir/fakebin/gh" "$dir/fakebin/no-mistakes"

  proj="$dir/project"; wt="$dir/wt"
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/_seed"
  git -C "$dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "origin baseline"
  git -C "$dir/_seed" push -q origin main
  rm -rf "$dir/_seed"
  git clone -q "$dir/origin.git" "$proj"
  git -C "$proj" remote set-head origin main 2>/dev/null || true
  git -C "$proj" worktree add -q -b fm/task-x1 "$wt" main
  touch "$home/state/.last-watcher-beat"

  {
    echo "window=firstmate:fm-$task_id"
    echo "endpoint_task_id=$task_id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "kind=ship"
    echo "mode=local-only"
    echo "harness=claude"
    echo "model=opus"
    echo "purpose=code"
  } > "$home/state/$task_id.meta"

  git -C "$wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "fix the thing"
  git init -q --bare "$dir/fork.git"
  git -C "$proj" remote add fork "$dir/fork.git"
  git -C "$wt" push -q fork fm/task-x1
  git -C "$proj" fetch -q fork

  printf '%s\n' "$dir"
}

run_teardown() {  # <dir> [args...]
  local dir=$1; shift
  env FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_CONFIG_OVERRIDE="$dir/home/config" FM_HOME="$dir/home" \
    PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@" 2>&1
}

test_teardown_records_landed_outcome() {
  require_python3
  local dir out rc line found=0
  dir=$(make_teardown_case landed)
  out=$(run_teardown "$dir")
  rc=$?
  [ "$rc" -eq 0 ] || fail "teardown should succeed on landed local-only fork-remote work: $out"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(field "$line" event_type)" = outcome ] || continue
    [ "$(field "$line" task_id)" = task-x1 ] || continue
    [ "$(field "$line" result)" = landed ] || fail "outcome record should say landed: $line"
    [ "$(field "$line" harness)" = claude ] || fail "outcome record has wrong harness: $line"
    [ "$(field "$line" purpose)" = code ] || fail "outcome record has wrong purpose: $line"
    found=1
  done < <(archive_records "$dir/home")
  [ "$found" -eq 1 ] || fail "no outcome record was written for a real landed fm-teardown.sh run"
  pass "fm-teardown.sh: a real landed teardown records an outcome=landed archive record"
}

test_teardown_records_abandoned_outcome_on_force() {
  require_python3
  local dir out rc line found=0
  dir=$(make_teardown_case forced)
  # Make the work genuinely unlanded (no fork push) so only --force can pass,
  # proving the abandoned classification, not a landed one that also succeeds.
  git -C "$dir/project" remote remove fork
  out=$(run_teardown "$dir" --force)
  rc=$?
  [ "$rc" -eq 0 ] || fail "forced teardown should succeed: $out"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(field "$line" event_type)" = outcome ] || continue
    [ "$(field "$line" task_id)" = task-x1 ] || continue
    [ "$(field "$line" result)" = abandoned ] || fail "outcome record should say abandoned: $line"
    found=1
  done < <(archive_records "$dir/home")
  [ "$found" -eq 1 ] || fail "no outcome record was written for a real forced fm-teardown.sh run"
  pass "fm-teardown.sh: a real --force teardown of unlanded work records an outcome=abandoned archive record"
}

test_teardown_outcome_reports_retried_only_for_a_completed_relaunch() {
  require_python3
  local dir out rc line found=0
  dir=$(make_teardown_case retried)
  # The journal a completed fm-control.sh relaunch leaves behind.
  {
    echo "v1"
    echo "task=task-x1"
    echo "phase=complete"
    echo "relaunched=true"
  } > "$dir/home/state/task-x1.control-relaunch"
  out=$(run_teardown "$dir")
  rc=$?
  [ "$rc" -eq 0 ] || fail "teardown should succeed: $out"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(field "$line" event_type)" = outcome ] || continue
    [ "$(field "$line" retried)" = true ] || fail "outcome after a completed relaunch should say retried=true: $line"
    found=1
  done < <(archive_records "$dir/home")
  [ "$found" -eq 1 ] || fail "no outcome record was written"
  pass "fm-teardown.sh: an outcome after a completed relaunch records retried=true"
}

test_teardown_outcome_omits_retried_after_a_rolled_back_relaunch() {
  require_python3
  local dir out rc line found=0
  dir=$(make_teardown_case not-retried)
  # The journal a refused/rolled-back relaunch leaves behind: it exists, but no
  # replacement agent was ever confirmed.
  {
    echo "v1"
    echo "task=task-x1"
    echo "phase=failed:checkpoint"
    echo "rollback=instructions-restored"
  } > "$dir/home/state/task-x1.control-relaunch"
  out=$(run_teardown "$dir")
  rc=$?
  [ "$rc" -eq 0 ] || fail "teardown should succeed: $out"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(field "$line" event_type)" = outcome ] || continue
    [ -z "$(field "$line" retried)" ] \
      || fail "a rolled-back relaunch must not be reported as a retry: $line"
    found=1
  done < <(archive_records "$dir/home")
  [ "$found" -eq 1 ] || fail "no outcome record was written"
  pass "fm-teardown.sh: a rolled-back relaunch is not reported as retried"
}

test_teardown_archives_into_the_overridden_data_dir() {
  require_python3
  local dir out rc line found=0
  dir=$(make_teardown_case dataoverride)
  mkdir -p "$dir/elsewhere/data" "$dir/elsewhere/state"
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_DATA_OVERRIDE="$dir/elsewhere/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" FM_HOME="$dir/home" \
    PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "teardown should succeed: $out"
  [ ! -e "$dir/home/data/llm-usage/firstmate.jsonl" ] \
    || fail "telemetry was archived under FM_HOME/data while FM_DATA_OVERRIDE pointed elsewhere"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(field "$line" event_type)" = outcome ] || continue
    [ "$(field "$line" task_id)" = task-x1 ] || continue
    found=1
  done < "$dir/elsewhere/data/llm-usage/firstmate.jsonl"
  [ "$found" -eq 1 ] || fail "no outcome record landed in the overridden data dir"
  pass "fm-teardown.sh: telemetry follows FM_DATA_OVERRIDE instead of FM_HOME/data"
}

test_fresh_spawn_records_purpose_in_meta_and_dispatch_event
test_fresh_spawn_with_redelegation_records_delegation_event
test_fresh_spawn_without_redelegation_omits_from_task_id
test_fresh_spawn_rejects_path_traversal_redelegated_from
test_real_relaunch_records_delegation_event
test_teardown_records_landed_outcome
test_teardown_records_abandoned_outcome_on_force
test_rolled_back_relaunch_journal_does_not_claim_a_relaunch
test_teardown_outcome_reports_retried_only_for_a_completed_relaunch
test_teardown_outcome_omits_retried_after_a_rolled_back_relaunch
test_teardown_archives_into_the_overridden_data_dir
