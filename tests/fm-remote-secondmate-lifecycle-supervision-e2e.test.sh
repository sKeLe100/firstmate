#!/usr/bin/env bash
# Full remote secondmate lifecycle over the deterministic generic SSH boundary,
# last stretch: startup readiness repair, watcher liveness recovery, legacy and
# unreachable endpoints at startup, and retirement. The fixture and the other
# stretches are named in tests/fm-remote-secondmate-lifecycle-lib.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"
# shellcheck source=tests/herdr-client-pair-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-client-pair-fixture.sh"
# shellcheck source=tests/fm-remote-secondmate-lifecycle-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-remote-secondmate-lifecycle-lib.sh"

launch_ios_fixture
# The startup legs run with the healthy watcher identity a supervising session
# publishes from the remote code root.
publish_healthy_watcher_identity "$PARENT/state" "$PARENT" "$REMOTE_ROOT/bin/fm-watch.sh"

rm -f "$TMP_ROOT/doctor.repaired"
: > "$DOCTOR_LOG"
[ "$(FM_FAKE_SSH_MODE=doctor-fixable remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = unreadable ] \
  || fail "the stopped-server fixture did not make the pre-repair endpoint probe unreadable"
launches_before_repair=$(grep -c '^tab create' "$HERDR_LOG" || true)
BOOT_REPAIRED=$(FM_FAKE_SSH_MODE=doctor-fixable remote_env "$ROOT/bin/fm-bootstrap.sh")
[ "$(cat "$DOCTOR_LOG")" = 'doctor-fixable -
doctor-fixable --fix
doctor-fixable -' ] || fail "liveness did not check, repair, and re-check readiness before probing"$'\n'"$(cat "$DOCTOR_LOG")"
assert_not_contains "$BOOT_REPAIRED" 'SECONDMATE_LIVENESS: secondmate ios:' \
  "successful pre-probe readiness repair produced a liveness failure"
launches_after_repair=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$launches_before_repair" -eq "$launches_after_repair" ] \
  || fail "readiness repair introduced a new remote relaunch point"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "the endpoint was not probed successfully after readiness repair"
pass "startup repairs remote readiness before probing without relaunching"

# --- ordinary-supervision recovery of a dead remote endpoint -----------------
# The watcher's cadence-gated liveness tick (bin/fm-watch.sh
# secondmate_liveness_tick) drives the same shared probe+relaunch library the
# startup sweep used above: a positively dead remote endpoint relaunches
# through the guarded remote spawn and emits exactly one check wake, while an
# unreachable host is preserved untouched. The tick runs against a dedicated
# state dir holding only this mate's endpoint meta so no other supervision
# source can fire first.

remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
WATCH_STATE="$TMP_ROOT/watch-liveness-state"
mkdir -p "$WATCH_STATE"
cp "$PARENT/state/ios.meta" "$WATCH_STATE/ios.meta"
# The remote spawn path mints its inheritance generation from a counter that
# lives beside the task record, so the dedicated watch state needs the real
# one; otherwise the pushed payload reads as superseded on the remote home.
cp "$PARENT/state/.remote-inherit-ios.generation" "$WATCH_STATE/" 2>/dev/null || true
touch "$WATCH_STATE/home-summary.json"

# A graceful agent exit leaves the pane with no registered agent - the exact
# incident this tick exists for.
ios_pane=$(sed -n 's/^herdr_pane_id=//p' "$remote_route_meta")
[ -n "$ios_pane" ] || fail "the remote route meta did not record its Herdr pane"
jq --arg p "$ios_pane" \
  '.typed |= with_entries(select(.key != $p)) | .working |= with_entries(select(.key != $p))' \
  "$HERDR_STATE" > "$TMP_ROOT/herdr-dead.json" && mv "$TMP_ROOT/herdr-dead.json" "$HERDR_STATE"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = dead ] \
  || fail "the agent-free remote pane did not classify dead"

tabs_before=$(grep -c '^tab create' "$HERDR_LOG" || true)
# exec keeps $! the watcher itself rather than the function's subshell, so a
# kill reaches the process that probes and writes into the fixture root.
# The relaunch is a full remote spawn, so its bound is widened past the 120s
# default that a loaded host can exceed.
FM_STATE_OVERRIDE="$WATCH_STATE" FM_SECONDMATE_LIVENESS_SECS=1 FM_POLL=1 \
  FM_SECONDMATE_LIVENESS_TIMEOUT=600 \
  FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  remote_env exec "$ROOT/bin/fm-watch.sh" \
  > "$TMP_ROOT/watch-liveness.out" 2> "$TMP_ROOT/watch-liveness.err" &
watch_pid=$!
watch_wait=0
watch_total=0
# shellcheck disable=SC2034 # read by name in ssh_progress_reset
watch_ssh_seen=''
# The auto-relaunch re-runs the remote spawn and its inheritance round-trips,
# so the bound is the gap between remote round-trips rather than the total.
while kill -0 "$watch_pid" 2>/dev/null && [ "$watch_wait" -lt "$EVENT_WAIT_TICKS" ] \
  && [ "$watch_total" -lt "$REMOTE_WAIT_TICKS" ]; do
  sleep 0.02
  ssh_progress_reset watch_wait watch_ssh_seen
  watch_wait=$((watch_wait + 1))
  watch_total=$((watch_total + 1))
done
if kill -0 "$watch_pid" 2>/dev/null; then
  kill "$watch_pid" 2>/dev/null || true
  fail "the watcher did not exit on its auto-relaunch wake within its wait bound: $(cat "$TMP_ROOT/watch-liveness.out" "$TMP_ROOT/watch-liveness.err" 2>/dev/null)"
fi
wait "$watch_pid" \
  || fail "the liveness watcher leg exited non-zero: $(cat "$TMP_ROOT/watch-liveness.err")"
watch_pid=''
grep -F 'check: secondmate ios auto-relaunched after remote endpoint dead on its configured host (host=remote-mac)' \
  "$TMP_ROOT/watch-liveness.out" >/dev/null \
  || fail "the dead remote secondmate was not auto-relaunched: $(cat "$TMP_ROOT/watch-liveness.out")"
[ "$(grep -c 'check: secondmate ios auto-relaunched' "$TMP_ROOT/watch-liveness.out")" -eq 1 ] \
  || fail "the remote auto-relaunch did not produce exactly one captain-facing line"
grep -F $'\tcheck\tsecondmate-relaunch-ios-' "$WATCH_STATE/.wake-queue" >/dev/null \
  || fail "the durable auto-relaunch wake row was not queued: $(cat "$WATCH_STATE/.wake-queue" 2>/dev/null)"
grep -F 'relaunched' "$WATCH_STATE/.secondmate-relaunch-ios" >/dev/null \
  || fail "the durable per-mate ledger did not record the relaunch"
tabs_after=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$tabs_after" -gt "$tabs_before" ] \
  || fail "the remote relaunch did not create a fresh remote endpoint ($tabs_before -> $tabs_after)"
assert_grep 'remote_host=remote-mac' "$WATCH_STATE/ios.meta" \
  "the watcher relaunch dropped the remote host route"
assert_grep 'herdr_session=fm-remote' "$remote_route_meta" \
  "the watcher relaunch did not re-record the pinned remote Herdr session"
assert_grep '- ios ' "$PARENT/data/secondmates.md" \
  "the watcher relaunch changed the registry route"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "the auto-relaunched remote endpoint did not read alive"
# Production relaunch updates the parent route meta and inheritance generation
# in place; the dedicated watch state above kept the rest of this suite's
# parent state out of scope, so fold both records back now.
cp "$WATCH_STATE/ios.meta" "$PARENT/state/ios.meta"
cp "$WATCH_STATE/.remote-inherit-ios.generation" "$PARENT/state/" 2>/dev/null || true
pass "watch liveness: a dead remote secondmate is auto-relaunched on its own host with one wake"

# Stop a backgrounded watcher and wait out the probe it may have in flight. A
# TERM ends the watcher at once but leaves a running probe child to finish on
# its own, so freeze the watcher first, note the children it has started, and
# wait for each of them to exit.
stop_watcher_and_drain() { # <watcher-pid>
  local pid=$1 child children drain_wait=0
  kill -STOP "$pid" 2>/dev/null || true
  children=$(ps -A -o pid= -o ppid= | awk -v parent="$pid" '$2 == parent { print $1 }')
  kill "$pid" 2>/dev/null || true
  kill -CONT "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  for child in $children; do
    while :; do
      case "$(ps -o stat= -p "$child" 2>/dev/null | tr -d '[:space:]')" in ''|Z*) break ;; esac
      drain_wait=$((drain_wait + 1))
      [ "$drain_wait" -le "$EVENT_WAIT_TICKS" ] || fail "the stopped watcher's in-flight probe never finished"
      sleep 0.02
    done
  done
}

