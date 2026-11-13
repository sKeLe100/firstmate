#!/usr/bin/env bash
# Behavior tests for the supervision host, part 2 of 2. The shared harness,
# fixtures, and helpers are in tests/fm-supervision-host-lib.sh; the cases that
# run before these are in tests/fm-supervision-host.test.sh.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells

# shellcheck source=tests/fm-supervision-host-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-supervision-host-lib.sh"

test_next_park_takes_over_the_cycle_a_pass_through_left_for_main() {
  local home left_watcher left_arm
  home=$(make_primary_home hook-takeover)
  leave_a_cycle_for_main_and_restart "$home"
  left_watcher=$LEFT_WATCHER
  left_arm=$LEFT_ARM
  turn_end "$home"
  wait_until 150 host_owns_the_only_cycle "$home" \
    || fail "takeover: the next park did not own the home's only watcher cycle (left arm $left_arm, watcher $left_watcher):"$'\n'"$(home_arms "$home")"$'\n'"$(cat "$home/state/.supervision-host.log")"
  ! kill -0 "$left_arm" 2>/dev/null || fail "takeover: the successor arm a pass-through left still runs (pid $left_arm)"
  ! kill -0 "$left_watcher" 2>/dev/null || fail "takeover: the successor watcher still runs (pid $left_watcher)"
  sleep 2
  ! hook_exited "$home" || fail "takeover: the takeover woke main: $(cat "$home/hook.err")"
  host_owns_the_only_cycle "$home" || fail "takeover: the park did not keep the cycle it took over"
  assert_re '^acked:' "$home/state/.watcher-down" "takeover: the takeover opened a downtime episode"
  assert_no_re 'rearm-resurface' "$home/state/.supervision-host.log" "takeover: the takeover resurfaced a recovery to main"
  append_status "$home" 'which region?' needs-decision
  wait_until 250 hook_exited "$home" || fail "takeover: the owned cycle did not deliver the next close: $(cat "$home/state/.supervision-host.log")"
  assert_rewoke_main "$home" "takeover (next close)"
  assert_re '^signal: .*demo.status' "$home/hook.err" "takeover: the next close must carry the watcher's reason line"
  pass "host+hook: the next park takes over the cycle a main-only pass-through left, so one arm owns it"
}

# A park stopped before its take-over stops the left cycle (here held in the
# take-over's handover snapshot by the recovery-marker lock) must not forget
# that cycle's arm: the park the Stop hook runs next still takes it over rather
# than attaching to it beside the orphan.
test_a_park_stopped_mid_take_over_leaves_the_take_over_to_the_next_park() {
  local home holder host
  home=$(make_primary_home hook-takeover-interrupted)
  leave_a_cycle_for_main_and_restart "$home"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2" || exit 1
    : > "$3"
    while [ ! -e "$4" ]; do sleep 0.1; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state/.watcher-down.lock" "$home/marker-lock-held" "$home/marker-lock-release" &
  holder=$!
  wait_until 100 test -e "$home/marker-lock-held" || fail "fixture: could not hold the recovery-marker lock"
  turn_end "$home"
  wait_until 150 grep -q "	take-over	arm=$LEFT_ARM\$" "$home/state/.supervision-host.log" \
    || fail "interrupted takeover: the park did not start a take-over of $LEFT_ARM: $(cat "$home/state/.supervision-host.log")"
  host=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")
  sleep 1
  kill -0 "$LEFT_WATCHER" 2>/dev/null || fail "fixture: the take-over stopped the left watcher before the park was stopped"
  kill -TERM "$host" 2>/dev/null || fail "fixture: the park host $host was not running"
  wait_until 150 sh -c '! kill -0 "$1" 2>/dev/null' _ "$host" || fail "fixture: the park host did not stop"
  : > "$home/marker-lock-release"
  wait "$holder" 2>/dev/null || true
  # The Stop hook runs the next park in place of the one stopped by a signal.
  wait_until 150 host_owns_the_only_cycle "$home" \
    || fail "interrupted takeover: the next park did not own the home's only watcher cycle (left arm $LEFT_ARM):"$'\n'"$(home_arms "$home")"$'\n'"$(cat "$home/state/.supervision-host.log")"
  ! kill -0 "$LEFT_ARM" 2>/dev/null || fail "interrupted takeover: the left arm still runs (pid $LEFT_ARM)"
  pass "host+hook: a park stopped mid take-over leaves the take-over to the next park"
}

# A successor the host cannot record for the next park's take-over (here the
# record path is a directory the record would land inside) must not be left
# running: the host stops it on exit, the close still reaches main unchanged,
# and main's next turn end owns a fresh cycle with no orphan beside it.
test_unrecorded_successor_is_stopped_rather_than_left_for_main() {
  local home
  home=$(make_primary_home hook-successor-unrecorded)
  mkdir "$home/state/.supervision-host-left"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "unrecorded successor: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 hook_exited "$home" || fail "unrecorded successor: the decision close never reached the Stop hook: $(cat "$home/state/.supervision-host.log")"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "fixture: the close was not a main-only pass-through"
  assert_re '	pass-through	successor-unrecorded	signal:' "$home/state/.supervision-host.log" "unrecorded successor: the failed record was not logged"
  assert_rewoke_main "$home" "unrecorded successor (pass-through)"
  assert_re '^signal: .*demo.status' "$home/hook.err" "unrecorded successor: the close must carry the watcher's reason line"
  wait_until 100 no_home_arms "$home" || fail "unrecorded successor: an arm outlived the host:"$'\n'"$(home_arms "$home")"
  rmdir "$home/state/.supervision-host-left" \
    || fail "unrecorded successor: the record left inside the directory was not removed: $(ls -A "$home/state/.supervision-host-left")"
  main_drain "$home" >/dev/null
  # shellcheck disable=SC2086 # the printed acknowledgement arguments
  [ -z "$MAIN_ACK" ] || FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" "$@" >/dev/null 2>&1' "$ROOT/bin/fm-wake-drain.sh" $MAIN_ACK \
    || fail "unrecorded successor: main's acknowledgement failed: $MAIN_ACK"
  turn_end "$home"
  wait_until 150 host_owns_the_only_cycle "$home" \
    || fail "unrecorded successor: main's next turn end did not own the home's only watcher cycle:"$'\n'"$(home_arms "$home")"$'\n'"$(cat "$home/state/.supervision-host.log")"
  pass "host+hook: a successor that cannot be recorded is stopped, and main's next turn end arms a fresh cycle"
}

# Grok and OpenCode have no mirror writer, because they cannot record a
# session's first captain prompt, and neither Codex nor omp has a proven one,
# so none of them has a verified dialog mirror: every attended close reaches
# main as without the host, while the away posture, which needs no mirror,
# still runs on the engine.
test_primary_without_a_verified_mirror_runs_away_only() {
  local home harness
  for harness in grok opencode omp codex; do
    home=$(make_home "attended-$harness" attended claude)
    FM_SUPERVISION_HOST_PRIMARY=$harness start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$harness: the host never started a watcher cycle"
    append_status "$home" 'fixture finished' 'done'
    wait_until 200 host_exited "$home" || fail "$harness: the host did not hand the attended close to main"
    assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
    assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
    [ "$(engine_calls "$home")" -eq 0 ] || fail "$harness: the engine ran an attended wake without a verified dialog mirror"
    assert_re "	pass-through	attended	no verified dialog mirror for $harness	" "$home/state/.supervision-host.log" \
      "the ledger must record that no verified mirror kept the close on main"
  done
  home=$(make_home away-grok away claude)
  FM_SUPERVISION_HOST_PRIMARY=grok start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away grok: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "away grok: the wake was not handled on the engine: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  assert_re '^primary=grok$' "$home/engine-call.1" "the away engine must carry the grok primary pin"
  assert_re '^POSTURE: AWAY\.' "$home/engine-call.1" "the away wake must carry the away tail"
  [ ! -s "$home/host.rc" ] || fail "a handled away wake on grok reached main: $(cat "$home/host.out")"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "away grok: the host did not stop on TERM"
  pass "host: a primary with no verified dialog mirror keeps every attended close on main, and its away posture still runs"
}

test_attended_wake_carries_the_dialog_mirror() {
  local home first second
  home=$(make_home attended-mirror attended)
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  printf '{"hook_event_name":"Stop","prompt_id":"p1","last_assistant_message":"Understood, low effort it is."}' > "$home/mirror-seed.2"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p2","prompt":"\342\201\243FIRSTMATE_OP: v1 watcher: signal: demo.status"}' > "$home/mirror-seed.3"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "mirror: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "mirror: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  first="$home/engine-call.1"
  assert_re '^arg=MAIN DIALOG MIRROR \(read-only context' "$first" "the wake must open with the dialog mirror"
  assert_re '^\[captain\] keep the export worker on low effort$' "$first" "the mirror must carry the captain's words"
  assert_re '^\[main\] Understood, low effort it is\.$' "$first" "the mirror must carry main's reply"
  assert_no_re 'FIRSTMATE_OP' "$first" "operational input must never be mirrored as dialog"
  append_status "$home" 'step two'
  wait_until 250 handled_at_least "$home" 2 || fail "mirror: the second wake was not handled"
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "fixture: the second turn did not resume the conversation"
  assert_no_re 'MAIN DIALOG MIRROR' "$second" "a resumed conversation must not be fed dialog it already has"
  pass "host: each wake carries the captain's dialog since the last wake, without operational input"
}

