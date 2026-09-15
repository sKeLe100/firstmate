#!/usr/bin/env bash
# tests/fm-watch-herdr-pane-recovery.test.sh - fm-watch.sh's herdr
# pane_not_found recovery path (bin/fm-watch.sh, the block guarded by
# `[ -z "$tail40" ] && [ "$backend" = herdr ]`). Drives a real fm-watch.sh
# subprocess across several poll cycles against a scripted fake `herdr` CLI
# (mirrors tests/fm-backend-herdr.test.sh's fake-CLI convention) so the
# recovery block, the meta rewrite, the meta lock, and the busy
# classification that follows all execute for real.
#
# Regression coverage for the loop-local `$w` staying stale after a successful
# recovery: a recovered pane whose native herdr state is genuinely busy must
# NOT be wedge-escalated on the poll it recovers on, even though its captured
# text hash is unchanged from before the pane broke (the reported incident's
# actual shape - idle-looking screen, genuinely busy worker underneath).
# Before the fix, `window_is_busy "$w" ...` on that same poll still used the
# pre-recovery target, which no longer matched the just-rewritten meta, fell
# back to a bogus task id and the tmux backend default, and reported
# not-busy - reintroducing the false-escalation failure mode the recovery
# exists to fix, in the one poll where it matters most.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-herdr-pane-recovery-tests)

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Mirrors bin/fm-watch.sh's window_key (not itself library-sourceable: it's
# defined inline in the watcher script, not a lib).
test_window_key() { printf '%s' "${1//:/_}" | tr '/.' '__'; }

file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true
}

wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_dir() {  # <dir> [limit-ticks]
  local dir=$1 limit=${2:-100} i=0
  while [ "$i" -lt "$limit" ]; do
    [ -e "$dir" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

wait_for_gone() {  # <path> [limit-ticks]
  local path=$1 limit=${2:-100} i=0
  while [ "$i" -lt "$limit" ]; do
    [ -e "$path" ] || return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

# make_herdr_pane_recovery_fakebin <dir> <old_pane> <new_pane> <wsid> <tab_id>
# <content_file> <break_marker>: a scripted `herdr` CLI. `pane read <new_pane>`
# always succeeds with <content_file>'s bytes (optionally delayed by
# FM_TEST_HERDR_READ_DELAY, to hold a caller inside an in-flight call). `pane
# read <old_pane>` succeeds the SAME way until <break_marker> exists, then
# fails (pane_not_found), the trigger for fm-watch.sh's recovery block. `pane
# list --workspace <wsid>` resolves <new_pane> for <tab_id>. `agent get`
# always reports the queried pane as natively busy ("working"), so the only
# thing that can make fm-watch.sh see it as not-busy is resolving the WRONG
# pane id (the regression this suite guards).
make_herdr_pane_recovery_fakebin() {  # <dir> <old_pane> <new_pane> <wsid> <tab_id> <content_file> <break_marker>
  local dir=$1 old_pane=$2 new_pane=$3 wsid=$4 tab_id=$5 content_file=$6 break_marker=$7
  local fb="$dir/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<SH
#!/usr/bin/env bash
set -u
LOG="\${FM_HERDR_LOG:-/dev/null}"
printf '%s\n' "\$*" >> "\$LOG"
case "\${1:-}" in
  status)
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    exit 0
    ;;
  pane)
    case "\${2:-}" in
      read)
        pane=\${3:-}
        if [ "\$pane" = "$old_pane" ] && [ -e "$break_marker" ]; then
          exit 1
        fi
        if [ "\$pane" = "$old_pane" ] || [ "\$pane" = "$new_pane" ]; then
          [ "\$pane" != "$new_pane" ] || [ -z "\${FM_TEST_HERDR_READ_DELAY:-}" ] || sleep "\$FM_TEST_HERDR_READ_DELAY"
          cat "$content_file"
          exit 0
        fi
        exit 1
        ;;
      list)
        printf '{"result":{"panes":[{"tab_id":"$tab_id","pane_id":"$new_pane"}]}}\n'
        exit 0
        ;;
    esac
    exit 1
    ;;
  agent)
    case "\${2:-}" in
      get) printf '{"result":{"agent":{"agent_status":"working"}}}\n'; exit 0 ;;
    esac
    exit 1
    ;;