# Host loss mid-supervision is never evidence of death: the same tick on an
# unreachable route probes, preserves, and stays silent.
WATCH_STATE_UNREACHABLE="$TMP_ROOT/watch-liveness-unreachable"
mkdir -p "$WATCH_STATE_UNREACHABLE"
cp "$WATCH_STATE/ios.meta" "$WATCH_STATE_UNREACHABLE/ios.meta"
touch "$WATCH_STATE_UNREACHABLE/home-summary.json"
ssh_before=$(cat "$SSH_COUNT" 2>/dev/null || printf '0')
FM_FAKE_SSH_MODE=unreachable FM_STATE_OVERRIDE="$WATCH_STATE_UNREACHABLE" \
  FM_SECONDMATE_LIVENESS_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  remote_env exec "$ROOT/bin/fm-watch.sh" \
  > "$TMP_ROOT/watch-unreachable.out" 2> "$TMP_ROOT/watch-unreachable.err" &
watch_pid=$!
# Each tick probes the route with one round-trip. Wait for two: the second
# shows the watcher took the first unreachable verdict and kept supervising,
# where one alone shows only that a tick started.
probe_wait=0
while [ "$(cat "$SSH_COUNT" 2>/dev/null || printf '0')" -lt $((ssh_before + 2)) ]; do
  kill -0 "$watch_pid" 2>/dev/null \
    || fail "the watcher exited against an unreachable remote secondmate: $(cat "$TMP_ROOT/watch-unreachable.out" "$TMP_ROOT/watch-unreachable.err")"
  probe_wait=$((probe_wait + 1))
  [ "$probe_wait" -le "$EVENT_WAIT_TICKS" ] || fail "the unreachable remote endpoint was never probed twice"
  sleep 0.02
