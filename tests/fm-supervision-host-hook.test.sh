#!/usr/bin/env bash
# Behavior tests for the supervision host Claude Stop-hook re-arm, successor take-over, and hand-back
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


test_main_only_close_after_handled_turn_restores_inherited_handling() {
  assert_main_only_close_after_handled_turn restore
  pass "host+hook: a main-only close after a handled turn restores inherited handling and rewakes main"
}


test_main_only_close_after_handled_turn_delivers_restore_failure() {
  assert_main_only_close_after_handled_turn refuse
  pass "host+hook: a refused inherited handling restore delivers a failure instead of silent success"
}


test_returned_driver_is_caught_attended() {
  assert_returned_driver_is_caught attended
  pass "host+hook: a driver returning to an idle worker is stale-handled while attended"
}


test_returned_driver_is_caught_away() {
  assert_returned_driver_is_caught away
  pass "host+hook: a driver returning to an idle worker is stale-handled while away"
}


test_lost_boundary_handoff() { assert_lost_handoff_keeps_watching boundary; }

test_lost_pass_through_handoff() { assert_lost_handoff_keeps_watching pass-through; }


# A close that turns main-only at its turn hands back through the same opt-in
# path and must keep its pass-through row too. The hand-back stops the successor
# this turn confirmed, and the owner replaces that stopped arm within its poll,
# so the live-watcher check waits for it.
test_acknowledged_handoff_at_the_turn_keeps_the_pass_through_row() {
  local home
  home=$(make_primary_home hook-turns-main-only-ack)
  : > "$home/config/supervision-handoff-ack"
  turn_main_only_at_second_offer "$home"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "ack turns-main-only: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'step one'
  wait_until_deadline 60 hook_exited "$home" || fail "ack turns-main-only: the Stop hook never closed: $(cat "$home/state/.supervision-host.log")"
  [ "$(cat "$home/offer-count" 2>/dev/null)" -ge 2 ] || fail "fixture: the close was not accepted before it turned main-only"
  assert_rewoke_main "$home" "ack turns-main-only"
  [ -f "$home/state/.supervision-handoff-pending" ] || fail "ack turns-main-only: the close was not handed back for acknowledgement"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "ack turns-main-only: the hand-back dropped the pass-through row"
  wait_until 150 watcher_live "$home" || fail "ack turns-main-only: the hand-back left no watcher: $(cat "$home/state/.watch-cycle-exits.log")"
  stop_home_processes "$home"
  pass "host+hook: an acknowledged hand-back at the turn keeps its pass-through row"
}


