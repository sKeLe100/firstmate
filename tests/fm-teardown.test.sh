#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh - thin wrapper that sources all split test files.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-teardown-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-lib.sh"
set -u

fm_git_identity fmtest fmtest@example.invalid

# Source all split test files (each defines test_* functions only).
# shellcheck source=tests/fm-teardown-landed-work.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-landed-work.sh"
# shellcheck source=tests/fm-teardown-pr-check.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-pr-check.sh"
# shellcheck source=tests/fm-teardown-backlog-close.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-backlog-close.sh"
# shellcheck source=tests/fm-teardown-legacy-records.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-legacy-records.sh"
# shellcheck source=tests/fm-teardown-index-lock.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-index-lock.sh"
# shellcheck source=tests/fm-teardown-secondmate.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-secondmate.sh"
# shellcheck source=tests/fm-teardown-herdr.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-herdr.sh"
# shellcheck source=tests/fm-teardown-pipeline-spend.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-pipeline-spend.sh"
# shellcheck source=tests/fm-teardown-parked-run.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-parked-run.sh"
# shellcheck source=tests/fm-teardown-parked-run-edge.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-parked-run-edge.sh"
# shellcheck source=tests/fm-teardown-process-reap.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-process-reap.sh"
# shellcheck source=tests/fm-teardown-source-guards.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-source-guards.sh"

add_glab_mr_for_head() {
  local case_dir=$1 state=$2 head=$3
  cat > "$case_dir/fakebin/glab" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/glab.log"
[ "\${1:-} \${2:-}" = "mr view" ] || exit 1
printf '{"state":"%s","sha":"%s","squash_commit_sha":"%s"}\n' '$state' '$head' 0000000000000000000000000000000000000001
SH
  chmod +x "$case_dir/fakebin/glab"
}

install_status_archive_publish_probe() {
  local case_dir=$1 command
  for command in ln mv; do
    cat > "$case_dir/fakebin/$command" <<'SH'
#!/usr/bin/env bash
case "${*: -1}" in
  */status.log)
    touch "$FM_ARCHIVE_TEST_CASE/publish-entered"
    if [ "$FM_ARCHIVE_TEST_MODE" = fail ]; then
      echo 'simulated archive publication failure' >&2
      exit 1
    fi
    bash -c '
      . "$1/bin/fm-watch.sh"
      scan_signals
    ' _ "$FM_ROOT_OVERRIDE" > "$FM_ARCHIVE_TEST_CASE/publish-signals" || exit 1
    ;;
esac
exec "/bin/${0##*/}" "$@"
SH
    chmod +x "$case_dir/fakebin/$command"
  done
}

# Intercept both the old move and atomic publication so the regressions also
# exercise the failure and watcher window on the pre-fix implementation.
prepare_status_archive_presentation() {
  local case_dir=$1
  write_meta "$case_dir" local-only ship
  touch "$case_dir/config/status-archive" "$case_dir/config/supervision-host-off"
  printf 'note: archived note\ndone: archived outcome\n' > "$case_dir/state/task-x1.status"
  FM_STATE_OVERRIDE="$case_dir/state" FM_CONFIG_OVERRIDE="$case_dir/config" FM_DATA_OVERRIDE="$case_dir/data" \
    bash "$ROOT/bin/fm-wake-drain.sh" > "$case_dir/before" 2> "$case_dir/drain.err" || fail "initial presentation failed"
  assert_grep 'archived note' "$case_dir/before" "fixture never presented the live note"
  FM_STATE_OVERRIDE="$case_dir/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_wake_status_mark_current "$2" "$2/task-x1.status"
  ' _ "$ROOT" "$case_dir/state" || fail "could not mark fixture status seen"
  printf 'ledger\n' > "$case_dir/state/.task-x1.home-appends"
  touch "$case_dir/state/.hb-surfaced-task-x1"
}

# Exercise Git's capability/error boundary through the real teardown entry point.
# Only merge-tree is intercepted; history, fetches, and preservation checks are real.
test_content_fallback_git_capability_boundary() {
  local mode case_dir rc head
  for mode in unsupported contained conflict unlanded error; do
    case_dir=$(make_case "content-git-$mode")
    write_meta "$case_dir" no-mistakes ship
    wt_commit_file "$case_dir" feature.txt hello "add feature"
    case "$mode" in
      conflict) land_on_origin_main "$case_dir" feature.txt different ;;
      unlanded) ;;
      *) land_on_origin_main "$case_dir" feature.txt hello ;;
    esac
    head=$(git -C "$case_dir/wt" rev-parse HEAD)
    cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
args=("$@")
if [ "${1:-}" = -C ]; then shift 2; fi
if [ "${1:-}" = merge-tree ]; then
  printf '%s\n' "$*" >> "${FM_TEST_MERGE_TREE_LOG:?}"
  case "${FM_TEST_MERGE_TREE_MODE:?}" in
    unsupported)
      echo "error: unknown option 'write-tree'" >&2
      exit 129 ;;
    error)
      echo 'fatal: unable to read tree object' >&2
      exit 128 ;;
  esac
fi
exec "$REAL_GIT_FOR_TEST" "${args[@]}"
SH
    cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_TREEHOUSE_LOG:?}"
exit 0
SH
    chmod +x "$case_dir/fakebin/git" "$case_dir/fakebin/treehouse"

    set +e
    FM_TEST_MERGE_TREE_MODE="$mode" \
      FM_TEST_MERGE_TREE_LOG="$case_dir/merge-tree.log" \
      FM_TEST_TREEHOUSE_LOG="$case_dir/treehouse.log" \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    grep -q -- 'merge-tree --write-tree' "$case_dir/merge-tree.log" \
      || fail "content-git-$mode: never attempted the containment proof"
    if [ "$mode" = contained ]; then
      expect_code 0 "$rc" "content-git-contained: supported containment should allow cleanup"
      assert_present "$case_dir/treehouse.log" "content-git-contained: cleanup never ran"
      assert_absent "$case_dir/state/task-x1.meta" "content-git-contained: task record survived cleanup"
      continue
    fi
    expect_code 1 "$rc" "content-git-$mode: teardown must refuse"
    assert_refusal_retained_task_state "$case_dir" "content-git-$mode" "$head"
    assert_absent "$case_dir/treehouse.log" "content-git-$mode: cleanup ran despite refusal"
    case "$mode" in
      unsupported|error)
        grep -q 'content-landed proof unavailable' "$case_dir/stderr" \
          || fail "content-git-$mode: unavailable proof was reported as unlanded work"
        ! grep -q 'not landed' "$case_dir/stderr" \
          || fail "content-git-$mode: unavailable proof still claims work is not landed"
        if [ "$mode" = unsupported ]; then
          grep -q -- 'merge-tree --write-tree.*Git 2.38' "$case_dir/stderr" \
            || fail 'content-git-unsupported: missing capability and Git requirement were not named'
        else
          grep -q 'Git exit 128' "$case_dir/stderr" \
            || fail 'content-git-error: unrelated Git failure was not identified'
          ! grep -q 'Git 2.38' "$case_dir/stderr" \
            || fail 'content-git-error: unrelated failure was mislabeled as old Git'
        fi
        ;;
      *)
        grep -q 'not landed' "$case_dir/stderr" \
          || fail "content-git-$mode: genuine unlanded-work refusal changed"
        ! grep -q 'proof unavailable' "$case_dir/stderr" \
          || fail "content-git-$mode: supported Git was reported as unavailable"
        ;;
    esac
  done
  pass 'content fallback distinguishes unavailable Git proof, containment, conflicts, and unlanded content'
}

