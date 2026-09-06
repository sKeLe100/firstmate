#!/usr/bin/env bash
# Regression test for the PC02/opencode worktree write-guard plugin that
# bin/fm-spawn.sh installs at .opencode/plugins/fm-worktree-guard.js.
#
# Confirmed production incidents (2026-09-03 token-burn-item10-no-self-resume,
# 2026-09-06 fm-relaunch-rebinds-pr-poll) had an opencode crewmate write edits
# into the primary firstmate checkout instead of its assigned worktree. This
# test spawns a real opencode task, then drives the generated plugin in a
# plain Node host to prove it refuses a write/edit tool call resolving
# outside the task's worktree while allowing one that stays inside it.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-worktree-guard)

test_opencode_guard_blocks_writes_outside_worktree() {
  local case_dir home proj wt fakebin id=guard-block out plugin primary_dir outside_target
  case_dir="$TMP_ROOT/block"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" pi opencode claude codex)
  fm_test_spawn_home "$home" opencode
  fm_git_worktree "$proj" "$wt" "wt-$id"
  fm_test_spawn_brief "$home" "$id"

  out=$(GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
  expect_code 0 $? "opencode spawn should succeed: $out"

  plugin="$wt/.opencode/plugins/fm-worktree-guard.js"
  assert_present "$plugin" "opencode spawn did not write the worktree-guard plugin"

  # A stand-in "primary checkout" distinct from the task worktree, mirroring
  # the real primary firstmate checkout a PC02 worker must never write to.
  primary_dir="$case_dir/primary-checkout"
  mkdir -p "$primary_dir"
  outside_target="$primary_dir/leaked-edit.md"

  node --input-type=module -e "
    import('$plugin').then(async (mod) => {
      const hooks = await mod.FmWorktreeGuard();
      const before = hooks['tool.execute.before'];
      let blockedWrite = 'no-throw';
      try {
        await before({ tool: 'write' }, { args: { filePath: '$outside_target' } });
      } catch (e) {
        blockedWrite = 'threw: ' + e.message;
      }
      let allowedWrite = 'threw';
      try {
        await before({ tool: 'write' }, { args: { filePath: '$wt/inside.md' } });
        allowedWrite = 'no-throw';
      } catch (e) {
        allowedWrite = 'threw: ' + e.message;
      }
      let blockedEdit = 'no-throw';
      try {
        await before({ tool: 'edit' }, { args: { filePath: '$outside_target' } });
      } catch (e) {
        blockedEdit = 'threw: ' + e.message;
      }
      let allowedBash = 'threw';
      try {
        await before({ tool: 'bash' }, { args: { command: 'ls $primary_dir' } });
        allowedBash = 'no-throw';
      } catch (e) {
        allowedBash = 'threw: ' + e.message;
      }
      console.log('BLOCKED_WRITE=' + blockedWrite);
      console.log('ALLOWED_WRITE=' + allowedWrite);
      console.log('BLOCKED_EDIT=' + blockedEdit);
      console.log('ALLOWED_BASH=' + allowedBash);
    }).catch((e) => { console.error(e); process.exit(1); });
  " >"$case_dir/node.out" 2>"$case_dir/node.err"
  expect_code 0 $? "guard plugin should load and run under plain Node: $(cat "$case_dir/node.err")"

  out=$(cat "$case_dir/node.out")
  assert_contains "$out" "BLOCKED_WRITE=threw:" "guard must refuse a write resolving outside the worktree"
  assert_contains "$out" "ALLOWED_WRITE=no-throw" "guard must allow a write that stays inside the worktree"
  assert_contains "$out" "BLOCKED_EDIT=threw:" "guard must refuse an edit resolving outside the worktree"
  assert_contains "$out" "ALLOWED_BASH=no-throw" "guard must not block read-only bash commands"
  pass "opencode worktree-guard plugin blocks write/edit calls escaping the assigned worktree"
}

test_opencode_guard_blocks_writes_outside_worktree
