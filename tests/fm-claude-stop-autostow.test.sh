#!/usr/bin/env bash
# tests/fm-claude-stop-autostow.test.sh - behavior tests for the auto-stow wake
# in the Claude Stop-owned auto-arm (bin/fm-claude-stop-autoarm.sh, autostow_fire
# and autostow_exit).
#
# The hook runs hermetically as a child of a fake harness (a bash symlink named
# "claude") that holds the fixture home's session lock. Stop payloads and
# transcripts are synthetic, and any watcher is a per-test fixture or a sleeping
# stand-in, so no real watcher, model, or fleet state is touched.
# shellcheck disable=SC2016 # single quotes are deliberate: $$ and $FM_HOME expand in the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-stop-autostow)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
export FAKE_CLAUDE

AUTOSTOW_SCRIPTS=(
  fm-claude-stop-autoarm.sh fm-context-usage.sh fm-primary-scope-lib.sh
  fm-supervision-lib.sh fm-wake-lib.sh fm-path-lib.sh fm-session-lock-lib.sh
  fm-cursor-lib.sh fm-hook-host-lib.sh fm-lock.sh fm-afk-contract.sh
  fm-classify-lib.sh fm-timeout-lib.sh fm-supervision-engine-lib.sh
)

install_hook() {
  local dir=$1 f
  mkdir -p "$dir/bin"
  for f in "${AUTOSTOW_SCRIPTS[@]}"; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-context-usage.sh" \
    "$dir/bin/fm-lock.sh" "$dir/bin/fm-afk-contract.sh"
}

# A primary home: a plain checkout with AGENTS.md and bin/, the shape that
# fm_primary_scope_matches accepts. The opt-out keeps supervision-host off.
make_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/config/supervision-host-off"
  install_hook "$dir"
  printf '%s\n' "$dir"
}

# A transcript whose last assistant turn carries <context-tokens> of context.
write_transcript() {  # <file> <context-tokens>
  printf '{"type":"user","message":{"content":"hi"}}\n' > "$1"
  printf '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":%d,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}\n' "$2" >> "$1"
}

# run_stop <home> <session-id> [transcript]: run the Stop hook as the session
# that holds the home's lock. Leaves the exit status in RC and stderr in ERR.
run_stop() {
  local dir=$1 sid=$2 transcript=${3:-} payload rc=0 errfile
  if [ -n "$transcript" ]; then
    payload=$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$sid" "$transcript")
  else
    payload=$(printf '{"session_id":"%s","stop_hook_active":false}' "$sid")
  fi
  errfile=$(mktemp "$TMP_ROOT/stderr.XXXXXX")
  printf '%s\n' "$payload" \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' >/dev/null 2>"$errfile" || rc=$?
  RC=$rc
  ERR=$(cat "$errfile")
  rm -f "$errfile"
}

stow_markers() {  # <home>
  find "$1/state" -maxdepth 1 -name '.auto-stow-*' 2>/dev/null | wc -l | tr -d ' '
}

expect_wake() {  # <message>
  [ "$RC" -eq 2 ] || fail "$1: expected exit 2, got $RC (stderr: $ERR)"
  case "$ERR" in
    *"firstmate auto-stow"*"Run the stow skill now (/stow)"*"Never run /clear yourself"*) ;;
    *) fail "$1: expected the auto-stow banner, got: $ERR" ;;
  esac
}

expect_silent() {  # <message>
  [ "$RC" -eq 0 ] || fail "$1: expected exit 0, got $RC (stderr: $ERR)"
  [ -z "$ERR" ] || fail "$1: expected silence, got: $ERR"
}

# 1. Restart band in an idle primary home: one wake, exit 2, and a marker keyed
#    to the session.
home=$(make_home "$TMP_ROOT/main")
t="$TMP_ROOT/main-restart.jsonl"
write_transcript "$t" 300000
run_stop "$home" sess-one "$t"
expect_wake "restart band, first stop"
[ -e "$home/state/.auto-stow-sess-one" ] || fail "restart wake must leave the sess-one marker"

# 2. The same session's next stop stays silent: once per session.
run_stop "$home" sess-one "$t"
expect_silent "second stop in the same session"

# 3. A new session id (after the captain's /clear) gets its own single wake.
run_stop "$home" sess-two "$t"
expect_wake "restart band in a new session"
[ "$(stow_markers "$home")" -eq 2 ] || fail "expected one marker per session, got $(stow_markers "$home")"

# 4. Warn and ok bands never wake and leave no marker.
warn_home=$(make_home "$TMP_ROOT/warn")
write_transcript "$TMP_ROOT/warn.jsonl" 200000
run_stop "$warn_home" sess-warn "$TMP_ROOT/warn.jsonl"
expect_silent "warn band"
[ "$(stow_markers "$warn_home")" -eq 0 ] || fail "warn band must not create a marker"