# A fresh Herdr task's pane shell lives in its leased copy, and `treehouse
# return` ends every process there, so returning the copy first kills the pane
# outside the focus-preserving close; Herdr below 0.8.0 then moves focus to a
# neighbouring workspace with nothing to restore it. This fake return models
# exactly that pane death and focus move.
test_herdr_projection_teardown_closes_pane_before_returning_its_copy() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-close-before-return)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  printf 'treehouse %s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
  : > "${FM_FAKE_HERDR_CLOSED:?}"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-close-before-return: forced teardown failed: $(cat "$case_dir/stderr")"
  assert_contains "$(cat "$log")" "treehouse return" \
    "herdr-projection-close-before-return: regression did not exercise the copy return"
  [ "$(awk '/pane close/ { print "close"; exit } /treehouse return/ { print "return"; exit }' "$log")" = close ] \
    || fail "herdr-projection-close-before-return: teardown returned the copy before closing the exact pane: $(cat "$log")"
  assert_contains "$(cat "$log")" "tab focus w2:t2" \
    "herdr-projection-close-before-return: teardown did not restore the exact pre-close active tab"
  pass "herdr projection teardown closes its exact pane, restoring focus, before returning the copy that holds its shell"
}

test_herdr_projection_teardown_refused_close_preserves_task_and_copy() {
  local case_dir log closed restored wt process_pid rc=0 process_survived=0
  case_dir=$(make_case herdr-projection-refused-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  printf 'running\n' > "$case_dir/state/task-x1.status"
  wt="$case_dir/wt"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  perl -e 'chdir $ARGV[0] or die $!; exec "sleep", "300" or die $!' "$wt" &
  process_pid=$!
  sleep 0.1
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    FM_FAKE_HERDR_CLOSE_FAIL=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  kill -0 "$process_pid" 2>/dev/null && process_survived=1
  kill "$process_pid" 2>/dev/null || true
  wait "$process_pid" 2>/dev/null || true

  expect_code 1 "$rc" "herdr-projection-refused-close: teardown should fail after the exact pane remains present"
  [ "$process_survived" = 1 ] \
    || fail "herdr-projection-refused-close: teardown reaped the pane shell in the task copy after the close was refused"
  assert_not_contains "$(cat "$log")" "treehouse return" \
    "herdr-projection-refused-close: teardown returned the task copy after the close was refused"
  assert_present "$case_dir/state/task-x1.meta" \
    "herdr-projection-refused-close: refusal erased the task metadata"
  assert_present "$case_dir/state/task-x1.status" \
    "herdr-projection-refused-close: refusal erased the task status"
  assert_present "$case_dir/state/task-x1.herdr-presentation" \
    "herdr-projection-refused-close: refusal erased the presentation journal"
  assert_grep "not confirmed gone" "$case_dir/stderr" \
    "herdr-projection-refused-close: refusal did not explain why teardown stopped"
  pass "herdr projection teardown retains the task, pane shell, and leased copy after a refused close"
}

test_merged_pr_patch_matching_preserves_indentation() {
  local case_dir mode rc pr_head local_head expected
  for mode in exact amended old-git; do
    case_dir=$(make_case "pr-indentation-$mode")
    write_meta "$case_dir" no-mistakes ship
    # A pushed parent makes the YAML patch the only unpushed commit, while
    # giving the local replay a different parent from the recorded PR head.
    wt_commit_file "$case_dir" local-parent.txt parent "local parent"
    git -C "$case_dir/wt" push -q origin HEAD:refs/heads/fm/task-x1
    git -C "$case_dir/project" fetch -q origin fm/task-x1
    wt_commit_file "$case_dir" config.yml $'a:\n  b: 1' "add YAML"
    append_pr_meta_url "$case_dir"
    pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head config.yml $'a:\n  b: 1' "add YAML")
    printf 'pr_head=%s\n' "$pr_head" >> "$case_dir/state/task-x1.meta"
    add_gh_pr_merged_for_head "$case_dir" "$pr_head"
    if [ "$mode" = amended ]; then
      printf 'a:\nb: 1\n' > "$case_dir/wt/config.yml"
      git -C "$case_dir/wt" add -- config.yml
      git -C "$case_dir/wt" commit -q --amend --no-edit
    elif [ "$mode" = old-git ]; then
      cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = patch-id ]; then
  printf '%s\n' "$*" >> "$FM_PATCH_ID_LOG"
  if [ "${2:-}" = --verbatim ]; then
    echo 'error: unknown option `verbatim`' >&2
    exit 129
  fi
fi
exec "$REAL_GIT_FOR_TEST" "$@"
SH
      chmod +x "$case_dir/fakebin/git"
    fi
    local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
    [ "$local_head" != "$pr_head" ] || fail "$mode: fixture did not diverge"

    set +e
    FM_PATCH_ID_LOG="$case_dir/patch-id.log" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expected=1
    [ "$mode" != exact ] || expected=0
    expect_code "$expected" "$rc" "pr-indentation-$mode: teardown exit"$'\n'"$(cat "$case_dir/stderr")"
    if [ "$expected" = 1 ]; then
      assert_grep REFUSED "$case_dir/stderr" "$mode: no refusal diagnostic"
      assert_refusal_retained_task_state "$case_dir" "$mode" "$local_head"
    fi
    if [ "$mode" = old-git ]; then
      assert_grep 'patch-id --verbatim' "$case_dir/patch-id.log" "old-git: capability rejection was not exercised"
      ! grep -q -- --stable "$case_dir/patch-id.log" || fail "old-git: fell back to whitespace-insensitive matching"
    fi
  done
  pass "merged PR patch matching preserves indentation, allows exact replays, and refuses unsupported Git"
}

