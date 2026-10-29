#!/usr/bin/env bash
# Full remote secondmate lifecycle over the deterministic generic SSH boundary,
# second stretch: inherited config convergence on a launched remote route, the
# mixed fleet snapshot, host-local update, and the restart refusals. The
# fixture and the other stretches are named in
# tests/fm-remote-secondmate-lifecycle-lib.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"
# shellcheck source=tests/fm-remote-secondmate-lifecycle-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-remote-secondmate-lifecycle-lib.sh"

launch_ios_fixture

printf '{"revision":2}\n' > "$PARENT/config/crew-dispatch.json"
printf 'grok\n' > "$PARENT/config/crew-harness"
set +e
FM_FAKE_SSH_MODE=inherit-partial remote_env "$ROOT/bin/fm-config-push.sh" \
  > "$TMP_ROOT/config-partial.out" 2>&1
config_partial_rc=$?
set -e
[ "$config_partial_rc" -ne 0 ] || fail "partial remote inheritance claimed complete convergence"
assert_grep '"revision":2' "$REMOTE_HOME/config/crew-dispatch.json" "partial inheritance did not apply its first file"
[ "$(cat "$REMOTE_HOME/config/crew-harness")" != grok ] \
  || fail "partial inheritance unexpectedly applied the failed file"
NUDGE_MARKER="$PARENT/state/.secondmate-nudge-pending/ios.pending"
assert_grep 'remote=1' "$NUDGE_MARKER" "partial inheritance left no durable remote reread marker"
publish_healthy_watcher_identity "$PARENT/state" "$PARENT" "$REMOTE_ROOT/bin/fm-watch.sh"
remote_env "$ROOT/bin/fm-bootstrap.sh" > "$TMP_ROOT/config-partial-retry.out" \
  || fail "bootstrap did not converge partial remote inheritance"
[ "$(cat "$REMOTE_HOME/config/crew-harness")" = grok ] \
  || fail "bootstrap did not apply the remaining inherited file"
assert_absent "$NUDGE_MARKER" "bootstrap cleared no remote reread marker after convergence"
PARTIAL_CONFIG_CORR=$(newest_remote_inbox_corr)
[ -n "$PARTIAL_CONFIG_CORR" ] || fail "bootstrap config reread did not carry a correlation token"
printf 'done [corr=%s]: converged inherited config re-read\n' "$PARTIAL_CONFIG_CORR" >> "$REMOTE_HOME/state/parent-replies.status"
PARTIAL_CONFIG_RESULT=$(next_reply_result)
await_reply_result "$PARTIAL_CONFIG_RESULT" \
  || fail "remote reply source did not capture the converged config acknowledgment"
PARTIAL_CONFIG_SEQ=${PARTIAL_CONFIG_RESULT%.result}
remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios "${PARTIAL_CONFIG_SEQ##*.}" "$PARTIAL_CONFIG_RESULT" >/dev/null \
  || fail "converged remote config acknowledgment was not ingested"
pass "partial remote inheritance retains reread intent through bootstrap convergence"

rm -f "$TMP_ROOT/inherit.entered" "$TMP_ROOT/inherit.release" "$TMP_ROOT/inherit.payload"
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
stale concurrent preference
EOF
FM_FAKE_SSH_MODE=inherit-block remote_env "$ROOT/bin/fm-config-push.sh" \
  > "$TMP_ROOT/config-concurrent-first.out" 2>&1 &
config_first=$!
inherit_wait=0
inherit_total=0
# shellcheck disable=SC2034 # read by name in ssh_progress_reset
inherit_ssh_seen=''
while [ ! -f "$TMP_ROOT/inherit.entered" ]; do
  kill -0 "$config_first" 2>/dev/null || fail "first inheritance transaction exited before its blocked write"
  ssh_progress_reset inherit_wait inherit_ssh_seen
  inherit_wait=$((inherit_wait + 1))
  inherit_total=$((inherit_total + 1))
  # Bound the gap between remote round-trips rather than the total, as the
  # spawn inheritance wait does.
  [ "$inherit_wait" -le "$EVENT_WAIT_TICKS" ] && [ "$inherit_total" -le "$REMOTE_WAIT_TICKS" ] || fail "first inheritance transaction never reached its blocked write"
  sleep 0.02