done
kill -0 "$watch_pid" 2>/dev/null \
  || fail "the watcher exited against an unreachable remote secondmate: $(cat "$TMP_ROOT/watch-unreachable.out" "$TMP_ROOT/watch-unreachable.err")"
stop_watcher_and_drain "$watch_pid"
watch_pid=''
ssh_after=$(cat "$SSH_COUNT" 2>/dev/null || printf '0')
# A watcher that survives this stop keeps probing into the fixture root until
# the EXIT trap races its removal, so prove nothing polls past a few cycles.
touch "$TMP_ROOT/watch-unreachable.stopped"
sleep 3
[ "$(cat "$SSH_COUNT" 2>/dev/null || printf '0')" = "$ssh_after" ] \
  || fail "the stopped unreachable watcher kept probing the remote endpoint"
[ -z "$(find "$WATCH_STATE_UNREACHABLE" -newer "$TMP_ROOT/watch-unreachable.stopped" -print)" ] \
  || fail "the stopped unreachable watcher kept writing its state"
[ ! -s "$WATCH_STATE_UNREACHABLE/.wake-queue" ] \
  || fail "an unreachable remote probe queued a wake: $(cat "$WATCH_STATE_UNREACHABLE/.wake-queue")"
assert_absent "$WATCH_STATE_UNREACHABLE/.secondmate-relaunch-ios" \
  "an unreachable remote probe ledgered a relaunch attempt"
