#!/usr/bin/env bash
# Behavior tests for the supervision host latch, park boundary, compaction, and lock ownership
# (bin/fm-supervision-host.sh, docs/supervision-host.md). Shared fixtures live
# in tests/supervision-host-helpers.sh.
#
# The loop cases run the real host, arm, watcher, wake grant, drain, outcome
# store, and lease scripts in a fixture home. The host runs as a child of a fake
# harness (a bash symlink named "claude") whose pid is the home's session lock,
# and its engine is a stub named by FM_SUPERVISION_ENGINE_CLAUDE_BIN that does
# what a branch turn does through the same scripts, so the real argument
# construction, bounding, and reaping are exercised without a model. A real
# status append drives each wake through the real watcher.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"



# The latch lives only in the opted-in host's away path: an attended close in a
# latched session and a home that dropped config/supervision-host both reach
# main exactly as they do without it.

test_idle_engine_conversation_is_compacted_once_across_hosts() {
  local home run ended
  home=$(make_home warm-compact attended claude)
  echo noreport > "$home/stub-mode"
  printf 'idle-seconds=60\nmin-context-tokens=1000\n' > "$home/config/warm-compact"
  mkdir -p "$home/claude/projects/p"
  printf '{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":90000,"cache_creation_input_tokens":0}}}\n' \
    > "$home/claude/projects/p/warm-sess.jsonl"
  for run in 1 2; do
    rm -f "$home/host.rc" "$home/park-clock"
    CLAUDE_CONFIG_DIR="$home/claude" FM_WARM_COMPACT_TICK=1 FM_SUPERVISION_HOST_PARK_SECONDS=3000 \
      FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_host "$home"
    wait_until 150 watcher_live "$home" || fail "warm-compact: run $run never started a watcher"
    seed_idle_engine_record "$home" 600
    ended=$(sed -n 's/^ended=//p' "$home/state/.supervision-host-engine")
    echo 10 > "$home/park-clock"
    if [ "$run" = 1 ]; then
      wait_until 150 compacted_once "$home" || fail "warm-compact: the idle engine conversation was not compacted"
      wait_until 100 grep -qx "compacted=$ended" "$home/state/.supervision-host-engine" || fail "warm-compact: the episode marker was not recorded with the engine record"
    else
      echo 20 > "$home/park-clock"
      sleep 3
    fi
    [ "$(compact_calls "$home")" = 1 ] || fail "warm-compact: run $run compacted the same idle episode again"
    stop_home_processes "$home"
    wait_until 100 host_exited "$home" || true
  done
  pass "host: an idle engine conversation is compacted once across hosts"
}

test_engine_conversation_the_next_turn_would_not_resume_is_not_compacted() {
  local home
  home=$(make_home warm-compact-stale attended claude)
  echo noreport > "$home/stub-mode"
  printf 'idle-seconds=60\nmin-context-tokens=1000\n' > "$home/config/warm-compact"
  mkdir -p "$home/claude/projects/p"
  printf '{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":90000,"cache_creation_input_tokens":0}}}\n' \
    > "$home/claude/projects/p/warm-sess.jsonl"
  CLAUDE_CONFIG_DIR="$home/claude" FM_WARM_COMPACT_TICK=1 FM_SUPERVISION_HOST_PARK_SECONDS=3000 \
    FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_host "$home"
  wait_until 150 watcher_live "$home" || fail "warm-compact-stale: no watcher started"
  seed_idle_engine_record "$home" 600
  sed -i 's/^model=.*/model=another-model/' "$home/state/.supervision-host-engine"
  echo 10 > "$home/park-clock"
  sleep 3
  [ "$(compact_calls "$home")" = 0 ] || fail "warm-compact-stale: compacted a conversation the next turn would not resume"
  stop_home_processes "$home"
  pass "host: a conversation the next turn would not resume is not compacted"
}

