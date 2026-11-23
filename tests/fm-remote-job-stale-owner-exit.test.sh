#!/usr/bin/env bash
# A serving worker that no longer owns the published lock must stop.
#
# Live failure shape (PC02, 2026-11-23): a lock was stolen or reclaimed while an
# older supervisor tree kept running, so two serving loops shared one account
# queue. The non-owner kept claiming jobs; the recorded owner then saw those
# records running and reclaimed them, publishing exit 125 ("remote job worker
# stopped before this job completed"). Every remote read through that queue then
# failed intermittently even though the host was reachable.
#
# The serving loop's heartbeat check only fires for the recorded owner, so a
# stale non-owner with a dead heartbeat never stopped. This drives the real
# worker, hands the lock to another live process, and requires the stale serving
# loop to stop without touching the replacement's lock or serving another job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job-stale-owner)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
WORKER_PID=
DECOY_PID=

cleanup_stale_owner_fixture() {
  if [ -n "$WORKER_PID" ]; then kill -TERM "$WORKER_PID" 2>/dev/null || true; fi
  if [ -n "$DECOY_PID" ]; then kill -TERM "$DECOY_PID" 2>/dev/null || true; fi
  wait 2>/dev/null || true
  rm -rf -- "$TMP_ROOT"
}
trap cleanup_stale_owner_fixture EXIT

mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME" "$ACCOUNT_HOME"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" \
  "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-touch-job.sh" <<'SH'
#!/bin/bash
printf 'ran\n' > "$1"
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'stale-owner fixture'

export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_QUEUE_TIMEOUT=60
export FM_REMOTE_JOB_TIMEOUT=30
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

fm_remote_job_prepare_state "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"

HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  > "$TMP_ROOT/worker.out" 2> "$TMP_ROOT/worker.err" &
WORKER_PID=$!

for _ in $(seq 1 200); do
  [ -f "$STATE_ROOT/worker.ready" ] && break
  sleep 0.05
done
assert_present "$STATE_ROOT/worker.ready" "the worker did not become ready"

# Prove the worker serves before the ownership loss, so a pass cannot be a
# worker that never came up.
TOUCHED="$TMP_ROOT/served-before"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-touch-job.sh "$TOUCHED" < /dev/null > /dev/null \
  || fail "staging the pre-loss job failed: $FM_REMOTE_JOB_ERROR"
JOB_ID=$FM_REMOTE_JOB_ID
for _ in $(seq 1 400); do
  [ "$(fm_remote_job_read_state "$STATE_ROOT/jobs/$JOB_ID" 2>/dev/null || true)" = "done" ] && break
  sleep 0.05
done
assert_present "$TOUCHED" "the worker never served its first job"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "could not reap the pre-loss job"

kill -0 "$WORKER_PID" 2>/dev/null || fail "the worker exited before ownership was handed away"

# Hand the lock to another live process exactly as a lock reclaim would: the
# replacement recorded owner is alive, so the stale loop's own cleanup must not
# remove it.
sleep 30 &
DECOY_PID=$!
printf '%s\n' "$DECOY_PID" > "$STATE_ROOT/worker.lock/pid"

exited=0
for _ in $(seq 1 400); do
  if ! kill -0 "$WORKER_PID" 2>/dev/null; then exited=1; break; fi
  sleep 0.05
done
[ "$exited" -eq 1 ] || fail "a serving loop that lost its lock ownership kept running"
wait "$WORKER_PID"; WORKER_RC=$?
[ "$WORKER_RC" -eq 0 ] || fail "a stale serving loop exited $WORKER_RC instead of stopping cleanly"
WORKER_PID=

grep -q 'lost worker lock ownership' "$TMP_ROOT/worker.err" \
  || fail "the stale serving loop did not report losing its lock ownership"
[ "$(cat "$STATE_ROOT/worker.lock/pid" 2>/dev/null)" = "$DECOY_PID" ] \
  || fail "the stale serving loop disturbed the replacement owner's lock"

# The stale loop must claim nothing more: the next job stays queued.
TOUCHED_AFTER="$TMP_ROOT/served-after"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-touch-job.sh "$TOUCHED_AFTER" < /dev/null > /dev/null \
  || fail "staging the post-loss job failed: $FM_REMOTE_JOB_ERROR"
JOB_ID=$FM_REMOTE_JOB_ID
sleep 2
[ "$(fm_remote_job_read_state "$STATE_ROOT/jobs/$JOB_ID" 2>/dev/null || true)" = queued ] \
  || fail "the stale serving loop claimed another job after losing its lock"
assert_absent "$TOUCHED_AFTER" "the stale serving loop executed another job after losing its lock"

pass "a serving loop that lost its lock stops without touching the replacement or claiming more work"