# Every file carrying the captain's dialog is owner-only, even under an open
# umask and when a readable copy was already there. The feed is removed before
# the engine starts, so a node wrapper records its mode as the wake renders.
test_dialog_bearing_files_are_owner_only() {
  local home old
  home=$(make_home attended-private attended)
  {
    printf '#!/usr/bin/env bash\nREAL_NODE=%q\n' "$(command -v node)"
    cat <<'SH'
prev=
for a in "$@"; do
  [ "$prev" != --mirror-file ] || { stat -c %a "$a" 2>/dev/null || stat -f %Lp "$a"; } >> "$FM_HOME/feed-modes"
  prev=$a
done
exec "$REAL_NODE" "$@"
SH
  } > "$home/fakebin/node"
  chmod +x "$home/fakebin/node"
  old=$(umask)
  umask 022
  for f in .host-mirror.jsonl .supervision-host-mirror .supervision-host-wake; do
    : > "$home/state/$f"
    chmod 644 "$home/state/$f"
  done
  start_host "$home"
  umask "$old"
  wait_until 150 watcher_live "$home" || fail "private: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "private: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  assert_re '^\[captain\] watch the fleet for me$' "$home/engine-call.1" "fixture: the wake must carry the captain's words"
  [ "$(mode_of "$home/state/.host-mirror.jsonl")" = 600 ] || fail "the dialog mirror must be owner-only, got $(mode_of "$home/state/.host-mirror.jsonl")"
  [ "$(mode_of "$home/state/.supervision-host-wake")" = 600 ] || fail "the wake file must be owner-only, got $(mode_of "$home/state/.supervision-host-wake")"
  [ "$(cat "$home/feed-modes" 2>/dev/null)" = 600 ] || fail "the mirror feed must be owner-only, got $(cat "$home/feed-modes" 2>/dev/null)"
  pass "host: the dialog mirror, its feed, and the wake file are owner-only"
}

# Dialog counts as delivered only once the turn that carried it is accepted
# with its report. A host that reaches its park boundary after feeding the
# mirror but before the turn, or is stopped mid-turn, leaves the conversation
# resumable without it, so the next turn must still carry it; a turn with no
# report starts a new conversation, which must carry it too.
test_undelivered_dialog_is_fed_again_on_the_next_turn() {
  local home real_node second third fourth
  home=$(make_home mirror-boundary attended)
  real_node=$(command -v node)
  cat > "$home/fakebin/node" <<SH
#!/usr/bin/env bash
if [ "\${2:-}" = wake-prompt ] && [ -e "\$FM_HOME/slow-render" ]; then echo 120 > "\$FM_HOME/park-clock"; fi
exec "$real_node" "\$@"
SH
  chmod +x "$home/fakebin/node"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"first ask"}' > "$home/mirror-seed.1"
  echo 0 > "$home/park-clock"
  # The park bound sits past every wall-clock check below, so a host that
  # ignored the test clock could never reach a boundary inside this case.
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=120 FM_SUPERVISION_HOST_TURN_TIMEOUT=20 FM_SUPERVISION_ENGINE_GRACE=1 start_session "$home"
  park_again "$home"
  append_status "$home" 'first'
  wait_until 250 handled_at_least "$home" 1 || fail "mirror boundary: the first wake was not handled: $(cat "$home/state/.supervision-host.log")"
  assert_re '^\[captain\] first ask$' "$home/engine-call.1" "fixture: the first turn did not carry the first dialog"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "mirror boundary: the first host did not stop on TERM"

  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p2","prompt":"second ask, never handed over"}' > "$home/mirror-seed.2"
  : > "$home/slow-render"
  echo 0 > "$home/park-clock"
  park_after_stop "$home"
  append_status "$home" 'reaches the boundary'
  wait_until 400 host_exited "$home" || fail "mirror boundary: the host did not end its park"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "fixture: the second host did not exit at its boundary"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "fixture: an engine turn ran at the boundary"
  main_drain_and_ack "$home"

  rm -f "$home/slow-render"
  echo 0 > "$home/park-clock"
  park_again "$home"
  append_status "$home" 'handled after the boundary'
  wait_until 250 handled_at_least "$home" 2 || fail "mirror boundary: the next wake was not handled: $(cat "$home/state/.supervision-host.log")"
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "fixture: the next turn did not resume the conversation"
  assert_re '^\[captain\] second ask, never handed over$' "$second" \
    "dialog fed to a wake that never reached the engine must reach the next turn"
  assert_no_re '^\[captain\] first ask$' "$second" "a resumed conversation must not be fed dialog it already has"

  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p3","prompt":"third ask, turn stopped"}' > "$home/mirror-seed.3"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "mirror boundary: the second handling host did not stop on TERM"
  echo hang > "$home/stub-mode"
  park_after_stop "$home"
  append_status "$home" 'stopped mid-turn'
  wait_until 250 test -e "$home/engine-call.3" || fail "mirror boundary: the stopped turn never started"
  assert_re '^\[captain\] third ask, turn stopped$' "$home/engine-call.3" "fixture: the stopped turn did not carry the third dialog"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "mirror boundary: the host did not stop mid-turn on TERM"
  echo handle > "$home/stub-mode"
  park_after_stop "$home"
  append_status "$home" 'handled after the stop'
  wait_until 250 handled_at_least "$home" 3 || fail "mirror boundary: the wake after the stop was not handled: $(cat "$home/state/.supervision-host.log")"
  third="$home/engine-call.4"
  assert_re '^arg=--resume$' "$third" "fixture: the turn after the stop did not resume the conversation"
  assert_re '^\[captain\] third ask, turn stopped$' "$third" "dialog of a turn stopped before its report must reach the next turn"
  assert_no_re '^\[captain\] second ask' "$third" "a resumed conversation must not be fed dialog a handled turn delivered"

  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p4","prompt":"fourth ask, turn unreported"}' > "$home/mirror-seed.4"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "mirror boundary: the third handling host did not stop on TERM"
  echo noreport > "$home/stub-mode"
  park_after_stop "$home"
  append_status "$home" 'no report'
  wait_until 250 host_exited "$home" || fail "mirror boundary: the unreported turn did not hand its wake back"
  assert_re '^\[captain\] fourth ask, turn unreported$' "$home/engine-call.5" "fixture: the unreported turn did not carry the fourth dialog"
  main_drain_and_ack "$home"
  echo handle > "$home/stub-mode"
  park_again "$home"
  append_status "$home" 'handled after no report'
  wait_until 250 handled_at_least "$home" 4 || fail "mirror boundary: the wake after the unreported turn was not handled: $(cat "$home/state/.supervision-host.log")"
  fourth="$home/engine-call.6"
  assert_re '^\[captain\] fourth ask, turn unreported$' "$fourth" "dialog of a turn that recorded no report must reach the next turn"
  pass "host: dialog a turn never completed with its report (a park boundary, a stopped turn, no report) reaches the next turn"
}