# The transport fixture exercises the existing busy/composer/submit readers,
# not a Claude run: live continuation acceptance remains a documented limit.
test_handoff_retry_respects_the_receiving_pane() {
  local home doorbell record real_ps
  home=$(make_primary_home handoff-doorbell)
  real_ps=$(command -v ps)
  cat > "$home/fakebin/ps" <<SH
#!/usr/bin/env bash
if [ "\$1:\$2" = '-o:pgid=,tpgid=' ]; then
  if [ -f "\$FM_HOME/background-session" ]; then printf '77 88\\n'; else printf '77 77\\n'; fi
  exit 0
fi
exec "$real_ps" "\$@"
SH
  chmod +x "$home/fakebin/ps"
  : > "$home/config/supervision-handoff-ack"
  printf '❯ human draft\n' > "$home/screen"
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *'%77'*) ;; *) exit 1 ;; esac
case "$1:$*" in
  display-message:*'#{pane_pid}'*)
    if [ -f "$FM_HOME/foreign-pane" ]; then printf '999999\n'; else cat "$FM_HOME/state/.lock"; fi ;;
  display-message:*'#{cursor_y}'*) printf '0\n' ;;
  capture-pane:*) cat "$FM_HOME/screen" ;;
  send-keys:*) printf '%s\n' "$*" >> "$FM_HOME/submits" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$home/fakebin/tmux"
  TMUX_PANE=%77 FM_SUPERVISION_HANDOFF_RETRY_SECONDS=3 start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "doorbell: no initial watcher"
  append_status "$home" 'which export format?' needs-decision
  wait_until_deadline 60 hook_exited "$home" || fail "doorbell: no hand-back"
  wait_until 150 grep -q 'retry' "$home/state/.supervision-handoff.log" || fail "doorbell: no retry"
  [ ! -s "$home/submits" ] || fail "doorbell: retry overwrote human input"
  printf '❯ \n' > "$home/screen"
  : > "$home/foreign-pane"
  # Observe a complete new retry while the pane does not own this session.
  cp "$home/state/.supervision-handoff.log" "$home/retries-before"
  wait_until 150 bash -c '! cmp -s "$1/retries-before" "$1/state/.supervision-handoff.log"' _ "$home" \
    || fail "doorbell: no foreign-pane retry"
  [ ! -s "$home/submits" ] || fail "doorbell: retry reached another session's pane"
  rm "$home/foreign-pane"
  : > "$home/background-session"
  cp "$home/state/.supervision-handoff.log" "$home/retries-before"
  wait_until 150 bash -c '! cmp -s "$1/retries-before" "$1/state/.supervision-handoff.log"' _ "$home" \
    || fail "doorbell: no background-session retry"
  [ ! -s "$home/submits" ] || fail "doorbell: retry reached a different foreground conversation"
  rm "$home/background-session"
  wait_until 150 grep -q $'\tretry\t.*\tempty$' "$home/state/.supervision-handoff.log" \
    || fail "doorbell: the submit helper did not confirm the idle owning pane's retry"
  [ -s "$home/submits" ] || fail "doorbell: idle owning pane received no retry"
  assert_grep 'Enter' "$home/submits" "the retry must submit, not merely type"
  doorbell=$(grep -- '-l ' "$home/submits" | head -1)
  record=$(printf '%s\n' "$doorbell" | grep -o '/[^ ]*/operational-inbox/[^ ]*\.msg')
  [ -n "$record" ] && [ -f "$record" ] || fail "doorbell: no durable operational record"
  assert_grep 'watcher: check: supervision-handoff' "$record" "the retry must be operational watcher input"
  [ -f "$home/state/.supervision-handoff-pending" ] || fail "doorbell: submission was mistaken for acknowledgement"
  stop_home_processes "$home"
  pass "host+hook: hand-back retry submits only to the idle owning pane without replacing human input"
}


# The herdr transport twin of the tmux case above: the detached owner inherits
# HERDR_ENV/HERDR_PANE_ID/HERDR_SESSION from a Claude primary's pane and must
# reach that exact pane through the real herdr adapter - only after proving the
# pane's shell pid is an ancestor of the pinned session owner, the session is
# the pane's foreground group, the native agent state is not submit-busy, the
# rendered busy footer is idle, and the composer is empty. A typed draft, a
# foreign pane, a different foreground conversation, a working agent, or an
# unreachable server each defer without touching the queued check.
test_handoff_retry_reaches_the_receiving_herdr_pane() {
  local home doorbell record
  home=$(make_primary_home handoff-herdr-doorbell)
  : > "$home/config/supervision-handoff-ack"
  printf '❯ human draft\n' > "$home/screen"
  printf 'idle\n' > "$home/herdr-status"
  cat > "$home/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
lock_pid() { cat "$FM_HOME/state/.lock"; }
agent_status() { cat "$FM_HOME/herdr-status" 2>/dev/null || printf 'idle\n'; }
arg_value() { # <flag> <args...>
  local flag=$1
  shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "$flag" ]; then printf '%s\n' "$2"; return 0; fi
    shift
  done
  return 1
}
case "${1:-}" in
  status)
    if [ -e "$FM_HOME/server-down" ]; then printf '{"server":{"running":false}}\n'; else printf '{"server":{"running":true}}\n'; fi ;;
  agent)
    [ "${2:-}" = get ] || exit 1
    if [ -e "$FM_HOME/foreign-agent" ]; then label=pi; else label=claude; fi
    if [ -e "$FM_HOME/foreign-binding" ]; then binding=pi; else binding=claude; fi
    printf '{"result":{"agent":{"agent":"%s","agent_status":"%s","agent_session":{"agent":"%s"}}}}\n' "$label" "$(agent_status)" "$binding" ;;
  pane)
    case "${2:-}" in
      process-info)
        pane=$(arg_value --pane "$@") || exit 1
        if [ -e "$FM_HOME/foreign-pane" ]; then shell_pid=999999; else shell_pid=$(lock_pid); fi
        if [ -e "$FM_HOME/background-session" ]; then
          fg=999999
        else
          fg=$(ps -o pgid= -p "$(lock_pid)" 2>/dev/null | tr -d ' ')
        fi
        printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"claude","argv0":"claude"}]}}}\n' \
          "$pane" "$shell_pid" "$fg" "$(lock_pid)" ;;
      read) cat "$FM_HOME/screen" ;;
      send-text)
        # pane send-text <pane> <text> --session <s>
        shift 3
        text=$1
        printf 'send-text %s\n' "$text" >> "$FM_HOME/submits"
        printf '❯ %s\n' "$text" > "$FM_HOME/screen" ;;
      send-keys)
        # pane send-keys <pane> <key> --session <s>
        shift 3
        key=$1
        printf 'send-keys %s\n' "$key" >> "$FM_HOME/submits"
        case "$key" in
          enter)
            printf 'working\n' > "$FM_HOME/herdr-status"
            printf '❯ \n' > "$FM_HOME/screen" ;;
        esac ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
