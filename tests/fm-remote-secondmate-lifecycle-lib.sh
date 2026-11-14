#!/usr/bin/env bash
# tests/fm-remote-secondmate-lifecycle-lib.sh - the shared fixture for the full
# remote secondmate lifecycle over the deterministic generic SSH boundary: a
# remote code root, its fake ssh, the parent home, and the helpers every part
# uses. Sourcing it builds the fixture. Each part runs one stretch of the
# lifecycle so it fits the per-script bound:
#   tests/fm-remote-secondmate-lifecycle-e2e.test.sh             provisioning, seeding, launch, send
#   tests/fm-remote-secondmate-lifecycle-inherit-e2e.test.sh     inherited config, snapshot, update, restart
#   tests/fm-remote-secondmate-lifecycle-supervision-e2e.test.sh liveness, startup, retirement
# A part sources tests/lib.sh and tests/remote-herdr-fixture.sh before this file.

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-e2e)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
LOCAL_HOME="$TMP_ROOT/local-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
SSH_COUNT="$TMP_ROOT/ssh.count"
DOCTOR_LOG="$TMP_ROOT/doctor.log"
HERDR_STATE="$TMP_ROOT/remote-herdr.state"
HERDR_LOG="$TMP_ROOT/remote-herdr.log"
TMUX_LOG="$TMP_ROOT/remote-tmux.log"
TMUX_STATE="$TMP_ROOT/remote-tmux.state"
# One fixture value names the remote route's steering-inbox surface, so the
# charter render assertions and the delivery checks below cannot drift apart.
PARENT_ROUTE_INBOX="$REMOTE_HOME/state/parent-route/ios.inbox"
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS"
cleanup() {
  local worker_pid=''
  touch "$TMP_ROOT/provision.release" "$TMP_ROOT/seed.release" "$TMP_ROOT/handoff.release" \
    "$TMP_ROOT/inherit.release" "$TMP_ROOT/launch.release" "$TMP_ROOT/race-clone.release" 2>/dev/null || true
  # A watcher leg cut short by a failed assertion is still polling the root.
  if [ -n "${watch_pid:-}" ]; then
    kill "$watch_pid" 2>/dev/null || true
    wait "$watch_pid" 2>/dev/null || true
  fi
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    # The published pid is the serving child; killing it alone lets its
    # detached supervisor restart it while the fixture root is being removed.
    . "$ROOT/bin/fm-remote-job-lib.sh"
    fm_remote_job_stop_worker_tree "$worker_pid" || true
  fi
  # This trap replaces the one tests/lib.sh installs, so run its cleanup here:
  # it makes read-only directories such as a route's git-hooks dir writable
  # before removing the root, which a bare rm -rf cannot.
  fm_test_cleanup
}
trap cleanup EXIT

# Materialize the current branch as the remote host's tracked code root. The
# fixture is a real git repository because provisioning and guarded sync exercise
# the same clone and fast-forward path as a second Mac.
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)
cat > "$REMOTE_ROOT/bin/tmux" <<SH
#!/usr/bin/env bash
set -u
log='$TMUX_LOG'
state='$TMUX_STATE'
fail_send='$TMP_ROOT/tmux-send-fail'
printf '%s\n' "\$*" >> "\$log"
case "\${1:-}" in
  has-session|new-session|set-window-option) exit 0 ;;
  list-windows)
    [ -f "\$state" ] || exit 0
    name=\$(cut -d'|' -f1 "\$state")
    case "\$*" in *'#{session_name}:#{window_name}'*) printf 'firstmate:%s\n' "\$name" ;; *) printf '%s\n' "\$name" ;; esac
    exit 0
    ;;
  new-window)
    name=; cwd=
    while [ "\$#" -gt 0 ]; do
      case "\$1" in -n) shift; name=\$1 ;; -c) shift; cwd=\$1 ;; esac
      shift
    done
    printf '%s|%s\n' "\$name" "\$cwd" > "\$state"
    printf '@1\n'
    exit 0
    ;;
  display-message)
    case "\$*" in
      *'#{pane_current_path}'*) cut -d'|' -f2- "\$state" ;;
      *'#{pane_current_command}'*) printf 'codex\n' ;;
      *'#{cursor_y}'*) printf '0\n' ;;
      *'#S'*) printf 'firstmate\n' ;;
      *) printf '%%1\n' ;;
    esac
    exit 0
    ;;
  capture-pane) printf '❯\n'; exit 0 ;;
  send-keys) [ ! -f "\$fail_send" ] || exit 1; exit 0 ;;
  kill-window) rm -f -- "\$state"; exit 0 ;;
  list-panes) printf 'codex\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/tmux"
