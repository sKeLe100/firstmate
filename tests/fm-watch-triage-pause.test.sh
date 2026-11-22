#!/usr/bin/env bash
# Behavior tests for watcher declared-wait, pause, and captain-hold rechecks
# (bin/fm-watch.sh, bin/fm-classify-lib.sh). Shared fixtures live in
# tests/watch-triage-helpers.sh.
#
# Classifier tests in fm-watch-triage.test.sh export FM_CREW_STATE_BIN pointing
# at a hermetic make_fake_crew_state stub and never unset it. Three launches in
# this file pass no FM_CREW_STATE_BIN, so in the original run they inherited
# that stub's default unknown verdict. Install the same hermetic fake here so
# those launches keep that verdict instead of hitting the real
# bin/fm-crew-state.sh.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-triage-pause-tests)
mkdir -p "$TMP_ROOT/crew-state-bin"
FM_CREW_STATE_BIN=$(make_fake_crew_state "$TMP_ROOT/crew-state-bin")
export FM_CREW_STATE_BIN

# --- non-terminal stale, crew NOT provably working: surfaced immediately ------
# The key requirement: a crew with no running pipeline that has gone quiet (and is
# not busy) has stopped - it may be done via interactive menus, waiting, or wedged.
# It must surface at once, never wait out the wedge timer, so these users (a
# non-no-mistakes crew, or any crew with no running pipeline) are never left hanging.

# A captain-held crew can leave a stable backend endpoint after its agent exits.
# fm-crew-state then authoritatively reports stopped rather than paused, but the
# confirmed-dead agent plus the declared wait or captain-held transfer must retain
# bounded pause handling.
# A still-live agent at an external-decision gate is the disconfirming case: it
# must surface once, while the unchanged hash must not append the same wake on
# every watcher re-arm.
test_exited_declared_pause_is_bounded_but_live_gate_surfaces() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back round wakes bare
  dir=$(make_case exited-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'idle bare shell after agent exit\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'paused: held per captain while an external decision is pending\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(watch_window_key "$window")
  pane_hash=$(hash_text "idle bare shell after agent exit")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  round=1
  while [ "$round" -le 6 ]; do
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    if wait_poll_cycle "$state" "$pid"; then
      reap "$pid"
    elif kill -0 "$pid" 2>/dev/null; then
      reap "$pid"
      fail "dead-agent watcher round $round timed out before completing a poll cycle"
    else
      wait "$pid" || fail "dead-agent watcher round $round failed"
    fi
    round=$((round + 1))
  done
  # A watcher that queues nothing never creates .wake-queue, so these counts
  # read a path that may legitimately be absent. awk aborts on a missing file
  # before END runs, which collapses the count to the empty string and turns the
  # next comparison into an "integer expression expected" error - reported as a
  # flood of an unprintable number of wakes instead of the real contract breach
  # the grep below names. No queue means no wakes, per the drain-count read at
  # the end of this file.
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -le 1 ] || fail "dead-agent declared pause flooded $wakes stale wakes across six unchanged polls"
  [ "$bare" -eq 0 ] || fail "dead-agent declared pause surfaced as $bare bare stopped-crew wakes"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    || fail "dead-agent declared pause did not use the bounded paused recheck"

  dir=$(make_case exited-captain-held); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'idle bare shell after captain-held transfer\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'captain-held [key=route]: tracked by held-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(watch_window_key "$window")
  pane_hash=$(hash_text "idle bare shell after captain-held transfer")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "captain-held dead-agent pane did not re-surface on the bounded cadence"
  grep -F "awaiting the captain" "$state/.wake-queue" >/dev/null \
    || fail "captain-held dead-agent pane surfaced as a stopped crew instead of a captain-owned recheck: $(cat "$state/.wake-queue")"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    && fail "captain-held dead-agent pane borrowed the pause verb's external-wait wording"

  dir=$(make_case alive-decision-gate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/gate.status"
  window="test:fm-gate"
  printf 'idle external-decision gate\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/gate.meta"
  printf 'paused: waiting at an active external-decision gate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-gate_status"
  key=$(watch_window_key "$window")
  pane_hash=$(hash_text "idle external-decision gate")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # First sight must surface promptly so a live external-decision gate is not
  # hidden behind the pause cadence.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "live external-decision gate did not surface immediately"
  ack_stopped_cycle "$state" || fail "could not acknowledge the immediate external-decision surface"

  # Re-arm with the stale timer already beyond the wedge threshold. This is the
  # exact unchanged-hash fallback after the immediate surface: it must retain
  # the pause cadence and discard any residual wedge timer instead of emitting
  # a second possible-wedge wake.
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"
    fail "live external-decision gate escalated on the wedge timer after its immediate surface: $(cat "$out")"
  fi
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "live external-decision gate lost its pause cadence marker"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "live external-decision gate retained the wedge timer"; }
  reap "$pid"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -eq 0 ] || fail "acknowledged external-decision surface replayed $wakes wakes"
  [ "$bare" -eq 0 ] || fail "acknowledged external-decision bare stale remained queued"
  pass "exited declared-pause and captain-held panes use bounded pause cadence while a live decision gate still surfaces once"
}

# Run one watcher round against a parked-worker fixture, so a round differs only
# in the pane contents the case just wrote. Armed the way fm-watch-arm.sh arms a
# successor after firstmate handled a wake, because that is what a supervision
# turn actually does and it is the only arm that stays in the poll loop instead of
# re-announcing the previous round's downtime - without it a round exits on
# `check: rearm-resurface` before it ever reaches the stale path, and every
# absorb assertion below passes vacuously. A live agent (pane_current_command
# matching the recorded harness) on an idle pane is the exact population
# pause_state_class answers `none` for.
# <mode> `exit` requires the watcher to surface and exit; `absorb` requires it to
# survive whole poll cycles - enough to see the new hash, count it stable, and
# reach the stale path. Returns 1 when the watcher does the other thing.
parked_watch_round() {  # <state> <fakebin> <out> <capture> <window> <exit|absorb>
  local state=$1 fakebin=$2 out=$3 capture=$4 window=$5 mode=$6 pid cycles=0
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · parked' \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  if [ "$mode" = exit ]; then
    wait_for_exit "$pid" 100 || { reap "$pid"; return 1; }
    return 0
  fi
  while [ "$cycles" -lt 4 ]; do
    wait_poll_cycle "$state" "$pid" 300 || { reap "$pid"; return 1; }
    cycles=$((cycles + 1))
  done
  reap "$pid"
  return 0
}


# --- work the captain is already holding: pane churn must not re-alarm -------
# The other record of a legitimate wait. The declared-wait bound above reads the
# status LINE, and a delivered task's line stays `done: PR ...` while the wait
# itself lives in the BACKLOG, written there by bin/fm-captain-hold.sh. No line
# predicate can see that record, so both stale alarms - the captain-relevant one
# and the inconclusive one - re-fired on every new pane hash for as long as the
# captain was deciding, which is the 2026-09 loop observed on delivered work
# awaiting their merge word.
# Pinned here, in both directions: while the call stands the first sight still
# alarms, further sights of the SAME call and status-log state are absorbed, and
# a new pane hash after the window's end alarms once more; and the identical
# fixture WITHOUT the hold keeps alarming on every hash, because a bound that
# swallowed an unheld delivery or blocker would be worse than the churn it removes.
#
# The backlog is real rather than a fixture file: bin/fm-captain-hold.sh is the
# only writer of a hold and tasks-axi the only reader, so a hand-written row
# would pin this test's idea of a hold instead of the one the watcher consults.
# These four cases require tasks-axi on PATH and fail if it is absent, so a
# missing backlog reader cannot turn unexercised safety checks into a green run.
#
# Cost: every case below drives churn through ONE watcher process rather than
# relaunching per pane change. Watcher startup dominates a round here, and an
# absorbing watcher stays in its poll loop across churn in production anyway, so
# the cheaper shape is also the more faithful one.

# The window key every hold fixture uses, derived the way fm-watch.sh derives it.
hold_key() {
  watch_window_key test:fm-held-merge
}