test_record_export_archives_before_teardown_or_preserves_sources_on_failure() {
  local case_dir export_root archive rc mode
  for mode in success failure inaccessible-config; do
    case_dir=$(make_case "record-export-$mode")
    write_meta "$case_dir" local-only ship
    export_root="$case_dir/export"
    printf '%s\n' "$export_root" > "$case_dir/config/record-export-root"
    mkdir -p "$case_dir/state/task-x1.inbox/handled"
    printf 'working: export me\ndone: complete\n' > "$case_dir/state/task-x1.status"
    printf 'pending captain text\n' > "$case_dir/state/task-x1.inbox/001.msg"
    printf 'handled captain text\n' > "$case_dir/state/task-x1.inbox/handled/002.msg"
    cp "$case_dir/state/task-x1.meta" "$case_dir/expected.meta"
    cp "$case_dir/state/task-x1.status" "$case_dir/expected.status"
    if [ "$mode" = failure ]; then
      printf 'not an export directory\n' > "$export_root"
    elif [ "$mode" = inaccessible-config ]; then
      mv "$case_dir/config" "$case_dir/config-target"
      ln -s "$case_dir/config-target" "$case_dir/config"
    fi
    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if [ "$mode" = success ]; then
      expect_code 0 "$rc" "record export teardown: $(cat "$case_dir/stderr")"
      archive="$export_root/archive/task-x1/teardown-test-task-x1"
      cmp -s "$case_dir/expected.meta" "$archive/meta" || fail "teardown archive lost metadata"
      cmp -s "$case_dir/expected.status" "$archive/status" || fail "teardown archive lost status"
      assert_grep 'pending captain text' "$archive/inbox/001.msg" "teardown archive lost a pending steer"
      assert_grep 'handled captain text' "$archive/inbox/handled/002.msg" "teardown archive lost a handled steer"
      assert_present "$archive/manifest.v1.json" "teardown archive did not commit its manifest"
      assert_absent "$case_dir/state/task-x1.meta" "successful export retained metadata"
      assert_absent "$case_dir/state/task-x1.status" "successful export retained status"
      assert_absent "$case_dir/state/task-x1.inbox" "successful export retained inbox"
    else
      [ "$rc" -ne 0 ] || fail "teardown ignored a record export failure in $mode mode: $(cat "$case_dir/stderr")"
      assert_grep 'record export' "$case_dir/stderr" \
        "teardown did not report the export failure reason"
      assert_grep 'retaining task records for retry' "$case_dir/stderr" \
        "teardown did not explain its record-preservation refusal"
      assert_present "$case_dir/state/task-x1.meta" "failed export removed metadata"
      assert_present "$case_dir/state/task-x1.status" "failed export removed status"
      assert_present "$case_dir/state/task-x1.inbox/001.msg" "failed export removed a pending steer"
      assert_present "$case_dir/state/task-x1.inbox/handled/002.msg" "failed export removed a handled steer"
    fi
  done
  pass "teardown commits the record archive before deleting sources and fails closed when export cannot commit"
}

test_record_export_captures_forced_secondmate_sub_state() {
  local case_dir home export_root archive rc=0
  case_dir=$(make_case record-export-secondmate-child)
  write_meta "$case_dir" local-only secondmate
  home="$case_dir/secondmate-home"
  export_root="$case_dir/export"
  mkdir -p "$home/state/child.inbox/handled" "$home/data" "$home/config" "$home/projects"
  printf 'task-x1\n' > "$home/.fm-secondmate-home"
  printf 'home=%s\n' "$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/child.meta" \
    "window=firstmate:fm-child" \
    "kind=scout" \
    "mode=local-only" \
    "project=$case_dir/project" \
    "worktree=$case_dir/wt" \
    "spawn_gen=child-generation"
  printf 'done: child complete\n' > "$home/state/child.status"
  printf 'pending child steer\n' > "$home/state/child.inbox/001.msg"
  printf 'handled child steer\n' > "$home/state/child.inbox/handled/002.msg"
  printf '%s\n' "$export_root" > "$case_dir/config/record-export-root"
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "forced secondmate record export: $(cat "$case_dir/stderr")"
  archive="$export_root/archive/child/child-generation"
  assert_present "$archive/meta" "secondmate child archive lost metadata"
  assert_grep 'done: child complete' "$archive/status" "secondmate child archive lost status"
  assert_grep 'pending child steer' "$archive/inbox/001.msg" "secondmate child archive lost pending inbox"
  assert_grep 'handled child steer' "$archive/inbox/handled/002.msg" "secondmate child archive lost handled inbox"
  assert_present "$archive/manifest.v1.json" "secondmate child archive did not commit"
  assert_absent "$home" "forced secondmate teardown retained the child home"
  pass "forced secondmate teardown exports task records from the child sub-state"
}

test_record_export_config_absent_never_reads_the_exporter() {
  local case_dir rc=0
  case_dir=$(make_case record-export-off)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-record-export.sh"
  mkdir -p "$case_dir/state/task-x1.inbox/handled"
  printf 'pending\n' > "$case_dir/state/task-x1.inbox/001.msg"
  run_copied_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "config-absent teardown without exporter: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.meta" "config-absent teardown retained metadata"
  assert_absent "$case_dir/state/task-x1.status" "config-absent teardown retained status"
  assert_absent "$case_dir/state/task-x1.inbox" "config-absent teardown retained inbox"
  pass "config-absent teardown does not read or invoke record export"
}

test_record_export_unopted_symlinked_config_does_not_block_teardown() {
  local case_dir rc=0
  case_dir=$(make_case record-export-symlink-config-off)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-record-export.sh"
  mv "$case_dir/config" "$case_dir/config-target"
  ln -s "$case_dir/config-target" "$case_dir/config"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "unopted symlinked config teardown: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.meta" "unopted symlinked config retained metadata"
  assert_absent "$case_dir/state/task-x1.status" "unopted symlinked config retained status"
  pass "unopted teardown ignores symlinked config when record export is absent"
}

test_record_export_waits_for_endpoint_quiescence_before_archiving() {
  local case_dir export_root archive rc=0
  case_dir=$(make_case record-export-close-retry)
  write_meta "$case_dir" local-only ship
  export_root="$case_dir/export"
  printf '%s\n' "$export_root" > "$case_dir/config/record-export-root"
  mkdir -p "$case_dir/state/task-x1.inbox/handled"
  printf 'done: before refusal\n' > "$case_dir/state/task-x1.status"
  printf 'before refusal\n' > "$case_dir/state/task-x1.inbox/001.msg"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  kill-window) exit 1 ;;
  list-windows) printf '%s\n' fm-task-x1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  run_teardown "$case_dir" > "$case_dir/first.stdout" 2> "$case_dir/first.stderr" || rc=$?
  expect_code 1 "$rc" "record-export-close-retry: endpoint close should refuse"
  assert_grep "could not be closed" "$case_dir/first.stderr" \
    "record-export-close-retry: first attempt did not reach endpoint refusal"
  assert_absent "$export_root/archive/task-x1/teardown-test-task-x1" \
    "record-export-close-retry: archive published while the endpoint remained live"
  assert_present "$case_dir/state/task-x1.meta" \
    "record-export-close-retry: endpoint refusal removed metadata"

  printf 'done: after refusal\n' > "$case_dir/state/task-x1.status"
  printf 'after refusal\n' > "$case_dir/state/task-x1.inbox/001.msg"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  rc=0
  run_teardown "$case_dir" > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "record-export-close-retry: retry should complete"
  archive="$export_root/archive/task-x1/teardown-test-task-x1"
  assert_grep "done: after refusal" "$archive/status" \
    "record-export-close-retry: retry archive contains status from before endpoint quiescence"
  assert_grep "after refusal" "$archive/inbox/001.msg" \
    "record-export-close-retry: retry archive contains inbox from before endpoint quiescence"
  assert_absent "$case_dir/state/task-x1.meta" \
    "record-export-close-retry: successful retry retained task metadata"
  pass "record export waits for endpoint quiescence and retry captures records changed after refusal"
}