# The attended engine never judges without the captain's words: a mirror that
# is missing, cannot be read, or holds an entry that does not parse hands the
# wake to main before any engine turn and leaves the mirror cursor where it was.
test_attended_wake_with_an_unreadable_mirror_reaches_main() {
  local home mirror cursor
  home=$(make_home attended-bad-mirror attended)
  mirror="$home/state/.host-mirror.jsonl"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  start_session "$home"
  park_again "$home"
  append_status "$home" 'first'
  wait_until 250 handled_at_least "$home" 1 || fail "bad mirror: the first wake was not handled: $(cat "$home/state/.supervision-host.log")"
  cursor=$(cat "$home/state/.host-mirror-cursor") || fail "fixture: the handled turn committed no mirror cursor"

  rm -f "$mirror"
  append_status "$home" 'missing mirror'
  wait_until 250 host_exited "$home" || fail "bad mirror: a missing mirror did not hand the wake to main"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the watcher's reason line"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "a missing mirror must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran without a mirror"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "a missing mirror moved the cursor"
  [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "a missing mirror staged a cursor"
  main_drain_and_ack "$home"

  park_again "$home"
  [ -f "$mirror" ] || fail "fixture: the next park did not write the mirror again"
  chmod 000 "$mirror"
  append_status "$home" 'unreadable mirror'
  wait_until 250 host_exited "$home" || fail "bad mirror: an unreadable mirror did not hand the wake to main"
  chmod 644 "$mirror"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the watcher's reason line"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "an unreadable mirror must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran without a readable mirror"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "an unreadable mirror moved the cursor"
  [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "an unreadable mirror staged a cursor"
  main_drain_and_ack "$home"

  printf '#!/usr/bin/env bash\nprev=\nfor a in "$@"; do [ "$prev" != --mirror-file ] || chmod 000 "$a"; prev=$a; done\nexec %q "$@"\n' \
    "$(command -v node)" > "$home/fakebin/node"
  chmod +x "$home/fakebin/node"
  park_again "$home"
  append_status "$home" 'mirror lost before the prompt'
  wait_until 250 host_exited "$home" || fail "bad mirror: a feed lost before the prompt did not hand the wake to main"
  rm -f "$home/fakebin/node"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "a feed lost before the prompt must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran without the feed it was promised"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "a feed lost before the prompt moved the cursor"
  main_drain_and_ack "$home"

  printf '{"seq":' >> "$mirror"
  printf '\n' >> "$mirror"
  park_again "$home"
  append_status "$home" 'malformed mirror'
  wait_until 250 host_exited "$home" || fail "bad mirror: a malformed mirror entry did not hand the wake to main"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "a malformed mirror entry must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran past a malformed mirror entry"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "a malformed mirror entry moved the cursor"
  [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "a malformed mirror entry staged a cursor past it"
  pass "host: an attended wake whose mirror is missing, cannot be read (at the feed or at the prompt), or holds a malformed entry reaches main before any engine turn, and the cursor stays put"
}

test_attended_latch_keeps_closes_on_main_and_records_recovery_off_main() {
  local home handled
  home=$(make_home attended-latch attended)
  echo fail > "$home/stub-mode"
  start_session "$home"
  park_again "$home"
  append_status "$home" 'first'
  wait_until 250 host_exited "$home" || fail "latch: the first engine error did not hand the wake back"
  assert_re '^supervision-host: the supervision session could not take this wake: the engine turn failed \(exit 3\); this wake is yours$' \
    "$home/host.out" "the first engine error must hand the wake back with its reason"
  assert_no_re 'paused' "$home/host.out" "one engine error must not latch the session"
  main_drain_and_ack "$home"

  park_again "$home"
  append_status "$home" 'second'
  wait_until 250 host_exited "$home" || fail "latch: the second engine error did not hand the wake back"
  assert_re '^supervision-host: the supervision session is paused after repeated engine errors; every wake reaches you for the next 5 minutes' "$home/host.out" \
    "the second consecutive engine error must trip the latch with one line"
  assert_grep 'cooldown=300' "$home/state/.supervision-host-health" "the latch must start with the Pi policy's five-minute cooldown"
  main_drain_and_ack "$home"

  park_again "$home"
  append_status "$home" 'inside the cooldown'
  wait_until 250 host_exited "$home" || fail "latch: a close inside the cooldown did not reach main"
  assert_re '^signal: .*demo.status' "$home/host.out" "a close inside the cooldown must reach main"
  assert_no_re '^supervision-host' "$home/host.out" "a close inside the cooldown must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 2 ] || fail "the engine ran inside the cooldown"
  assert_re '	pass-through	attended	the supervision session is cooling down' "$home/state/.supervision-host.log" \
    "the ledger must record the cooldown"
  main_drain_and_ack "$home"

  end_cooldown "$home"
  park_again "$home"
  append_status "$home" 'the probe fails'
  wait_until 250 host_exited "$home" || fail "latch: the failed probe did not hand the wake back"
  [ "$(engine_calls "$home")" -eq 3 ] || fail "the cooldown's end did not let one wake probe the engine"
  assert_no_re 'paused' "$home/host.out" "a failed probe must not repeat the trip line"
  assert_grep 'cooldown=600' "$home/state/.supervision-host-health" "a failed probe must double the cooldown"
  main_drain_and_ack "$home"

  end_cooldown "$home" 2400
  park_again "$home"
  append_status "$home" 'a later probe fails'
  wait_until 250 host_exited "$home" || fail "latch: the later failed probe did not hand the wake back"
  [ "$(engine_calls "$home")" -eq 4 ] || fail "the grown cooldown's end did not let one wake probe the engine"
  assert_grep 'cooldown=3600' "$home/state/.supervision-host-health" "the doubled cooldown must stop at one hour"
  main_drain_and_ack "$home"

  end_cooldown "$home"
  echo handle > "$home/stub-mode"
  handled=$(handled_count "$home")
  park_again "$home"
  append_status "$home" 'the probe succeeds'
  wait_until 250 handled_at_least "$home" $((handled + 1)) \
    || fail "latch: the successful probe was not handled: $(cat "$home/host.out"; tail -n 5 "$home/state/.supervision-host.log")"
  assert_re '	recovered	after a successful probe$' "$home/state/.supervision-host.log" "the ledger must record the recovery"
  ! wait_until 20 host_exited "$home" || fail "a routine probe's recovery reached main: $(cat "$home/host.out")"
  assert_no_re '^supervision-host' "$home/host.out" "a recovery must stay off main"
  assert_grep 'cooldown=0' "$home/state/.supervision-host-health" "a successful probe must clear the latch"
  assert_grep 'errors=0' "$home/state/.supervision-host-health" "a successful probe must clear the error streak"
  pass "host: attended, two engine errors latch the session, main keeps every close unchanged in the cooldown, a failed probe doubles it up to its cap, and a routine probe's recovery stays in the ledger, off main"
}

test_away_wake_is_handled_on_the_engine_and_never_reaches_main() {
  local home lock_pid session first second pid watcher
  home=$(make_home away-handled away)
  echo hold-lease > "$home/stub-mode"
  # Dialog in the mirror that an away wake must neither carry nor mark read.
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "away: the wake was not handled: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  lock_pid=$(cat "$home/state/.lock")

  first="$home/engine-call.1"
  assert_re '^actor=branch$' "$first" "the engine must run as the branch actor"
  assert_re "^holder=$lock_pid\$" "$first" "the engine's lease holder must be the session-lock holder"
  assert_re '^primary=claude$' "$first" "the engine must carry the primary-harness pin"
  assert_re '^turn=host-' "$first" "the engine must carry its report turn"
  assert_re '^arg=--safe-mode$' "$first" "the engine must load none of the home's hooks"
  assert_re '^arg=dontAsk$' "$first" "the engine must never prompt"
  assert_re '^arg=sonnet$' "$first" "the engine must default to its default model"
  assert_re '^arg=--session-id$' "$first" "the first turn must open a new conversation"
  assert_re '^POSTURE: AWAY\.' "$first" "the wake must carry the away tail"
  assert_grep 'keep the export worker on low effort' "$home/state/.host-mirror.jsonl" "fixture: the captain's dialog was not mirrored"
  assert_no_re 'MAIN DIALOG MIRROR|low effort' "$first" "an away wake must carry no dialog mirror"
  assert_absent "$home/state/.host-mirror-cursor" "a handled away wake must leave the mirror cursor where it was"
  assert_absent "$home/state/.host-mirror-cursor.next" "an away wake must stage no mirror cursor"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "the engine's report did not reach the outcome store"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the engine's acknowledgement did not consume the wake"
  if FM_HOME="$home" "$LEASE" check demo >/dev/null 2>&1; then
    fail "the host did not release the lease the engine left held: $(FM_HOME="$home" "$LEASE" check demo)"
  fi
  [ ! -s "$home/host.rc" ] || fail "a handled away wake reached main: $(cat "$home/host.out")"
  [ "$(grep -cv '^watcher: started pid=' "$home/host.out")" -eq 0 ] \
    || fail "a handled away wake printed more than the first cycle's status to main: $(cat "$home/host.out")"
  watcher_live "$home" || fail "the host is not parked on a live successor cycle"

  echo handle > "$home/stub-mode"
  append_status "$home" 'step two'
  wait_until 250 handled_at_least "$home" 2 || fail "away: the second wake was not handled"
  session=$(sed -n '/^arg=--session-id$/{n;s/^arg=//p;}' "$first")
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "a later turn must resume the conversation"
  assert_re "^arg=$session\$" "$second" "a later turn must resume the same conversation"
  [ "$(grep -c '"task":"demo"' "$home/state/branch-outcomes.jsonl")" -eq 2 ] || fail "the second outcome was not recorded"
  assert_re '	handled	turn=[^	]*\.2	.* cost=0\.25 conversation_cost=0\.5 ' "$home/state/.supervision-host.log" \
    "a resumed turn must log its own cost, not the conversation's running total"

  pid=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -TERM "$pid"
  wait_until 200 host_exited "$home" || fail "the host did not stop on TERM"
  expect_code 143 "$(cat "$home/host.rc")" "a TERMed host must exit 143"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$watcher" || fail "a stopped host left its watcher running"
  assert_absent "$home/state/.supervision-host" "a stopped host left its record"
  pass "host: an away wake is handled on the engine through the branch contract and never reaches main"
}

test_away_turn_without_a_report_hands_the_wake_to_main() {
  local home token
  home=$(make_home away-noreport away)
  echo noreport > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "noreport: the host never started a watcher cycle"
  append_status "$home" 'needs a look'
  wait_until 250 host_exited "$home" || fail "noreport: the host did not hand the wake to main"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*recorded no outcome for its wake; this wake is yours$' "$home/host.out" "the handback must say why"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the unhandled wake must stay durable for main"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the wake to main"
  token=$(cat "$home/state/.watcher-down")
  case "$token" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "a handback must leave the recovery marker in downtime for the owner's rewake, got: $token" ;;
  esac
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  pass "host: an engine turn that records no outcome hands its durable wake to main"
}

test_return_during_an_engine_turn_hands_its_outcomes_to_main() {
  local home
  home=$(make_home away-return away)
  echo return > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return: the host never started a watcher cycle"
  append_status "$home" 'mid-task'
  wait_until 250 host_exited "$home" || fail "return: the host did not hand the late outcome to main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a late-outcome handoff must exit 0 for the owner to deliver"
  assert_absent "$home/state/.afk-contract" "fixture: the stub's return did not archive the record"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handoff must carry the close"
  assert_re '^supervision-host: the captain returned while the away session was handling this wake.*store rows 1[,)]' "$home/host.out" \
    "the handoff must say the captain returned mid-turn and name the store rows"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "the handoff must carry the turn's outcome for main to relay"
  assert_re '	handled	turn=' "$home/state/.supervision-host.log" "the turn itself was handled"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the handled wake must stay acknowledged"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the outcome to main"
  pass "host: a captain return during an engine turn hands that turn's outcomes to main"
}

# Silent outcomes stay stored, but neither captain-return path names or relays
# them when the host decides whether to hand the wake to main.
test_silent_outcomes_are_not_relayed_when_the_captain_returns() {
  local mode home host
  for mode in return-silent return-fail-silent; do
    home=$(make_home "away-$mode" away)
    echo "$mode" > "$home/stub-mode"
    start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$mode: the host never started a watcher cycle"
    append_status "$home" 'no-change result during a captain return'

    if [ "$mode" = return-silent ]; then
      wait_until 250 handled_at_least "$home" 1 || fail "$mode: the wake was not handled: host=$(cat "$home/host.out" 2>/dev/null) log=$(tail -n 8 "$home/state/.supervision-host.log" 2>/dev/null) report=$(cat "$home/engine-report.log" 2>/dev/null)"
      [ ! -s "$home/host.rc" ] || fail "$mode: a silent-only outcome forced a captain handoff: $(cat "$home/host.out")"
      watcher_live "$home" || fail "$mode: the host did not park on its successor"
      host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
      kill -TERM "$host"
      wait_until 200 host_exited "$home" || fail "$mode: the host did not stop on TERM"
    else
      wait_until 250 host_exited "$home" || fail "$mode: the failed turn did not hand the wake to main: $(cat "$home/host.out" 2>/dev/null) $(tail -n 8 "$home/state/.supervision-host.log" 2>/dev/null)"
      assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); this wake is yours$' \
        "$home/host.out" "$mode: the failed turn must still hand its wake to main"
    fi
    assert_no_re 'captain returned|store rows|^supervision-host: outcome ' "$home/host.out" \
      "$mode: a silent outcome was referenced in the captain-return handoff"
    assert_grep '"silent":true' "$home/state/branch-outcomes.jsonl" "$mode: the silent outcome was not retained in the store"
    assert_absent "$home/state/.afk-contract" "$mode: the captain return was not archived"
  done
  pass "host: silent outcomes are excluded from both captain-return handoff paths"
}

test_large_turn_relays_an_early_visible_outcome() {
  local home count
  home=$(make_home away-many-receipts away)
  echo return-many > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "many receipts: the host never started a watcher cycle"
  append_status "$home" 'large turn with a visible first outcome'
  wait_until 2000 host_exited "$home" || fail "many receipts: the captain-return handoff did not finish: host=$(cat "$home/host.out" 2>/dev/null) log=$(tail -n 8 "$home/state/.supervision-host.log" 2>/dev/null) report=$(tail -n 5 "$home/engine-report.log" 2>/dev/null) rows=$(wc -l < "$home/state/branch-outcomes.jsonl" 2>/dev/null)"
  count=$(grep -c '^supervision-host: outcome ' "$home/host.out")
  [ "$count" -eq 1 ] || fail "many receipts: expected one visible outcome, got $count: $(tail -n 5 "$home/host.out")"
  [ "$(wc -l < "$home/state/branch-outcomes.jsonl" | tr -d ' ')" -eq 1001 ] \
    || fail "many receipts: the fixture did not exceed the old 1,000-row window: rows=$(wc -l < "$home/state/branch-outcomes.jsonl") host=$(cat "$home/host.out") report=$(cat "$home/engine-report.log") tail=$(tail -c 300 "$home/state/branch-outcomes.jsonl")"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "many receipts: the early visible outcome was lost behind later silent rows"
  assert_no_grep 'bulk silent fixture' "$home/host.out" "many receipts: silent outcomes were relayed"
  pass "host: an early visible outcome survives more than 1,000 same-turn receipts"
}

test_outcome_lookup_failure_is_not_treated_as_silence() {
  local home
  home=$(make_home away-lookup-failure away)
  echo return-lookup-fail > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "lookup failure: the host never started a watcher cycle"
  append_status "$home" 'outcome lookup failure after a captain return'
  wait_until 2000 host_exited "$home" || fail "lookup failure: the host treated an unreadable store as a silent outcome"
  assert_re '^supervision-host: the captain returned while the away session was handling this wake, but the recorded outcomes could not be verified; main must review them$' \
    "$home/host.out" "lookup failure: the main handoff did not explain the lookup failure"
  assert_re '^supervision-host: outcome lookup failed for turn receipt rows 1; visible outcomes may require manual review$' \
    "$home/host.out" "lookup failure: the missing outcome warning was not emitted"
  pass "host: an outcome lookup failure forces a visible main handoff"
}

# The live failure this guards: a Cursor park superseded by the captain's
# return kills its host as the engine turn ends, so the host's own handoff is
# never printed. The outcome still reaches main: the next host's first cycle
# resurfaces the durable queue and main's drain presents it.
test_outcome_after_the_return_survives_a_host_killed_at_the_turn_end() {
  local home host rc drained
  home=$(make_home away-return-first away)
  echo return-first > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return-first: the host never started a watcher cycle"
  append_status "$home" 'finishing while the captain comes back'
  wait_until 250 grep -qs 'supervision-host-return:1' "$home/state/.wake-queue" \
    || fail "return-first: the late outcome was never queued: $(cat "$home/engine-report.log" 2>/dev/null)"
  host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  kill -TERM "$host"
  wait_until 250 host_exited "$home" || fail "return-first: the stopped host did not exit"
  rc=$(cat "$home/host.rc")
  [ "$rc" -gt 128 ] || fail "fixture: the host was not stopped mid-turn (rc=$rc): $(cat "$home/host.out")"
  assert_no_re '^supervision-host: ' "$home/host.out" "fixture: the stopped host printed a handoff, so this case proves nothing"
  for f in "$home"/state/.supervision-host-result.* "$home"/state/.supervision-host-errors.*; do
    [ -e "$f" ] && fail "a host stopped mid-turn left its turn file behind: $f"
  done
  assert_grep 'supervision-host-return:1' "$home/state/.wake-queue" "the late outcome must stay queued after its host died"

  rm -f "$home/host.rc"
  start_host "$home"
  wait_until 250 host_exited "$home" || fail "return-first: the next host did not resurface the queued outcome"
  assert_re '^check: rearm-resurface$' "$home/host.out" "the next host's first cycle must resurface the queue"
  assert_re '	pass-through	attended	main-only	check: rearm-resurface' "$home/state/.supervision-host.log" "the attended resurface must reach main"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  assert_contains "$drained" "supervision-host outcome 1 for demo [routine] was recorded after the captain returned" \
    "main's drain must present the outcome the killed host never handed off"
  pass "host: an outcome recorded after the return reaches main even when its host dies at the turn's end"
}

# A host killed outright mid-turn leaves turn files, but the bounded engine's
# watchdog stops the engine when its owner dies. The next host clears the files.
test_next_host_clears_a_turn_its_killed_predecessor_left() {
  local home host engine
  home=$(make_home away-killed-mid-turn away)
  echo return-first > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "killed: the host never started a watcher cycle"
  append_status "$home" 'mid-turn when its host is killed'
  wait_until 250 grep -qs 'supervision-host-return:1' "$home/state/.wake-queue" || fail "killed: the turn never reported"
  host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  engine=$(cut -f1 "$home/state/.supervision-host.engine-pid")
  kill -KILL "$host"
  wait_until 100 host_exited "$home" || fail "killed: the host did not die"
  ls "$home"/state/.supervision-host-result.* >/dev/null 2>&1 || fail "fixture: the killed turn left no result file, so this case proves nothing"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$engine" || fail "the bounded engine survived its killed host"

  rm -f "$home/host.rc"
  start_host "$home"
  wait_until 250 host_exited "$home" || fail "killed: the next host did not resurface the queued outcome"
  ! kill -0 "$engine" 2>/dev/null || fail "the next host revived its killed predecessor's engine"
  for f in "$home"/state/.supervision-host-result.* "$home"/state/.supervision-host-errors.* \
    "$home"/state/.supervision-host-descendants.* "$home/state/.supervision-host-turn"; do
    [ -e "$f" ] && fail "the next host left its killed predecessor's turn file behind: $f"
  done
  assert_re '^check: rearm-resurface$' "$home/host.out" "the next host's first cycle must resurface the queue"
  pass "host: a killed predecessor's engine is reaped and the next host removes its turn files"
}

test_report_without_acknowledgement_hands_the_wake_to_main() {
  local home
  home=$(make_home away-noack away)
  echo noack > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "noack: the host never started a watcher cycle"
  append_status "$home" 'reported, never acknowledged'
  wait_until 250 host_exited "$home" || fail "noack: the host counted an unacknowledged wake handled: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*the engine turn left its granted wake rows [0-9]+( [0-9]+)* unacknowledged; this wake is yours$' "$home/host.out" \
    "the handback must name the rows the turn left unacknowledged"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the unacknowledged wake must stay durable for main"
  assert_re '	failed	turn=.*	unacked=[0-9]' "$home/state/.supervision-host.log" "the ledger must record the turn as failed"
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the wake to main"
  pass "host: a turn that reports but leaves its granted rows queued hands the wake to main"
}

test_return_during_a_failed_turn_still_hands_its_outcomes_to_main() {
  local home
  home=$(make_home away-return-fail away)
  echo return-fail > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return-fail: the host never started a watcher cycle"
  append_status "$home" 'mid-task, then a crash'
  wait_until 250 host_exited "$home" || fail "return-fail: the host did not hand the wake to main"
  expect_code 0 "$(cat "$home/host.rc")" "a failed turn's handback must exit 0 for the owner to deliver"
  assert_absent "$home/state/.afk-contract" "fixture: the stub's return did not archive the record"
  assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); .*captain returned during its turn.*store rows 1[,)]' "$home/host.out" \
    "the handback must say the turn failed, that the captain returned, and name the store rows"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "the handback must carry the failed turn's outcome for main to relay"
  assert_re '	failed	turn=' "$home/state/.supervision-host.log" "the turn itself failed"
  pass "host: a captain return during a failed engine turn still hands that turn's outcomes to main"
}