done
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
current concurrent preference
EOF
remote_env "$ROOT/bin/fm-bootstrap.sh" > "$TMP_ROOT/config-concurrent-second.out" 2>&1 &
config_second=$!
sleep 0.2
kill -0 "$config_second" 2>/dev/null \
  || fail "bootstrap bypassed the active remote inheritance transaction"
touch "$TMP_ROOT/inherit.release"
wait "$config_first" || fail "first serialized inheritance transaction failed"
wait "$config_second" || fail "bootstrap inheritance transaction failed after waiting"
[ "$(tail -1 "$REMOTE_HOME/data/captain-shared.md")" = 'current concurrent preference' ] \
  || fail "later bootstrap convergence was overwritten by stale inherited bytes"
pass "config push and bootstrap serialize remote inheritance convergence"

printf 'codex\n' > "$PARENT/config/crew-harness"
# A failed reread nudge now means the durable remote inbox RECORD could not be
# written (a swallowed doorbell alone no longer fails a recorded steer), so
# the failure is induced by making the remote steering inbox unwritable.
chmod 555 "$PARENT_ROUTE_INBOX"
if remote_env "$ROOT/bin/fm-config-push.sh" > "$TMP_ROOT/config-push-fail.out" 2>&1; then
  chmod 755 "$PARENT_ROUTE_INBOX"
  fail "remote config push claimed success after its reread record could not be written"
fi
if [ ! -f "$NUDGE_MARKER" ]; then
  chmod 755 "$PARENT_ROUTE_INBOX"
  printf 'config push failure output:\n%s\n' "$(cat "$TMP_ROOT/config-push-fail.out")" >&2
  fail "failed remote config reread did not retain a retry marker"
fi
assert_grep 'remote=1' "$NUDGE_MARKER" "remote config reread marker lost its placement"
chmod 755 "$PARENT_ROUTE_INBOX"
remote_env "$ROOT/bin/fm-config-push.sh" > "$TMP_ROOT/config-push-retry.out" \
  || fail "unchanged remote config push did not retry its pending reread"
assert_absent "$NUDGE_MARKER" "successful remote config reread left its retry marker"
assert_grep 'config-reread: sent' "$TMP_ROOT/config-push-retry.out" "remote config reread retry was not reported"
CONFIG_CORR=$(newest_remote_inbox_corr)
[ -n "$CONFIG_CORR" ] || fail "remote config reread did not carry a correlation token"
printf 'done [corr=%s]: inherited config re-read\n' "$CONFIG_CORR" >> "$REMOTE_HOME/state/parent-replies.status"
CONFIG_RESULT=$(next_reply_result)
await_reply_result "$CONFIG_RESULT" \
  || fail "remote reply source did not capture the config reread acknowledgement"
CONFIG_SEQ=${CONFIG_RESULT%.result}
remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios "${CONFIG_SEQ##*.}" "$CONFIG_RESULT" >/dev/null \
  || fail "remote config reread acknowledgement was not ingested"
pass "remote inherited config retains and retries a failed live reread nudge"

resolve_ios_pending

# Structured fleet state comes from each home's published ledger. The remote
# host is explicit, and the local route remains alongside it.
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LOCAL_HOME" \
  "$ROOT/bin/fm-home-summary-refresh.sh" >/dev/null \
  || fail "local fixture did not publish its home ledger"
remote_env "$ROOT/bin/fm-on.sh" ios fm-home-summary-refresh.sh >/dev/null \
  || fail "remote fixture did not publish its home ledger"