# An orphan status log archived by record hygiene must survive status-archive
# retention: the prune counts 30 days from archive time, not the log's last write.
test_record_hygiene_archive_survives_status_archive_prune() {
  local case_dir rc=0
  case_dir=$(make_case record-hygiene-archive-retention)
  write_meta "$case_dir" local-only ship
  touch "$case_dir/config/status-archive"
  printf 'done: complete\n' > "$case_dir/state/task-x1.status"
  printf 'failed [at=1]: orphan from a lost task\n' > "$case_dir/state/orphan-x2.status"
  touch -t 200001010000 "$case_dir/state/orphan-x2.status"
  FM_TEST_LIB_SOURCED=1 bash -c '
    SCRIPT_DIR="$1/bin"; STATE="$2/state"; DATA="$2/data"
    # shellcheck source=bin/fm-classify-lib.sh
    . "$SCRIPT_DIR/fm-classify-lib.sh"
    # shellcheck source=bin/fm-tasks-axi-lib.sh
    . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
    # shellcheck source=bin/fm-backlog-transition-lib.sh
    . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
    # shellcheck source=bin/fm-backend.sh
    . "$SCRIPT_DIR/fm-backend.sh"
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$SCRIPT_DIR/fm-timeout-lib.sh"
    # shellcheck source=bin/fm-record-hygiene-lib.sh
    . "$SCRIPT_DIR/fm-record-hygiene-lib.sh"
    record_hygiene_report
  ' _ "$ROOT" "$case_dir" > "$case_dir/hygiene.out" 2>&1 || fail "record hygiene archive pass failed: $(cat "$case_dir/hygiene.out")"
  assert_present "$case_dir/data/orphan-x2/status.log" "record hygiene did not archive the orphan status log"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "status-archive teardown after record hygiene: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/data/task-x1/status.log" "status-archive teardown did not archive its own task"
  assert_present "$case_dir/data/orphan-x2/status.log" "teardown pruned a status log record hygiene just archived"
  pass "a status log archived by record hygiene survives the next status-archive teardown"
}

# The checks-green report is read as bin/fm-crew-state.sh reads it: a note
# that names this PR and reports checks green releases the ready line even
# with text around the report, while one naming a PR whose number merely
# starts with this PR's number does not.
test_secondmate_pr_ready_line_follows_green_report_with_trailing_text() {
  local case_dir channel url pr_head
  url=https://github.com/example/repo/pull/7
  case_dir=$(make_case mate-pr-ready-green-text)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  mkdir -p "$case_dir/parent/state" "$case_dir/home/config"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  : > "$case_dir/home/config/ready-after-green"
  run() {
    FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
      PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" > "$case_dir/pr-check.out" 2> "$case_dir/pr-check.err" \
      || fail "mate-pr-ready-green-text: fm-pr-check failed: $(cat "$case_dir/pr-check.err")"
  }

  printf 'done [at=1]: PR %s0 checks green, held for captain merge\n' "$url" > "$case_dir/state/task-x1.status"
  run
  [ ! -e "$channel" ] || ! grep -q 'child-pr-task-x1' "$channel" \
    || fail "mate-pr-ready-green-text: a report naming PR 70 released PR 7's ready line"

  printf 'done [at=2]: PR %s checks green, held for captain merge.\n' "$url" >> "$case_dir/state/task-x1.status"
  run
  assert_grep "done [key=child-pr-task-x1]: child task-x1 PR ready: $url mode=no-mistakes" <(sed -E 's/ \[at=[0-9]+\]//' "$channel") \
    "mate-pr-ready-green-text: a checks-green report with trailing text did not release the ready line"
  ! grep -q '^actionable:' "$case_dir/pr-check.err" \
    || fail "mate-pr-ready-green-text: the released ready line was reported as a channel problem"
  pass "fm-pr-check releases the PR-ready line on a checks-green report that carries surrounding text"
}

# With config/ready-after-green present, registering a no-mistakes PR in a
# secondmate home withholds the ready line until the child's own status holds
# the checks-green report for that exact PR; without the flag it publishes at
# registration as before.
test_secondmate_pr_ready_line_waits_for_green_when_opted_in() {
  local case_dir channel url other pr_head
  url=https://github.com/example/repo/pull/7
  other=https://github.com/example/repo/pull/8
  case_dir=$(make_case mate-pr-ready-green)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  mkdir -p "$case_dir/parent/state" "$case_dir/home/config"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  run() {
    FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
      PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" > "$case_dir/pr-check.out" 2> "$case_dir/pr-check.err" \
      || fail "mate-pr-ready-green: fm-pr-check failed: $(cat "$case_dir/pr-check.err")"
  }

  : > "$case_dir/home/config/ready-after-green"
  printf 'working [at=1]: waiting for CI on %s\n' "$url" > "$case_dir/state/task-x1.status"
  run
  grep -q '^armed:' "$case_dir/pr-check.out" || fail "mate-pr-ready-green: the poll was not armed while checks were pending"
  [ ! -e "$channel" ] || ! grep -q 'child-pr-task-x1' "$channel" \
    || fail "mate-pr-ready-green: the ready line was published before the checks-green report"
  ! grep -q '^actionable:' "$case_dir/pr-check.err" \
    || fail "mate-pr-ready-green: a withheld ready line was reported as a channel problem"

  printf 'done [at=2]: PR %s checks green\n' "$other" >> "$case_dir/state/task-x1.status"
  run
  [ ! -e "$channel" ] || ! grep -q 'child-pr-task-x1' "$channel" \
    || fail "mate-pr-ready-green: another PR's checks-green report released this PR's ready line"

  printf 'done [at=3]: PR %s checks green\n' "$url" >> "$case_dir/state/task-x1.status"
  run
  assert_grep "done [key=child-pr-task-x1]: child task-x1 PR ready: $url mode=no-mistakes" <(sed -E 's/ \[at=[0-9]+\]//' "$channel") \
    "mate-pr-ready-green: the ready line did not follow the checks-green report"

  rm -f "$channel" "$case_dir/home/config/ready-after-green"
  printf 'working [at=4]: waiting for CI on %s\n' "$url" > "$case_dir/state/task-x1.status"
  run
  assert_grep "done [key=child-pr-task-x1]: child task-x1 PR ready: $url mode=no-mistakes" <(sed -E 's/ \[at=[0-9]+\]//' "$channel") \
    "mate-pr-ready-green: without the flag the ready line left its registration-time behavior"
  pass "fm-pr-check withholds the PR-ready line until checks are green when config/ready-after-green is present"
}