exit 0
SH
  chmod +x "$home/fakebin/herdr"
  HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SESSION=fm-lab-doorbell \
    FM_SUPERVISION_HANDOFF_RETRY_SECONDS=3 start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "herdr doorbell: no initial watcher"
  append_status "$home" 'which export format?' needs-decision
  wait_until_deadline 60 hook_exited "$home" || fail "herdr doorbell: no hand-back"
  wait_until 150 grep -q 'retry' "$home/state/.supervision-handoff.log" || fail "herdr doorbell: no retry"
  [ ! -s "$home/submits" ] || fail "herdr doorbell: retry overwrote human input"
  printf '❯ \n' > "$home/screen"
  : > "$home/foreign-pane"
  # Observe a complete new retry while the pane does not own this session.
  cp "$home/state/.supervision-handoff.log" "$home/retries-before"
  wait_until 150 bash -c '! cmp -s "$1/retries-before" "$1/state/.supervision-handoff.log"' _ "$home" \
    || fail "herdr doorbell: no foreign-pane retry"
  [ ! -s "$home/submits" ] || fail "herdr doorbell: retry reached another session's pane"
  rm "$home/foreign-pane"
  : > "$home/background-session"
  cp "$home/state/.supervision-handoff.log" "$home/retries-before"
  wait_until 150 bash -c '! cmp -s "$1/retries-before" "$1/state/.supervision-handoff.log"' _ "$home" \
    || fail "herdr doorbell: no background-session retry"
  [ ! -s "$home/submits" ] || fail "herdr doorbell: retry reached a different foreground conversation"
  rm "$home/background-session"
  : > "$home/foreign-agent"
  cp "$home/state/.supervision-handoff.log" "$home/retries-before"
  wait_until 150 bash -c '! cmp -s "$1/retries-before" "$1/state/.supervision-handoff.log"' _ "$home" \
    || fail "herdr doorbell: no foreign-agent retry"
  [ ! -s "$home/submits" ] || fail "herdr doorbell: retry reached a foreign registered agent"
  rm "$home/foreign-agent"
  # All other delivery conditions pass: Claude, native/rendered idle, empty
  # composer, and the pinned foreground owner. Only its binding is foreign.
  : > "$home/foreign-binding"
  cp "$home/state/.supervision-handoff.log" "$home/retries-before"
  wait_until 150 bash -c '! cmp -s "$1/retries-before" "$1/state/.supervision-handoff.log"' _ "$home" \
    || fail "herdr doorbell: no foreign-binding retry"
  [ ! -s "$home/submits" ] || fail "herdr doorbell: retry reached a foreign session binding"
  [ -f "$home/state/.supervision-handoff-pending" ] || fail "herdr doorbell: foreign binding consumed the pending check"
  rm "$home/foreign-binding"
  printf 'working\n' > "$home/herdr-status"
  cp "$home/state/.supervision-handoff.log" "$home/retries-before"
  wait_until 150 bash -c '! cmp -s "$1/retries-before" "$1/state/.supervision-handoff.log"' _ "$home" \
    || fail "herdr doorbell: no working-agent retry"
  [ ! -s "$home/submits" ] || fail "herdr doorbell: retry reached a busy agent"
  printf 'idle\n' > "$home/herdr-status"
  # Native status is idle and the composer is empty; only the rendered footer
  # says Claude is generating. The intent requires this independent veto.
  printf 'Thinking… (esc to interrupt)\n❯ \n' > "$home/screen"
  cp "$home/state/.supervision-handoff.log" "$home/retries-before"
  wait_until 150 bash -c '! cmp -s "$1/retries-before" "$1/state/.supervision-handoff.log"' _ "$home" \
    || fail "herdr doorbell: no rendered-busy retry"
  [ ! -s "$home/submits" ] || fail "herdr doorbell: retry reached a rendered-busy agent with native idle status"
  [ -f "$home/state/.supervision-handoff-pending" ] || fail "herdr doorbell: rendered busy consumed the pending check"
  printf '❯ \n' > "$home/screen"
  : > "$home/server-down"
  cp "$home/state/.supervision-handoff.log" "$home/retries-before"
  wait_until 150 bash -c '! cmp -s "$1/retries-before" "$1/state/.supervision-handoff.log"' _ "$home" \
    || fail "herdr doorbell: no server-down retry"
  [ ! -s "$home/submits" ] || fail "herdr doorbell: retry reached an unreadable pane"
  rm "$home/server-down"
  wait_until 150 grep -q $'\tretry\t.*\tempty$' "$home/state/.supervision-handoff.log" \
    || fail "herdr doorbell: the submit helper did not confirm the idle owning pane's retry"
  [ -s "$home/submits" ] || fail "herdr doorbell: idle owning pane received no retry"
  assert_grep 'enter' "$home/submits" "the retry must submit, not merely type"
  doorbell=$(grep 'send-text ' "$home/submits" | head -1)
  record=$(printf '%s\n' "$doorbell" | grep -o '/[^ ]*/operational-inbox/[^ ]*\.msg')
  [ -n "$record" ] && [ -f "$record" ] || fail "herdr doorbell: no durable operational record"
  assert_grep 'watcher: check: supervision-handoff' "$record" "the retry must be operational watcher input"
  [ -f "$home/state/.supervision-handoff-pending" ] || fail "herdr doorbell: submission was mistaken for acknowledgement"
  stop_home_processes "$home"
  pass "host+hook: hand-back retry submits only to the idle owning herdr pane without replacing human input"
}