make_hold_home() {  # <name> <status-line> <hold|nohold>
  local name=$1 line=$2 hold=$3 dir state
  dir=$(make_case "$name"); state="$dir/state"
  mkdir -p "$dir/data" "$dir/config"
  fm_test_tasks_toml "$dir/.tasks.toml" || return 1
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  (cd "$dir" && tasks-axi add held-merge 'delivered work' --file data/backlog.md) >/dev/null 2>&1 \
    || return 1
  if [ "$hold" = hold ]; then
    run_hold "$dir" hold held-merge --reason 'awaiting the captain on the merge' || return 1
  fi
  printf 'window=test:fm-held-merge\nkind=ship\nharness=grok\nbackend=tmux\n' \
    > "$state/held-merge.meta"
  printf '%s\n' "$line" > "$state/held-merge.status"
  printf '%s' "$(seen_sig "$state/held-merge.status")" > "$state/.seen-held-merge_status"
  printf '%s\n' "$dir"
}

# Launch one watcher against a hold fixture, armed the way parked_watch_round
# arms one, plus the home the backlog read resolves against. The crew reads
# stopped: a delivered worker's agent has exited, and that is the population
# whose alarm the call must bound. The pid lands in HOLD_WATCH_PID rather than on
# stdout: a command substitution would background the watcher inside a subshell,
# leaving the caller unable to wait on or reap its own watcher.
HOLD_WATCH_PID=
hold_watch_launch() {  # <dir> <out> <capture>
  local dir=$1 out=$2 capture=$3
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-held-merge \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS="${FM_HOLD_PAUSE_RESURFACE_SECS:-999}" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" 2>&1 &
  HOLD_WATCH_PID=$!
}

# One sighting that must surface and exit the cycle.
hold_watch_surface() {  # <dir> <out> <capture> <pane-text>
  local dir=$1 out=$2 capture=$3 text=$4
  printf '%s\n' "$text" > "$capture"
  hold_watch_launch "$dir" "$out" "$capture"
  wait_for_exit "$HOLD_WATCH_PID" 100 || { reap "$HOLD_WATCH_PID"; return 1; }
  return 0
}

# <count> successive pane changes driven through ONE watcher, each given three
# poll cycles: one to see the new hash, one to count it stable and classify, one
# to prove the classification held. The watcher must stay in the loop throughout.
hold_watch_churn() {  # <dir> <out> <capture> <label> <count>
  local dir=$1 out=$2 capture=$3 label=$4 count=$5 i=1 c
  local state="$dir/state"
  printf '%s 0\n' "$label" > "$capture"
  hold_watch_launch "$dir" "$out" "$capture"
  while [ "$i" -le "$count" ]; do
    printf '%s %s\n' "$label" "$i" > "$capture"
    c=0
    while [ "$c" -lt 3 ]; do
      wait_poll_cycle "$state" "$HOLD_WATCH_PID" 300 \
        || { reap "$HOLD_WATCH_PID"; return 1; }
      c=$((c + 1))
    done
    i=$((i + 1))
  done
  reap "$HOLD_WATCH_PID"
  return 0
}