# A GitLab merge request squash-merged (or merged by a merge train) lands a
# commit on main that is not the MR head, and main then moved on over the same
# lines, so the content check is inconclusive. The MR's own head is published
# only as refs/merge-requests/<n>/head, which this copy never fetched. With
# config/park-on-review or config/auto-land present, teardown must read the MR
# through glab, fetch that ref, and accept the merged record; the same history
# with the MR still open refuses. With neither flag the merged MR is never read
# through glab and teardown refuses on the inconclusive content check.
test_squash_merged_gitlab_mr_allows_when_main_moved_on() {
  local case_dir rc local_head pr_head tmp scenario state expected
  for scenario in merged:park-on-review merged:auto-land opened:park-on-review merged:; do
    state=${scenario%%:*}
    case_dir=$(make_case "gitlab-mr-$state-${scenario#*:}")
    write_meta "$case_dir" no-mistakes ship
    wt_commit_file "$case_dir" feature.txt hello "add feature"
    local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
    tmp="$case_dir/_pipeline"
    git clone -q "$case_dir/origin.git" "$tmp"
    git -C "$tmp" fetch -q "$case_dir/wt" "fm/task-x1:fm/task-x1"
    git -C "$tmp" checkout -q fm/task-x1
    printf '%s\n' pipeline > "$tmp/fix.txt"
    git -C "$tmp" add -- fix.txt
    git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "no-mistakes fix"
    pr_head=$(git -C "$tmp" rev-parse HEAD)
    git -C "$tmp" push -q origin "HEAD:refs/merge-requests/7/head"
    git -C "$tmp" checkout -q main
    printf '%s\n' reworded > "$tmp/feature.txt"
    git -C "$tmp" add -- feature.txt
    git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash then main rewords"
    git -C "$tmp" push -q origin main
    rm -rf "$tmp"
    ! git -C "$case_dir/wt" cat-file -e "$pr_head^{commit}" 2>/dev/null \
      || fail "gitlab-mr-$state: test setup bug, the MR head is already local"
    printf '%s\n' 'pr=https://gitlab.example.com/team/sub/repo/-/merge_requests/7' \
      >> "$case_dir/state/task-x1.meta"
    add_gh_axi_error "$case_dir"
    add_glab_mr_for_head "$case_dir" "$state" "$pr_head"
    [ -z "${scenario#*:}" ] || : > "$case_dir/config/${scenario#*:}"

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    if [ -z "${scenario#*:}" ]; then
      expect_code 1 "$rc" "gitlab-mr-no-flag: teardown exit"$'\n'"$(cat "$case_dir/stderr")"
      [ ! -e "$case_dir/glab.log" ] || fail "gitlab-mr-no-flag: teardown read the merge request through glab without an opt-in flag"
      grep -q REFUSED "$case_dir/stderr" || fail "gitlab-mr-no-flag: no REFUSED line in stderr"
      assert_refusal_retained_task_state "$case_dir" gitlab-mr-no-flag "$local_head"
      continue
    fi
    expected=1
    [ "$state" != merged ] || expected=0
    expect_code "$expected" "$rc" "gitlab-mr-$scenario: teardown exit"$'\n'"$(cat "$case_dir/stderr")"
    grep -qF -- 'mr view 7 -R https://gitlab.example.com/team/sub/repo -F json' "$case_dir/glab.log" \
      || fail "gitlab-mr-$scenario: teardown did not read the merge request through glab"
    if [ "$state" = merged ]; then
      ! grep -q REFUSED "$case_dir/stderr" || fail "gitlab-mr-merged: teardown printed a REFUSED line"
    else
      grep -q REFUSED "$case_dir/stderr" || fail "gitlab-mr-opened: no REFUSED line in stderr"
      assert_refusal_retained_task_state "$case_dir" gitlab-mr-opened "$local_head"
    fi
  done
  pass "teardown proves a squash- or train-merged GitLab MR landed from the MR head only with an opt-in flag, and refuses an open one"
}

test_status_archive_cursor_failure_retries_without_duplicate() {
  local case_dir rc
  case_dir=$(make_case status-archive-cursor-retry)
  prepare_status_archive_presentation "$case_dir"
  cp "$case_dir/state/task-x1.status" "$case_dir/expected"
  cp "$case_dir/state/.status-presentation-cursor" "$case_dir/cursor.before"
  printf 'broken\tidentity\tnot-an-offset\t0\n' >> "$case_dir/state/.status-presentation-cursor"
  cp "$case_dir/state/.status-presentation-cursor" "$case_dir/cursor.malformed"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "malformed presentation cursor"
  assert_present "$case_dir/state/task-x1.status" "cursor failure lost live history"
  cmp -s "$case_dir/cursor.malformed" "$case_dir/state/.status-presentation-cursor" \
    || fail "cursor failure changed presentation rows"
  assert_absent "$case_dir/data/task-x1/status.log" "failed retirement left a duplicate archive"
  assert_present "$case_dir/state/task-x1.meta" "cursor failure removed task metadata"
  cp "$case_dir/cursor.before" "$case_dir/state/.status-presentation-cursor"
  rc=0
  run_teardown "$case_dir" > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "retry after cursor repair"
  cmp -s "$case_dir/expected" "$case_dir/data/task-x1/status.log" || fail "retry archive lost history"
  assert_absent "$case_dir/state/task-x1.status" "successful retry retained live status"
  assert_absent "$case_dir/data/task-x1/status.1.log" "retry wrote a duplicate archive"
  pass "cursor retirement failure removes its archive so retry publishes one history"
}

test_status_archive_failed_publish_preserves_presentation() {
  local case_dir rc
  case_dir=$(make_case status-archive-failed-publish)
  prepare_status_archive_presentation "$case_dir"
  cp "$case_dir/state/.status-presentation-cursor" "$case_dir/cursor.before"
  cp "$case_dir/state/.seen-task-x1_status" "$case_dir/seen.before"
  install_status_archive_publish_probe "$case_dir"
  rc=0
  FM_ARCHIVE_TEST_CASE="$case_dir" FM_ARCHIVE_TEST_MODE=fail \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "failed archive publication"
  assert_present "$case_dir/publish-entered" "fixture never attempted publication"
  cmp -s "$case_dir/cursor.before" "$case_dir/state/.status-presentation-cursor" || fail "failed archive retired presentation cursor"
  cmp -s "$case_dir/seen.before" "$case_dir/state/.seen-task-x1_status" || fail "failed archive cleared seen marker"
  assert_present "$case_dir/state/.task-x1.home-appends" "failed archive cleared home append ledger"
  assert_present "$case_dir/state/task-x1.status" "failed archive lost live history"
  assert_present "$case_dir/state/task-x1.meta" "failed archive removed task metadata"
  FM_STATE_OVERRIDE="$case_dir/state" FM_CONFIG_OVERRIDE="$case_dir/config" FM_DATA_OVERRIDE="$case_dir/data" \
    bash "$ROOT/bin/fm-wake-drain.sh" > "$case_dir/after" 2>> "$case_dir/drain.err" || fail "retry presentation failed"
  assert_no_grep 'archived note' "$case_dir/after" "failed archive re-presented note"
  assert_no_grep 'archived outcome' "$case_dir/after" "failed archive re-presented outcome"
  pass "failed archive publication preserves presentation and watcher bookkeeping"
}

test_status_archive_missing_status_noop() {
  local case_dir rc
  case_dir=$(make_case status-archive-missing-status)
  write_meta "$case_dir" local-only ship
  touch "$case_dir/config/status-archive"
  mkdir -p "$case_dir/state/.status-presentation-lock"
  printf '%s\n' "$$" > "$case_dir/state/.status-presentation-lock/pid"
  printf 'neighbor\tidentity\t0\t0\n' > "$case_dir/state/.status-presentation-cursor"
  cp "$case_dir/state/.status-presentation-cursor" "$case_dir/cursor.before"
  # A regression must fail within a bound, not wait forever on our live lock.
  . "$ROOT/bin/fm-timeout-lib.sh"
  rc=0
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    fm_run_timed 20 "$TEARDOWN" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "local missing-status retirement"
  cmp -s "$case_dir/cursor.before" "$case_dir/state/.status-presentation-cursor" || fail "missing-status no-op rewrote neighboring cursor"
  assert_present "$case_dir/state/.status-presentation-lock" "missing-status no-op contended with presentation lock"
  assert_absent "$case_dir/data/task-x1" "missing-status no-op created empty archive"
  pass "local missing-status retirement stays lock-free without creating an archive"
}