# The live failure (2026-10-17): after the engine handled a routine wake, the
# host parked on the handling successor it started for that wake, and that
# successor never resurfaced a durable row appended later. Five captain inbox
# notes queued over half an hour reached the queue but woke no one until a
# stale close four hours later. A note queued while the host is parked on a
# handled wake's successor must rewake main.
test_claude_stop_hook_rewakes_main_for_an_inbox_note_after_a_handled_wake() {
  local home drained
  home=$(make_primary_home hook-inbox-after-handled)
  ln -s "$ROOT/.agents" "$home/.agents"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "inbox after handled: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'step one'
  wait_until 600 handled_at_least "$home" 1 \
    || fail "inbox after handled: the routine wake was not handled on the engine: $(cat "$home/state/.supervision-host.log")"
  wait_until 150 watcher_live "$home" || fail "inbox after handled: the host is not parked on a live successor"
  sleep 2
  hook_exited "$home" && fail "fixture: the handled routine wake reached main: $(cat "$home/hook.err")"
  FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" note "the captain sent this from Basecamp" >/dev/null \
    || fail "fixture: the inbox note was not saved and announced"
  assert_grep 'check: captain inbox note' "$home/state/.wake-queue" "fixture: the note queued no wake row"
  wait_until_deadline 60 hook_exited "$home" \
    || fail "inbox after handled: the queued inbox note never woke main: $(cat "$home/state/.supervision-host.log"; cat "$home/state/.watcher-down")"
  assert_rewoke_main "$home" "inbox after handled"
  assert_re '^check: rearm-resurface' "$home/hook.err" "the rewake must carry the recovery close for the queued note"
  [ "$(handled_count "$home")" -eq 1 ] || fail "inbox after handled: the engine took the main-only inbox close"
  drained=$(main_drain "$home")
  assert_contains "$drained" 'check: captain inbox note' "main's drain must present the queued inbox note"
  pass "host+hook: an inbox note queued while the host is parked on a handled wake's successor rewakes main"
}



