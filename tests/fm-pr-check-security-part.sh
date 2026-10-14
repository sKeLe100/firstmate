#!/usr/bin/env bash
# Content-preserving upstream test block, sourced by fm-pr-check-security.test.sh.

test_custom_snapshot_cleanup_on_signal() {
  local dir state child_pid_file pid child_pid i rc
  dir=$(make_case custom-snapshot-signal)
  state="$dir/home/state"
  child_pid_file="$dir/custom-child.pid"
  # shellcheck disable=SC2016  # The generated child expands $$ when it runs.
  printf '%s\n' '#!/usr/bin/env bash' 'trap "" TERM' \
    'printf "%s\n" "$$" > "$FM_TEST_CUSTOM_CHILD_PID"' 'while :; do sleep 1; done' \
    > "$state/custom.check.sh"
  chmod 0700 "$state/custom.check.sh"
  cat > "$dir/fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
"$@" &
child=$!
trap 'kill -TERM "$child" 2>/dev/null; exit 124' TERM
wait "$child"
SH
  chmod 0700 "$dir/fakebin/timeout"
  FM_HOME="$dir/home" "$REGISTER" custom >/dev/null \
    || fail "could not register signal cleanup custom check"

  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_POLL=0 FM_CHECK_INTERVAL=0 \
    FM_SIGNAL_GRACE=0 FM_TEST_CUSTOM_CHILD_PID="$child_pid_file" \
    PATH="$dir/fakebin:$BASE_PATH" "$WATCH" \
    > "$dir/watch.out" 2> "$dir/watch.err" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    [ -s "$child_pid_file" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.02
    i=$((i + 1))
  done
  [ -s "$child_pid_file" ] || fail "watcher did not start the custom check child"
  find "$state" -maxdepth 1 -name '.fm-custom-check.*' -print | grep . >/dev/null \
    || fail "watcher did not create the custom check snapshot"
  child_pid=$(cat "$child_pid_file")
  kill -TERM "$pid" 2>/dev/null || fail "could not signal watcher during custom check"
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.02
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "signaled watcher did not exit promptly"
  fi
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -ne 0 ] || fail "signaled watcher exited successfully"
  ! kill -0 "$child_pid" 2>/dev/null || fail "signaled watcher left the custom check child running"
  ! find "$state" -maxdepth 1 -name '.fm-custom-check.*' -print | grep . >/dev/null \
    || fail "signaled watcher left a private custom check snapshot"
  ! find "$state" -maxdepth 1 -name '.fm-check-output.*' -print | grep . >/dev/null \
    || fail "signaled watcher left a private check output file"
  [ ! -e "$state/.watch.lock/pid" ] || fail "signaled watcher left its singleton lock"
  pass "watcher signals promptly stop custom checks and clean private state"
}

test_returned_custom_check_descendants_are_drained() {
  local backend dir state fakebin ready direct_done child_pid_file child_pid check rc force_fallback
  for backend in installed-timeout fallback-timeout; do
    dir=$(make_case "returned-custom-descendant-$backend")
    state="$dir/home/state"
    fakebin="$dir/fakebin"
    ready="$dir/descendant-ready"
    direct_done="$dir/direct-check-done"
    child_pid_file="$dir/descendant.pid"
    # The descendant ignores TERM and never exits on its own while this case's
    # directory exists, so its absence can only mean the watcher drained it.
    cat > "$state/custom.check.sh" <<'SH'
#!/usr/bin/env bash
perl -e '$SIG{TERM}="IGNORE"; open my $ready, ">", $ENV{FM_TEST_DESCENDANT_READY} or die $!; print {$ready} "ready\n"; close $ready; select undef, undef, undef, 0.2 while -d $ENV{FM_TEST_DESCENDANT_HOLD}' &
printf '%s\n' "$!" > "$FM_TEST_DESCENDANT_PID"
while [ ! -s "$FM_TEST_DESCENDANT_READY" ]; do sleep 0.01; done
: > "$FM_TEST_DIRECT_DONE"
SH
    # The watcher runs this check next in the same cycle, only after it has
    # finished with the returned one, so its wake both records whether the
    # descendant outlived that drain and stops the watcher.
    cat > "$state/z-drain-witness.check.sh" <<'SH'
#!/usr/bin/env bash
case "$(ps -o stat= -p "$(cat "$FM_TEST_DESCENDANT_PID")" 2>/dev/null)" in
  ''|Z*) printf 'descendant drained\n' ;;
  *) printf 'descendant alive\n' ;;