test_status_archive_nested_secondmate_children() {
  local case_dir home nested_home rc unsafe
  for unsafe in none children; do
    case_dir=$(make_case "status-archive-nested-$unsafe")
    write_meta "$case_dir" local-only secondmate
    home="$case_dir/secondmate-home"
    nested_home="$home/nested-home"
    mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" \
      "$nested_home/state" "$nested_home/data" "$nested_home/config" "$nested_home/projects"
    printf 'task-x1\n' > "$home/.fm-secondmate-home"
    printf 'nested-sm\n' > "$nested_home/.fm-secondmate-home"
    printf 'home=%s\n' "$home" >> "$case_dir/state/task-x1.meta"
    fm_write_meta "$home/state/nested-sm.meta" "window=firstmate:fm-nested-sm" \
      "kind=secondmate" "mode=local-only" "home=$nested_home" "project=$case_dir/project" "worktree=$case_dir/wt"
    fm_write_meta "$nested_home/state/grandchild.meta" "window=firstmate:fm-grandchild" \
      "kind=scout" "mode=local-only" "project=$case_dir/project" "worktree=$case_dir/wt"
    touch "$case_dir/config/status-archive"
    printf 'done: parent history\n' > "$case_dir/state/task-x1.status"
    printf 'done: child history\n' > "$home/state/nested-sm.status"
    printf 'done: grandchild history\n' > "$nested_home/state/grandchild.status"
    printf 'marker\n' > "$case_dir/state/.paused-overdue-task-x1"
    printf 'marker\n' > "$home/state/.paused-overdue-nested-sm"
    printf 'marker\n' > "$nested_home/state/.paused-overdue-grandchild"
    if [ "$unsafe" = children ]; then
      mkdir -p "$case_dir/data/task-x1" "$case_dir/outside"
      ln -s "$case_dir/outside" "$case_dir/data/task-x1/children"
    fi
    rc=0
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if [ "$unsafe" = children ]; then
      expect_code 1 "$rc" "symlinked child archive directory"
      assert_present "$nested_home/state/grandchild.status" "unsafe child archive lost history"
      assert_absent "$case_dir/outside/nested-sm" "child archive escaped through symlink"
    else
      expect_code 0 "$rc" "nested secondmate status archive: $(cat "$case_dir/stderr")"
      assert_grep 'parent history' "$case_dir/data/task-x1/status.log" "parent history missing"
      assert_grep 'child history' "$case_dir/data/task-x1/children/nested-sm/status.log" "child history missing"
      assert_grep 'grandchild history' "$case_dir/data/task-x1/children/nested-sm/children/grandchild/status.log" "grandchild history missing"
      assert_absent "$case_dir/state/.paused-overdue-task-x1" "parent overdue marker survived teardown"
      assert_absent "$home/state/.paused-overdue-nested-sm" "child overdue marker survived teardown"
      assert_absent "$nested_home/state/.paused-overdue-grandchild" "grandchild overdue marker survived teardown"
      assert_absent "$home" "forced retirement retained secondmate home"
    fi
  done
  pass "forced secondmate retirement preserves two descendant levels and refuses linked child directories"
}

# Archive coverage uses the real teardown entry point over isolated homes.
test_status_archive_opt_in() {
  local case_dir rc mode
  for mode in off on; do
    case_dir=$(make_case "status-archive-$mode")
    write_meta "$case_dir" local-only ship
    printf 'working: started\nneeds-decision [key=choice]: choose\nresolved [key=choice]: chosen\ndone: complete\n' > "$case_dir/state/task-x1.status"
    printf 'marker\n' > "$case_dir/state/.paused-overdue-task-x1"
    cp "$case_dir/state/task-x1.status" "$case_dir/expected"
    mkdir -p "$case_dir/data/old"
    printf 'old archive\n' > "$case_dir/data/old/status.log"
    touch -t 200001010000 "$case_dir/data/old/status.log"
    [ "$mode" = off ] || touch "$case_dir/config/status-archive"
    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "status archive $mode teardown"
    assert_absent "$case_dir/state/task-x1.status" "live status survived teardown"
    assert_absent "$case_dir/state/.paused-overdue-task-x1" "overdue marker survived task teardown"
    if [ "$mode" = on ]; then
      cmp -s "$case_dir/expected" "$case_dir/data/task-x1/status.log" || fail "opt-in archive lost history"
    else
      assert_absent "$case_dir/data/task-x1/status.log" "default-off teardown created an archive"
      assert_present "$case_dir/data/old/status.log" "default-off teardown pruned an archive"
    fi
  done
  pass "status archival is opt-in and preserves the complete log"
}

test_status_archive_pruning_failure_warns_and_completes() {
  local case_dir rc operation
  for operation in rm find; do
    case_dir=$(make_case "status-archive-prune-failure-$operation")
    write_meta "$case_dir" local-only ship
    touch "$case_dir/config/status-archive"
    printf 'done: current history\n' > "$case_dir/state/task-x1.status"
    mkdir -p "$case_dir/data/unrelated-old"
    printf 'expired\n' > "$case_dir/data/unrelated-old/status.log"
    touch -t 200001010000 "$case_dir/data/unrelated-old/status.log"
    cat > "$case_dir/fakebin/$operation" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in */unrelated-old|*/unrelated-old/status.log) exit 1 ;; esac
done
exec "${FM_ARCHIVE_TEST_COMMAND:?}" "$@"
SH
    chmod +x "$case_dir/fakebin/$operation"
    rc=0
    FM_ARCHIVE_TEST_COMMAND="$(command -v "$operation")" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "unrelated archive $operation failure aborted teardown"
    grep -E 'warning:.*unrelated-old' "$case_dir/stderr" >/dev/null || fail "pruning failure did not name its path"
    assert_grep 'current history' "$case_dir/data/task-x1/status.log" "pruning failure lost current archive"
    assert_absent "$case_dir/state/task-x1.meta" "pruning failure retained current metadata"
    assert_present "$case_dir/data/unrelated-old/status.log" "failure fixture did not preserve expired archive"
  done
  pass "retention failures warn without aborting unrelated teardown"
}

test_status_archive_publish_and_cold_log_stay_inert() {
  local case_dir rc text
  case_dir=$(make_case status-archive-inert)
  prepare_status_archive_presentation "$case_dir"
  install_status_archive_publish_probe "$case_dir"
  rc=0
  FM_ARCHIVE_TEST_CASE="$case_dir" FM_ARCHIVE_TEST_MODE=scan \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "archive publication: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/publish-entered" "fixture never attempted publication"
  [ ! -s "$case_dir/publish-signals" ] || fail "archival caused a spurious watcher wake"
  assert_present "$case_dir/data/task-x1/status.log" "archive absent"
  for text in task-x1.status .task-x1.home-appends .seen-task-x1_status .hb-surfaced-task-x1 .task-x1.open-decisions-cursor; do
    assert_absent "$case_dir/state/$text" "retirement left live bookkeeping"
  done
  assert_no_grep 'task-x1' "$case_dir/state/.status-presentation-cursor" "retirement left presentation cursor"
  printf 'blocked: archive must stay cold\n' >> "$case_dir/data/task-x1/status.log"
  FM_STATE_OVERRIDE="$case_dir/state" FM_CONFIG_OVERRIDE="$case_dir/config" FM_DATA_OVERRIDE="$case_dir/data" \
    bash "$ROOT/bin/fm-wake-drain.sh" > "$case_dir/after" 2>> "$case_dir/drain.err" || fail "post-retirement presentation failed"
  for text in task-x1 'archive must stay cold' 'archived note'; do
    assert_no_grep "$text" "$case_dir/after" "archive re-presented"
  done
  FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" bash -c '
    . "$1/bin/fm-watch.sh"
    scan_signals
    status_presentation_snapshot "$STATE"
  ' _ "$ROOT" > "$case_dir/snapshot" || fail "cold archive snapshot failed"
  [ ! -s "$case_dir/snapshot" ] || fail "watcher or snapshot consumed archive"
  pass "archive publication and cold logs never re-wake or re-present"
}