ok_home=$(make_home "$TMP_ROOT/ok")
write_transcript "$TMP_ROOT/ok.jsonl" 100000
run_stop "$ok_home" sess-ok "$TMP_ROOT/ok.jsonl"
expect_silent "ok band"
[ "$(stow_markers "$ok_home")" -eq 0 ] || fail "ok band must not create a marker"

# 5. Helper failure is silent: a transcript with no usage record, a missing
#    transcript file, and a payload without transcript_path.
fail_home=$(make_home "$TMP_ROOT/helper-fail")
printf '{"type":"user","message":{"content":"hi"}}\n' > "$TMP_ROOT/no-usage.jsonl"
run_stop "$fail_home" sess-nousage "$TMP_ROOT/no-usage.jsonl"
expect_silent "transcript without a usage record"
run_stop "$fail_home" sess-missing "$TMP_ROOT/does-not-exist.jsonl"
expect_silent "missing transcript file"
run_stop "$fail_home" sess-nopath
expect_silent "payload without transcript_path"
[ "$(stow_markers "$fail_home")" -eq 0 ] || fail "helper failure must not create a marker"

# 6. Off switch: config/auto-stow-off silences a home that would otherwise wake.
off_home=$(make_home "$TMP_ROOT/off")
: > "$off_home/config/auto-stow-off"
run_stop "$off_home" sess-off "$t"
expect_silent "config/auto-stow-off"
[ "$(stow_markers "$off_home")" -eq 0 ] || fail "config/auto-stow-off must not create a marker"

# 7. A secondmate home is opt-in: silent without config/auto-stow, and it wakes
#    once that opt-in exists.
sm_home=$(make_home "$TMP_ROOT/secondmate")
printf 'sm-autostow-1\n' > "$sm_home/.fm-secondmate-home"
run_stop "$sm_home" sess-sm "$t"
expect_silent "secondmate home without config/auto-stow"
: > "$sm_home/config/auto-stow"
run_stop "$sm_home" sess-sm "$t"
expect_wake "secondmate home with config/auto-stow"

# 8. AFK never rewakes the primary; the away daemon owns triage.
afk_home=$(make_home "$TMP_ROOT/afk")
: > "$afk_home/state/.afk"
run_stop "$afk_home" sess-afk "$t"
expect_silent "AFK posture"
[ "$(stow_markers "$afk_home")" -eq 0 ] || fail "AFK must not create a marker"

# 9. Supervision needed with no live watcher: the wake must not run uncovered,
#    so the arm runs first and the stow waits for a covered turn.
arm_home=$(make_home "$TMP_ROOT/arm-first")
: > "$arm_home/state/task-1.meta"
cat > "$arm_home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
chmod +x "$arm_home/bin/fm-watch-arm.sh"
run_stop "$arm_home" sess-arm "$t"
[ -s "$arm_home/state/arm-ran" ] || fail "supervision without a live watcher must still arm"
case "$ERR" in
  *"auto-stow"*) fail "stow must not wake while supervision is uncovered, got: $ERR" ;;
esac
[ "$(stow_markers "$arm_home")" -eq 0 ] || fail "uncovered supervision must not create a marker"

# 10. Supervision needed with a live, identity-matched, fresh watcher: the stow
#     wake fires before arming, and the covering watcher is left alone.
live_home=$(make_home "$TMP_ROOT/live-watcher")
: > "$live_home/state/task-1.meta"
cat > "$live_home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
exit 0
SH
chmod +x "$live_home/bin/fm-watch-arm.sh"
sleep 600 &
watch_pid=$!
watch_path="$(cd "$live_home/bin" && pwd)/fm-watch.sh"
watch_identity=$(fm_test_pid_identity "$watch_pid")
[ -n "$watch_identity" ] || fail "could not read the fixture watcher's identity"
mkdir -p "$live_home/state/.watch.lock"
printf '%s\n' "$watch_pid" > "$live_home/state/.watch.lock/pid"
printf '%s\n' "$live_home" > "$live_home/state/.watch.lock/fm-home"
printf '%s\n' "$watch_path" > "$live_home/state/.watch.lock/watcher-path"
printf '%s\n' "$watch_identity" > "$live_home/state/.watch.lock/pid-identity"
touch "$live_home/state/.last-watcher-beat"
run_stop "$live_home" sess-live "$t"
expect_wake "restart band under a live watcher"
[ ! -e "$live_home/state/arm-ran" ] || fail "the covered stow wake must not re-arm the watcher"
kill "$watch_pid" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true