install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
  "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'
REMOTE_ORIGIN="$TMP_ROOT/firstmate-origin.git"
git init -q --bare "$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" remote add origin "file://$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" push -q -u origin main
git --git-dir="$REMOTE_ORIGIN" symbolic-ref HEAD refs/heads/main

# One remote-backed direct-PR project. The remote home clones its origin, never
# the primary working tree.
git init -q --bare "$TMP_ROOT/alpha.git"
git -C "$PARENT/projects" init -q -b main alpha
git -C "$PARENT/projects/alpha" config user.email test@example.com
git -C "$PARENT/projects/alpha" config user.name Test
printf 'alpha\n' > "$PARENT/projects/alpha/README.md"
git -C "$PARENT/projects/alpha" add README.md
git -C "$PARENT/projects/alpha" commit -qm init
git -C "$PARENT/projects/alpha" remote add origin "file://$TMP_ROOT/alpha.git"
git -C "$PARENT/projects/alpha" push -q -u origin main
cat > "$PARENT/data/projects.md" <<EOF
- alpha [direct-PR] - alpha project (added 2026-08-02)
EOF
printf 'codex big-model high\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"
printf 'primary harness defaults\n' > "$PARENT/config/crew-harness"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_FAKE_SSH_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$FM_FAKE_SSH_COUNT"
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
argv_b64=$4
command_fields=$(perl -MMIME::Base64=decode_base64 -e '
  my $data=decode_base64($ARGV[0]);
  my @args=split(/\0/, $data);
  print join("\t", map { defined $_ ? $_ : "" } @args[0..2]);
' "$argv_b64")
IFS=$'\t' read -r command_name _command_action command_rel <<EOF
$command_fields
EOF
case "${FM_FAKE_SSH_MODE:-normal}:$command_name:$command_rel" in
  inherit-partial:fm-remote-inherit.sh:config/crew-harness) exit 255 ;;
  inherit-block:fm-remote-inherit.sh:data/captain-shared.md)
    cat > "$FM_FAKE_INHERIT_PAYLOAD"
    touch "$FM_FAKE_INHERIT_ENTERED"
    while [ ! -f "$FM_FAKE_INHERIT_RELEASE" ]; do sleep 0.02; done
    "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" < "$FM_FAKE_INHERIT_PAYLOAD"
    exit $?
    ;;