test_status_archive_reuse_and_retention() {
  local case_dir rc archive
  case_dir=$(make_case status-archive-reuse)
  write_meta "$case_dir" local-only ship
  touch "$case_dir/config/status-archive"
  mkdir -p "$case_dir/data/task-x1" "$case_dir/data/old" "$case_dir/outside"
  printf 'first generation\n' > "$case_dir/data/task-x1/status.log"
  printf 'outside sentinel\n' > "$case_dir/outside/status.log"
  ln -s "$case_dir/outside/status.log" "$case_dir/data/task-x1/status.1.log"
  ln -s "$case_dir/outside" "$case_dir/data/symlink-task"
  printf 'expired\n' > "$case_dir/data/old/status.log"
  printf 'report survives\n' > "$case_dir/data/old/report.md"
  printf 'unowned file survives\n' > "$case_dir/data/old/status.notes.log"
  touch -t 200001010000 "$case_dir/data/old/"* "$case_dir/outside/status.log"
  printf 'done: second generation\n' > "$case_dir/state/task-x1.status"
  touch -t 200001010000 "$case_dir/state/task-x1.status"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "status archive reuse"
  assert_grep 'first generation' "$case_dir/data/task-x1/status.log" "first archive overwritten"
  archive="$case_dir/data/task-x1/status.2.log"
  assert_grep 'second generation' "$archive" "reused ID did not select a fresh archive"
  assert_grep 'outside sentinel' "$case_dir/outside/status.log" "archive or pruning followed a symlink"
  [ -L "$case_dir/data/task-x1/status.1.log" ] || fail "archive replaced an existing symlink"
  assert_absent "$case_dir/data/old/status.log" "expired status archive survived pruning"
  assert_present "$case_dir/data/old/report.md" "pruning removed other task data"
  assert_present "$case_dir/data/old/status.notes.log" "pruning removed an unowned filename"
  pass "reused task IDs never overwrite archives and retention removes only old owned logs"
}

test_status_archive_unsafe_paths_refuse() {
  local case_dir rc unsafe
  for unsafe in source data task children; do
    case_dir=$(make_case "status-archive-unsafe-$unsafe")
    write_meta "$case_dir" local-only ship
    touch "$case_dir/config/status-archive"
    mkdir -p "$case_dir/outside"
    printf 'untouched\n' > "$case_dir/outside/sentinel"
    printf 'done: complete\n' > "$case_dir/state/task-x1.status"
    case "$unsafe" in
      source) rm "$case_dir/state/task-x1.status"; ln -s "$case_dir/outside/sentinel" "$case_dir/state/task-x1.status" ;;
      data) rmdir "$case_dir/data"; ln -s "$case_dir/outside" "$case_dir/data" ;;
      task) ln -s "$case_dir/outside" "$case_dir/data/task-x1" ;;
      children) mkdir -p "$case_dir/data/task-x1"; ln -s "$case_dir/outside" "$case_dir/data/task-x1/children" ;;
    esac
    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if [ "$unsafe" = data ]; then
      expect_code 0 "$rc" "configured symlinked data root"
      assert_grep 'done: complete' "$case_dir/outside/task-x1/status.log" "archive did not use physical data root"
    elif [ "$unsafe" = children ]; then
      expect_code 0 "$rc" "pruning ignores symlinked children: $(cat "$case_dir/stderr")"
    else
      [ "$rc" -ne 0 ] || fail "unsafe $unsafe archive path accepted"
      assert_present "$case_dir/state/task-x1.status" "refusal lost status"
    fi
    assert_grep 'untouched' "$case_dir/outside/sentinel" "unsafe path changed outside data"
    assert_absent "$case_dir/outside/status.log" "archive escaped through symlink"
  done
  pass "archive sources and directories reject symlinks; pruning never follows children links"
}

# A merge-time cleanup request belongs to the detached cleanup that runs this
# teardown: only that cleanup removes it, after its outcome report is saved, so
# a cleanup that dies mid-teardown is still retried by the next park tick.
test_teardown_leaves_the_merge_cleanup_request_to_its_cleanup() {
  local case_dir wt_head rc
  case_dir=$(make_case keep-cleanup-request)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  printf 'pr=https://github.com/example/repo/pull/7\n' > "$case_dir/state/task-x1.review-park-land"
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "keep-cleanup-request: teardown should succeed when work is merged into local main"
  assert_present "$case_dir/state/task-x1.review-park-land" "teardown removed the merge cleanup request its cleanup still owns"
  pass "teardown leaves a merge cleanup request for the detached cleanup that owns it"
}