hold_stale_wakes() {  # <state>
  awk -F '\t' '$3 == "stale" && $4 == "test:fm-held-merge" { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

# Both status lines a held task really carries: the delivery that routes through
# the captain-relevant stale branch, and a worker line that routes through the
# inconclusive one. The hold is invisible to the status line in both, so both
# branches had the same blindness and both are covered.
test_open_captain_call_bounds_stale_churn() {
  local spec name line dir state out capture throttle wakes
  command -v tasks-axi >/dev/null 2>&1 \
    || fail "tasks-axi is required (captain-hold stale bound)"
  for spec in \
    'held-delivery|done: PR https://example.invalid/pull/1 checks green' \
    'held-worker-line|working: still tidying the branch'
  do
    name=${spec%%|*}; line=${spec#*|}
    dir=$(make_hold_home "$name" "$line" hold) \
      || fail "[$name] could not build a captain-held backlog fixture"
    state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"
    throttle="$state/.paused-resurfaced-$(hold_key)"

    # First sight still alarms: the call bounds repetition, never the first look.
    hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 1s' \
      || fail "[$name] first sight of held work did not surface"
    wakes=$(hold_stale_wakes "$state")
    [ "$wakes" -eq 1 ] || fail "[$name] first sight produced $wakes wakes instead of one"
    ack_stopped_cycle "$state" || fail "[$name] could not acknowledge the first surface"

    # The pane churns while the SAME call stands. Every one of these alarmed.
    hold_watch_churn "$dir" "$out" "$capture" 'idle, tick' 2 \
      || fail "[$name] watcher exited during pane churn instead of supervising through it: $(cat "$out")"
    wakes=$(hold_stale_wakes "$state")
    [ "$wakes" -eq 0 ] \
      || fail "[$name] pane churn re-alarmed held work $wakes time(s) inside the re-surface window"

    # After the window ends, the next new pane hash re-surfaces held work exactly
    # once, so a forgotten call on a churning pane cannot hide behind the bound.
    [ -e "$throttle" ] || fail "[$name] the absorbed churn recorded no re-surface cadence to elapse"
    set_mtime "$(( $(date +%s) - 5000 ))" "$throttle"
    hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 9s' \
      || fail "[$name] held work did not re-surface once its re-surface window elapsed"
    wakes=$(hold_stale_wakes "$state")
    [ "$wakes" -eq 1 ] \
      || fail "[$name] elapsed re-surface window produced $wakes wakes instead of one"
  done
  pass "work under an open captain call surfaces once, absorbs pane churn, then re-surfaces when the window elapses"
}


# The other half of the same bound, and the one that decides whether widening the
# wait was safe: the identical fixtures with NO hold must keep alarming on every
# new hash, on both branches.
test_stale_churn_without_a_captain_call_still_alarms() {
  local spec name line dir state out capture round wakes
  command -v tasks-axi >/dev/null 2>&1 \
    || fail "tasks-axi is required (unheld stale alarm)"
  for spec in \
    'unheld-delivery|done: PR https://example.invalid/pull/1 checks green' \
    'unheld-blocker|blocked: cannot reach the release host' \
    'unheld-worker-line|working: still tidying the branch'
  do
    name=${spec%%|*}; line=${spec#*|}
    dir=$(make_hold_home "$name" "$line" nohold) \
      || fail "[$name] could not build an unheld backlog fixture"
    state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"
    round=1
    while [ "$round" -le 2 ]; do
      hold_watch_surface "$dir" "$out" "$capture" "idle, elapsed ${round}s" \
        || fail "[$name] an unheld stale window stopped alarming on round $round"
      wakes=$(hold_stale_wakes "$state")
      [ "$wakes" -eq 1 ] \
        || fail "[$name] round $round produced $wakes wakes instead of one"
      ack_stopped_cycle "$state" || fail "[$name] could not acknowledge round $round"
      round=$((round + 1))
    done
  done
  pass "a stale window with no open captain call keeps alarming on every new hash"
}


# The cadence marker may never outlive the wake it claims to record. Recording it
# before publishing the durable wake turned a delayed alarm into a lost one: the
# append fails, the watcher exits with nothing queued, and the next sighting
# reads that fresh marker and absorbs the retry. An unwritable queue is the real
# failure, so it is the one this drives.
test_failed_wake_append_does_not_arm_the_captain_hold_throttle() {
  local dir state out capture wakes rc
  command -v tasks-axi >/dev/null 2>&1 \
    || fail "tasks-axi is required (failed wake append)"
  dir=$(make_hold_home append-failure 'done: PR https://example.invalid/pull/1 checks green' hold) \
    || fail "could not build a captain-held backlog fixture"
  state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"

  # A directory where the queue file belongs: every append fails, whatever the
  # caller does, so the watcher cannot publish the wake it just decided to send.
  # Its exit code is read directly here because a refusing watcher exits NON-zero,
  # which is the correct outcome and not the "surfaced" one hold_watch_surface means.
  rm -f "$state/.wake-queue"
  mkdir -p "$state/.wake-queue"
  printf 'idle, elapsed 1s\n' > "$capture"
  hold_watch_launch "$dir" "$out" "$capture"
  wait_for_exit "$HOLD_WATCH_PID" 100
  rc=$?
  rmdir "$state/.wake-queue"
  [ "$rc" -ne 124 ] || fail "the watcher did not exit when its durable queue could not be written"
  [ "$rc" -ne 0 ] || fail "the watcher reported success despite an unwritable durable queue"
  [ -e "$state/.paused-resurfaced-$(hold_key)" ] \
    && fail "a wake that never reached the durable queue still armed the re-surface throttle"

  # The retry must alarm: nothing was ever delivered, so nothing may be absorbed.
  hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 2s' \
    || fail "the retry after a failed wake append was absorbed instead of alarming"
  wakes=$(hold_stale_wakes "$state")
  [ "$wakes" -eq 1 ] \
    || fail "the retry after a failed wake append produced $wakes wakes instead of one"
  pass "a wake that never reached the durable queue arms no re-surface throttle"
}

# The task id is not the captain call. A task can be answered with `--release`
# and held again as a genuinely different call with NO status append, and binding
# the throttle to the status-log signature alone let the second call inherit the
# first one's silence and absorbed its first sight. That is the one alarm this
# bound must never swallow: a delivery announced twice is noise, but a decision
# waiting on the captain that is never surfaced is invisible.
# Measured at base c499f84 this fixture alarms on every sighting, so the
# suppression was introduced by the bound itself rather than pre-existing.
test_reheld_captain_call_starts_its_own_resurface_window() {
  local dir state out capture wakes
  command -v tasks-axi >/dev/null 2>&1 \
    || fail "tasks-axi is required (re-held captain call)"
  dir=$(make_hold_home reheld-call 'done: PR https://example.invalid/pull/1 checks green' hold) \
    || fail "could not build a captain-held backlog fixture"
  state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"

  hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 1s' \
    || fail "first sight of the first captain call did not surface"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first call's surface"
  hold_watch_churn "$dir" "$out" "$capture" 'idle, tick' 1 \
    || fail "the first call's churn was not absorbed"
  [ "$(hold_stale_wakes "$state")" -eq 0 ] \
    || fail "the first call's churn re-alarmed inside its own window"

  # Answer and release, then re-hold: a second, distinct captain call on the same
  # task id, with no status append, so the status signature cannot tell them apart.
  printf 'go ahead\n' > "$dir/decision.txt"
  run_hold "$dir" answer held-merge --decision-file "$dir/decision.txt" --release \
    || fail "could not record the captain's answer"
  run_hold "$dir" hold held-merge --reason 'awaiting the captain a second time' \
    || fail "could not re-hold the task as a second captain call"

  hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 3s' \
    || fail "the second captain call inherited the first call's silence"
  wakes=$(hold_stale_wakes "$state")
  [ "$wakes" -eq 1 ] \
    || fail "the second captain call produced $wakes first wakes instead of one"
  pass "a released-then-re-held task is a distinct captain call whose first sight still alarms"
}


# Quiet mode's record is a present captain (bin/fm-afk-contract.sh AWAY OR
# QUIET), so it silences nothing: the same hold is rechecked with that record
# live, both on the watcher's own cadence and through the one-shot handoff a
# running quiet daemon owns.
write_quiet_record() {  # <state>
  if ! FM_HOME="$(dirname "$1")" FM_STATE_OVERRIDE="$1" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1; then
    fail "could not write quiet mode's record in $1"
  fi
}

# --- declared waits are condition-aware: `until <UTC ISO 8601>` --------------
# A paused: line naming when the wait clears is rechecked at that time when it
# falls within the flat cadence, but a distant or mistyped time cannot extend
# the cadence, and a time that has passed is rechecked at once.
paused_until_fixture() {  # <name> <until-epoch> <status-age-secs>
  local name=$1 until=$2 age=$3 dir state statusf window key back
  dir=$(make_case "$name"); state="$dir/state"
  window="test:fm-until"
  statusf="$state/until.status"
  printf 'idle, waiting for the reset\n' > "$dir/pane.txt"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/until.meta"
  printf 'paused: rate limit resets, until %s, then resuming\n' "$(iso_utc_at "$until")" > "$statusf"
  back=$(( $(date +%s) - age ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-until_status"
  key=$(watch_window_key "$window")
  printf '%s' "$(hash_text 'idle, waiting for the reset')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' "$dir"
}

# The pause ceiling is opt-in; a case that exercises it arms the home's presence flag.
arm_pause_ceiling() {  # <home-dir>
  mkdir -p "$1/config" && : > "$1/config/pause-ceiling"
}

until_watch() {  # <dir> <cadence> -> pid in UNTIL_PID
  local dir=$1
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-until FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS="$2" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" 2>&1 &
  UNTIL_PID=$!
}

test_pause_ceiling_dated_overdue_pause_opens_one_decision() {
  local dir state class
  dir=$(paused_until_fixture until-overdue "$(( $(date +%s) - 90000 ))" 90000); state="$dir/state"
  arm_pause_ceiling "$dir"
  class=$(FM_STATE_OVERRIDE="$state" FM_HOME="$dir" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE='state: working · source: active run' bash -c '. "$1"; pause_state_class test:fm-until until' _ "$WATCH")
  [ "$class" = paused ] || fail "overdue dated pause classified as working: $class"
  until_watch "$dir" 240
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "a declared wait whose until time passed was not rechecked ahead of the cadence"; }
  grep -F 'stale: test:fm-until' "$dir/watch.out" >/dev/null || fail "the due recheck did not print a stale wake: $(cat "$dir/watch.out")"
  grep -F 'wait overdue - decide or release' "$dir/watch.out" >/dev/null \
    || fail "the overdue recheck did not request a decision: $(cat "$dir/watch.out")"
  grep -F 'possible wedge' "$dir/watch.out" >/dev/null && fail "a due declared wait was mislabeled a possible wedge"
  grep -F 'paused-overdue-until' < <(status_open_decisions "$state/until.status") >/dev/null \
    || fail "the overdue pause did not open a keyed decision"
  local heartbeat
  heartbeat=$(FM_STATE_OVERRIDE="$state" FM_HOME="$dir" bash -c '. "$1"; STATE="$2"; heartbeat_scan_finds_actionable; printf "%s" "$FM_HEARTBEAT_SURFACE_ENDPOINTS"' _ "$WATCH" "$state") \
    || fail "heartbeat did not classify the overdue pause as actionable"
  case "$heartbeat" in *until.status*) ;; *) fail "heartbeat omitted overdue pause status: $heartbeat" ;; esac
  # The due recheck fires once per declaration: a second watcher on the same
  # unchanged declaration absorbs it again.
  ack_stopped_cycle "$state" || fail "could not acknowledge the due recheck"
  : > "$dir/watch.out"
  until_watch "$dir" 240
  if ! wait_poll_cycle "$state" "$UNTIL_PID" || ! wait_poll_cycle "$state" "$UNTIL_PID"; then
    reap "$UNTIL_PID"; fail "the due recheck repeated on every poll instead of once per declaration: $(cat "$dir/watch.out")"
  fi
  reap "$UNTIL_PID"
  printf 'working: resumed\n' >> "$state/until.status"
  # A fresh watcher observes the resumed status and closes the keyed decision.
  : > "$dir/watch.out"
  until_watch "$dir" 240
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "resumed worker did not clear the overdue decision"; }
  [ -z "$(status_open_decisions "$state/until.status")" ] \
    || fail "resuming the worker did not close the overdue pause decision"
  pass "with config/pause-ceiling, a dated pause past its ceiling opens one keyed decision that a worker event closes"
}

test_pause_ceiling_absent_keeps_old_pauses_on_the_recheck() {
  local dir state statusf before
  dir=$(paused_until_fixture pause-ceiling-absent "" 90000); state="$dir/state"; statusf="$state/until.status"
  printf 'paused: waiting for an external dependency\n' > "$statusf"
  set_mtime "$(( $(date +%s) - 90000 ))" "$statusf"
  before=$(cat "$statusf")
  # A marker left by an earlier opt-in must not change anything once the flag is gone.
  FM_STATE_OVERRIDE="$state" FM_HOME="$dir" FM_PAUSE_UNDATED_MAX_SECS=1 bash -c '
    . "$1"
    wake() { :; }
    printf "%s:%s\n" "$(stat_devino "$2")" "$(_fm_status_file_size "$2")" > "$STATE/.paused-overdue-until"
    status_pause_is_overdue "paused: waiting for an external dependency" 90000 "$(date +%s)" && exit 3
    pause_overdue_reconcile until "$2" && exit 4
    handle_paused_stale test:fm-until until hash
  ' _ "$WATCH" "$statusf" || fail "without config/pause-ceiling an old pause was treated as overdue"
  [ "$(cat "$statusf")" = "$before" ] || fail "without config/pause-ceiling the watcher wrote to the status log: $(cat "$statusf")"
  [ -e "$state/.paused-overdue-until" ] || fail "without config/pause-ceiling the watcher touched a leftover overdue marker"
  grep -F 'stale: test:fm-until' "$state/.wake-queue" >/dev/null || fail "without config/pause-ceiling the old pause was not rechecked"
  grep -F 'wait overdue' "$state/.wake-queue" >/dev/null && fail "without config/pause-ceiling the recheck asked for an overdue decision"
  pass "without config/pause-ceiling an old pause keeps the plain recheck and opens no decision"
}

test_overdue_resume_race_uses_pause_snapshot() {
  local dir state statusf timing
  for timing in before after; do
    dir=$(paused_until_fixture "overdue-resume-race-$timing" "$(( $(date +%s) - 90000 ))" 90000); state="$dir/state"; statusf="$state/until.status"
    arm_pause_ceiling "$dir"
    FM_STATE_OVERRIDE="$state" FM_HOME="$dir" FM_PAUSE_UNDATED_MAX_SECS=1 bash -c '
      . "$1"
      original_append=$(declare -f fm_wake_status_append_self_announced)
      eval "${original_append/fm_wake_status_append_self_announced ()/original_append_impl ()}"
      fm_wake_status_append_self_announced() {
        case "$3" in blocked*)
          [ "$timing" != before ] || printf "working: resumed\n" >> "$2"
          original_append_impl "$@"
          [ "$timing" != after ] || printf "working: resumed\n" >> "$2"
          return 1 ;;
        esac
        original_append_impl "$@"
      }
      timing=$3
      handle_paused_stale test:fm-until until hash
      [ ! -s "$STATE/.wake-queue" ] || exit 1
      [ ! -e "$STATE/.paused-overdue-until" ] || exit 1
      [ -z "$(status_open_decisions "$2")" ] || exit 1
      grep -Fq "resolved [key=paused-overdue-until]" "$2"
    ' _ "$WATCH" "$statusf" "$timing" || fail "initial overdue publication missed a resume ($timing)"
  done
  pass "overdue publication reconciles resumes before or after the blocker append without a stale alert"
}