assert_grep 'remote_host=remote-mac' "$WATCH_STATE_UNREACHABLE/ios.meta" \
  "an unreachable remote probe changed the route metadata"
assert_grep '- ios ' "$PARENT/data/secondmates.md" \
  "an unreachable remote probe changed the registry route"
pass "watch liveness: an unreachable remote secondmate is probed, preserved, and never failed over"

# --- a stale herdr client shadowing the one the server accepts --------------
# The remote host's job PATH can resolve an older self-updated herdr ahead of
# the one its running server accepts; the server then refuses every command
# from it with protocol_mismatch. The host-local state read must still reach
# the live endpoint through the accepted client.
make_herdr_client_pair "$TMP_ROOT/client-pair" 0.7.1 14 0.7.5 16
export FM_HERDR_PAIR_DIR="$TMP_ROOT/client-pair"
SHADOWED_STATE=$(FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  PATH="$TMP_ROOT/client-pair/stale:$REMOTE_ROOT/bin:$TMP_ROOT/client-pair/tools:/usr/bin:/bin" \
  "$REMOTE_ROOT/bin/fm-remote-secondmate-control.sh" state ios 2>"$TMP_ROOT/shadowed-state.err")
[ "$SHADOWED_STATE" = alive ] \
  || fail "a live endpoint behind a stale shadowing client must still read alive, got: $SHADOWED_STATE ($(cat "$TMP_ROOT/shadowed-state.err"))"
assert_contains "$(cat "$TMP_ROOT/client-pair/stale.log")" 'pane get' "the stale client was not the one the job PATH resolved first"
unset FM_HERDR_PAIR_DIR
pass "the host-local state read steps around a stale shadowing herdr client"

remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-before-liveness-legacy.meta"
cp "$PARENT/state/ios.meta" "$TMP_ROOT/parent-ios-before-liveness-legacy.meta"
cp "$PARENT/data/secondmates.md" "$TMP_ROOT/registry-before-liveness-legacy.md"
cat > "$remote_route_meta" <<EOF
window=firstmate:fm-ios
worktree=$REMOTE_HOME
project=$REMOTE_ROOT
harness=codex
kind=secondmate
backend=tmux
EOF
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-liveness-legacy.meta"
printf 'fm-ios|%s\n' "$REMOTE_HOME" > "$TMUX_STATE"
tmux_state_before=$(cat "$TMUX_STATE")
launches_before_legacy=$(grep -c '^tab create' "$HERDR_LOG" || true)
BOOT_LEGACY=$(remote_env "$ROOT/bin/fm-bootstrap.sh")
assert_contains "$BOOT_LEGACY" "SECONDMATE_LIVENESS: secondmate ios: skipped: remote endpoint state is unverified on remote-mac" \
  "liveness accepted an alive legacy remote backend"
cmp -s "$TMP_ROOT/remote-ios-liveness-legacy.meta" "$remote_route_meta" \
  || fail "liveness rewrote the alive legacy endpoint metadata"
cmp -s "$TMP_ROOT/parent-ios-before-liveness-legacy.meta" "$PARENT/state/ios.meta" \
  || fail "liveness rewrote the parent route metadata for an alive legacy endpoint"
cmp -s "$TMP_ROOT/registry-before-liveness-legacy.md" "$PARENT/data/secondmates.md" \
  || fail "liveness changed the registry route for an alive legacy endpoint"
[ "$(cat "$TMUX_STATE")" = "$tmux_state_before" ] \
  || fail "liveness changed or killed the alive legacy endpoint"
launches_after_legacy=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$launches_before_legacy" -eq "$launches_after_legacy" ] \
  || fail "liveness relaunched an alive legacy endpoint"