# Opt-in on every primary, Claude included (docs/supervision-host.md): through
# the real Stop hook, a Claude primary home with no config/supervision-host
# runs the plain watcher arm, mirrors nothing, and every wake reaches main as
# the arm printed it; a home with config/supervision-host-off does the same.
test_claude_stop_hook_without_the_opt_in_runs_the_plain_arm_and_off_keeps_it() {
  local home
  home=$(make_primary_home hook-no-opt-in)
  ln -s "$ROOT/.agents" "$home/.agents"
  rm -f "$home/config/supervision-host"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "no opt-in: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'step one'
  wait_until_deadline 60 hook_exited "$home" || fail "no opt-in: the Stop hook never closed"
  assert_rewoke_main "$home" "no opt-in"
  assert_re '^signal: .*demo.status' "$home/hook.err" "no opt-in: the rewake must carry the arm's close"
  assert_no_re '^supervision-host' "$home/hook.err" "no opt-in: the close must reach main exactly as the arm printed it"
  assert_absent "$home/state/.supervision-host.log" "a Claude home without config/supervision-host must never run the host"
  assert_absent "$home/state/.host-mirror.jsonl" "a Claude home without config/supervision-host must mirror nothing"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "a Claude home without config/supervision-host ran an engine turn"
  : > "$home/session.stop"
  stop_home_processes "$home"

  home=$(make_primary_home hook-opted-out)
  : > "$home/config/supervision-host-off"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "off: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'step one'
  wait_until_deadline 60 hook_exited "$home" || fail "off: the Stop hook never closed"
  assert_rewoke_main "$home" "off"
  assert_re '^signal: .*demo.status' "$home/hook.err" "off: the rewake must carry the arm's close"
  assert_no_re '^supervision-host' "$home/hook.err" "off: the close must reach main exactly as the arm printed it"
  assert_absent "$home/state/.supervision-host.log" "a home opted out by config/supervision-host-off must never run the host"
  assert_absent "$home/state/.host-mirror.jsonl" "a home opted out by config/supervision-host-off must mirror nothing"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "a home opted out by config/supervision-host-off ran an engine turn"
  : > "$home/session.stop"
  stop_home_processes "$home"
  pass "host+hook: a Claude home without config/supervision-host runs the plain arm (opt-in), and an off file keeps it"
}









fm_test_run \
  test_main_only_close_after_handled_turn_restores_inherited_handling \
  test_main_only_close_after_handled_turn_delivers_restore_failure \
  test_returned_driver_is_caught_attended \
  test_returned_driver_is_caught_away \
  test_lost_boundary_handoff \
  test_lost_pass_through_handoff \
  test_acknowledged_handoff_at_the_turn_keeps_the_pass_through_row \
  test_handoff_retry_respects_the_receiving_pane \
  test_handoff_retry_reaches_the_receiving_herdr_pane \
  test_claude_stop_hook_rewakes_main_for_an_inbox_note_after_a_handled_wake \
  test_claude_stop_hook_without_the_opt_in_runs_the_plain_arm_and_off_keeps_it \