test_busy_overdue_pause_does_not_enter_wedge_ladder() {
  local dir state statusf
  dir=$(paused_until_fixture busy-overdue "$(( $(date +%s) - 90000 ))" 90000); state="$dir/state"; statusf="$state/until.status"
  arm_pause_ceiling "$dir"
  FM_STATE_OVERRIDE="$state" FM_HOME="$dir" FM_PAUSE_UNDATED_MAX_SECS=1 bash -c '
    . "$1"
    wake() { :; }
    key=$(window_key test:fm-until)
    since="$STATE/.stale-since-$key"; escalations="$STATE/.escalated-$key"
    busy_turn_bound_check test:fm-until until first "$since" "$escalations" || exit 1
    status_open_decisions "$2" | grep -Fq paused-overdue-until || exit 1
    before=$(wc -l < "$STATE/.wake-queue")
    busy_turn_bound_check test:fm-until until second "$since" "$escalations" || exit 1
    busy_turn_bound_check test:fm-until until third "$since" "$escalations" || exit 1
    [ "$(wc -l < "$STATE/.wake-queue")" = "$before" ] || exit 1
    [ ! -e "$since" ] && [ ! -e "$escalations" ] || exit 1
    printf "working: resumed\n" >> "$2"
    STALE_ESCALATE_SECS=999999
    busy_turn_bound_check test:fm-until until resumed "$since" "$escalations"
    [ "$?" -eq 1 ] && [ -e "$since" ] || exit 1
    [ -z "$(status_open_decisions "$2")" ]
  ' _ "$WATCH" "$statusf" || fail "busy overdue pause repeated a wake or lost normal wedge tracking after resume"
  pass "busy overdue decisions suppress wedge alerts until a worker event, then restore ordinary tracking"
}

test_overdue_marker_survives_reconcile_and_closes_on_working() {
  local dir state statusf
  dir=$(paused_until_fixture overdue-marker-eof "" 90000); state="$dir/state"; statusf="$state/overdue-marker-eof.status"
  arm_pause_ceiling "$dir"
  printf 'holding: waiting for an external dependency\n' > "$statusf"
  FM_STATE_OVERRIDE="$state" FM_HOME="$dir" FM_CLASSIFY_PAUSED_VERB=holding bash -c '
    . "$1"
    fm_wake_status_append_self_announced() { printf "%s\n" "$3" >> "$2"; }
    fm_wake_append() { :; }
    wake() { :; }
    resurface_absorbed test:fm-overdue "$STATE/.paused-resurfaced-overdue-marker-eof" 90000 overdue "" 0 "$2" \
      "blocked [key=paused-overdue-overdue-marker-eof]: paused 90000s, wait overdue - decide or release" \
      "$STATE/.paused-overdue-overdue-marker-eof" "$(stat_devino "$2"):$(_fm_status_file_size "$2")"
    [ -s "$STATE/.paused-overdue-overdue-marker-eof" ] || exit 1
    pause_overdue_reconcile overdue-marker-eof "$2"; [ "$?" -eq 0 ] || exit 1
    printf "blocked [key=other]: unrelated decision\n" >> "$2"
    pause_overdue_reconcile overdue-marker-eof "$2"; [ "$?" -eq 0 ] || exit 1
    [ -s "$STATE/.paused-overdue-overdue-marker-eof" ] || exit 1
    printf "holding [at=200]: waiting for an external dependency\n" >> "$2"
    pause_overdue_reconcile overdue-marker-eof "$2"; [ "$?" -eq 0 ] || exit 1
    [ -s "$STATE/.paused-overdue-overdue-marker-eof" ] || exit 1
    printf "Still waiting for the dependency\n" >> "$2"
    pause_overdue_reconcile overdue-marker-eof "$2"; [ "$?" -eq 0 ] || exit 1
    [ -s "$STATE/.paused-overdue-overdue-marker-eof" ] || exit 1
    printf "working: resumed\n" >> "$2"
    FM_CLASSIFY_RESOLVE_VERB=answered pause_overdue_reconcile overdue-marker-eof "$2"; [ "$?" -eq 1 ] || exit 1
    [ ! -e "$STATE/.paused-overdue-overdue-marker-eof" ] || exit 1
    grep -Fq "answered [key=paused-overdue-overdue-marker-eof]" "$2" || exit 1
    ! FM_CLASSIFY_RESOLVE_VERB=answered status_open_decisions "$2" | grep -Fq paused-overdue-overdue-marker-eof || exit 1
    printf "holding: waiting for an external dependency\n" >> "$2"
    offset=$(_fm_status_file_size "$2")
    identity=$(stat_devino "$2")
    printf "%s:%s\n" "$identity" "$offset" > "$STATE/.paused-overdue-overdue-marker-eof"
    printf "blocked [key=paused-overdue-overdue-marker-eof]: overdue\n" >> "$2"
    printf "merged\n" >> "$2"
    pause_overdue_reconcile overdue-marker-eof "$2"; [ "$?" -eq 1 ] || exit 1
    [ ! -e "$STATE/.paused-overdue-overdue-marker-eof" ] || exit 1
    printf "holding: waiting for an external dependency\n" >> "$2"
    offset=$(_fm_status_file_size "$2")
    identity=$(stat_devino "$2")
    printf "%s:%s\n" "$identity" "$offset" > "$STATE/.paused-overdue-overdue-marker-eof"
    printf "blocked [key=paused-overdue-overdue-marker-eof]: overdue\n" >> "$2"
    printf "holding [at=300]: waiting for an external dependency\n" >> "$2"
    pause_overdue_reconcile overdue-marker-eof "$2"; [ "$?" -eq 0 ] || exit 1
    [ -s "$STATE/.paused-overdue-overdue-marker-eof" ] || exit 1
    printf "needs-decision: captain input required\n" >> "$2"
    pause_overdue_reconcile overdue-marker-eof "$2"; [ "$?" -eq 1 ] || exit 1
    [ ! -e "$STATE/.paused-overdue-overdue-marker-eof" ] || exit 1
    grep -Fq "resolved [key=paused-overdue-overdue-marker-eof]" "$2"
  ' _ "$WATCH" "$statusf" || fail "a freshly written overdue marker did not survive reconcile and close on working"
  pass "a fresh overdue marker survives reconciliation and closes when the worker resumes"
}