esac
SH
    for check in custom z-drain-witness; do
      chmod 0700 "$state/$check.check.sh"
      FM_HOME="$dir/home" "$REGISTER" "$check" >/dev/null \
        || fail "could not register $backend returned-descendant $check check"
    done
    if [ "$backend" = installed-timeout ]; then
      cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
      chmod 0700 "$fakebin/timeout"
      force_fallback=0
    else
      rm -f "$fakebin/timeout" "$fakebin/gtimeout"
      force_fallback=1
    fi

    rc=0
    FM_TEST_CHECK_TIMEOUT=10 FM_CHECK_FORCE_FALLBACK="$force_fallback" \
      FM_TEST_DESCENDANT_READY="$ready" FM_TEST_DESCENDANT_HOLD="$dir" \
      FM_TEST_DESCENDANT_PID="$child_pid_file" FM_TEST_DIRECT_DONE="$direct_done" \
      run_watcher_bounded "$dir/home" "$fakebin" > "$dir/watch.out" 2> "$dir/watch.err" || rc=$?
    child_pid=$(cat "$child_pid_file" 2>/dev/null || true)
    if [ -n "$child_pid" ] && process_is_live_non_zombie "$child_pid"; then
      kill -KILL "$child_pid" 2>/dev/null || true
      fail "$backend watcher left a returned check descendant alive"
    fi
    [ "$rc" -eq 0 ] \
      || fail "$backend watcher did not stop after the direct check returned (rc=$rc): $(cat "$dir/watch.err")"
    [ -s "$ready" ] && [ -n "$child_pid" ] && [ -e "$direct_done" ] \
      || fail "$backend watcher did not complete the direct custom check"
    grep -qxF "check: $state/z-drain-witness.check.sh: descendant drained" "$dir/watch.out" \
      || fail "$backend watcher moved past a returned check before draining its descendant: $(cat "$dir/watch.out")"
    ! find "$state" -maxdepth 1 -name '.fm-custom-check.*' -print | grep . >/dev/null \
      || fail "$backend watcher left a private custom check snapshot"
    ! find "$state" -maxdepth 1 -name '.fm-check-output.*' -print | grep . >/dev/null \
      || fail "$backend watcher left a private check output file"
    [ ! -e "$state/.watch.lock/pid" ] || fail "$backend watcher left its singleton lock"
  done
  pass "returned custom check descendants are drained on installed and fallback timeout paths"
}