esac
exit 1
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# write_herdr_task_meta <state> <task> <session> <pane> <wsid> <tab_id>:
# the meta shape fm-watch.sh's recovery block reads (herdr_workspace_id,
# herdr_tab_id, herdr_session, herdr_pane_id) plus the ordinary window=/
# backend= fields every recorded_windows() scan and window_to_task lookup
# keys off.
write_herdr_task_meta() {  # <state> <task> <session> <pane> <wsid> <tab_id>
  local state=$1 task=$2 session=$3 pane=$4 wsid=$5 tab_id=$6
  fm_write_meta "$state/$task.meta" \
    "window=$session:$pane" \
    "backend=herdr" \
    "kind=ship" \
    "harness=claude" \
    "herdr_session=$session" \
    "herdr_pane_id=$pane" \
    "herdr_workspace_id=$wsid" \
    "herdr_tab_id=$tab_id"
  printf 'working: doing real work\n' > "$state/$task.status"
  prime_status_seen "$state" "$state/$task.status"
}

test_recovered_herdr_pane_rewrites_meta_and_stays_busy_absorbed() {
  local dir state fakebin out content_file break_marker key pid
  local session=lab old_pane=stale-pane-7 new_pane=fresh-pane-9 wsid=ws1 tab_id=tab1
  dir=$(make_case herdr-pane-recovery-absorbed); state="$dir/state"
  out="$dir/watch.out"; content_file="$dir/pane.txt"; break_marker="$dir/.pane-broken"
  printf 'Compiling assets...\n' > "$content_file"
  write_herdr_task_meta "$state" upstream-sync "$session" "$old_pane" "$wsid" "$tab_id"
  key=$(test_window_key "$session:$old_pane")
  fakebin=$(make_herdr_pane_recovery_fakebin "$dir" "$old_pane" "$new_pane" "$wsid" "$tab_id" "$content_file" "$break_marker")

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>"$dir/watch.err" &
  pid=$!

  # Poll A: first-ever sight of this pane's content (unbroken). Poll B: same
  # content again, so the SAME hash is now recorded twice (the realistic
  # shape of the incident - the pane's visible text had already settled
  # before the binding broke). Both prime .count-$key to 1 with no wedge
  # timer or wake yet.
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited during priming poll A: out=$(cat "$out") err=$(cat "$dir/watch.err")"
  fi
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited during priming poll B: out=$(cat "$out") err=$(cat "$dir/watch.err")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "priming polls (pane never broken yet) already printed a wake reason: $(cat "$out")"; }
  [ "$(cat "$state/.count-$key" 2>/dev/null || echo 0)" -ge 1 ] 2>/dev/null \
    || { reap "$pid"; fail "priming did not record a repeat same-hash occurrence before breaking the pane"; }

  # Break the binding: the NEXT poll's `pane read $old_pane` fails
  # pane_not_found, forcing fm-watch.sh's recovery block. The recovered
  # `pane read $new_pane` returns the SAME unchanged content, so this poll's
  # hash matches the primed one - the h==prev branch that decides busy vs.
  # escalate.
  : > "$break_marker"
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited during the pane-recovery poll: out=$(cat "$out") err=$(cat "$dir/watch.err")"
  fi

  [ "$(fm_meta_get "$state/upstream-sync.meta" herdr_pane_id)" = "$new_pane" ] \
    || { reap "$pid"; fail "recovery did not rewrite herdr_pane_id to the resolved pane"; }
  [ "$(fm_meta_get "$state/upstream-sync.meta" window)" = "$session:$new_pane" ] \
    || { reap "$pid"; fail "recovery did not rewrite window= to the resolved pane target"; }
  kill -0 "$pid" 2>/dev/null \
    || fail "a genuinely busy recovered pane (herdr-native working) made the watcher exit: out=$(cat "$out") err=$(cat "$dir/watch.err")"
  [ ! -s "$out" ] \
    || fail "a genuinely busy recovered pane printed a wake reason (the stale \$w regression - window_is_busy resolved the wrong task/backend post-recovery): $(cat "$out")"
  reap "$pid"
  pass "a herdr pane recovered from pane_not_found is reclassified busy through its native agent state (not the pre-recovery target) and absorbed, not wedge-escalated, on the very poll it recovers"
}