# The remote ledger is collected over the transport inside the snapshot's
# budget; widen it so a loaded host still reads the published ledger.
SNAPSHOT=$(FM_SNAPSHOT_BUDGET=120 remote_env "$ROOT/bin/fm-fleet-snapshot.sh" --json)
if ! printf '%s' "$SNAPSHOT" | jq -e '.secondmate_current.records | any(.id == "ios" and .remote == true and .host == "remote-mac" and .provenance.selected == "structured-home")' >/dev/null; then
  printf 'secondmate projection:\n%s\n' "$(printf '%s' "$SNAPSHOT" | jq '.secondmate_current')" >&2
  fail "fleet snapshot did not select the remote structured-home projection"
fi
printf '%s' "$SNAPSHOT" | jq -e '.tasks[] | select(.id == "ios") | .paths.home.present == null and .endpoint.agent_alive == "unknown"' >/dev/null \
  || fail "the fleet snapshot performed or invented a remote endpoint-liveness probe"
printf '%s' "$SNAPSHOT" | jq -e '.secondmate_current.records | any(.id == "local" and .remote == false)' >/dev/null \
  || fail "fleet snapshot lost the existing local secondmate route"
pass "fleet snapshot projects mixed local and remote structured state"
rm -f "$PARENT/state/.wake-queue"

# The remote code root updates independently, then the persistent home imports
# and fast-forwards to that host-local commit without touching project clones.
REMOTE_SEED="$TMP_ROOT/firstmate-seed"
git clone -q "file://$REMOTE_ORIGIN" "$REMOTE_SEED"
git -C "$REMOTE_SEED" config user.email test@example.com
git -C "$REMOTE_SEED" config user.name Test
printf 'remote update probe\n' > "$REMOTE_SEED/REMOTE_UPDATE_PROBE"
git -C "$REMOTE_SEED" add REMOTE_UPDATE_PROBE
git -C "$REMOTE_SEED" commit -qm 'advance remote code root'
git -C "$REMOTE_SEED" push -q origin main
UPDATE_OUT=$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh update ios)
assert_contains "$UPDATE_OUT" 'synced:' "remote update did not report a host-local fast-forward"
[ "$(git -C "$REMOTE_HOME" rev-parse HEAD)" = "$(git -C "$REMOTE_ROOT" rev-parse HEAD)" ] \
  || fail "remote persistent home did not fast-forward to its code-root commit"
assert_present "$REMOTE_HOME/REMOTE_UPDATE_PROBE" "remote update did not materialize the code-root commit"
pass "remote update imports and fast-forwards the persistent home on its configured host"

# The remote restart verb is not a second implementation: its host-local leg runs
# the ORDINARY control plane against a record that is plain and local on that
# host. These two refusals can only come from that plane's own pre-stop
# capability tables, and they leave the live agent exactly as it was - which is
# the whole safety property of asking before anything is stopped.
RELAUNCH_UNVERIFIED=$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh \
  relaunch ios notaharness - - 2>&1) && fail "an unverified runtime should refuse a remote restart"
assert_contains "$RELAUNCH_UNVERIFIED" 'unverified remote secondmate harness' \
  "the remote restart verb did not refuse an unverified runtime"
RELAUNCH_ROUTE_META="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$RELAUNCH_ROUTE_META" "$TMP_ROOT/ios-before-relaunch.meta"
mkdir -p "$TMP_ROOT/not-a-checkout"
sed "s|^worktree=.*|worktree=$TMP_ROOT/not-a-checkout|" \
  "$TMP_ROOT/ios-before-relaunch.meta" > "$RELAUNCH_ROUTE_META"
RELAUNCH_CHECKPOINT=$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh \
  relaunch ios codex big-model high 2>&1) && fail "a restart with no accountable checkout should refuse"
assert_contains "$RELAUNCH_CHECKPOINT" 'refusing to relaunch without a checkout whose unlanded work can be accounted for' \
  "the host-local restart did not reach the control plane's own pre-stop checkpoint"
cp "$TMP_ROOT/ios-before-relaunch.meta" "$RELAUNCH_ROUTE_META"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "a refused remote restart must leave the running agent untouched"
pass "the remote restart verb delegates to the host-local control plane and refuses before stopping anything"

echo "ALL TESTS PASSED"