mv -f "$TMP_ROOT/remote-ios-before-liveness-legacy.meta" "$remote_route_meta"
rm -f "$TMUX_STATE"
pass "startup reports alive legacy backends without changing their routes"

# Host loss never creates a local replacement. Remove both the published ledger
# and its parent-side cache so the structured-home read degrades explicitly;
# endpoint liveness remains the startup supervisor's concern.
rm -f -- "$REMOTE_HOME/state/home-summary.json"
rm -rf -- "$PARENT/state/secondmate-summary-cache"
launches_before=$(grep -c '^tab create' "$HERDR_LOG" || true)
rm -rf -- "$PARENT/state/.watch.lock"
rm -f -- "$PARENT/state/.last-watcher-beat"
BOOT_UNAVAILABLE=$(FM_FAKE_SSH_MODE=unreachable remote_env "$ROOT/bin/fm-bootstrap.sh")
assert_contains "$BOOT_UNAVAILABLE" 'SECONDMATE_LIVENESS: secondmate ios: skipped: remote host unavailable or endpoint state unknown' \
  "bootstrap did not preserve an unreachable remote endpoint as unknown"
UNAVAILABLE=$(FM_FAKE_SSH_MODE=unreachable remote_env "$ROOT/bin/fm-fleet-snapshot.sh" --json)
printf '%s' "$UNAVAILABLE" | jq -e '.secondmate_current.records | any(.id == "ios"
  and .current.state == "unknown" and .provenance.selected != "structured-home"
  and (.current.reason | test("home ledger.*(timed out|missing|unreadable|invalid)")))' >/dev/null \
  || fail "unreachable no-ledger remote home did not degrade to explicit unknown state"
printf '%s' "$UNAVAILABLE" | jq -e '.tasks[] | select(.id == "ios") | .paths.home.present == null and .endpoint.agent_alive == "unknown"' >/dev/null \
  || fail "unreachable remote endpoint liveness was not left to supervision"
rm -f "$PARENT/state/.wake-queue"
launches_after=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$launches_before" -eq "$launches_after" ] || fail "unreachable projection attempted a replacement launch"
assert_present "$PARENT/state/ios.meta" "unreachable readiness removed the parent route metadata"
assert_grep '- ios ' "$PARENT/data/secondmates.md" "unreachable readiness removed the registry route"
pass "unreachable no-ledger remote state remains explicit with no local respawn or failover"

# Retirement delegates its safety check to the remote home. An in-flight child
# record refuses cleanup and preserves both machines' durable routes.
# A sibling remote secondmate workspace shares fm-remote and must survive every
# refusal and the eventual successful retirement of ios.
# This fixture overrides FM_ROOT for transport, so teardown's root-owned guard
# sees the fixture root rather than the source script path used by fm-send.
publish_healthy_watcher_identity "$PARENT/state" "$PARENT" "$REMOTE_ROOT/bin/fm-watch.sh"
resolve_ios_pending
SIBLING_CREATE=$("$REMOTE_ROOT/bin/herdr" workspace create --cwd "$REMOTE_ROOT" \
  --label 2ndmate-macos --no-focus --session fm-remote)
SIBLING_WORKSPACE=$(printf '%s' "$SIBLING_CREATE" | jq -r '.result.workspace.workspace_id')
SIBLING_PANE=$(printf '%s' "$SIBLING_CREATE" | jq -r '.result.root_pane.pane_id')
[ -n "$SIBLING_WORKSPACE" ] && [ "$SIBLING_WORKSPACE" != null ] \
  || fail "the shared-session sibling fixture did not create a workspace"
[ -n "$SIBLING_PANE" ] && [ "$SIBLING_PANE" != null ] \
  || fail "the shared-session sibling fixture did not create a pane"
printf 'kind=ship\n' > "$REMOTE_HOME/state/child.meta"
rm -rf "$PARENT/state/procevent"
: > "$PARENT/state/procevent"
if remote_env "$ROOT/bin/fm-teardown.sh" ios >/dev/null 2>&1; then
  fail "remote retirement ignored in-flight child work"