esac
# The readiness gate is answered here rather than by the real doctor, which
# would inspect and repair the RUNNER's own account. tests/fm-remote-doctor.test.sh
# owns the doctor's real behavior against controlled account fixtures; this
# boundary owns only what the callers do with its verdict.
if [ "$command_name" = fm-remote-doctor.sh ]; then
  printf '%s %s\n' "${FM_FAKE_SSH_MODE:-normal}" "${_command_action:--}" >> "$FM_FAKE_DOCTOR_LOG"
  case "${FM_FAKE_SSH_MODE:-normal}" in
    unreachable) exit 255 ;;
    doctor-fix-unknown)
      if [ "${_command_action:-}" = --fix ]; then
        printf 'fix launchagent=applied: wrote the Aqua-scoped launch agent\n'
        exit 255
      fi
      printf 'check launchagent=fixable: no Firstmate herdr launch agent\n'
      printf 'error: this host is not ready for a remote second mate; unresolved: launchagent\n' >&2
      exit 1
      ;;
    doctor-human)
      printf 'check gui-session=human: no Aqua login session exists for uid 501\n'
      printf 'action: gui-session: log that account in once at the console\n'
      printf 'error: this host is not ready for a remote second mate; unresolved: gui-session\n' >&2
      exit 1
      ;;
    doctor-fixable)
      # Red until --fix runs on this host, green on every later read-only run.
      if [ "${_command_action:-}" = --fix ]; then
        touch "$FM_FAKE_DOCTOR_REPAIRED"
        printf 'fix launchagent=applied: wrote the Aqua-scoped launch agent\n'
        printf 'ok: remote second-mate readiness confirmed on this host\n'
        exit 0
      fi
      [ -f "$FM_FAKE_DOCTOR_REPAIRED" ] || {
        printf 'check launchagent=fixable: no Firstmate herdr launch agent\n'
        printf 'error: this host is not ready for a remote second mate; unresolved: launchagent\n' >&2
        exit 1
      }
      ;;
  esac
  printf 'check herdr=ok: /usr/bin/herdr\n'
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
if [ "${FM_FAKE_SSH_MODE:-normal}" = doctor-fixable ] \
  && [ "$command_name" = fm-remote-secondmate-control.sh ] \
  && [ "$_command_action" = state ] \
  && [ ! -f "$FM_FAKE_DOCTOR_REPAIRED" ]; then
  printf 'unreadable\n'
  exit 0
fi
case "${FM_FAKE_SSH_MODE:-normal}:$command_name:$command_rel" in
  launch-nonherdr-route:fm-remote-secondmate-control.sh:*)
    [ "$_command_action" = launch ] || exit 93
    printf 'schema=fm-remote-secondmate-control.v1\n'
    printf 'backend=tmux\n'
    printf 'target=firstmate:fm-ios\n'
    printf 'harness=codex\n'
    exit 0
    ;;
  launch-default-session-route:fm-remote-secondmate-control.sh:*)
    [ "$_command_action" = launch ] || exit 93
    printf 'schema=fm-remote-secondmate-control.v1\n'
    printf 'backend=herdr\n'
    printf 'target=default:w1:p2\n'
    printf 'herdr_session=default\n'
    printf 'harness=codex\n'
    exit 0
    ;;
  provision-block-fail:fm-remote-home-provision.sh:*)
    touch "$FM_FAKE_SEED_ENTERED"
    while [ ! -f "$FM_FAKE_SEED_RELEASE" ]; do sleep 0.02; done
    exit 1
    ;;
  launch-block:fm-remote-secondmate-control.sh:*)
    [ "$_command_action" = launch ] || exit 93
    touch "$FM_FAKE_LAUNCH_ENTERED"
    while [ ! -f "$FM_FAKE_LAUNCH_RELEASE" ]; do sleep 0.02; done
    ;;
esac
case "${FM_FAKE_SSH_MODE:-normal}" in
  unreachable) exit 255 ;;
  ambiguous) "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"; exit 255 ;;
  # The remote retirement really runs, then reports what its forced secondmate
  # teardown reports for a lost child slot: tests/fm-teardown.test.sh owns that
  # remote-side exit 4.
  retire-lost-slot)
    rc=0
    "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" || rc=$?
    if [ "$rc" -eq 0 ] && [ "$command_name:$_command_action" = fm-remote-secondmate-control.sh:retire ]; then
      printf 'warning: treehouse return left pool slot 3 (/remote/slot-3) dirty or unverified; the pool lost this slot. Remaining paths:\n' >&2
      printf '  ?? left-behind-clone/\n' >&2
      printf 'teardown ios finished its cleanup and removed its task record, but a returned pool slot did not come back clean\n' >&2
      exit 4
    fi
    exit "$rc"
    ;;
  *) exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" ;;
esac
SH
chmod +x "$FAKEBIN/fake-ssh"