test_incomplete_engine_result_hands_the_wake_to_main() {
  local home
  home=$(make_home away-emptyresult away)
  echo emptyresult > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "emptyresult: the host never started a watcher cycle"
  append_status "$home" 'handled, but the result is empty'
  wait_until 250 host_exited "$home" || fail "emptyresult: the host counted an empty result handled: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*the engine turn ended with an error or an incomplete result; this wake is yours$' "$home/host.out" \
    "the handback must say the engine's result was incomplete"
  assert_re '	failed	turn=.*	error=1 ' "$home/state/.supervision-host.log" "the ledger must record the turn as failed"
  assert_no_re '	handled	turn=' "$home/state/.supervision-host.log" "an incomplete result must never count as handled"
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  pass "host: an engine turn whose result is incomplete hands its wake to main"
}

test_engine_turn_is_bounded_and_its_descendants_reaped() {
  local home orphan
  home=$(make_home away-hang away)
  echo hang > "$home/stub-mode"
  FM_SUPERVISION_HOST_TURN_TIMEOUT=3 FM_SUPERVISION_ENGINE_GRACE=1 start_host "$home"
  wait_until 150 watcher_live "$home" || fail "hang: the host never started a watcher cycle"
  append_status "$home" 'slow one'
  wait_until 300 host_exited "$home" || fail "hang: the bounded turn did not end"
  assert_re '^supervision-host: .*the engine turn hit its 3s bound; this wake is yours$' "$home/host.out" "a bounded turn must hand its wake to main"
  orphan=$(cat "$home/orphan-pid")
  wait_until 50 sh -c '! kill -0 "$1" 2>/dev/null' _ "$orphan" \
    || fail "an engine tool process in its own process group outlived the turn: $(ps -p "$orphan" -o pid=,pgid=,command=)"
  pass "host: an engine turn is bounded, and tool processes outside its process group are reaped"
}