test_teardown_removes_poll_artifacts() {
  local dir fakebin artifact counterpart rc
  dir=$(make_case teardown-cleanup)
  fakebin="$dir/fakebin"
  fm_write_meta "$dir/home/state/task-a.meta" \
    'window=firstmate:fm-task-a' \
    'endpoint_task_id=task-a' \
    "worktree=$dir/missing-worktree" \
    "project=$dir/project" \
    'kind=ship' \
    'mode=local-only'
  printf 'check\n' > "$dir/home/state/task-a.check.sh"
  printf 'data\n' > "$dir/home/state/task-a.pr-poll"
  printf 'registration\n' > "$dir/home/state/task-a.pr-poll-registration"
  printf 'trust\n' > "$dir/home/state/task-a.check-trust"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  touch "$dir/home/state/.last-watcher-beat"

  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$BASE_PATH" \
    "$TEARDOWN" task-a --force > "$dir/teardown.out" 2> "$dir/teardown.err" \
    || fail "teardown cleanup fixture failed"
  [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "teardown left the runnable check"
  [ ! -e "$dir/home/state/task-a.pr-poll" ] || fail "teardown left the sidecar"
  [ ! -e "$dir/home/state/task-a.pr-poll-registration" ] || fail "teardown left the PR poll registration"
  [ ! -e "$dir/home/state/task-a.check-trust" ] || fail "teardown left the custom check registration"

  dir=$(make_case teardown-retirement-receipt)
  fakebin="$dir/fakebin"
  fm_write_meta "$dir/home/state/task-a.meta" \
    'window=firstmate:fm-task-a' \
    'endpoint_task_id=task-a' \
    "worktree=$dir/missing-worktree" \
    "project=$dir/project" \
    'kind=ship' \
    'mode=local-only' \
    'pr=https://github.com/o/r/pull/18'
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/18
  fm_pr_poll_snapshot_capture "$dir/home/state" task-a "$POLL" \
    || fail "could not snapshot teardown receipt fixture"
  fm_pr_poll_retirement_publish "$dir/home/state" task-a "$POLL" merged \
    || fail "could not publish teardown receipt fixture"
  rm -f "$dir/home/state/task-a.check.sh"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  touch "$dir/home/state/.last-watcher-beat"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$BASE_PATH" \
    "$TEARDOWN" task-a --force > "$dir/teardown.out" 2> "$dir/teardown.err" \
    || fail "teardown could not finish a valid crash-left retirement receipt"
  assert_poll_absent "$dir/home/state" task-a
  [ ! -e "$dir/home/state/task-a.meta" ] || fail "receipt-aware teardown left task metadata"

  for artifact in check.sh pr-poll; do
    dir=$(make_case "teardown-final-directory-${artifact//./-}")
    fakebin="$dir/fakebin"
    fm_write_meta "$dir/home/state/task-a.meta" \
      'window=firstmate:fm-task-a' \
      'endpoint_task_id=task-a' \
      "worktree=$dir/missing-worktree" \
      "project=$dir/project" \
      'kind=ship' \
      'mode=local-only'
    if [ "$artifact" = check.sh ]; then
      counterpart=pr-poll
    else
      counterpart=check.sh
    fi
    mkdir "$dir/home/state/task-a.$artifact"
    printf 'directory sentinel\n' > "$dir/home/state/task-a.$artifact/sentinel"
    printf 'counterpart sentinel\n' > "$dir/home/state/task-a.$counterpart"
    cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
exit 0
SH
    chmod +x "$fakebin/tmux"
    touch "$dir/home/state/.last-watcher-beat"
    set +e
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_TMUX_LOG="$dir/tmux.log" \
      PATH="$fakebin:$BASE_PATH" "$TEARDOWN" task-a --force \
      > "$dir/teardown.out" 2> "$dir/teardown.err"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "teardown accepted a directory-shaped $artifact"
    [ -e "$dir/home/state/task-a.meta" ] || fail "teardown removed metadata before $artifact refusal"
    [ "$(cat "$dir/home/state/task-a.$artifact/sentinel")" = 'directory sentinel' ] \
      || fail "teardown changed the directory-shaped $artifact"
    [ "$(cat "$dir/home/state/task-a.$counterpart")" = 'counterpart sentinel' ] \
      || fail "teardown removed the counterpart before $artifact refusal"
    grep -F 'kill-window' "$dir/tmux.log" >/dev/null 2>&1 \
      && fail "teardown killed the endpoint before $artifact refusal"
  done

  pass "teardown removes safe poll artifacts and refuses directory-shaped check files without traversal"
}

# The Gerrit watch must follow a change exactly as the GitHub watch follows a
# pull request, on any server, and must never turn an unreadable or merely
# submittable change into a merge. Its evidence against a real change is in
# docs/gerrit-change-watch.md; this exercises the same paths hermetically.
test_gerrit_merge_watch() {
  local dir state out rc url value notool entry bindir name tool
  dir=$(make_case gerrit-merge-watch)
  state="$dir/home/state"
  url=https://gerrit.example/c/group/apps/console/+/4201
  # The Gerrit branch reads its status with the real jq, and BASE_PATH is
  # deliberately restricted, so this exposes jq explicitly rather than depending
  # on the host keeping it in one of those four directories.
  ln -sf "$REAL_JQ" "$dir/fakebin/jq"

  write_poll_meta "$state" task-a "$url"
  fm_pr_poll_prepare "$state" task-a gerrit "$url" gerrit.example group/apps/console 4201 "$POLL" \
    || fail "could not prepare a Gerrit poll"
  fm_pr_poll_publish_prepared || fail "could not publish a Gerrit poll"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
    || fail "published Gerrit poll provenance or metadata binding was invalid"
  [ "$(cat "$state/task-a.pr-poll")" = "gerrit
$url
gerrit.example
group/apps/console
4201" ] || fail "published Gerrit sidecar bytes were not exact"

  # Only an exact MERGED status wakes firstmate. Every other reading, including
  # an abandoned change, a lowercase spelling, and a changed format, stays
  # silent rather than reporting a merge.
  for value in NEW ABANDONED merged Merged MERGED_LATER '' not-a-status; do
    out=$(FM_TEST_GERRIT_STATUS="$value" run_poll "$dir")
    [ -z "$out" ] || fail "Gerrit poll emitted for status '$value'"
  done

  # Readiness is not merge. A change that is fully submittable - nothing in its
  # blocked_on list, submit OK, submittable true - is exactly what an approved
  # but unsubmitted change looks like, and a merged change reports the same
  # three fields. Only the status separates them, so only the status is read.
  out=$(FM_TEST_GERRIT_STATUS=NEW FM_TEST_GERRIT_SUBMIT=OK \
    FM_TEST_GERRIT_SUBMITTABLE=true FM_TEST_GERRIT_BLOCKED_ON='' run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll read a submittable open change as merged"

  out=$(FM_TEST_GERRIT_STATUS=MERGED FM_TEST_GERRIT_SUBMIT=OK \
    FM_TEST_GERRIT_SUBMITTABLE=true FM_TEST_GERRIT_BLOCKED_ON='' run_poll "$dir")
  [ "$out" = merged ] || fail "Gerrit poll did not emit exactly one merged line"

  out=$(FM_TEST_GERRIT_FAIL=1 FM_TEST_GERRIT_STATUS=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll emitted after a gerrit-axi failure"
  out=$(FM_TEST_GERRIT_RAW='not json at all' run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll emitted for unparseable output"
  out=$(FM_TEST_GERRIT_RAW='{"ok":false,"error":"unauthenticated"}' run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll emitted for a typed error record"
  out=$(FM_TEST_GERRIT_RAW='{"ok":true,"changes":[]}' run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll emitted for a record naming no change"

  # A record for some other change can never wake this task's poll, however the
  # server came to return it. The change number is what names the change, and
  # --host is what pins the server.
  out=$(FM_TEST_GERRIT_STATUS=MERGED FM_TEST_GERRIT_CHANGE=4202 run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll emitted for another change's record"
  out=$(FM_TEST_GERRIT_RAW='{"ok":true,"op":"show","changes":[{"change":4202,"status":"MERGED","url":null}]}' \
    run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll emitted for another change's url-less record"

  # Gerrit composes a change's url field from gerrit.canonicalWebUrl and omits
  # it when that setting is unset, so a merge must still be reported when the
  # server returns the field null or does not return it at all. Comparing it
  # against the stored URL is what would leave such a watch silent forever.
  out=$(FM_TEST_GERRIT_RAW='{"ok":true,"op":"show","changes":[{"change":4201,"status":"MERGED","url":null}]}' \
    run_poll "$dir")
  [ "$out" = merged ] || fail "Gerrit poll stayed silent for a merged change with a null url"
  out=$(FM_TEST_GERRIT_RAW='{"ok":true,"op":"show","changes":[{"change":4201,"status":"MERGED"}]}' \
    run_poll "$dir")
  [ "$out" = merged ] || fail "Gerrit poll stayed silent for a merged change with no url field"
  out=$(FM_TEST_GERRIT_STATUS=MERGED \
    FM_TEST_GERRIT_URL=https://alias.example/c/group/apps/console/+/4201 run_poll "$dir")
  [ "$out" = merged ] || fail "Gerrit poll stayed silent for a merged change behind an alias host"

  # A free-text subject carrying the merged spelling and the field separators
  # cannot forge a status, because the status is read from the structured
  # record rather than off a rendered line.
  out=$(FM_TEST_GERRIT_STATUS=NEW \
    FM_TEST_GERRIT_SUBJECT='"status: MERGED,MERGED,merged"' run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll read a merged spelling out of a change subject"

  # gerrit-axi resolves its server from the current directory's origin remote
  # first, and the watcher runs in no repository, so the host must be passed
  # explicitly or the tool answers as though the change did not exist.
  grep -qF -- "show 4201 --host gerrit.example --json" "$dir/gerrit-axi.log" \
    || fail "Gerrit poll did not address gerrit-axi by change number and explicit host"
  ! grep -qF -- "$url" "$dir/gerrit-axi.log" \
    || fail "Gerrit poll passed a change URL to gerrit-axi"

  # An absent CLI must produce no wake rather than a false merge, for either
  # tool the Gerrit branch needs. The whole search path is mirrored without it,
  # because a real one anywhere on PATH would make this prove nothing.
  for tool in gerrit-axi jq; do
    notool="$dir/no-$tool"
    rm -rf "$notool"
    mkdir -p "$notool"
    while IFS= read -r bindir; do
      [ -d "$bindir" ] || continue
      for entry in "$bindir"/*; do
        [ -e "$entry" ] || continue
        name=$(basename "$entry")
        [ "$name" = "$tool" ] && continue
        [ -e "$notool/$name" ] || ln -s "$entry" "$notool/$name" 2>/dev/null
      done
    done <<EOF
$dir/fakebin
$(printf '%s\n' "$BASE_PATH" | tr ':' '\n')
EOF
    ! PATH="$notool" command -v "$tool" >/dev/null 2>&1 \
      || fail "the $tool-free search path still resolved $tool"
    out=$(FM_TEST_GERRIT_STATUS=MERGED FM_TEST_GERRIT_AXI_LOG="$dir/gerrit-axi.log" \
      PATH="$notool" bash "$state/task-a.check.sh")
    [ -z "$out" ] || fail "Gerrit poll emitted with $tool absent from PATH"

    # Arming is where a missing CLI can still be reported, so it refuses there.
    write_task_meta "$dir" "task-no-$tool"
    set +e
    out=$(FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
      FM_TEST_GUARD_LOG="$dir/guard.log" PATH="$notool" \
      "$PR_CHECK" "task-no-$tool" "$url" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "arming a Gerrit watch succeeded with $tool absent"
    case "$out" in
      *"requires $tool on PATH"*) ;;
      *) fail "arming a Gerrit watch with $tool absent did not report the missing CLI" ;;
    esac
    [ ! -e "$state/task-no-$tool.check.sh" ] || fail "refused Gerrit arming left a poll armed"
  done

  # A doctored sidecar cannot redirect the poll: the stored parts must rebuild
  # the stored URL exactly.
  printf '%s\n%s\n%s\n%s\n%s\n' gerrit "$url" elsewhere.example group/apps/console 4201 \
    > "$state/task-a.pr-poll"
  out=$(FM_TEST_GERRIT_STATUS=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll emitted for a sidecar whose host was swapped"
  printf '%s\n%s\n%s\n%s\n%s\n' gerrit "$url" gerrit.example group/apps/other 4201 \
    > "$state/task-a.pr-poll"
  out=$(FM_TEST_GERRIT_STATUS=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll emitted for a sidecar whose project was swapped"
  printf '%s\n%s\n%s\n%s\n%s\n' gerrit "$url" gerrit.example group/apps/console 4202 \
    > "$state/task-a.pr-poll"
  out=$(FM_TEST_GERRIT_STATUS=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll emitted for a sidecar whose change number was swapped"

  pass "the Gerrit watch wakes only on an explicit merged status and never on submittability"
}

# Arming a Gerrit watch records the canonical change identity and no pr_head.
# A Gerrit revision names one patch set, and bin/fm-review-diff.sh has no Gerrit
# path to resolve a current head with, so a recorded revision would quietly
# become the reviewed content after the next amend.
test_gerrit_arming_records_no_patch_set_revision() {
  local dir state rc out
  dir=$(make_case gerrit-arming)
  state="$dir/home/state"
  ln -sf "$REAL_JQ" "$dir/fakebin/jq"

  write_task_meta "$dir" task-rev
  FM_TEST_GERRIT_REVISION=$(git -C "$dir/wt" rev-parse HEAD) run_check_entry "$dir" task-rev \
    https://gerrit.example/c/group/apps/console/+/4201 >/dev/null \
    || fail "arming a Gerrit watch failed"
  grep -qxF 'pr=https://gerrit.example/c/group/apps/console/+/4201' "$state/task-rev.meta" \
    || fail "arming did not record the canonical Gerrit change URL"
  grep -q '^pr_head=' "$state/task-rev.meta" \
    && fail "arming recorded a Gerrit patch set revision as pr_head"
  [ -e "$state/task-rev.check.sh" ] || fail "arming a Gerrit watch left no poll armed"

  # Submitting a Gerrit change is refused outright, before anything is read or
  # recorded, rather than left as a silently absent provider branch.
  set +e
  out=$(run_merge_entry "$dir" task-rev \
    https://gerrit.example/c/group/apps/console/+/4201 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the merge path accepted a Gerrit change"
  case "$out" in
    *"does not submit a Gerrit change"*) ;;
    *) fail "the Gerrit merge refusal did not say firstmate does not submit" ;;
  esac
  [ ! -e "$state/task-rev.merge-authority" ] || fail "a refused Gerrit merge recorded merge authority"

  pass "Gerrit arming records no patch set revision and the merge path refuses to submit"
}

# A push to refs/for/ leaves no ref a fetch can see, so a remote-tracking ref
# that holds the worker's HEAD - the no-mistakes gate branch after a pipeline
# run - says nothing about what was published. Arming accepts the named head
# only when a live read shows the change's current patch set carrying that
# HEAD's tree - the squash is a new commit on the server's base, so the tree and
# not the commit names what was published - and refuses otherwise, before
# anything is recorded or armed. Once arming has recorded the change as pr=, a
# later done naming it is accepted from that record without a read, so a
# reviewer's rebase or new patch set on the server does not revoke it.
test_gerrit_ready_gate_reads_the_published_tree() {
  local dir state base published other out rc
  dir=$(make_case gerrit-ready-gate)
  state="$dir/home/state"
  ln -sf "$REAL_JQ" "$dir/fakebin/jq"
  base=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'one\n' > "$dir/wt/a"
  git -C "$dir/wt" add a
  git -C "$dir/wt" commit -q -m first
  printf 'two\n' > "$dir/wt/b"
  git -C "$dir/wt" add b
  git -C "$dir/wt" commit -q -m second
  git -C "$dir/wt" update-ref refs/remotes/no-mistakes/fm/task "$(git -C "$dir/wt" rev-parse HEAD)"
  published=$(git -C "$dir/wt" commit-tree "$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')" -p "$base" -m squashed)
  other=$(git -C "$dir/wt" rev-parse HEAD~1)
  [ "$(git -C "$dir/wt" rev-parse "$published^{tree}")" != "$(git -C "$dir/wt" rev-parse "$other^{tree}")" ] \
    || fail "the fixture's two revisions carry the same tree"

  write_task_meta "$dir" task-mismatch
  set +e
  out=$(FM_TEST_GERRIT_REVISION=$other run_check_entry "$dir" task-mismatch \
    https://gerrit.example/c/group/apps/console/+/4201 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a change whose patch set is not this copy's HEAD tree"
  case "$out" in
    *"not the published content"*) ;;
    *) fail "the refusal did not say the change does not carry the named head: $out" ;;
  esac
  grep -q '^pr=' "$state/task-mismatch.meta" && fail "a refused Gerrit arming recorded pr="
  [ ! -e "$state/task-mismatch.check.sh" ] || fail "a refused Gerrit arming armed a poll"

  write_task_meta "$dir" task-unknown
  set +e
  FM_TEST_GERRIT_REVISION=0123456789abcdef0123456789abcdef01234567 run_check_entry "$dir" task-unknown \
    https://gerrit.example/c/group/apps/console/+/4201 >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a patch set this copy has never held"

  write_task_meta "$dir" task-unread
  set +e
  FM_TEST_GERRIT_FAIL=1 run_check_entry "$dir" task-unread \
    https://gerrit.example/c/group/apps/console/+/4201 >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a change it could not read"

  : > "$dir/gerrit-axi.log"
  write_task_meta "$dir" task-published
  FM_TEST_GERRIT_REVISION=$published run_check_entry "$dir" task-published \
    https://gerrit.example/c/group/apps/console/+/4201 >/dev/null \
    || fail "arming refused a change whose current patch set carries this copy's HEAD tree"
  grep -qF -- "show 4201 --host gerrit.example --json" "$dir/gerrit-axi.log" \
    || fail "the gate did not read the change from its own server"
  [ -e "$state/task-published.check.sh" ] || fail "an accepted Gerrit arming left no poll armed"
  grep -q '^pr_head=' "$state/task-published.meta" \
    && fail "the gate's live revision was recorded as pr_head"

  git -C "$dir/wt" update-ref -d refs/remotes/no-mistakes/fm/task
  : > "$dir/gerrit-axi.log"
  set +e
  out=$(FM_TEST_GERRIT_REVISION=0123456789abcdef0123456789abcdef01234567 \
    FM_TEST_GERRIT_AXI_LOG="$dir/gerrit-axi.log" PATH="$dir/fakebin:$BASE_PATH" \
    bash -c '. "$1/bin/fm-timeout-lib.sh"; . "$1/bin/fm-dod-lib.sh"
      fm_dod_accept_ship_done ship no-mistakes "$2" "$3" "$4" "$5" task-published "$6"' \
    _ "$ROOT" "$dir/wt" "$dir/project" \
    "done: PR https://gerrit.example/c/group/apps/console/+/4201 published for review" \
    "$state" "$state/task-published.meta" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a server-side rebase after arming revoked the recorded change's done: $out"
  [ ! -s "$dir/gerrit-axi.log" ] || fail "a done naming the recorded change read the server again"
  pass "Gerrit arming accepts a published HEAD only by the change's current patch set tree"
}

# On a Gerrit project the pipeline's push is skipped, so a fix round's commits
# stay in its local gate until the worker recovers custody. A worker that
# publishes before recovering has an unfixed HEAD and an unfixed patch set that
# agree, so the published-tree check alone accepts it. A no-mistakes ready
# report on a Gerrit change must therefore also show the copy holds the run's
# result: refused while the run still holds the branch, when HEAD's tree is not
# the pipeline head's, or when the run cannot be read; accepted once recovered,
# even after the publish's Change-Id stamp rewrote the branch's messages.
test_gerrit_nm_ready_gate_requires_recovered_custody() {
  local dir state base unfixed fixed stamped squash elsewhere out rc url line
  dir=$(make_case gerrit-custody-gate)
  state="$dir/home/state"
  ln -sf "$REAL_JQ" "$dir/fakebin/jq"
  url=https://gerrit.example/c/group/apps/console/+/4201
  line="done: PR $url published for review"
  base=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'flawed\n' > "$dir/wt/doc"
  git -C "$dir/wt" add doc
  git -C "$dir/wt" commit -q -m "Document the value"
  unfixed=$(git -C "$dir/wt" rev-parse HEAD)
  # The pipeline's fix commit exists only in its gate: build it in another repo,
  # so this copy does not hold its object, exactly as before recovery.
  elsewhere="$dir/gate-only"
  git clone -q "$dir/wt" "$elsewhere"
  printf 'fixed\n' > "$elsewhere/doc"
  git -C "$elsewhere" commit -q -am "no-mistakes(review): Correct the documented value"
  fixed=$(git -C "$elsewhere" rev-parse HEAD)
  git -C "$dir/wt" cat-file -e "$fixed" 2>/dev/null && fail "the fixture copy already holds the pipeline's fix"

  # Case A from the live test: the server holds the unfixed patch set, which
  # matches the unrecovered HEAD, and the run reports custody unreturned.
  write_task_meta "$dir" task-unrecovered
  set +e
  out=$(FM_TEST_GERRIT_REVISION=$unfixed FM_TEST_NM_PIPELINE_HEAD=$fixed \
    FM_TEST_NM_NEXT_ACTION=recover_custody run_check_entry "$dir" task-unrecovered "$url" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a publish of the head before the pipeline's fixes were recovered"
  case "$out" in
    *"still holds this copy's branch"*) ;;
    *) fail "the refusal did not say the run still holds the branch: $out" ;;
  esac
  grep -q '^pr=' "$state/task-unrecovered.meta" && fail "a refused unrecovered publish recorded pr="
  [ ! -e "$state/task-unrecovered.check.sh" ] || fail "a refused unrecovered publish armed a poll"

  # The same state with no next action reported still refuses on the trees.
  set +e
  out=$(FM_TEST_GERRIT_REVISION=$unfixed FM_TEST_NM_PIPELINE_HEAD=$fixed run_check_entry "$dir" task-unrecovered "$url" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a copy whose HEAD is not the run's result"
  case "$out" in
    *"does not carry the no-mistakes run's result"*) ;;
    *) fail "the refusal did not say the copy lacks the run's result: $out" ;;
  esac

  set +e
  FM_TEST_GERRIT_REVISION=$unfixed FM_TEST_NM_NEXT_ACTION=continue_active_run \
    run_check_entry "$dir" task-unrecovered "$url" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a publish while the run is still active"

  set +e
  out=$(FM_TEST_GERRIT_REVISION=$unfixed FM_TEST_NM_FAIL=1 run_check_entry "$dir" task-unrecovered "$url" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a publish whose no-mistakes run could not be read"
  case "$out" in
    *"could not be read"*) ;;
    *) fail "the refusal did not say the run could not be read: $out" ;;
  esac

  # A failed run whose own head was published has nothing to recover, so the
  # trees agree; its outcome alone refuses it, as does a missing outcome.
  set +e
  out=$(FM_TEST_GERRIT_REVISION=$unfixed FM_TEST_NM_OUTCOME=failed run_check_entry "$dir" task-unrecovered "$url" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a publish of a failed no-mistakes run"
  case "$out" in
    *"has outcome failed, not a pass"*) ;;
    *) fail "the refusal did not name the run's failed outcome: $out" ;;
  esac
  grep -q '^pr=' "$state/task-unrecovered.meta" && fail "a refused failed-run publish recorded pr="
  set +e
  FM_TEST_GERRIT_REVISION=$unfixed FM_TEST_NM_OUTCOME='' run_check_entry "$dir" task-unrecovered "$url" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a publish of a run with no outcome"

  # A published-for-review done whose URL is not a canonical Gerrit change is
  # refused, even though a gate push left HEAD on a remote-tracking ref.
  git -C "$dir/wt" update-ref refs/remotes/no-mistakes/fm/task "$unfixed"
  set +e
  out=$(FM_TEST_GERRIT_REVISION=$unfixed PATH="$dir/fakebin:$BASE_PATH" \
    bash -c '. "$1/bin/fm-timeout-lib.sh"; . "$1/bin/fm-dod-lib.sh"
      fm_dod_accept_ship_done ship no-mistakes "$2" "$3" "$4"' \
    _ "$ROOT" "$dir/wt" "$dir/project" \
    "done: PR https://gerrit.example/r/c/group/apps/console/+/4201/1 published for review" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the done gate accepted a published-for-review report naming no Gerrit change"
  case "$out" in
    *"canonical https://<host>/c/<project>/+/<number> form"*) ;;
    *) fail "the refusal did not name the canonical Gerrit change form: $out" ;;
  esac
  git -C "$dir/wt" update-ref -d refs/remotes/no-mistakes/fm/task

  # Recovery fast-forwards the copy to the fix; the publish then stamps a
  # Change-Id, rewriting the message but not the tree, and pushes one squash.
  git -C "$dir/wt" fetch -q "$elsewhere" "$fixed"
  git -C "$dir/wt" merge -q --ff-only "$fixed"
  stamped=$(git -C "$dir/wt" commit-tree "$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')" -p "$unfixed" \
    -m "no-mistakes(review): Correct the documented value" -m "Change-Id: I0123456789abcdef0123456789abcdef01234567")
  git -C "$dir/wt" reset -q --hard "$stamped"
  squash=$(git -C "$dir/wt" commit-tree "$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')" -p "$base" -m squashed)
  [ "$stamped" != "$fixed" ] || fail "the fixture's stamped head did not diverge from the pipeline head"

  # The done gate itself, as crew-state and the secondmate ledger call it.
  set +e
  out=$(FM_TEST_GERRIT_REVISION=$squash FM_TEST_NM_PIPELINE_HEAD=$fixed \
    FM_TEST_GERRIT_AXI_LOG="$dir/gerrit-axi.log" PATH="$dir/fakebin:$BASE_PATH" \
    bash -c '. "$1/bin/fm-timeout-lib.sh"; . "$1/bin/fm-dod-lib.sh"
      fm_dod_accept_ship_done ship no-mistakes "$2" "$3" "$4"' \
    _ "$ROOT" "$dir/wt" "$dir/project" "$line" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "the done gate refused a recovered, published copy: $out"

  write_task_meta "$dir" task-recovered
  FM_TEST_GERRIT_REVISION=$squash FM_TEST_NM_PIPELINE_HEAD=$fixed run_check_entry "$dir" task-recovered "$url" >/dev/null \
    || fail "arming refused a recovered copy whose squash carries the pipeline's result"
  grep -qxF "pr=$url" "$state/task-recovered.meta" || fail "the recovered publish was not recorded"

  # A direct-PR task never runs the pipeline, so no run is asked about.
  : > "$dir/nm.log"
  write_task_meta "$dir" task-direct
  sed -i.bak 's/^mode=no-mistakes$/mode=direct-PR/' "$state/task-direct.meta" && rm -f "$state/task-direct.meta.bak"
  FM_TEST_GERRIT_REVISION=$squash FM_TEST_NM_FAIL=1 FM_TEST_NM_LOG="$dir/nm.log" \
    run_check_entry "$dir" task-direct "$url" >/dev/null \
    || fail "a direct-PR Gerrit publish was refused over a pipeline it never runs"
  [ ! -s "$dir/nm.log" ] || fail "a direct-PR Gerrit publish consulted no-mistakes"
  pass "a no-mistakes Gerrit ready report requires the pipeline's fixes recovered into the published copy"
}

# The GitLab watch must follow a merge request exactly as the GitHub watch
# follows a pull request, on any instance, and must never turn an unreadable
# merge request into a merge. Its evidence against the public fixture project
# https://gitlab.com/KarotKris/gitlab-merge-watch-fixture is in
# docs/gitlab-merge-watch.md; this exercises the same paths hermetically.

# A Forgejo pull request is followed by number through "tea api" on the one
# login registered for its host. Only a boolean merged field of true wakes the
# poll: tea api exits 0 on an HTTP error with the error body as output, so an
# error body, an unmerged record, a tea failure, and an ambiguous login all
# stay silent, and the read never depends on how many newer pull requests the
# repository has.
test_forgejo_merge_watch() {
  local dir state out url value
  dir=$(make_case forgejo-merge-watch)
  state="$dir/home/state"
  url=https://forgejo.example/o/r/pulls/7
  cat > "$dir/fakebin/tea" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_TEA_LOG"
if [ "${1:-} ${2:-}" = "login list" ]; then
  printf '[\n'
  printf '  {\n    "name": "main",\n    "url": "https://forgejo.example"\n  }'
  if [ -n "${FM_TEST_TEA_SECOND_LOGIN:-}" ]; then
    printf ',\n  {\n    "name": "other",\n    "url": "https://forgejo.example"\n  }'
  fi
  printf '\n]\n'
  exit 0
fi
[ "${1:-}" = api ] || exit 0
[ -z "${FM_TEST_TEA_FAIL:-}" ] || exit 1
case "${FM_TEST_TEA_PULL:-open}" in
  merged) printf '{"state":"closed","merged":true,"head":{"sha":"abc"}}\n' ;;
  error) printf '{"message":"The target couldn'"'"'t be found.","url":"x"}\n' ;;
  *) printf '{"state":"open","merged":false,"head":{"sha":"abc"}}\n' ;;
esac
SH
  chmod +x "$dir/fakebin/tea"
  ln -sf "$(command -v jq)" "$dir/fakebin/jq"
  : > "$dir/tea.log"

  write_poll_meta "$state" task-a "$url"
  fm_pr_poll_prepare "$state" task-a forgejo "$url" forgejo.example o/r 7 "$POLL" \
    || fail "could not prepare a Forgejo poll"
  fm_pr_poll_publish_prepared || fail "could not publish a Forgejo poll"

  for value in open error; do
    out=$(FM_TEST_TEA_LOG="$dir/tea.log" FM_TEST_TEA_PULL=$value run_poll "$dir")
    [ -z "$out" ] || fail "Forgejo poll emitted for a $value reading"
  done
  out=$(FM_TEST_TEA_LOG="$dir/tea.log" FM_TEST_TEA_PULL=merged FM_TEST_TEA_FAIL=1 run_poll "$dir")
  [ -z "$out" ] || fail "Forgejo poll emitted after a tea failure"
  out=$(FM_TEST_TEA_LOG="$dir/tea.log" FM_TEST_TEA_PULL=merged FM_TEST_TEA_SECOND_LOGIN=1 run_poll "$dir")
  [ -z "$out" ] || fail "Forgejo poll emitted with an ambiguous tea login"
  out=$(FM_TEST_TEA_LOG="$dir/tea.log" FM_TEST_TEA_PULL=merged run_poll "$dir")
  [ "$out" = merged ] || fail "Forgejo poll did not emit exactly one merged line"

  grep -qF -- "api --login main --repo o/r /repos/{owner}/{repo}/pulls/7" "$dir/tea.log" \
    || fail "the poll did not read the one pull request by number on the host's login"
  ! grep -qF -- "pulls list" "$dir/tea.log" \
    || fail "the poll scanned a pull request list instead of reading by number"
  pass "Forgejo poll reads one pull request by number through tea api and wakes only on merged true"
}

# The one tea login for a Forgejo host is found by parsing
# `tea login list --output json` as JSON, never by splitting each line on
# quotes. The pretty-printed fixture below is byte-for-byte what tea 0.14.0
# prints for two logins; the two compact fixtures are the same records with one
# object per line and as one line, the shapes a line-oriented split misread as
# a url equal to the login name, refusing every host. Both the sourced helper
# and the static watcher body, which keeps its own copy of the filter, must
# resolve every shape, strip scheme, port, and path from the url, and refuse
# an ambiguous host.
test_forgejo_login_list_shapes() {
  local dir state out shape url
  dir=$(make_case forgejo-login-shapes)
  state="$dir/home/state"
  cat > "$dir/tea-multiline.json" <<'JSON'
[
  {
    "name": "fixture-one",
    "url": "https://git.example.com",
    "ssh_host": "git.example.com",
    "user": "someone",
    "default": "true"
  },
  {
    "name": "fixture-two",
    "url": "http://code.internal:3000/",
    "ssh_host": "code.internal",
    "user": "other",
    "default": "false"
  }
]
JSON
  jq -c . "$dir/tea-multiline.json" > "$dir/tea-oneline.json"
  { printf '[\n'; jq -c '.[]' "$dir/tea-multiline.json" | sed '1!s/^/,/'; printf ']\n'; } \
    > "$dir/tea-perobject.json"
  [ "$(wc -l < "$dir/tea-oneline.json")" -eq 1 ] || fail "the one-line fixture is not one line"
  grep -q '^{"name":"fixture-one","url":"https://git.example.com"' "$dir/tea-perobject.json" \
    || fail "the per-object fixture does not put a whole login on one line"
  printf '[{"name":"a","url":"https://git.example.com"},{"name":"b","url":"https://git.example.com:3000/x"}]\n' \
    > "$dir/tea-ambiguous.json"
  cat > "$dir/fakebin/tea" <<'SH'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "login list" ]; then
  cat "$FM_TEST_TEA_LOGINS"
  exit 0
fi
[ "${1:-}" = api ] || exit 0
printf '%s\n' "$*" >> "$FM_TEST_TEA_LOG"
printf '{"state":"closed","merged":true,"head":{"sha":"abc"}}\n'
SH
  chmod +x "$dir/fakebin/tea"
  ln -sf "$(command -v jq)" "$dir/fakebin/jq"
  : > "$dir/tea.log"

  url=https://code.internal/o/r/pulls/7
  write_poll_meta "$state" task-a "$url"
  fm_pr_poll_prepare "$state" task-a forgejo "$url" code.internal o/r 7 "$POLL" \
    || fail "could not prepare a Forgejo poll"
  fm_pr_poll_publish_prepared || fail "could not publish a Forgejo poll"

  for shape in multiline oneline perobject; do
    out=$(FM_TEST_TEA_LOGINS="$dir/tea-$shape.json" PATH="$dir/fakebin:$PATH" fm_pr_forgejo_login git.example.com) \
      || fail "$shape: the login helper refused a host with exactly one login"
    [ "$out" = fixture-one ] || fail "$shape: the login helper resolved '$out' for git.example.com"
    out=$(FM_TEST_TEA_LOGINS="$dir/tea-$shape.json" PATH="$dir/fakebin:$PATH" fm_pr_forgejo_login code.internal) \
      || fail "$shape: the login helper refused a url with a port and trailing slash"
    [ "$out" = fixture-two ] || fail "$shape: the login helper resolved '$out' for code.internal"
    ! FM_TEST_TEA_LOGINS="$dir/tea-$shape.json" PATH="$dir/fakebin:$PATH" fm_pr_forgejo_login elsewhere.example >/dev/null \
      || fail "$shape: the login helper resolved a host with no registered login"
    out=$(FM_TEST_TEA_LOGINS="$dir/tea-$shape.json" FM_TEST_TEA_LOG="$dir/tea.log" run_poll "$dir")
    [ "$out" = merged ] || fail "$shape: the static poll did not resolve the login and report the merge"
    grep -qF -- "api --login fixture-two --repo o/r" "$dir/tea.log" \
      || fail "$shape: the static poll did not read through the host's login"
    : > "$dir/tea.log"
  done
  ! FM_TEST_TEA_LOGINS="$dir/tea-ambiguous.json" PATH="$dir/fakebin:$PATH" fm_pr_forgejo_login git.example.com >/dev/null \
    || fail "the login helper picked one of two logins for the same host"
  out=$(FM_TEST_TEA_LOGINS="$dir/tea-ambiguous.json" FM_TEST_TEA_LOG="$dir/tea.log" run_poll "$dir")
  [ -z "$out" ] || fail "the static poll read through an ambiguous login"
  pass "Forgejo login match parses tea's JSON in every line shape, in the helper and the static poll"
}