test_compaction_abandoned_at_the_park_boundary_is_not_marked_done() {
  local home
  home=$(make_home warm-compact-abandon attended claude)
  echo hang > "$home/stub-mode"
  printf 'idle-seconds=60\nmin-context-tokens=1000\n' > "$home/config/warm-compact"
  mkdir -p "$home/claude/projects/p"
  printf '{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":90000,"cache_creation_input_tokens":0}}}\n' \
    > "$home/claude/projects/p/warm-sess.jsonl"
  CLAUDE_CONFIG_DIR="$home/claude" FM_WARM_COMPACT_TICK=1 FM_SUPERVISION_HOST_PARK_SECONDS=3000 FM_SUPERVISION_ENGINE_GRACE=1 \
    FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_host "$home"
  wait_until 150 watcher_live "$home" || fail "warm-compact-abandon: no watcher started"
  seed_idle_engine_record "$home" 600
  echo 10 > "$home/park-clock"
  wait_until 150 test -e "$home/engine-call.1" || fail "warm-compact-abandon: the compaction never started"
  echo 3000 > "$home/park-clock"
  wait_until_deadline 60 host_exited "$home" || fail "warm-compact-abandon: the host did not end its park"
  ! grep -q '^compacted=' "$home/state/.supervision-host-engine" || fail "warm-compact-abandon: an abandoned compaction was marked done"
  stop_home_processes "$home"
  pass "host: a compaction abandoned at the park boundary is not marked done"
}


# A close that lands while a turn is running can only wait: the host ends its
# park at the bound regardless of how many closes are queued behind it. The
# park runs on the test clock (FM_TEST_SUPERVISION_HOST_CLOCK), which the test
# moves to the refusal window's opening (park bound minus the turn bound and
# grace) before it releases the held turn, so the second close can never take
# a turn of its own on any machine speed. The bound also stays well past every
# wall-clock check in the case: a host that ignored the test clock would start
# the second turn instead of silently passing at a wall-clock boundary.


# Rendering the wake prompt runs after the successor cycle has started; the
# shim holds the render on a FIFO, and the test moves the park's test clock to
# the refusal window's opening before releasing it, so the close passes the
# arrival check and the pre-turn recheck must refuse on any machine speed. The
# snapshot proves the successor arm it started can be checked afterwards. The
# park bound stays past the case's wall-clock checks, so an ignored test clock
# would let the turn run and the engine-call assertions catch it.


# A leaked test clock in a real primary's environment must stay inert: the
# host reads it only alongside the FM_TEST_SEAM marker that test suites set.


# An owner whose own bound is the park lets a turn run past the boundary up to
# its limit; a limit below the boundary or at the registration is the boundary.


# The first cycle's status line reaches the owner before any close and only
# once; --restart replaces a watcher it would otherwise attach to, and the
# owner's predecessor arm makes the first cycle a handling successor. The home
# names no usable engine, so every attended close passes straight to main.

test_tagged_lock_holder_reaches_the_engine_whole() {
  local home first
  home=$(make_home tagged-holder away)
  echo hold-lease > "$home/stub-mode"
  # A Windows/Git Bash home: uname reports MINGW and ps -W lists the session
  # harness the lock names as win:7204; every other ps question is the real one.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" MINGW64_NT-10.0-26200\n' > "$home/fakebin/uname"
  cat > "$home/fakebin/ps" <<'SH'
#!/usr/bin/env bash
[ "$*" = -W ] || exec /bin/ps "$@"
printf '%s\n' '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND'
printf '%s\n' '  4201508       0       0       7204  ?              0 22:24:48 C:\Users\u\.local\bin\claude.exe'
SH
  chmod +x "$home/fakebin/uname" "$home/fakebin/ps"
  printf 'win:7204\n' > "$home/state/.lock"
  env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID \
    FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$PATH" \
    CLAUDE_PID=7204 CLAUDE_CODE_SESSION_ID=tagged-session \
    bash -c '"$0" park > "$FM_HOME/host.out" 2>&1; printf "%s\n" "$?" > "$FM_HOME/host.rc"' "$HOST" 2>> "$home/claude.err" &
  wait_until 150 watcher_live "$home" || fail "tagged: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "tagged: the wake was not handled: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  first="$home/engine-call.1"
  assert_re '^holder=win:7204$' "$first" "the engine's lease holder must be the tagged session-lock holder, whole"
  assert_re '^branch win:7204 [0-9]+ live$' "$home/engine-lease.log" \
    "the engine's lease must record the tagged holder whole and read live"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until_deadline 60 host_exited "$home" || fail "tagged: the host did not stop on TERM"
  pass "host: a Windows-tagged session-lock holder reaches the engine's lease whole"
}

fm_test_run \
  test_idle_engine_conversation_is_compacted_once_across_hosts \
  test_engine_conversation_the_next_turn_would_not_resume_is_not_compacted \
  test_compaction_abandoned_at_the_park_boundary_is_not_marked_done \
  test_tagged_lock_holder_reaches_the_engine_whole \