test_overdue_terminal_status_ignores_pane_display_churn() {
  local dir state statusf pid
  dir=$(paused_until_fixture overdue-display-churn "$(( $(date +%s) - 90000 ))" 90000); state="$dir/state"; statusf="$state/until.status"
  arm_pause_ceiling "$dir"
  printf 'window=test:fm-until\nkind=ship\n' > "$state/until.meta"
  set_mtime "$(( $(date +%s) - 90000 ))" "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-until_status"
  until_watch "$dir" 240
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "overdue pause did not open its decision"; }
  grep -Fq 'paused-overdue-until' < <(status_open_decisions "$statusf") || fail "overdue decision was not opened"
  ack_stopped_cycle "$state" || fail "could not acknowledge overdue decision"

  printf 'idle, waiting for the reset; display changed\n' > "$dir/pane.txt"
  until_watch "$dir" 240
  pid=$UNTIL_PID
  if ! wait_poll_cycle "$state" "$pid" || ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "terminal overdue pause repeated a stale wake after pane display changed: $(cat "$dir/watch.out")"
  fi
  [ ! -s "$dir/watch.out" ] || fail "pane display churn printed another stale wake"
  [ ! -s "$state/.wake-queue" ] || fail "pane display churn queued another stale wake"
  reap "$pid"
  pass "an open overdue decision suppresses terminal stale wakes caused only by pane display churn"
}

test_reused_task_id_does_not_inherit_overdue_pause() {
  local dir state statusf
  dir=$(paused_until_fixture reused-overdue-task "" 90000); state="$dir/state"; statusf="$state/until.status"
  arm_pause_ceiling "$dir"
  printf 'paused: waiting for an external dependency\n' > "$statusf"
  FM_STATE_OVERRIDE="$state" FM_HOME="$dir" FM_FAKE_CREW_STATE='state: working · source: active run' bash -c '
    . "$1"
    fm_wake_status_append_self_announced() { printf "%s\n" "$3" >> "$2"; }
    fm_wake_append() { :; }
    wake() { :; }
    resurface_absorbed test:fm-until "$STATE/.paused-resurfaced-reused" 90000 overdue "" 0 "$2" "blocked [key=paused-overdue-until]: paused 90000s, wait overdue - decide or release" "$STATE/.paused-overdue-until" "$(stat_devino "$2"):$(_fm_status_file_size "$2")"
    mv "$2" "$2.retired"
    printf "working: fresh task\n" > "$2"
    result=$(pause_state_class test:fm-until until)
    [ "$result" != paused ] || exit 1
    [ ! -e "$STATE/.paused-overdue-until" ]
  ' _ "$WATCH" "$statusf" || fail "a reused task id inherited its prior overdue pause marker"
  pass "a reused task id with fresh working status does not inherit overdue pause state"
}

test_malformed_dated_pause_is_not_undated_overdue() {
  local dir state result class statusf
  dir=$(paused_until_fixture malformed-until "" 90000); state="$dir/state"; statusf="$state/until.status"
  arm_pause_ceiling "$dir"
  printf 'paused: waiting until not-a-time\n' > "$statusf"
  set_mtime "$(( $(date +%s) - 90000 ))" "$statusf"
  result=$(FM_STATE_OVERRIDE="$state" FM_HOME="$dir" FM_PAUSE_UNDATED_MAX_SECS=60 bash -c '. "$1"; status_pause_is_overdue "paused: waiting until not-a-time" 90000 "$(date +%s)"; printf "%s" "$?"' _ "$WATCH")
  [ "$result" = 1 ] || fail "malformed dated pause entered the undated overdue path"
  class=$(FM_STATE_OVERRIDE="$state" FM_HOME="$dir" FM_PAUSE_UNDATED_MAX_SECS=60 FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE='state: working · source: run-step' bash -c '. "$1"; pause_state_class test:fm-until until' _ "$WATCH")
  [ "$class" = working ] || fail "watcher classification treated a malformed dated pause as overdue: $class"
  pass "malformed dated pauses remain on bounded recheck"
}

test_undated_pause_age_uses_the_pause_line() {
  local now=1800000000 age
  age=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_pause_age "$2" 7200 "$3"' _ "$ROOT" "paused [at=$((now - 90000))]: waiting" "$now")
  [ "$age" = 90000 ] || fail "a later file touch moved the pause age ($age)"
  age=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_pause_age "$2" 7200 "$3"' _ "$ROOT" "paused: waiting" "$now")
  [ "$age" = 7200 ] || fail "an unstamped pause did not keep the file age ($age)"
  arm_pause_ceiling "$TMP_ROOT/undated-age-home"
  result=$(FM_CONFIG_OVERRIDE="$TMP_ROOT/undated-age-home/config" FM_PAUSE_UNDATED_MAX_SECS=0 bash -c '. "$1/bin/fm-classify-lib.sh"; status_pause_is_overdue "paused: waiting" 9 1800000000; printf "%s" "$?"' _ "$ROOT")
  [ "$result" = 1 ] || fail "zero bound made a fresh pause overdue"
  pass "the undated bound uses the pause timestamp and rejects zero"
}

test_undated_pause_overdue_bound() {
  local dir state statusf class
  dir=$(paused_until_fixture undated-overdue "" 30); state="$dir/state"; statusf="$state/until.status"
  arm_pause_ceiling "$dir"
  printf 'paused: waiting for an external dependency\n' > "$statusf"
  set_mtime "$(( $(date +%s) - 30 ))" "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-until_status"
  export FM_PAUSE_UNDATED_MAX_SECS=60 FM_PAUSE_RESURFACE_SECS=240
  until_watch "$dir" 240
  wait_poll_cycle "$state" "$UNTIL_PID" || { reap "$UNTIL_PID"; fail "fresh undated pause exited before its ceiling"; }
  wait_poll_cycle "$state" "$UNTIL_PID" || { reap "$UNTIL_PID"; fail "undated pause exited before its ceiling"; }
  [ -z "$(status_open_decisions "$statusf")" ] || fail "undated pause opened a decision before its bound"

  set_mtime "$(( $(date +%s) - 61 ))" "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-until_status"
  class=$(FM_STATE_OVERRIDE="$state" FM_HOME="$dir" FM_PAUSE_UNDATED_MAX_SECS=60 FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE='state: working · source: active run' bash -c '. "$1"; pause_state_class test:fm-until until' _ "$WATCH")
  [ "$class" = paused ] || fail "overdue undated pause classified as working: $class"
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "overdue undated pause did not surface"; }
  grep -Fq 'paused-overdue-until' < <(status_open_decisions "$statusf") || fail "overdue undated pause did not open a decision"
  class=$(FM_STATE_OVERRIDE="$state" FM_HOME="$dir" bash -c '. "$1"; status_open_decisions() { printf called > "$3"; return 1; }; pause_state_class test:fm-until until' _ "$WATCH" "$state" "$dir/open-fold-called")
  [ "$class" = paused ] || fail "unchanged overdue pause did not stay classified as paused: $class"
  [ ! -e "$dir/open-fold-called" ] || fail "unchanged overdue poll folded the full status log"
  ack_stopped_cycle "$state" || fail "could not acknowledge the overdue undated wake"

  printf 'resolved [key=unrelated]: another decision closed\n' >> "$statusf"
  class=$(FM_STATE_OVERRIDE="$state" FM_HOME="$dir" bash -c '. "$1"; pause_overdue_reconcile until "$2"; printf "%s" "$?"' _ "$WATCH" "$statusf")
  [ "$class" = 0 ] || fail "an unrelated resolved key cleared the overdue pause decision"
  grep -Fq 'paused-overdue-until' < <(status_open_decisions "$statusf") || fail "the overdue decision closed on an unrelated resolution"

  printf 'working: resumed\n' >> "$statusf"
  until_watch "$dir" 240
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "undated resume did not close decision"; }
  [ -z "$(status_open_decisions "$statusf")" ] || fail "undated resume left decision open"
  unset FM_PAUSE_UNDATED_MAX_SECS FM_PAUSE_RESURFACE_SECS
  pass "undated pauses stay quiet through the bound and close their overdue decision on resume"
}