fi
assert_present "$REMOTE_HOME" "refused remote retirement removed the home"
assert_present "$PARENT/state/ios.meta" "refused remote retirement removed parent metadata"
assert_grep '- ios ' "$PARENT/data/secondmates.md" "refused remote retirement removed the route"
rm -f "$PARENT/state/procevent"
mkdir "$PARENT/state/procevent"
remote_env "$ROOT/bin/fm-bootstrap.sh" >/dev/null \
  || fail "bootstrap failed while repairing a preserved remote reply source"
assert_present "$PARENT/state/procevent/remote-reply-ios.source" \
  "bootstrap did not repair reply registration after retirement rollback"
resolve_ios_pending
rm -f "$REMOTE_HOME/state/child.meta"
mkdir -p "$PARENT/data/handoff"
ln -s "$TMP_ROOT/missing-outbox-target" "$PARENT/data/handoff/ios.outbox.md"
if remote_env "$ROOT/bin/fm-teardown.sh" ios >/dev/null 2>&1; then
  fail "remote retirement accepted an unsafe backlog outbox"
fi
assert_present "$REMOTE_HOME" "unsafe backlog outbox retirement removed the remote home"
rm -f "$PARENT/data/handoff/ios.outbox.md"
mkdir -p "$TMP_ROOT/external-pending"
printf 'task_id=ios\nphase=resolved\n' > "$TMP_ROOT/external-pending/escape"
mv "$PARENT/state/pending-replies" "$PARENT/state/pending-replies.safe"
ln -s "$TMP_ROOT/external-pending" "$PARENT/state/pending-replies"
if remote_env "$ROOT/bin/fm-teardown.sh" ios >/dev/null 2>&1; then
  fail "remote retirement accepted a symlinked pending-replies directory"