# 11. Two parallel stop firings in one session, both owning the lock: exactly
#     one wake wins the marker.
race_home=$(make_home "$TMP_ROOT/race")
race_payload="$TMP_ROOT/race.payload"
printf '{"session_id":"sess-race","transcript_path":"%s","stop_hook_active":false}\n' "$t" > "$race_payload"
race_dir="$TMP_ROOT/race-out"
mkdir -p "$race_dir"
FM_HOME="$race_home" PAYLOAD_FILE="$race_payload" RACE_DIR="$race_dir" "$FAKE_CLAUDE" -c '
  printf "%s\n" "$$" > "$FM_HOME/state/.lock"
  "$FM_HOME/bin/fm-claude-stop-autoarm.sh" < "$PAYLOAD_FILE" 2> "$RACE_DIR/a.err" & pa=$!
  "$FM_HOME/bin/fm-claude-stop-autoarm.sh" < "$PAYLOAD_FILE" 2> "$RACE_DIR/b.err" & pb=$!
  wait "$pa"; echo "$?" > "$RACE_DIR/a.rc"
  wait "$pb"; echo "$?" > "$RACE_DIR/b.rc"
' >/dev/null 2>&1
wakes=$(cat "$race_dir/a.rc" "$race_dir/b.rc" | grep -c '^2$' || true)
[ "$wakes" -eq 1 ] || fail "two parallel firings must yield exactly one stow wake, got $wakes"
[ "$(stow_markers "$race_home")" -eq 1 ] || fail "two parallel firings must leave exactly one marker"

# 12. A long-poll home (FM_POLL=300, so this hook's derived grace is 360s) whose
#     live watcher's beacon is 320s old reads healthy to the derived grace and
#     stale to the turn-end guard's flat 300s. The pre-arm coverage check must
#     read the guard's own grace, so the stow waits for the arm and the guard
#     sees the auto-arm's fresh rewake instead of blocking the same stop again.
poll_home=$(make_home "$TMP_ROOT/long-poll")
: > "$poll_home/state/task-1.meta"
cat > "$poll_home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: fixture wake\n'
exit 0
SH
chmod +x "$poll_home/bin/fm-watch-arm.sh"
sleep 600 &
poll_watch_pid=$!
poll_watch_path="$(cd "$poll_home/bin" && pwd)/fm-watch.sh"
poll_identity=$(fm_test_pid_identity "$poll_watch_pid")
[ -n "$poll_identity" ] || fail "could not read the long-poll fixture watcher's identity"
mkdir -p "$poll_home/state/.watch.lock"
printf '%s\n' "$poll_watch_pid" > "$poll_home/state/.watch.lock/pid"
printf '%s\n' "$poll_home" > "$poll_home/state/.watch.lock/fm-home"
printf '%s\n' "$poll_watch_path" > "$poll_home/state/.watch.lock/watcher-path"
printf '%s\n' "$poll_identity" > "$poll_home/state/.watch.lock/pid-identity"
fm_touch_epoch "$(( $(date +%s) - 320 ))" "$poll_home/state/.last-watcher-beat"
printf 'pending:downtime:fixture-generation\n' > "$poll_home/state/.watcher-down"
FM_POLL=300 run_stop "$poll_home" sess-poll "$t"
[ "$RC" -eq 2 ] || fail "the aged-beacon stop must take the arm path and rewake, got $RC (stderr: $ERR)"
[ -s "$poll_home/state/arm-ran" ] || fail "a beacon stale to the guard's grace must not satisfy the pre-arm coverage check"
case "$ERR" in
  *"firstmate watcher wake"*) ;;
  *) fail "the one continuation must be the auto-arm's own rewake, got: $ERR" ;;
esac
case "$ERR" in
  *"firstmate auto-stow"*) fail "the aged-beacon stop must not emit the auto-stow wake, got: $ERR" ;;
esac
[ "$(stow_markers "$poll_home")" -eq 0 ] || fail "the aged-beacon stop must not create an auto-stow marker"
guard_rc=0
cp "$ROOT/bin/fm-turnend-guard.sh" "$poll_home/bin/fm-turnend-guard.sh"
chmod +x "$poll_home/bin/fm-turnend-guard.sh"
guard_out=$(printf '{"stop_hook_active":false,"session_id":"sess-poll"}\n' \
  | CLAUDECODE=1 FM_HOME="$poll_home" "$poll_home/bin/fm-turnend-guard.sh" --claude 2>&1) || guard_rc=$?
[ "$guard_rc" -eq 0 ] || fail "the guard must allow the stop the auto-arm's one rewake covers, got $guard_rc: $guard_out"
case "$guard_out" in
  *"TURN WOULD END BLIND"*) fail "the guard must not block a stop whose rewake the auto-arm already committed: $guard_out" ;;
esac
[ ! -e "$poll_home/state/.turnend-claude-blocks" ] || fail "the guard must not charge the block budget for a stop the auto-arm covers"
kill "$poll_watch_pid" 2>/dev/null || true
wait "$poll_watch_pid" 2>/dev/null || true

pass "fm-claude-stop-autostow.test.sh"