test_herdr_pane_recovery_holds_the_meta_lock_during_its_write() {
  local dir state fakebin out content_file break_marker pid lock_seen=0
  local old_pane=stale-pane-3 new_pane=fresh-pane-4 wsid=ws2 tab_id=tab2
  dir=$(make_case herdr-pane-recovery-lock); state="$dir/state"
  out="$dir/watch.out"; content_file="$dir/pane.txt"; break_marker="$dir/.pane-broken"
  printf 'Running build...\n' > "$content_file"
  write_herdr_task_meta "$state" upstream-sync lab "$old_pane" "$wsid" "$tab_id"
  : > "$break_marker"
  fakebin=$(make_herdr_pane_recovery_fakebin "$dir" "$old_pane" "$new_pane" "$wsid" "$tab_id" "$content_file" "$break_marker")

  # Delay the recovered re-read (issued INSIDE the lock, between the meta
  # rewrite and its release) so the test has a real window to observe the
  # lock directory held, proving fm_meta_lock_path/fm_lock_acquire_wait are
  # actually exercised rather than just reachable-but-unused.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_TEST_HERDR_READ_DELAY=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>"$dir/watch.err" &
  pid=$!

  if wait_for_dir "$state/.meta-upstream-sync.lock" 100; then
    lock_seen=1
    wait_for_gone "$state/.meta-upstream-sync.lock" 100 \
      || { reap "$pid"; fail "the recovery's meta lock was never released: $(cat "$dir/watch.err")"; }
  fi
  if ! wait_poll_cycle "$state" "$pid" 200; then
    reap "$pid"
    fail "watcher exited during the lock-instrumented recovery poll: out=$(cat "$out") err=$(cat "$dir/watch.err")"
  fi
  [ "$lock_seen" -eq 1 ] \
    || fail "never observed the per-task meta lock directory held during the recovery's meta write (fm_meta_lock_path/fm_lock_acquire_wait not exercised)"
  [ "$(fm_meta_get "$state/upstream-sync.meta" herdr_pane_id)" = "$new_pane" ] \
    || fail "recovery under the meta lock did not still rewrite herdr_pane_id"
  reap "$pid"
  pass "the herdr pane recovery's meta rewrite acquires and releases the per-task meta lock"
}

# make_herdr_pane_recovery_fail_fakebin <dir> <old_pane> <new_pane> <wsid>
# <tab_id> <break_marker> <resolve_ok> <new_pane_readable>: a scripted `herdr`
# CLI for the two recovery-failure paths that make_herdr_pane_recovery_fakebin
# doesn't cover. `pane read <old_pane>` fails (pane_not_found) once
# <break_marker> exists, same as the happy-path fake. `pane list --workspace
# <wsid>` reports <new_pane> for <tab_id> only when <resolve_ok> is "1" (a
# gone-tab is an empty panes array, so `fm_backend_herdr_resolve_pane_not_found`
# comes back empty). `pane read <new_pane>` only succeeds when
# <new_pane_readable> is "1", letting a caller simulate a resolved pane that
# still fails to read right after reassignment.
make_herdr_pane_recovery_fail_fakebin() {  # <dir> <old_pane> <new_pane> <wsid> <tab_id> <break_marker> <resolve_ok> <new_pane_readable>
  local dir=$1 old_pane=$2 new_pane=$3 wsid=$4 tab_id=$5 break_marker=$6 resolve_ok=$7 new_pane_readable=$8
  local fb="$dir/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  status)
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    exit 0
    ;;
  pane)
    case "\${2:-}" in
      read)
        pane=\${3:-}
        if [ "\$pane" = "$old_pane" ] && [ -e "$break_marker" ]; then
          exit 1
        fi
        if [ "\$pane" = "$old_pane" ]; then
          printf 'unbroken content\n'
          exit 0
        fi
        if [ "\$pane" = "$new_pane" ] && [ "$new_pane_readable" = "1" ]; then
          printf 'recovered content\n'
          exit 0
        fi
        exit 1
        ;;
      list)
        if [ "$resolve_ok" = "1" ]; then
          printf '{"result":{"panes":[{"tab_id":"$tab_id","pane_id":"$new_pane"}]}}\n'
        else
          printf '{"result":{"panes":[]}}\n'
        fi
        exit 0
        ;;
    esac
    exit 1
    ;;
  agent)
    case "\${2:-}" in
      get) printf '{"result":{"agent":{"agent_status":"working"}}}\n'; exit 0 ;;
    esac
    exit 1
    ;;