# Opt-in config/paused-recheck-silent: an unchanged paused declaration that was
# already surfaced once is rechecked without a wake; first sight, a changed
# declaration, a due declared time, and an open decision still wake.
silent_recheck_fixture() {  # <name> <until-epoch> <status-age-secs> -> dir
  local dir state window key
  dir=$(make_case "$1"); state="$dir/state"; window="test:fm-until"
  printf 'idle, waiting for the reset\n' > "$dir/pane.txt"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/until.meta"
  printf 'paused: rate limit resets, until %s, then resuming\n' "$(iso_utc_at "$2")" > "$state/until.status"
  set_mtime "$(( $(date +%s) - $3 ))" "$state/until.status"
  printf '%s' "$(seen_sig "$state/until.status")" > "$state/.seen-until_status"
  key=$(watch_window_key "$window")
  printf '%s' "$(hash_text 'idle, waiting for the reset')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  mkdir -p "$dir/config"
  printf '%s\n' "$dir"
}

silent_recheck_case() {  # <name> <flag:on|off> <status-body> -> dir; leaves the first-sight wake acked
  local name=$1 flag=$2 body=$3 dir state key
  dir=$(silent_recheck_fixture "$name" "$(( $(date +%s) + 86400 ))" 500); state="$dir/state"
  printf '%s\n' "$body" > "$state/until.status"
  set_mtime "$(( $(date +%s) - 500 ))" "$state/until.status"
  printf '%s' "$(seen_sig "$state/until.status")" > "$state/.seen-until_status"
  mkdir -p "$dir/config"
  [ "$flag" = on ] && : > "$dir/config/paused-recheck-silent"
  until_watch "$dir" 240
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "first sight of a declared pause did not wake ($name): $(cat "$dir/watch.out")"; }
  ack_stopped_cycle "$state" || fail "could not acknowledge the first-sight wake ($name)"
  key=$(watch_window_key test:fm-until)
  set_mtime "$(( $(date +%s) - 600 ))" "$state/.paused-resurfaced-$key"
  : > "$dir/watch.out"
  printf '%s\n' "$dir"
}

test_silent_recheck_flag_on_absorbs_unchanged_pause() {
  local dir state key before
  dir=$(silent_recheck_case silent-on on 'paused: rate limit resets, until 2999-01-01T00:00Z, then resuming'); state="$dir/state"
  key=$(watch_window_key test:fm-until)
  before=$(cat "$state/.paused-resurfaced-$key")
  until_watch "$dir" 240
  if ! wait_poll_cycle "$state" "$UNTIL_PID" || ! wait_poll_cycle "$state" "$UNTIL_PID"; then
    reap "$UNTIL_PID"; fail "an unchanged paused recheck woke the supervisor with the flag on: $(cat "$dir/watch.out")"
  fi
  reap "$UNTIL_PID"
  [ "$(cat "$state/.paused-resurfaced-$key")" = "$before" ] || fail "the recheck changed the declaration scope"
  [ "$state/.paused-resurfaced-$key" -nt "$state/until.status" ] || fail "the recheck was not recorded in the throttle marker"
  grep -F 'rechecked without a wake' "$state/.watch-triage.log" >/dev/null || fail "the silent recheck was not logged"
  pass "with paused-recheck-silent on, an unchanged paused declaration is rechecked without a wake"
}

test_silent_recheck_flag_off_still_wakes() {
  local dir state
  dir=$(silent_recheck_case silent-off off 'paused: rate limit resets, until 2999-01-01T00:00Z, then resuming'); state="$dir/state"
  until_watch "$dir" 240
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "an unchanged paused recheck did not wake with the flag off"; }
  grep -F 'stale: test:fm-until' "$dir/watch.out" >/dev/null || fail "the recheck wake was not printed with the flag off: $(cat "$dir/watch.out")"
  pass "with paused-recheck-silent absent, the unchanged paused recheck still wakes"
}

test_silent_recheck_flag_on_wakes_for_an_open_decision() {
  local dir state body
  body=$(printf 'needs-decision [at=%s] [key=open-q]: which option\npaused: rate limit resets, until 2999-01-01T00:00Z, then resuming' "$(date +%s)")
  dir=$(silent_recheck_case silent-open-decision on "$body"); state="$dir/state"
  until_watch "$dir" 240
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "an open decision did not wake an unchanged pause with the flag on"; }
  pass "with paused-recheck-silent on, an open decision still wakes"
}

test_silent_recheck_flag_on_wakes_for_a_changed_declaration() {
  local dir state
  dir=$(silent_recheck_case silent-changed on 'paused: rate limit resets, until 2999-01-01T00:00Z, then resuming'); state="$dir/state"
  printf 'paused: a different wait, until 2999-01-01T00:00Z\n' > "$state/until.status"
  set_mtime "$(( $(date +%s) - 500 ))" "$state/until.status"
  printf '%s' "$(seen_sig "$state/until.status")" > "$state/.seen-until_status"
  until_watch "$dir" 240
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "a changed declaration did not wake with the flag on"; }
  pass "with paused-recheck-silent on, a changed declaration still wakes"
}

test_silent_recheck_flag_on_absorbs_unchanged_pause_for_a_live_ship_agent() {
  local dir state
  dir=$(silent_recheck_case silent-live-ship on 'paused: rate limit resets, until 2999-01-01T00:00Z, then resuming'); state="$dir/state"
  printf 'window=test:fm-until\nkind=ship\nharness=grok\nbackend=tmux\n' > "$state/until.meta"
  FM_FAKE_TMUX_CURRENT_COMMAND=grok until_watch "$dir" 240
  if ! wait_poll_cycle "$state" "$UNTIL_PID" || ! wait_poll_cycle "$state" "$UNTIL_PID"; then
    reap "$UNTIL_PID"; fail "an unchanged paused recheck woke the supervisor for a live ship agent with the flag on: $(cat "$dir/watch.out")"
  fi
  reap "$UNTIL_PID"
  pass "with paused-recheck-silent on, an unchanged paused recheck for a live ship agent is silent"
}

test_silent_recheck_flag_on_absorbs_a_ticking_pane_for_a_live_ship_agent() {
  local dir state
  dir=$(silent_recheck_case silent-ticking on 'paused: waiting on the vendor reply'); state="$dir/state"
  printf 'window=test:fm-until\nkind=ship\nharness=grok\nbackend=tmux\n' > "$state/until.meta"
  printf 'idle, waiting for the reset 12:01\n' > "$dir/pane.txt"
  printf '%s' "$(hash_text 'idle, waiting for the reset 12:01')" > "$state/.hash-$(watch_window_key test:fm-until)"
  FM_FAKE_TMUX_CURRENT_COMMAND=grok until_watch "$dir" 240
  if ! wait_poll_cycle "$state" "$UNTIL_PID" || ! wait_poll_cycle "$state" "$UNTIL_PID"; then
    reap "$UNTIL_PID"; fail "a changed pane on an unchanged paused declaration woke the supervisor with the flag on: $(cat "$dir/watch.out")"
  fi
  reap "$UNTIL_PID"
  pass "with paused-recheck-silent on, a ticking pane on an unchanged paused declaration is silent"
}