test_teardown_preserves_opencode_busy_plugin_on_pool_return
test_teardown_emits_mistakes_ledger_advisory
test_missing_startup_source_refuses_before_cleanup
test_unreadable_startup_source_refuses_before_cleanup
test_missing_adapter_sibling_refuses_before_cleanup
test_forced_child_missing_adapter_sibling_refuses_before_cleanup
test_forced_secondmate_own_missing_adapter_sibling_refuses_before_child_cleanup
test_retained_sources_still_reach_the_ordinary_refusal
test_local_only_fork_remote_allows
test_teardown_closes_the_backlog_item_itself
test_teardown_closes_a_gerrit_task_with_its_change_url_as_a_note
test_teardown_closes_a_gitlab_task_with_its_merge_request_url_as_a_note
test_teardown_manual_backend_leaves_the_backlog_to_the_operator
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_teardown_leaves_the_merge_cleanup_request_to_its_cleanup
test_landed_on_other_origin_branch_with_stale_refs_allows
test_refresh_failure_does_not_read_as_landed
test_refreshed_refs_still_refuse_unreachable_commits
test_uncommitted_work_refuses_even_when_commits_landed
test_edit_saved_during_refresh_refuses
test_no_remote_project_refuses_without_fetching
test_refresh_never_prunes_a_dropped_branch
test_reachable_work_needs_no_fetch
test_hung_fetch_is_bounded_and_refuses
test_gate_remote_is_not_refreshed_into_landed
test_no_mistakes_origin_remote_allows
test_direct_pr_origin_remote_refuses_until_merged
test_direct_pr_origin_remote_merged_allows
test_no_mistakes_truly_unpushed_refuses
test_no_mistakes_mirror_only_branch_refuses
test_local_only_force_overrides_unpushed
test_secondmate_pr_registration_publishes_ready_line
test_secondmate_pr_ready_line_waits_for_green_when_opted_in
test_secondmate_pr_ready_line_follows_green_report_with_trailing_text
test_secondmate_home_teardown_delivers_final_line_or_refuses
test_teardown_missing_busy_sidecar_completes
test_teardown_retires_polytoken_wiring_on_pool_return
test_teardown_preserves_tracked_polytoken_layer
test_teardown_preserves_ignored_project_polytoken_layer
test_teardown_leaves_polytoken_layer_for_other_harnesses
test_herdr_teardown_clears_escalation_marker
test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes
test_herdr_flat_teardown_refuses_records_on_unparseable_presence
test_herdr_flat_teardown_preflight_refuses_before_changes
test_herdr_teardown_presentation_lock_namespace_is_per_account
test_forced_secondmate_herdr_child_preflight_refuses_before_changes
test_forced_secondmate_teardown_holds_descendant_lifecycle_locks
test_forced_secondmate_teardown_removes_each_processed_childs_opencode_session
test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed
test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed
test_herdr_projection_teardown_retires_journal_only_after_confirmed_close
test_herdr_projection_teardown_retains_journal_when_close_unconfirmed
test_herdr_projection_teardown_surfaces_restore_failure_without_blocking_cleanup
test_herdr_projection_teardown_closes_pane_before_returning_its_copy
test_herdr_projection_teardown_refused_close_preserves_task_and_copy
test_teardown_retires_task_watcher_markers_and_orphan_journal
test_teardown_retains_journal_bound_to_another_pane
test_teardown_retires_v1_journal_when_projected_workspace_gone
test_teardown_retains_v1_journal_when_projected_workspace_present
test_teardown_retains_v1_journal_when_workspace_query_ambiguous
test_squash_merged_branch_deleted_allows
test_squash_merged_pr_allows_when_head_ancestor_of_pr_head
test_no_pr_recorded_discovers_merged_pr_by_branch_allows
test_squash_merged_pr_allows_replayed_unpushed_patch
test_merged_pr_patch_matching_preserves_indentation
test_merged_pr_with_later_local_commit_refuses
test_squash_merged_rebased_branch_allows
test_squash_merged_forgejo_pr_allows_when_main_moved_on
test_squash_merged_gitlab_mr_allows_when_main_moved_on
test_squash_merged_same_file_different_content_refuses
test_squash_merged_rebased_local_with_unlanded_commit_refuses
test_squash_merged_stale_local_refuses_when_forge_unreachable
test_pr_check_does_not_refresh_stale_pr_head
test_pr_check_records_remote_head_when_local_lags
test_content_in_default_fallback_allows
test_content_fallback_uses_recorded_base_branch
test_content_fallback_refreshes_stale_origin_ref
test_dirty_worktree_refuses
test_hidden_untracked_work_refuses_before_return
test_repowise_index_only_worktree_is_not_unlanded_work
test_untracked_only_refusal_diagnostic
test_tracked_edit_refusal_diagnostic
test_mixed_refusal_diagnostic
test_scout_nested_clone_returns_with_no_untracked_entries
test_ship_nested_clone_is_refused_and_bytes_stay
test_dirty_return_warns_which_slot_was_lost
test_dirty_return_warns_even_when_a_later_step_refuses
test_forced_secondmate_child_scout_nested_clone_returns_clean
test_forced_secondmate_dirty_child_return_warns_and_completes
test_return_that_removes_copy_warns_cannot_verify
test_scout_ignored_files_survive_scratch_clean
test_gh_error_and_content_absent_refuses
test_legacy_record_without_the_flag_refuses
test_windowless_legacy_record_with_gone_worktree_tears_down
test_windowless_legacy_record_tears_down_with_the_legacy_flag
test_windowless_legacy_record_still_refuses_unlanded_work
test_windowless_record_outside_the_leftover_class_still_refuses
test_windowless_leftover_retries_its_retained_legacy_stamp_without_the_flag
test_close_removes_opencode_session_and_gcs_the_routing_row
test_retain_keeps_the_routing_row_for_the_still_open_item
test_legacy_record_teardown_completes_when_landed_and_endpoint_dead
test_legacy_record_teardown_refuses_unlanded_work
test_legacy_record_teardown_refuses_an_ambiguous_endpoint
test_legacy_record_rolls_the_stamp_back_when_the_marker_write_fails
test_retained_legacy_stamp_still_faces_the_endpoint_gate
test_legacy_record_never_accepts_a_corrupt_spawn_gen
test_stale_index_lock_cleared_and_teardown_succeeds
test_live_index_lock_is_never_removed_and_teardown_refuses
test_lsof_error_never_clears_index_lock
test_stale_index_lock_cleanup_rechecks_dirty_worktree
test_non_linked_index_lock_path_is_checked_from_worktree
test_index_lock_mtime_read_failure_refuses
test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds
test_persistent_index_lock_exhausts_retries_and_refuses_loudly
test_empty_retry_wait_uses_default_without_aborting
test_fractional_legacy_retry_wait_refuses_without_arithmetic_error
test_teardown_records_the_task_pipeline_spend
test_teardown_skips_pipeline_spend_when_disabled
test_teardown_records_unavailable_spend_for_a_gone_worktree
test_parked_own_run_is_aborted_before_teardown
test_parked_run_in_a_resolved_workspace_home_is_aborted
test_parked_own_run_concludes_on_passed_with_override_after_abort
test_parked_own_run_concludes_on_passed_with_skips_after_abort
test_parked_run_advanced_past_unfetched_head_is_still_aborted
test_parked_run_with_mismatched_ledger_head_is_never_aborted
test_parked_run_with_malformed_ledger_row_is_never_aborted
test_parked_run_with_impossible_ledger_date_is_never_aborted
test_terminal_status_with_gate_never_queries_or_aborts_ledger_fallback
test_parked_run_advanced_head_locally_fetched_is_still_aborted
test_parked_advanced_run_without_anchor_is_never_aborted
test_parked_advanced_run_ancestor_anchor_is_never_aborted
test_parked_terminal_unfetched_row_is_never_aborted
test_parked_run_terminal_newest_row_at_own_head_is_never_aborted
test_parked_run_behind_diverged_newer_row_is_never_aborted
test_parked_advanced_run_ambiguous_rows_are_never_aborted
test_ledger_proven_continuation_never_aborts_active_run
test_parked_own_run_refuses_when_abort_is_unconfirmed
test_mismatched_run_after_abort_refuses_unconfirmed
test_empty_status_after_abort_refuses_unconfirmed
test_not_found_status_after_abort_confirms_completion
test_another_branchs_parked_run_is_never_touched
test_own_autonomous_run_is_left_alone
test_leaked_worktree_process_is_reaped
test_leaked_tasktmp_process_is_reaped
test_lsof_absent_reaps_tmux_process_group
test_lsof_error_refuses_before_removal
test_reused_pid_identity_is_not_force_killed
test_exec_changed_process_is_still_reaped
test_process_spawned_during_grace_is_reaped_on_later_pass
test_persistent_scan_refuses_after_bounded_retries
test_process_exit_during_identity_lookup_does_not_refuse
test_run_abort_precedes_process_reap_precedes_worktree_removal
test_work_written_at_reap_boundary_is_preserved
test_content_fallback_git_capability_boundary
test_record_export_archives_before_teardown_or_preserves_sources_on_failure
test_record_export_captures_forced_secondmate_sub_state
test_record_export_config_absent_never_reads_the_exporter
test_record_export_unopted_symlinked_config_does_not_block_teardown
test_record_export_waits_for_endpoint_quiescence_before_archiving
test_record_hygiene_archive_survives_status_archive_prune
test_status_archive_cursor_failure_retries_without_duplicate
test_status_archive_failed_publish_preserves_presentation
test_status_archive_missing_status_noop
test_status_archive_nested_secondmate_children
test_status_archive_opt_in
test_status_archive_pruning_failure_warns_and_completes
test_status_archive_publish_and_cold_log_stay_inert
test_status_archive_reuse_and_retention
test_status_archive_unsafe_paths_refuse