fi
assert_present "$REMOTE_HOME" "unsafe pending-replies retirement removed the remote home"
assert_present "$TMP_ROOT/external-pending/escape" "unsafe retirement removed an external pending reply"
rm -f "$PARENT/state/pending-replies"
mv "$PARENT/state/pending-replies.safe" "$PARENT/state/pending-replies"
retired_wake_corr=$(FM_HOME="$PARENT" bash -c '
  . "$1"
  fm_pending_reply_create "$2" "$2/state" ios "New routed work is in your backlog."
' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$PARENT") \
  || fail "could not seed remote receiver wake retirement state"
retired_wake_rec="$PARENT/state/pending-replies/$retired_wake_corr"
FM_HOME="$PARENT" bash -c '
  . "$1"
  fm_pending_reply_set "$2" phase resolved
  fm_pending_reply_set "$2" delivered_epoch 1
' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$retired_wake_rec" \
  || fail "could not settle remote receiver wake retirement state"
printf 'confirmed:%s\n' "$retired_wake_corr" > "$PARENT/state/.backlog-handoff-ios.wake-pending"
printf '%s\tattempt\n' "$(date +%s)" > "$PARENT/state/.secondmate-relaunch-ios"
printf '%s\tdead\n' "$(date +%s)" > "$PARENT/state/.secondmate-relaunch-bound-ios"
liveness_lock="$PARENT/state/.secondmate-liveness-ios.lock"
# The link is published before the claim finishes; signal only after acquire.
# shellcheck disable=SC2016 # Positional parameters expand in the child shell.
( STATE="$PARENT/state" exec bash -c '. "$1" && fm_lock_acquire_wait "$2" && touch "$3" && exec sleep 120' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$liveness_lock" "$TMP_ROOT/liveness.entered" ) &
liveness_holder_pid=$!
liveness_wait=0
while [ ! -f "$TMP_ROOT/liveness.entered" ]; do
  kill -0 "$liveness_holder_pid" 2>/dev/null || fail "liveness lock holder exited before acquiring the lock"
  liveness_wait=$((liveness_wait + 1))
  [ "$liveness_wait" -le "$EVENT_WAIT_TICKS" ] || fail "liveness lock holder never acquired the lock"
  sleep 0.02
done
liveness_owner=$liveness_holder_pid
[ "$(cat "$liveness_lock/pid" 2>/dev/null)" = "$liveness_owner" ] \
  || fail "liveness lock holder did not own its acquired lock"
if remote_env "$ROOT/bin/fm-teardown.sh" ios > "$TMP_ROOT/teardown-liveness-busy.out" 2>&1; then
  fail "remote retirement proceeded under an active liveness episode"
fi
assert_grep 'liveness check is in progress for ios' "$TMP_ROOT/teardown-liveness-busy.out" \
  "a liveness-busy retirement did not ask for a retry"
assert_present "$REMOTE_HOME" "a liveness-busy retirement removed the remote home"
assert_present "$PARENT/state/ios.meta" "a liveness-busy retirement removed parent metadata"
assert_grep '- ios ' "$PARENT/data/secondmates.md" "a liveness-busy retirement removed the registry route"
[ "$(cat "$liveness_lock/pid" 2>/dev/null)" = "$liveness_owner" ] \
  || fail "a liveness-busy retirement removed or took the episode's lock"
kill "$liveness_holder_pid" 2>/dev/null || true
wait "$liveness_holder_pid" 2>/dev/null || true
handoff_lock="$PARENT/state/.backlog-handoff-ios.lock"
FM_HOME="$PARENT" /bin/bash -c '
  . "$1"
  fm_lock_acquire_wait "$2"
  touch "$3"
  while [ ! -f "$4" ]; do sleep 0.02; done
  fm_lock_release "$2"
' _ "$ROOT/bin/fm-wake-lib.sh" "$handoff_lock" "$TMP_ROOT/handoff.entered" \
  "$TMP_ROOT/handoff.release" &
handoff_holder_pid=$!
handoff_wait=0
while [ ! -f "$TMP_ROOT/handoff.entered" ]; do
  kill -0 "$handoff_holder_pid" 2>/dev/null || fail "handoff lock holder exited before acquiring the route lock"
  handoff_wait=$((handoff_wait + 1))
  [ "$handoff_wait" -le "$EVENT_WAIT_TICKS" ] || fail "handoff lock holder never acquired the route lock"
  sleep 0.02
done
rm -f "$TMUX_STATE" "$TMP_ROOT/launch.entered" "$TMP_ROOT/launch.release"
FM_FAKE_SSH_MODE=launch-block remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-retirement.out" 2>&1 &
spawn_retirement_pid=$!
launch_wait=0
launch_total=0
# shellcheck disable=SC2034 # read by name in ssh_progress_reset
launch_ssh_seen=''
# The respawn performs readiness and inheritance jobs before launch, so bound
# the gap between remote round-trips as the earlier blocked worker path does.
# Either failure prints the respawn's own output, which cleanup then removes.
while [ ! -f "$TMP_ROOT/launch.entered" ]; do
  if ! kill -0 "$spawn_retirement_pid" 2>/dev/null; then
    spawn_retirement_rc=0
    wait "$spawn_retirement_pid" || spawn_retirement_rc=$?
    printf 'remote respawn exited %s; its output:\n%s\n' "$spawn_retirement_rc" \
      "$(cat "$TMP_ROOT/spawn-retirement.out")" >&2
    fail "remote respawn exited before its blocked launch"
  fi
  ssh_progress_reset launch_wait launch_ssh_seen
  launch_wait=$((launch_wait + 1))
  launch_total=$((launch_total + 1))
  if [ "$launch_wait" -gt "$EVENT_WAIT_TICKS" ] || [ "$launch_total" -gt "$REMOTE_WAIT_TICKS" ]; then
    printf 'remote respawn output so far:\n%s\n' "$(cat "$TMP_ROOT/spawn-retirement.out")" >&2
    fail "remote respawn never reached its blocked launch"
  fi
  sleep 0.02
done
FM_FAKE_SSH_MODE=retire-lost-slot remote_env "$ROOT/bin/fm-teardown.sh" ios \
  > "$TMP_ROOT/teardown-serialized.out" 2> "$TMP_ROOT/teardown-serialized.err" &
teardown_pid=$!
sleep 0.2
kill -0 "$teardown_pid" 2>/dev/null || fail "remote retirement bypassed an active remote respawn"
assert_present "$REMOTE_HOME" "remote retirement removed the home during an active remote respawn"
touch "$TMP_ROOT/launch.release"
if ! wait "$spawn_retirement_pid"; then
  printf 'serialized respawn output:\n%s\n' "$(cat "$TMP_ROOT/spawn-retirement.out")" >&2
  fail "serialized remote respawn failed"
fi
sleep 0.2
kill -0 "$teardown_pid" 2>/dev/null || fail "remote retirement bypassed an active backlog handoff"
touch "$TMP_ROOT/handoff.release"
wait "$handoff_holder_pid" || fail "handoff lock holder failed to release"
teardown_rc=0
wait "$teardown_pid" || teardown_rc=$?
if [ "$teardown_rc" -ne 4 ]; then
  printf 'serialized retirement output:\n%s\n%s\n' "$(cat "$TMP_ROOT/teardown-serialized.out")" \
    "$(cat "$TMP_ROOT/teardown-serialized.err")" >&2
  fail "remote retirement with a lost child slot did not exit 4 (exit $teardown_rc)"
fi
assert_grep 'teardown ios complete (remote ' "$TMP_ROOT/teardown-serialized.out" \
  "remote retirement with a lost child slot did not report its local completion on stdout"
assert_grep 'pool slot 3 (/remote/slot-3) dirty or unverified; the pool lost this slot' "$TMP_ROOT/teardown-serialized.err" \
  "remote retirement did not forward the remote lost-slot warning"
assert_grep 'left-behind-clone' "$TMP_ROOT/teardown-serialized.err" \
  "remote retirement did not forward the lost slot's remaining paths"
assert_no_grep 'teardown ios ' "$TMP_ROOT/teardown-serialized.err" \
  "remote retirement forwarded remote completion text to stderr"
assert_absent "$REMOTE_HOME" "remote retirement did not remove the remote home"
assert_absent "$PARENT/state/ios.meta" "remote retirement did not remove parent metadata"
assert_absent "$PARENT/state/.backlog-handoff-ios.wake-pending" \
  "remote retirement left receiver wake state that could poison a replacement route"
assert_absent "$retired_wake_rec" "remote retirement left the retired receiver wake correlation"
assert_absent "$PARENT/state/.secondmate-relaunch-ios" \
  "remote retirement left the relaunch ledger a same-id replacement would inherit"
assert_absent "$PARENT/state/.secondmate-relaunch-bound-ios" \
  "remote retirement left the relaunch park marker a same-id replacement would inherit"
assert_absent "$liveness_lock" "remote retirement left its liveness lock behind"
assert_no_grep '- ios ' "$PARENT/data/secondmates.md" "remote retirement did not remove the registry route"
jq -e --arg workspace "$SIBLING_WORKSPACE" --arg pane "$SIBLING_PANE" '
  any(.workspaces[]; .workspace_id == $workspace and .label == "2ndmate-macos")
  and any(.tabs[]; .workspace_id == $workspace and .pane_id == $pane)
' "$HERDR_STATE" >/dev/null \
  || fail "remote retirement removed the sibling secondmate workspace or pane from fm-remote"
assert_no_grep 'session stop' "$HERDR_LOG" "remote retirement stopped the shared fm-remote session"
assert_no_grep 'server stop' "$HERDR_LOG" "remote retirement stopped the shared fm-remote server"
pass "remote retirement refuses child work, then removes only its own endpoint while a shared-session sibling survives"

echo "ALL TESTS PASSED"