test_silent_recheck_flag_on_wakes_when_the_agent_exited() {
  local dir state
  dir=$(silent_recheck_case silent-dead on 'paused: rate limit resets, until 2999-01-01T00:00Z, then resuming'); state="$dir/state"
  printf 'window=test:fm-until\nkind=ship\nharness=grok\nbackend=tmux\n' > "$state/until.meta"
  FM_FAKE_TMUX_CURRENT_COMMAND=zsh until_watch "$dir" 240
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "a paused recheck for an exited agent did not wake with the flag on"; }
  grep -F 'stale: test:fm-until' "$dir/watch.out" >/dev/null || fail "the exited-agent recheck wake was not printed: $(cat "$dir/watch.out")"
  pass "with paused-recheck-silent on, a paused recheck for an exited agent still wakes"
}

test_silent_recheck_flag_on_wakes_when_declared_time_is_due() {
  local dir state
  dir=$(silent_recheck_fixture silent-due "$(( $(date +%s) - 30 ))" 500); state="$dir/state"
  mkdir -p "$dir/config"; : > "$dir/config/paused-recheck-silent"
  until_watch "$dir" 240
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "a due declared time did not wake with the flag on"; }
  grep -F 'declared clearing time has passed' "$dir/watch.out" >/dev/null || fail "the due wake was not the declared-time recheck"
  pass "with paused-recheck-silent on, a due declared time still wakes"
}

# --- a live worker paused on its own background job --------------------------
# A worker declared `paused:` on its own background job and the job then ended
# without a new status line, so only the passage of time can tell the watcher
# the wait should be over. Without `until`, the first-sight alert spends the
# declaration's re-surface throttle and every later sight - including the one
# after the job ended - is held for PAUSE_RESURFACE_SECS. Naming the job's
# start plus its timeout as `until` gives that same declaration one recheck once
# the job can no longer be running.
bg_job_paused_case() {  # <name> <status-line> -> dir
  local dir state window key
  dir=$(make_case "$1"); state="$dir/state"; window="test:fm-parked"
  printf 'window=%s\nkind=scout\nharness=grok\nbackend=tmux\n' "$window" > "$state/parked.meta"
  printf '%s\n' "$2" > "$state/parked.status"
  printf '%s' "$(seen_sig "$state/parked.status")" > "$state/.seen-parked_status"
  key=$(watch_window_key "$window")
  printf 'nightly build running' > "$dir/pane.txt"
  printf '%s' "$(hash_text 'nightly build running')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' "$dir"
}

bg_job_stale_wakes() {  # <state> -> count of stale wakes queued for the parked window
  awk -F '\t' '$3 == "stale" && $4 == "test:fm-parked" { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

test_required_captain_hold_tests_fail_without_tasks_axi() {
  local name out
  out="$TMP_ROOT/missing-tasks-axi.out"
  for name in \
    test_open_captain_call_bounds_stale_churn \
    test_stale_churn_without_a_captain_call_still_alarms \
    test_failed_wake_append_does_not_arm_the_captain_hold_throttle \
    test_reheld_captain_call_starts_its_own_resurface_window
  do
    # Hide only this dependency's discovery in the child, regardless of where
    # the host installed it, while keeping the suite's setup tools available.
    if (
      # shellcheck disable=SC2329 # Exported for dependency discovery in the child Bash.
      command() {
        if [ "$#" -eq 2 ] && [ "$1" = -v ] && [ "$2" = tasks-axi ]; then
          return 1
        fi
        builtin command "$@"
      }
      export -f command
      FM_TEST_ONLY="$name" bash "$ROOT/tests/fm-watch-triage-pause.test.sh"
    ) > "$out" 2>&1; then
      fail "$name passed without required tasks-axi: $(cat "$out")"
    fi
    grep -F 'not ok - tasks-axi is required' "$out" >/dev/null \
      || fail "$name failed without the dependency diagnostic: $(cat "$out")"
    grep -F 'skip:' "$out" >/dev/null \
      && fail "$name skipped a required test: $(cat "$out")"
  done
  pass "all four required captain-hold tests fail when tasks-axi is unavailable"
}

# The superseded-wait check is opt-in through config/paused-wait-supersession;
# cases arm it unless asked for the flag-absent default.
make_superseded_pause_case() {  # <name> <status-line> [armed|unarmed]
  local name=$1 status_line=$2 arm=${3:-armed} dir state window key sig
  dir=$(make_case "$name"); state="$dir/state"; window="test:fm-superseded"
  mkdir -p "$dir/config"
  [ "$arm" = unarmed ] || : > "$dir/config/paused-wait-supersession"
  printf 'idle at declared wait\n' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/paused.meta"
  printf '%s\n' "$status_line" > "$state/paused.status"
  sig=$(seen_sig "$state/paused.status"); printf '%s' "$sig" > "$state/.seen-paused_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'idle at declared wait')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' "$dir"
}

superseded_pause_round() {  # <dir> <crew-state-line> <exit|absorb> [busy]
  local dir=$1 crew_state=$2 mode=$3 busy=${4:-no} state="$1/state" out="$1/watch.out" pid
  local command=zsh busy_max=999999
  case "$busy" in
    yes|recent) command=grok; [ "$busy" = yes ] && busy_max=1; printf 'working\nCtrl+c:cancel\n' > "$dir/pane.txt" ;;
  esac
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-superseded \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_FAKE_TMUX_CURRENT_COMMAND="$command" \
    FM_FAKE_CREW_STATE="$crew_state" FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE_LOG="$dir/crew-state.log" \
    FM_BUSY_TURN_MAX_SECS="$busy_max" FM_PAUSE_RESURFACE_SECS=240 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" >> "$out" 2>&1 &
  pid=$!
  if [ "$mode" = exit ]; then
    wait_for_exit "$pid" 100 || { reap "$pid"; return 1; }
  else
    wait_poll_cycle "$state" "$pid" 100 || { reap "$pid"; return 1; }
    reap "$pid"
  fi
}