test_restarted_host_stops_what_a_killed_predecessor_left() {
  local home first_host arm watcher
  home=$(make_home away-crash away)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "crash: the host never started a watcher cycle"
  first_host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  arm=$(awk -F '\t' '$1 == "arm" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -KILL "$first_host"
  sleep 1
  kill -0 "$arm" 2>/dev/null || fail "crash: fixture error: the arm died with its host, so this case proves nothing"
  start_host "$home"
  wait_until 200 sh -c '! kill -0 "$1" 2>/dev/null && ! kill -0 "$2" 2>/dev/null' _ "$arm" "$watcher" \
    || fail "a restarted host left its killed predecessor's arm or watcher running"
  wait_until 100 sh -c 'grep -q "	start	gen=host-" "$1" && [ "$(grep -c "	start	" "$1")" -ge 2 ]' _ "$home/state/.supervision-host.log" \
    || fail "the restarted host did not start"
  pass "host: a restarted host stops, by recorded identity, the cycle a killed predecessor left running"
}

test_park_boundary_ends_the_park_before_the_hook_timeout() {
  local home token
  home=$(make_home boundary attended)
  # The wall-clock bound must sit past the exit check: only the injected clock
  # can reach the boundary in time, so a host ignoring it fails instead of
  # passing on real elapsed seconds.
  FM_SUPERVISION_HOST_PARK_SECONDS=60 FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_host "$home"
  wait_until 150 watcher_live "$home" || fail "boundary: the host never started a watcher cycle"
  echo 60 > "$home/park-clock"
  wait_until 150 host_exited "$home" || fail "boundary: the host did not end its park"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "the park boundary must reach main as a host line"
  watcher_live "$home" && fail "the park boundary left the watcher running"
  token=$(cat "$home/state/.watcher-down")
  case "$token" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "the park boundary must publish downtime for the owner's rewake, got: $token" ;;
  esac
  pass "host: the park ends itself with a boundary wake and a stopped watcher"
}

# A close that lands while a turn is running can only wait: the host ends its
# park at the bound regardless of how many closes are queued behind it. The
# park runs on the test clock (FM_TEST_SUPERVISION_HOST_CLOCK), which the test
# moves to the refusal window's opening (park bound minus the turn bound and
# grace) before it releases the held turn, so the second close can never take
# a turn of its own on any machine speed. The bound also stays well past every
# wall-clock check in the case: a host that ignored the test clock would start
# the second turn instead of silently passing at a wall-clock boundary.
test_park_boundary_holds_under_back_to_back_closes() {
  # The turn bound is the one wall-clock bound left: it must cover the stub's
  # report work after release, so the product never kills the held turn.
  local home park=300 turn=19 grace=1
  home=$(make_home boundary-busy away)
  echo held > "$home/stub-mode"
  mkfifo "$home/stub-release"
  echo 0 > "$home/park-clock"
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=$park \
    FM_SUPERVISION_HOST_TURN_TIMEOUT=$turn FM_SUPERVISION_ENGINE_GRACE=$grace start_host "$home"
  wait_until 150 watcher_live "$home" || fail "boundary-busy: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'the first of many'
  wait_until 450 sh -c '[ -e "$1/engine-call.1" ] || [ -s "$1/host.rc" ]' _ "$home" \
    || fail "boundary-busy: the host never started the first turn: $(cat "$home/host.out" "$home/state/.supervision-host.log" 2>/dev/null)"
  [ -e "$home/engine-call.1" ] \
    || fail "boundary-busy: the host exited without starting the first turn: $(cat "$home/host.out" "$home/state/.supervision-host.log" 2>/dev/null)"
  append_status "$home" 'queued while the first close is still handled'
  echo $((park - turn - grace)) > "$home/park-clock"
  exec 3<> "$home/stub-release"
  printf 'release\n' >&3
  wait_until 450 host_exited "$home" \
    || fail "the host kept handling back-to-back closes past its park boundary: $(cat "$home/state/.supervision-host.log")"
  exec 3>&-
  ! grep -q '	failed	' "$home/state/.supervision-host.log" \
    || fail "the held turn hit its turn bound or failed: $(cat "$home/state/.supervision-host.log")"
  [ "$(handled_count "$home")" -eq 1 ] || fail "the held turn did not complete once released: $(cat "$home/state/.supervision-host.log")"
  [ ! -e "$home/engine-call.2" ] || fail "a close waiting at the boundary still got an engine turn"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "the park boundary must reach main as a host line"
  [ "$(tail -n 1 "$home/host.out")" = "$(grep '^supervision-host: cycle boundary - ' "$home/host.out")" ] \
    || fail "a close read at the boundary must be printed ahead of the boundary line: $(cat "$home/host.out")"
  assert_grep 'demo.status' "$home/state/.wake-queue" "a close waiting at the boundary must stay queued for main"
  watcher_live "$home" && fail "the park boundary left the watcher running"
  pass "host: waiting closes cannot carry the park past its boundary"
}

# Rendering the wake prompt runs after the successor cycle has started; the
# shim holds the render on a FIFO, and the test moves the park's test clock to
# the refusal window's opening before releasing it, so the close passes the
# arrival check and the pre-turn recheck must refuse on any machine speed. The
# snapshot proves the successor arm it started can be checked afterwards. The
# park bound stays past the case's wall-clock checks, so an ignored test clock
# would let the turn run and the engine-call assertions catch it.
test_park_boundary_rechecked_just_before_the_engine_turn() {
  local home real_node pid park=120 turn=3 grace=1
  home=$(make_home boundary-late away)
  real_node=$(command -v node)
  mkfifo "$home/render-release"
  echo 0 > "$home/park-clock"
  cat > "$home/fakebin/node" <<SH
#!/usr/bin/env bash
if [ "\${2:-}" = wake-prompt ]; then
  cp "\$FM_HOME/state/.supervision-host" "\$FM_HOME/host-record-at-render" 2>/dev/null
  read -r _ < "\$FM_HOME/render-release"
fi
exec "$real_node" "\$@"
SH
  chmod +x "$home/fakebin/node"
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=$park \
    FM_SUPERVISION_HOST_TURN_TIMEOUT=$turn FM_SUPERVISION_ENGINE_GRACE=$grace start_host "$home"
  wait_until 150 watcher_live "$home" || fail "boundary-late: the host never started a watcher cycle"
  append_status "$home" 'arrives with just enough margin'
  wait_until 300 sh -c '[ -s "$1/host-record-at-render" ] || [ -s "$1/host.rc" ]' _ "$home" \
    || fail "boundary-late: the host neither reached the wake render nor exited: $(cat "$home/host.out" "$home/state/.supervision-host.log" 2>/dev/null)"
  [ -s "$home/host-record-at-render" ] \
    || fail "the close was stopped before the successor started: $(cat "$home/host.out")"
  echo $((park - turn - grace)) > "$home/park-clock"
  exec 3<> "$home/render-release"
  printf 'release\n' >&3
  wait_until 300 host_exited "$home" || fail "boundary-late: the host did not end its park"
  exec 3>&-
  assert_re '^signal: .*demo.status' "$home/host.out" "the close read at the boundary must reach main"
  [ "$(tail -n 1 "$home/host.out")" = "$(grep '^supervision-host: cycle boundary - ' "$home/host.out")" ] \
    || fail "the close must be printed ahead of the boundary line: $(cat "$home/host.out")"
  ! ls "$home"/engine-call.* >/dev/null 2>&1 || fail "an engine turn started that could run past the boundary"
  assert_no_re '	(handled|failed)	turn=' "$home/state/.supervision-host.log" "no engine turn may be logged"
  assert_grep 'demo.status' "$home/state/.wake-queue" "a close refused at the boundary must stay queued for main"
  while IFS= read -r pid; do
    kill -0 "$pid" 2>/dev/null && fail "the boundary left the successor arm $pid running"
  done < <(awk -F '\t' '$1 == "arm" { print $2 }' "$home/host-record-at-render")
  watcher_live "$home" && fail "the boundary left the watcher running"
  pass "host: a close whose margin runs out while the successor starts reaches main at the boundary without a turn"
}

# A leaked test clock in a real primary's environment must stay inert: the
# host reads it only alongside the FM_TEST_SEAM marker that test suites set.
test_park_test_clock_requires_the_marker() {
  local home
  home=$(make_home clock-armed away)
  echo 99999 > "$home/park-clock"
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_host "$home"
  wait_until 150 host_exited "$home" || fail "clock-armed: the marked test clock did not end the park"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "the marked test clock must drive the boundary"

  home=$(make_home clock-unmarked away)
  echo 99999 > "$home/park-clock"
  FM_TEST_SEAM='' FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_host "$home"
  wait_until 150 watcher_live "$home" || fail "clock-unmarked: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'handled on the wall clock'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "a test clock without FM_TEST_SEAM changed the park: $(cat "$home/host.out" "$home/state/.supervision-host.log")"
  [ ! -s "$home/host.rc" ] || fail "a test clock without FM_TEST_SEAM ended the park: $(cat "$home/host.out")"
  assert_no_re 'cycle boundary' "$home/host.out" "a test clock without FM_TEST_SEAM reached the boundary"
  pass "host: the park's test clock is inert without the test marker"
}

test_park_seconds_at_or_beyond_the_hook_registration_fall_back_to_the_default() {
  park_outcome park-28799 28799
  [ "$PARK_OUTCOME" = handled ] || fail "a park just under the registration must be honored"
  park_outcome park-28800 28800
  [ "$PARK_OUTCOME" = boundary ] || fail "a park at the registration must fall back to the default"
  park_outcome park-huge 100000000000000000000
  [ "$PARK_OUTCOME" = boundary ] || fail "a park far beyond the registration must fall back to the default"
  pass "host: a park at or beyond the Stop-hook registration falls back to the default boundary"
}

# An owner whose own bound is the park lets a turn run past the boundary up to
# its limit; a limit below the boundary or at the registration is the boundary.
test_park_limit_lets_a_turn_outlive_the_boundary() {
  local cases name limit want home
  cases='limit-later:28000:handled limit-earlier:50:boundary limit-registration:28800:boundary limit-absent::boundary'
  for c in $cases; do
    name=${c%%:*}; limit=${c#*:}; want=${limit#*:}; limit=${limit%%:*}
    home=$(make_home "$name" away)
    FM_SUPERVISION_HOST_PARK_SECONDS=100 FM_SUPERVISION_HOST_PARK_LIMIT=$limit FM_SUPERVISION_HOST_TURN_TIMEOUT=200 \
      FM_SUPERVISION_ENGINE_GRACE=10 start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$name: the host never started a watcher cycle"
    append_status "$home" 'one close'
    wait_until 250 sh -c '[ -s "$1/host.rc" ] || grep -q "	handled	" "$1/state/.supervision-host.log" 2>/dev/null' _ "$home" \
      || fail "$name: the close was neither handled nor handed to main: $(cat "$home/state/.supervision-host.log")"
    if host_exited "$home"; then
      grep -q '^supervision-host: cycle boundary - ' "$home/host.out" || fail "$name: the host exited without the boundary: $(cat "$home/host.out")"
      [ "$want" = boundary ] || fail "$name: a turn inside the owner's limit was refused at the boundary"
    else
      [ "$want" = handled ] || fail "$name: a turn past the boundary ran without a later limit"
      kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
      wait_until 200 host_exited "$home" || fail "$name: the host did not stop on TERM"
    fi
  done
  pass "host: an owner's later park limit lets a turn outlive the boundary, and no other limit does"
}

# The first cycle's status line reaches the owner before any close and only
# once; --restart replaces a watcher it would otherwise attach to, and the
# owner's predecessor arm makes the first cycle a handling successor. The home
# names no usable engine, so every attended close passes straight to main.
test_first_cycle_status_streams_and_owner_options_reach_it() {
  local home stale fresh generation predecessor
  home=$(make_home stream attended pi)
  start_host "$home"
  wait_until 150 grep -qs '^watcher: started pid=' "$home/host.out" \
    || fail "stream: the first cycle's status did not reach the owner before a close: $(cat "$home/host.out")"
  host_exited "$home" && fail "stream: the host exited before any close: $(cat "$home/host.out")"
  append_status "$home" 'fixture finished' 'done'
  wait_until 200 host_exited "$home" || fail "stream: the attended close did not reach main"
  [ "$(grep -c '^watcher: ' "$home/host.out")" -eq 1 ] || fail "stream: the status line must be printed once: $(cat "$home/host.out")"
  [ "$(sed -n '1p' "$home/host.out" | cut -c1-17)" = 'watcher: started ' ] || fail "stream: the status line must come first"
  assert_re '^signal: .*demo.status' "$home/host.out" "stream: the close must follow the status line"
  # Main handles that close, so the next cycle has no episode to resurface.
  FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$home/drain.err" || fail "stream: main's drain failed"
  ack_drain_err "$home/state" "$home/drain.err" >/dev/null 2>&1 || fail "stream: main's acknowledgement failed: $(cat "$home/drain.err")"
  # Pass-through can leave a successor watcher running. Retire that cycle so
  # the orphan-arm fixture below owns the watcher we later ask --restart to replace.
  FM_HOME="$home" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null || fail "stream: could not stop the prior cycle"

  # A watcher a dead arm left behind, holding this home's watcher lock.
  FM_HOME="$home" PATH="$home/fakebin:$PATH" perl -e 'setpgrp(0, 0); exec @ARGV' "$ROOT/bin/fm-watch-arm.sh" \
    > "$home/stale-arm.out" 2>&1 &
  wait_until 150 grep -qs '^watcher: started pid=' "$home/stale-arm.out" \
    || fail "stream: the fixture arm never started its watcher: $(cat "$home/stale-arm.out")"
  wait_until 150 watcher_live "$home" || fail "stream: the fixture watcher never started"
  kill -KILL "$!" 2>/dev/null || true
  wait "$!" 2>/dev/null || true
  stale=$(cat "$home/state/.watch.lock/pid")
  rm -f "$home/host.out" "$home/host.rc"
  start_host "$home" --restart
  # Stopping the old watcher opens a downtime episode, so the fresh cycle may
  # close on its resurface before the arm confirms it, and the arm then prints
  # only that close (bin/fm-watch-arm.sh): either order is the owner's cycle.
  wait_until 150 sh -c 'grep -qs "^watcher: started pid=" "$1/host.out" || [ -s "$1/host.rc" ]' _ "$home" \
    || fail "stream: the restarting host never reported its cycle: $(cat "$home/host.out" "$home/claude.err" 2>/dev/null)"
  fresh=$(sed -n 's/^watcher: started pid=\([0-9]*\).*/\1/p' "$home/host.out")
  [ "$fresh" != "$stale" ] || fail "stream: --restart attached to the watcher it should have replaced"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$stale" || fail "stream: --restart left the old watcher running"
  wait_until 200 host_exited "$home" || append_status "$home" 'second close' 'done'
  wait_until 200 host_exited "$home" || fail "stream: the restarting host's close did not reach main"
  assert_re '^(signal: .*demo.status|check: rearm-resurface)$' "$home/host.out" "stream: the restarting host's close must reach main"

  # That close left an unacknowledged downtime episode; a host the owner starts
  # as the closed arm's successor takes it over as a handling successor
  # instead of re-announcing it.
  generation=$(sed -n 's/^[a-z]*:[a-z]*://p' "$home/state/.watcher-down")
  [ -n "$generation" ] || fail "fixture: the close left no downtime episode: $(cat "$home/state/.watcher-down")"
  predecessor=$(sed -n '1p' "$home/claude-pids")
  rm -f "$home/host.out" "$home/host.rc"
  FM_WATCH_PREDECESSOR_ARM_PID=$predecessor start_host "$home" --restart
  wait_until 150 grep -qs '^watcher: started pid=' "$home/host.out" || fail "stream: the successor host never reported its cycle"
  assert_re "^watcher: started pid=[0-9]+ \\(beacon fresh\\) recovery-generation=$generation\$" "$home/host.out" \
    "the owner's predecessor must make the first cycle a handling successor of the pending generation"
  sleep 3
  host_exited "$home" && fail "a handling successor re-announced the pending episode: $(cat "$home/host.out")"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "stream: the successor host did not stop on TERM"
  pass "host: the first cycle's status streams once, --restart replaces a stale watcher, and an owner predecessor makes a handling successor"
}

test_latch_trips_after_two_engine_errors_then_probes_and_recovers() {
  local home
  home=$(make_home away-latch away)
  trip_latch "$home"

  park_again "$home"
  append_status "$home" 'inside the cooldown'
  wait_until 250 host_exited "$home" || fail "latch: a close inside the cooldown did not reach main"
  assert_re '^signal: .*demo.status' "$home/host.out" "a close inside the cooldown must reach main"
  assert_re '^supervision-host: the away session is paused after repeated engine errors until .*; this wake is yours$' \
    "$home/host.out" "a close inside the cooldown must say why main has it"
  [ "$(engine_calls "$home")" -eq 2 ] || fail "the engine ran inside the cooldown"
  assert_grep 'demo.status' "$home/state/.wake-queue" "a close inside the cooldown must stay durable for main"
  main_drain_and_ack "$home"

  end_cooldown "$home"
  park_again "$home"
  append_status "$home" 'the probe fails'
  wait_until 250 host_exited "$home" || fail "latch: the failed probe did not hand the wake back"
  [ "$(engine_calls "$home")" -eq 3 ] || fail "the cooldown's end did not let one wake probe the engine"
  assert_no_re 'paused' "$home/host.out" "a failed probe must not repeat the trip line"
  assert_grep 'cooldown=600' "$home/state/.supervision-host-health" "a failed probe must double the cooldown"
  main_drain_and_ack "$home"

  end_cooldown "$home" 2400
  park_again "$home"
  append_status "$home" 'a later probe fails'
  wait_until 250 host_exited "$home" || fail "latch: the later failed probe did not hand the wake back"
  [ "$(engine_calls "$home")" -eq 4 ] || fail "the grown cooldown's end did not let one wake probe the engine"
  assert_grep 'cooldown=3600' "$home/state/.supervision-host-health" "the doubled cooldown must stop at one hour"
  main_drain_and_ack "$home"

  end_cooldown "$home"
  echo handle > "$home/stub-mode"
  park_again "$home"
  append_status "$home" 'the probe succeeds'
  wait_until 250 handled_at_least "$home" 1 || fail "latch: the successful probe was not handled: $(cat "$home/host.out")"
  [ "$(engine_calls "$home")" -eq 5 ] || fail "the cooldown's end did not let the recovering wake probe the engine"
  host_exited "$home" && fail "an away recovery must not reach main: $(cat "$home/host.out")"
  assert_re '	recovered	after a successful probe' "$home/state/.supervision-host.log" "the ledger must record the recovery"
  assert_grep 'cooldown=0' "$home/state/.supervision-host-health" "a successful probe must clear the latch"
  assert_grep 'errors=0' "$home/state/.supervision-host-health" "a successful probe must clear the error streak"
  watcher_live "$home" || fail "the recovered host is not parked on a live successor cycle"
  pass "host: two engine errors latch the session, main keeps every away wake in the cooldown, a failed probe doubles it up to its cap, and a report recovers it silently"
}

# The latch lives only in the opted-in host's away path: an attended close in a
# latched session and a home that dropped config/supervision-host both reach
# main exactly as they do without it.
test_latch_keeps_attended_closes_on_main_and_skips_unopted_homes() {
  local home health
  home=$(make_home latch-scope away)
  trip_latch "$home"
  health=$(cat "$home/state/.supervision-host-health")

  FM_HOME="$home" "$CONTRACT" archive >/dev/null 2>&1 || fail "fixture: could not archive the away posture"
  park_again "$home"
  append_status "$home" 'attended while latched'
  wait_until 250 host_exited "$home" || fail "latch scope: the attended close did not reach main"
  assert_re '^signal: .*demo.status' "$home/host.out" "an attended close in a latched session must reach main"
  assert_no_re '^supervision-host' "$home/host.out" "an attended close in a latched session must reach main exactly as the arm printed it"
  [ "$(cat "$home/state/.supervision-host-health")" = "$health" ] || fail "an attended close changed the latch"
  main_drain_and_ack "$home"

  : > "$home/config/supervision-host-off"
  FM_HOME="$home" "$CONTRACT" enter --words 'watch the fleet; merge nothing' >/dev/null 2>&1 \
    || fail "fixture: could not record the away posture again"
  park_again "$home"
  append_status "$home" 'away after opting out'
  wait_until 250 host_exited "$home" || fail "latch scope: the close after the opt-out did not reach main"
  assert_re '^supervision-host: the home no longer runs the supervision host$' "$home/host.out" \
    "a home opted out by config/supervision-host-off must hand the close back as the opt-out, not the latch"
  assert_no_re 'paused' "$home/host.out" "a home opted out by config/supervision-host-off must not read the latch"
  [ "$(engine_calls "$home")" -eq 2 ] || fail "an engine ran after the latch tripped"
  pass "host: an attended close in a latched session reaches main as the arm printed it and leaves the latch as it was, and a home that opted out with off never reads it"
}

test_unchanged_held_outcome_reaches_the_captain_once_until_a_new_event() {
  local home cycle old pid watcher
  home=$(make_home away-held-once away)
  echo captain > "$home/stub-mode"
  mkdir -p "$home/projects/held"
  git -C "$home/projects/held" init -q
  git -C "$home/projects/held" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m init
  fm_write_meta "$home/state/held.meta" \
    'window=fm-held' "worktree=$home/projects/held" "project=$home/projects/held" \
    'harness=claude' 'kind=ship' 'mode=no-mistakes' 'yolo=off' 'spawn_gen=g1' \
    'pr=https://example.test/o/r/pull/153'
  printf 'done: PR https://example.test/o/r/pull/153 open, green, mergeable\n' > "$home/state/held.status"
  old=$(( $(date +%s) - 600 ))
  perl -e 'my $t = shift; utime $t, $t, @ARGV or exit 1' "$old" \
    "$home/state/held.meta" "$home/state/held.status" \
    || fail "fixture: could not age the held task's records"
  prime_status_seen "$home/state" "$home/state/held.status"

  export FM_FAKE_CREW_STATE_held='state: done · source: fake'
  export FM_INACTIVE_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" FM_INACTIVE_RECONCILE_SECS=60
  start_host "$home"
  wait_until 250 captain_rows_at_least "$home" 1 \
    || fail "held: the first cadence never escalated the held outcome: $(cat "$home/state/.supervision-host.log" 2>/dev/null)"
  assert_grep 'child=held' "$home/state/branch-outcomes.jsonl" "held: the escalation did not name the held task's outcome: $(cat "$home"/engine-drain.* "$home/state/.supervision-host.log")"
  wait_until 150 handled_at_least "$home" 1 || fail "held: the escalating turn never finished"
  assert_no_grep '	inactive-outcome:' "$home/state/.wake-queue" "held: the branch acknowledgement left the presentation row queued"

  for cycle in 1 2 3 4; do
    old=$(( $(date +%s) - 120 ))
    perl -e 'my $t = shift; utime $t, $t, @ARGV or exit 1' "$old" "$home/state/.inactive-outcome-reconcile" \
      || fail "held: could not age the scan marker before cadence $cycle"
    wait_until 150 scan_ran "$home" || fail "held: cadence $cycle never rescanned"
    wait_until 150 scan_idle "$home" || fail "held: cadence $cycle never finished its scan"
    ! wait_until 10 flood_signal "$home" \
      || fail "held: cadence $cycle re-escalated the unchanged held outcome: $(cat "$home/state/branch-outcomes.jsonl")"
  done
  [ "$(captain_rows "$home")" -eq 1 ] || fail "held: the unchanged situation reached the captain $(captain_rows "$home") times"
  [ -s "$home/host.rc" ] && fail "held: the host handed a wake to main: $(cat "$home/host.out")"

  printf 'needs-decision [key=merge-153]: merge PR 153 now or hold it for the return?\n' >> "$home/state/held.status"
  wait_until 250 captain_rows_at_least "$home" 2 \
    || fail "held: the new decision never reached the captain path: $(cat "$home/state/branch-outcomes.jsonl")"
  [ "$(captain_rows "$home")" -eq 2 ] || fail "held: the decision escalated $(captain_rows "$home") rows, not one"
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" list --recent 1 | sed -n 's/.*"task":"\([^"]*\)".*"verdict":"\([a-z]*\)".*/\1 \2/p')" = 'held captain' ] \
    || fail "held: the decision was not recorded as a captain outcome for the held task: $(cat "$home/state/branch-outcomes.jsonl")"
  unset FM_FAKE_CREW_STATE_held FM_INACTIVE_CREW_STATE_BIN FM_INACTIVE_RECONCILE_SECS
  # Stop the host and its watcher here, so no cadence scan is still writing
  # into this home while the suite's cleanup removes it.
  pid=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -TERM "$pid"
  wait_until 200 host_exited "$home" || fail "held: the host did not stop on TERM"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$watcher" || fail "held: a stopped host left its watcher running"
  pass "host: an unchanged held outcome reaches the captain once across cadences, and a later decision on the task still does"
}

test_unverified_engine_hands_every_away_wake_to_main() {
  local home
  home=$(make_home no-engine away 'pi')
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "no engine: the host never started a watcher cycle"
  append_status "$home" 'anything'
  wait_until 200 host_exited "$home" || fail "no engine: the wake did not reach main"
  assert_re "^supervision-host: no supervision engine runs here: config/supervision-host names 'pi', which is not a verified supervision engine" \
    "$home/host.out" "an unverified engine must be named on the wake it hands to main"
  ! ls "$home"/engine-call.* >/dev/null 2>&1 || fail "no engine: an engine ran"
  pass "host: a home naming an unverified engine hands every away wake to main with the reason"
}

test_host_outside_the_lock_owner_stands_down() {
  local home out rc other
  home=$(make_home not-owner attended)
  "$FAKE_CLAUDE" -c 'sleep 30' &
  other=$!
  printf '%s\n' "$other" >> "$home/claude-pids"
  printf '%s\n' "$other" > "$home/state/.lock"
  out=$(FM_HOME="$home" PATH="$home/fakebin:$PATH" "$HOST" park 2>&1); rc=$?
  expect_code 0 "$rc" "a host that does not own supervision exits 0"
  assert_contains "$out" "supervision-host stood down: this session does not own supervision" "the stand-down must say why"
  watcher_live "$home" && fail "a host that does not own supervision started a watcher"
  kill -TERM "$other" 2>/dev/null || true
  pass "host: a host outside the session-lock owner stands down without arming"
}

test_superseded_host_leaves_the_owner_untouched() {
  local home owner watcher lock_pid
  home=$(make_home superseded away)
  # One fake harness runs the owner host, then, on a signal file, a second host
  # under an auto-arm generation the ledger has already superseded.
  FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$PATH" \
    "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" >> "$FM_HOME/claude-pids"
      "$0" park > "$FM_HOME/host.out" 2>&1 &
      while [ ! -e "$FM_HOME/go-second" ]; do sleep 0.1; done
      FM_SUPERVISION_HOST_AUTOARM_GEN=1 FM_SUPERVISION_HOST_OWNER_PID=$$ "$0" park > "$FM_HOME/host2.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/host2.rc"
      wait
    ' "$HOST" 2>> "$home/claude.err" &
  wait_until 150 watcher_live "$home" || fail "superseded: the owner host never started a watcher cycle"
  owner=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  lock_pid=$(cat "$home/state/.lock")
  printf 'epoch=2 owner_pid=%s outcome=arming\n' "$lock_pid" > "$home/state/.claude-autoarm-epoch"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID="$lock_pid" "$LEASE" claim demo >/dev/null 2>&1 \
    || fail "fixture: could not hold a branch lease"
  : > "$home/go-second"
  wait_until 200 sh -c '[ -s "$1" ]' _ "$home/host2.rc" || fail "superseded: the second host did not return"
  expect_code 0 "$(cat "$home/host2.rc")" "a superseded host exits 0"
  assert_grep 'supervision-host stood down: this session does not own supervision' "$home/host2.out" "the stand-down must say why"
  kill -0 "$owner" 2>/dev/null || fail "a superseded host stopped the owner host"
  [ "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")" = "$owner" ] \
    || fail "a superseded host took the owner's host record"
  if [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null)" != "$watcher" ] || ! kill -0 "$watcher" 2>/dev/null; then
    fail "a superseded host stopped the owner's watcher"
  fi
  FM_HOME="$home" "$LEASE" check demo 2>/dev/null | grep -q '^branch ' || fail "a superseded host released the owner's branch leases"
  kill -TERM "$owner"
  wait_until 200 sh -c '! kill -0 "$1" 2>/dev/null && ! kill -0 "$2" 2>/dev/null' _ "$owner" "$watcher" \
    || fail "superseded: the owner host did not stop on TERM"
  pass "host: a host under a superseded auto-arm generation stands down without touching the owner"
}
test_next_park_takes_over_the_cycle_a_pass_through_left_for_main
test_a_park_stopped_mid_take_over_leaves_the_take_over_to_the_next_park
test_unrecorded_successor_is_stopped_rather_than_left_for_main
test_primary_without_a_verified_mirror_runs_away_only
test_attended_wake_carries_the_dialog_mirror
test_dialog_bearing_files_are_owner_only
test_undelivered_dialog_is_fed_again_on_the_next_turn
test_attended_wake_with_an_unreadable_mirror_reaches_main
test_away_wake_is_handled_on_the_engine_and_never_reaches_main
test_away_turn_without_a_report_hands_the_wake_to_main
test_return_during_an_engine_turn_hands_its_outcomes_to_main
test_silent_outcomes_are_not_relayed_when_the_captain_returns
test_large_turn_relays_an_early_visible_outcome
test_outcome_lookup_failure_is_not_treated_as_silence
test_outcome_after_the_return_survives_a_host_killed_at_the_turn_end
test_next_host_clears_a_turn_its_killed_predecessor_left
test_report_without_acknowledgement_hands_the_wake_to_main
test_return_during_a_failed_turn_still_hands_its_outcomes_to_main
test_incomplete_engine_result_hands_the_wake_to_main
test_latch_trips_after_two_engine_errors_then_probes_and_recovers
test_latch_keeps_attended_closes_on_main_and_skips_unopted_homes
test_attended_latch_keeps_closes_on_main_and_records_recovery_off_main
test_engine_turn_is_bounded_and_its_descendants_reaped
test_restarted_host_stops_what_a_killed_predecessor_left
test_park_boundary_ends_the_park_before_the_hook_timeout
test_park_boundary_holds_under_back_to_back_closes
test_park_boundary_rechecked_just_before_the_engine_turn
test_park_test_clock_requires_the_marker
test_park_seconds_at_or_beyond_the_hook_registration_fall_back_to_the_default
test_park_limit_lets_a_turn_outlive_the_boundary
test_first_cycle_status_streams_and_owner_options_reach_it
test_unchanged_held_outcome_reaches_the_captain_once_until_a_new_event
test_unverified_engine_hands_every_away_wake_to_main
test_host_outside_the_lock_owner_stands_down
test_superseded_host_leaves_the_owner_untouched