# Bounds for the polling loops in every part, counted in loop ticks. A loop
# ends as soon as its event lands, so a bound only sets how long a genuinely
# stuck leg takes to fail, and each is generous so a loaded host cannot trip it.
#   EVENT_WAIT_TICKS   0.02s ticks, at least 60s: a background step reaching
#                      its blocked point, or the gap between remote round-trips
#   REMOTE_WAIT_TICKS  0.02s ticks, at least 600s: a whole remote spawn or push,
#                      however many round-trips it makes
#   REPLY_WAIT_TICKS   0.05s ticks, at least 120s: the reply source capturing
#                      and handing off a correlated remote answer
# shellcheck disable=SC2034 # read by the parts that source this file
EVENT_WAIT_TICKS=3000
# shellcheck disable=SC2034 # read by the parts that source this file
REMOTE_WAIT_TICKS=30000
REPLY_WAIT_TICKS=2400

publish_healthy_watcher_identity() { # <state> <home> <watch-script>
  local state=$1 home=$2 watch=$3 identity
  identity=$(FM_HOME="$PARENT" FM_STATE_OVERRIDE="$PARENT/state" /bin/bash -c \
    '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$$") \
    || fail "could not derive fixture watcher identity"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$watch" > "$state/.watch.lock/watcher-path"
  touch "$state/.last-watcher-beat"
}

# Every remote leg here runs the real entrypoint and job worker on this
# machine, which on a loaded runner can outlast the production per-mate
# convergence budget; tests/fm-bootstrap-network-parallel.test.sh owns that
# budget's behavior, so this suite gives convergence ample time.
# The inheritance push overlaps its sends to hide real SSH round trips, but
# this fixture's transport has none and its job worker still runs one home's
# commands one at a time, so overlap only adds submission overhead to every
# remote spawn here; the suite sends one item at a time and leaves the
# overlapped scheduler to tests/fm-bootstrap-network-parallel.test.sh.
remote_env() {
  FM_SECONDMATE_CONVERGENCE_TIMEOUT="${FM_SECONDMATE_CONVERGENCE_TIMEOUT:-900}" \
  FM_REMOTE_INHERIT_PUSH_JOBS=1 \
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_SSH_MODE="${FM_FAKE_SSH_MODE:-normal}" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_FAKE_SEED_ENTERED="$TMP_ROOT/seed.entered" \
  FM_FAKE_SEED_RELEASE="$TMP_ROOT/seed.release" \
  FM_FAKE_DOCTOR_LOG="$DOCTOR_LOG" \
  FM_FAKE_DOCTOR_REPAIRED="$TMP_ROOT/doctor.repaired" \
  FM_FAKE_INHERIT_ENTERED="$TMP_ROOT/inherit.entered" \
  FM_FAKE_INHERIT_RELEASE="$TMP_ROOT/inherit.release" \
  FM_FAKE_INHERIT_PAYLOAD="$TMP_ROOT/inherit.payload" \
  FM_FAKE_LAUNCH_ENTERED="$TMP_ROOT/launch.entered" \
  FM_FAKE_LAUNCH_RELEASE="$TMP_ROOT/launch.release" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_REMOTE_REPLY_WAIT_SECONDS=10 \
  "$@"
}

reply_owner() {
  remote_env "$ROOT/bin/fm-procevent.sh" list 2>/dev/null \
    | awk -v id="$SID" 'NR > 1 && $1 == id { print $3; exit }'
}

await_reply_result() { # <result-path>
  local result=$1 handled=${1%.result}.handled _
  if [ "$(reply_owner)" != live ]; then
    remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 &
  fi
  for _ in $(seq 1 "$REPLY_WAIT_TICKS"); do
    [ -s "$result" ] && [ -f "$handled" ] && return 0
    sleep 0.05
  done
  return 1
}

# Reset a stall counter whenever the fake ssh has made a remote round-trip
# since the last poll, so a polling bound measures stalled progress rather
# than total wall time on a host where each inherited file costs a round-trip.
ssh_progress_reset() { # <stall-counter-var> <last-seen-count-var>
  local now=''
  read -r now < "$SSH_COUNT" 2>/dev/null || true
  if [ -n "$now" ] && [ "$now" != "${!2}" ]; then
    printf -v "$2" '%s' "$now"
    printf -v "$1" '%s' 0
  fi
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

# The correlation token of the newest record in the remote secondmate's
# steering inbox: a remote steer is delivered as a durable record there, so
# the corr a reply must echo is read from the record body, never from typed
# pane bytes.
newest_remote_inbox_corr() {
  grep -Eoh 'corr=[a-f0-9]{16}' "$PARENT_ROUTE_INBOX"/*.msg 2>/dev/null \
    | tail -1 | cut -d= -f2-
}


SID='remote-reply-ios'

# The path the remote reply source writes its next captured result to.
next_reply_result() {
  local seq
  seq=$(find "$PARENT/state/procevent-inbox" -name "$SID.*.result" 2>/dev/null | wc -l | tr -d ' ')
  printf '%s\n' "$PARENT/state/procevent-inbox/$SID.$((seq + 1)).result"
}

resolve_ios_pending() {
  local pending_record pending_corr pending_result pending_seq before_results now_results pending_seen
  for pending_record in "$PARENT/state/pending-replies"/*; do
    [ -f "$pending_record" ] || continue
    [ "$(grep '^task_id=' "$pending_record" | cut -d= -f2-)" = ios ] || continue
    [ "$(grep '^phase=' "$pending_record" | cut -d= -f2-)" != resolved ] || continue
    pending_corr=$(basename "$pending_record")
    before_results=$(find "$PARENT/state/procevent-inbox" -name "$SID.*.result" 2>/dev/null | wc -l | tr -d ' ')
    printf 'done [corr=%s]: concurrent inherited data re-read\n' "$pending_corr" \
      >> "$REMOTE_HOME/state/parent-replies.status"
    if [ "$(reply_owner)" != live ]; then
      remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 &
    fi
    pending_seen=0
    for _ in $(seq 1 "$REPLY_WAIT_TICKS"); do
      now_results=$(find "$PARENT/state/procevent-inbox" -name "$SID.*.result" 2>/dev/null | wc -l | tr -d ' ')
      pending_result=$(find "$PARENT/state/procevent-inbox" -name "$SID.*.result" -print 2>/dev/null | sort | tail -1)
      if [ "$now_results" -gt "$before_results" ] && [ -n "$pending_result" ] \
        && [ -f "${pending_result%.result}.handled" ]; then
        pending_seen=1
        break
      fi
      sleep 0.05
    done
    [ "$pending_seen" -eq 1 ] \
      || fail "remote reply source did not capture a concurrent inheritance acknowledgment"
    pending_result=$(find "$PARENT/state/procevent-inbox" -name "$SID.*.result" -print | sort | tail -1)
    pending_seq=${pending_result%.result}
    pending_seq=${pending_seq##*.}
    remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios "$pending_seq" "$pending_result" >/dev/null \
      || fail "concurrent inheritance acknowledgment was not ingested"
  done
}

seed_ios_route() { # <home>
  FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
    FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
    remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$1" alpha
}

# One local route beside the remote one, so mixed fleets stay parseable and
# projected.
add_local_route() {
  mkdir -p "$LOCAL_HOME/data" "$LOCAL_HOME/state" "$LOCAL_HOME/config" "$LOCAL_HOME/projects" "$LOCAL_HOME/bin"
  printf 'local\n' > "$LOCAL_HOME/.fm-secondmate-home"
  printf 'fixture\n' > "$LOCAL_HOME/AGENTS.md"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$LOCAL_HOME/data/backlog.md"
  cat >> "$PARENT/data/secondmates.md" <<ROUTE
- local - Local delivery (home: $LOCAL_HOME; scope: local work; projects: alpha; added 2026-08-02)
ROUTE
}

# Seed and launch the remote ios route beside the local one: the state the
# parts after tests/fm-remote-secondmate-lifecycle-e2e.test.sh build on. That
# part owns the assertions on each of these steps.
launch_ios_fixture() {
  local out
  out=$(seed_ios_route "$REMOTE_HOME" 2>&1) || fail "fixture remote seed failed"$'\n'"$out"
  add_local_route
  printf 'pi\n' > "$PARENT/config/crew-harness"
  out=$(remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1) \
    || fail "fixture remote spawn failed"$'\n'"$out"
  publish_healthy_watcher_identity "$PARENT/state" "$PARENT" "$ROOT/bin/fm-watch.sh"
}