test_declared_wait_surfaces_superseding_state() {
  local dir state window
  dir=$(make_superseded_pause_case gate-unreported 'paused: waiting for validation run R')
  state="$dir/state"; window=test:fm-superseded
  superseded_pause_round "$dir" \
    'state: parked · source: run-step · ask-user: authority decision · run: R' exit \
    || fail "idle paused run parked at an unreported human gate did not surface"
  grep -F "stale: $window (paused wait superseded: run R is parked at a human-owed gate with no open decision)" \
    "$dir/watch.out" >/dev/null || fail "gate wake did not identify the run and missing decision"
  ack_stopped_cycle "$state" || fail "could not acknowledge the idle gate wake"
  superseded_pause_round "$dir" \
    'state: parked · source: run-step · ask-user: authority decision · run: R' absorb \
    || fail "the same declaration and run re-alarmed inside the cadence"
  [ ! -s "$state/.wake-queue" ] || fail "the same declaration and run produced a duplicate wake"

  dir=$(make_superseded_pause_case gate-reported 'paused: waiting for validation run R')
  state="$dir/state"
  printf 'needs-decision [key=nm-R-review]: decide the ask-user finding\npaused: waiting for validation run R\n' > "$state/paused.status"
  sig=$(seen_sig "$state/paused.status"); printf '%s' "$sig" > "$state/.seen-paused_status"
  superseded_pause_round "$dir" \
    'state: parked · source: run-step · ask-user: authority decision · run: R' absorb \
    || fail "an already-open decision did not preserve the declared-wait cadence"
  [ ! -s "$state/.wake-queue" ] || fail "gate with an open needs-decision generated a stale wake"

  dir=$(make_superseded_pause_case gate-working 'paused: waiting for validation run R')
  state="$dir/state"
  superseded_pause_round "$dir" 'state: working · source: run-step · validating (running) · run: R' absorb \
    || fail "a working validation run did not preserve the declared-wait cadence"
  [ ! -s "$state/.wake-queue" ] || fail "working run generated a stale wake"

  dir=$(make_superseded_pause_case gate-terminal 'paused: waiting for validation run R')
  state="$dir/state"
  superseded_pause_round "$dir" 'state: done · source: run-step · run: R' exit \
    || fail "terminal validation run did not supersede the declared wait"
  grep -F 'paused wait superseded: current run R is terminal (done)' "$dir/watch.out" >/dev/null \
    || fail "terminal wake did not identify the superseded wait"

  dir=$(make_superseded_pause_case gate-terminal-pr 'paused: waiting for validation run R')
  state="$dir/state"
  superseded_pause_round "$dir" 'state: done · source: run-step · run: R1 · pr=https://example.test/1' exit \
    || fail "terminal run with PR did not supersede the declared wait"
  grep -F 'current run R1 is terminal (done)' "$dir/watch.out" >/dev/null \
    || fail "PR suffix obscured the first terminal run id"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first terminal wake"
  superseded_pause_round "$dir" 'state: done · source: run-step · run: R2 · pr=https://example.test/2' exit \
    || fail "second terminal run with PR did not supersede the declared wait"
  grep -F 'current run R2 is terminal (done)' "$dir/watch.out" >/dev/null \
    || fail "different terminal run shared the first run's throttle"

  dir=$(make_superseded_pause_case gate-busy-recent 'paused: waiting for validation run R')
  superseded_pause_round "$dir" \
    'state: parked · source: run-step · ask-user: authority decision · run: R' exit recent \
    || fail "recent busy paused run parked at an unreported human gate did not surface"
  grep -F 'run R is parked at a human-owed gate' "$dir/watch.out" >/dev/null \
    || fail "recent busy gate wake did not identify the run"

  dir=$(make_superseded_pause_case gate-busy-old 'paused: waiting for validation run R')
  state="$dir/state"
  set_mtime "$(( $(date +%s) - 500 ))" "$state/paused.meta"
  superseded_pause_round "$dir" \
    'state: parked · source: run-step · ask-user: authority decision · run: R' exit yes \
    || fail "old busy paused run parked at an unreported human gate did not surface"
  grep -F 'run R is parked at a human-owed gate' "$dir/watch.out" >/dev/null \
    || fail "old busy gate wake did not identify the run"
  ack_stopped_cycle "$state" || fail "could not acknowledge the busy gate wake"
  superseded_pause_round "$dir" \
    'state: parked · source: run-step · ask-user: authority decision · run: R' absorb yes \
    || fail "the repeated busy poll failed"
  [ ! -s "$state/.wake-queue" ] || fail "the busy gate repeated inside the cadence"

  pass "declared waits surface unreported gates and terminal runs once, while working runs and answered gates keep the pause cadence on idle and busy paths"
}

# Absent config/paused-wait-supersession the same superseding states keep main's
# declared-wait handling: no superseded wake, nothing queued, and no crew-state
# read beyond the one the idle declared-wait recheck already spends (none on the
# busy paths), counted through the stub's read log.
test_superseded_wait_check_is_opt_in() {
  local c n crew_state busy reads got dir state
  for c in "idle-gate|state: parked · source: run-step · ask-user: authority decision · run: R|no|1" \
           "idle-terminal|state: done · source: run-step · run: R|no|1" \
           "busy-recent|state: parked · source: run-step · ask-user: authority decision · run: R|recent|0" \
           "busy-old|state: parked · source: run-step · ask-user: authority decision · run: R|yes|0"; do
    IFS='|' read -r n crew_state busy reads <<< "$c"
    dir=$(make_superseded_pause_case "unarmed-$n" 'paused: waiting for validation run R' unarmed)
    state="$dir/state"
    [ "$busy" != yes ] || set_mtime "$(( $(date +%s) - 500 ))" "$state/paused.meta"
    superseded_pause_round "$dir" "$crew_state" absorb "$busy" \
      || fail "$n: flag-absent watcher round failed"
    ! grep -F 'paused wait superseded' "$dir/watch.out" >/dev/null \
      || fail "$n: flag-absent watcher surfaced a superseded wait"
    [ ! -s "$state/.wake-queue" ] || fail "$n: flag-absent watcher queued a wake"
    got=0
    [ ! -f "$dir/crew-state.log" ] || got=$(wc -l < "$dir/crew-state.log" | tr -d ' ')
    [ "$got" = "$reads" ] || fail "$n: flag-absent watcher read crew state $got times, want $reads"
  done
  pass "without config/paused-wait-supersession superseding states keep the declared-wait cadence and spend no extra crew-state read"
}

# The flag scopes the check to the foreground watcher: while the away-mode flag
# exists, a busy paused worker whose run is parked at an unreported human gate
# gets no superseded wake and no crew-state read, exactly as with the flag absent.
test_superseded_wait_check_skips_away_mode() {
  local c busy mode arm got dir out
  for c in recent:absorb yes:exit; do
    busy=${c%%:*} mode=${c#*:} out=''
    for arm in unarmed armed; do
      dir=$(make_superseded_pause_case "away-busy-$busy-$arm" 'paused: waiting for validation run R' "$arm")
      date '+%s' > "$dir/state/.afk"
      [ "$busy" != yes ] || set_mtime "$(( $(date +%s) - 500 ))" "$dir/state/paused.meta"
      superseded_pause_round "$dir" \
        'state: parked · source: run-step · ask-user: authority decision · run: R' "$mode" "$busy" \
        || fail "busy-$busy $arm: away-mode watcher round failed: $(cat "$dir/watch.out")"
      ! grep -F 'paused wait superseded' "$dir/watch.out" >/dev/null \
        || fail "busy-$busy $arm: away-mode watcher surfaced a superseded wait"
      got=0
      [ ! -f "$dir/crew-state.log" ] || got=$(wc -l < "$dir/crew-state.log" | tr -d ' ')
      [ "$got" = 0 ] || fail "busy-$busy $arm: away-mode watcher read crew state $got times, want 0"
      if [ "$arm" = unarmed ]; then
        out=$(cat "$dir/watch.out")
      else
        [ "$(cat "$dir/watch.out")" = "$out" ] \
          || fail "busy-$busy: armed away-mode output differs from flag-absent: $(cat "$dir/watch.out") vs $out"
      fi
    done
  done
  pass "with the away-mode flag present an armed busy paused worker at a human gate behaves exactly as with the flag absent: no superseded wake and no crew-state read"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

fm_test_run \
  test_required_captain_hold_tests_fail_without_tasks_axi \
  test_declared_wait_surfaces_superseding_state \
  test_superseded_wait_check_is_opt_in \
  test_superseded_wait_check_skips_away_mode \
  test_exited_declared_pause_is_bounded_but_live_gate_surfaces \
  test_open_captain_call_bounds_stale_churn \
  test_stale_churn_without_a_captain_call_still_alarms \
  test_failed_wake_append_does_not_arm_the_captain_hold_throttle \
  test_reheld_captain_call_starts_its_own_resurface_window \
  test_pause_ceiling_dated_overdue_pause_opens_one_decision \
  test_pause_ceiling_absent_keeps_old_pauses_on_the_recheck \
  test_overdue_resume_race_uses_pause_snapshot \
  test_busy_overdue_pause_does_not_enter_wedge_ladder \
  test_overdue_marker_survives_reconcile_and_closes_on_working \
  test_overdue_terminal_status_ignores_pane_display_churn \
  test_reused_task_id_does_not_inherit_overdue_pause \
  test_malformed_dated_pause_is_not_undated_overdue \
  test_undated_pause_age_uses_the_pause_line \
  test_undated_pause_overdue_bound \
  test_silent_recheck_flag_on_absorbs_unchanged_pause \
  test_silent_recheck_flag_off_still_wakes \
  test_silent_recheck_flag_on_wakes_for_an_open_decision \
  test_silent_recheck_flag_on_wakes_for_a_changed_declaration \
  test_silent_recheck_flag_on_absorbs_unchanged_pause_for_a_live_ship_agent \
  test_silent_recheck_flag_on_absorbs_a_ticking_pane_for_a_live_ship_agent \
  test_silent_recheck_flag_on_wakes_when_the_agent_exited \
  test_silent_recheck_flag_on_wakes_when_declared_time_is_due \