esac
exit 1
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

test_herdr_pane_recovery_leaves_meta_untouched_when_tab_is_gone() {
  local dir state fakebin out break_marker pid
  local session=lab old_pane=stale-pane-5 new_pane=fresh-pane-6 wsid=ws3 tab_id=tab3
  dir=$(make_case herdr-pane-recovery-tab-gone); state="$dir/state"
  out="$dir/watch.out"; break_marker="$dir/.pane-broken"
  write_herdr_task_meta "$state" upstream-sync "$session" "$old_pane" "$wsid" "$tab_id"
  : > "$break_marker"
  fakebin=$(make_herdr_pane_recovery_fail_fakebin "$dir" "$old_pane" "$new_pane" "$wsid" "$tab_id" "$break_marker" 0 1)

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>"$dir/watch.err" &
  pid=$!

  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited when the tab could not be resolved (pane_not_found with no matching tab): err=$(cat "$dir/watch.err")"
  fi
  kill -0 "$pid" 2>/dev/null \
    || { reap "$pid"; fail "watcher exited rather than treating an unresolvable tab as no evidence for the poll"; }
  [ ! -s "$out" ] \
    || { reap "$pid"; fail "an unresolvable tab produced a wake instead of being absorbed as no evidence: $(cat "$out")"; }
  [ "$(fm_meta_get "$state/upstream-sync.meta" herdr_pane_id)" = "$old_pane" ] \
    || { reap "$pid"; fail "meta's herdr_pane_id was rewritten even though the tab could not be resolved to a new pane"; }
  [ "$(fm_meta_get "$state/upstream-sync.meta" window)" = "$session:$old_pane" ] \
    || { reap "$pid"; fail "meta's window= was rewritten even though the tab could not be resolved to a new pane"; }
  reap "$pid"
  pass "a herdr pane_not_found with no resolvable tab leaves the meta untouched and is absorbed as no evidence for that poll"
}

test_herdr_pane_recovery_writes_both_fields_together_even_when_retry_capture_fails() {
  local dir state fakebin out break_marker pid
  local session=lab old_pane=stale-pane-8 new_pane=fresh-pane-2 wsid=ws4 tab_id=tab4
  dir=$(make_case herdr-pane-recovery-retry-fails); state="$dir/state"
  out="$dir/watch.out"; break_marker="$dir/.pane-broken"
  write_herdr_task_meta "$state" upstream-sync "$session" "$old_pane" "$wsid" "$tab_id"
  : > "$break_marker"
  fakebin=$(make_herdr_pane_recovery_fail_fakebin "$dir" "$old_pane" "$new_pane" "$wsid" "$tab_id" "$break_marker" 1 0)

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>"$dir/watch.err" &
  pid=$!

  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited when the resolved pane still failed to read on retry: err=$(cat "$dir/watch.err")"
  fi
  kill -0 "$pid" 2>/dev/null \
    || { reap "$pid"; fail "watcher exited rather than treating a still-failing retry capture as no evidence for the poll"; }
  [ ! -s "$out" ] \
    || { reap "$pid"; fail "a still-failing retry capture produced a wake instead of being absorbed as no evidence: $(cat "$out")"; }
  [ "$(fm_meta_get "$state/upstream-sync.meta" herdr_pane_id)" = "$new_pane" ] \
    || { reap "$pid"; fail "resolved pane id was not written to meta even though resolution succeeded"; }
  [ "$(fm_meta_get "$state/upstream-sync.meta" window)" = "$session:$new_pane" ] \
    || { reap "$pid"; fail "window= disagrees with herdr_pane_id after a resolved-but-unreadable retry - the two fields must be written together, not left partially updated"; }
  reap "$pid"
  pass "a resolved herdr pane that still fails its retry capture still gets herdr_pane_id and window= written together, never left disagreeing"
}

test_recovered_herdr_pane_rewrites_meta_and_stays_busy_absorbed
test_herdr_pane_recovery_holds_the_meta_lock_during_its_write
test_herdr_pane_recovery_leaves_meta_untouched_when_tab_is_gone
test_herdr_pane_recovery_writes_both_fields_together_even_when_retry_capture_fails

printf '# all fm-watch-herdr-pane-recovery tests passed\n'
