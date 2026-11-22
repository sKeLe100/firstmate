# tests/fm-watch-triage.test.sh - the classifier predicates and the watcher's
# triage of signals, stale panes, gone endpoints, cleanup, busy turns, and
# declared-wait churn, from the cases in tests/fm-watch-triage-lib.sh. Wedge
# deferrals, captain holds, process-event results, heartbeats, away mode, and the
# exit picker run in tests/fm-watch-triage-waits.test.sh.
set -u

# shellcheck source=tests/fm-watch-triage-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-watch-triage-lib.sh"

test_afk_heartbeat_preserves_idle_accounting() {
  local dir state fakebin out pid
  dir=$(make_case afk-heartbeat); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  date '+%s' > "$state/.afk"
  printf '3\n' > "$state/.heartbeat-streak"
  touch "$state/.last-heartbeat"
  set_mtime "$(( $(date +%s) - 30 ))" "$state/.last-heartbeat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "away-mode heartbeat did not hand off to daemon triage"
  [ "$(cat "$state/.heartbeat-streak")" = 4 ] || fail "away-mode heartbeat did not preserve idle backoff accounting"
  awk -F '\t' '$3 == "heartbeat" && $4 == "heartbeat" { found=1 } END { exit !found }' \
    "$state/.wake-queue" || fail "away-mode heartbeat did not enqueue a heartbeat wake"
  grep -Fx heartbeat "$out" >/dev/null || fail "away-mode heartbeat lost its transport wake reason"
  pass "away-mode heartbeat keeps daemon triage and idle backoff accounting"
}

test_colliding_endpoints_keep_independent_stale_history() (
  unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
  unset FM_WATCH_HANDLING_SUCCESSOR FM_WATCH_DELIVERED_REASON FM_FAKE_CREW_STATE
  unset FM_FAKE_TMUX_WINDOWS FM_FAKE_TMUX_WINDOW FM_FAKE_TMUX_CAPTURE
  local dir state fakebin out pid round endpoint key first_key second_key marker
  dir=$(make_case independent-window-keys); state="$dir/state"; fakebin="$dir/fakebin"
  mkdir -p "$dir/config" "$dir/data"
  out="$dir/watch.out"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows) printf 'a.b\na_b\n' ;;
  capture-pane)
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -t ]; then printf 'quiet pane for %s' "$2"; exit 0; fi
      shift
    done
    exit 1 ;;
  display-message) printf 'bash\n' ;;
  *) exit 1 ;;
esac
SH
  printf 'window=s:a.b\nkind=ship\nharness=codex\n' > "$state/first.meta"
  printf 'window=s:a_b\nkind=ship\nharness=codex\n' > "$state/second.meta"
  # Conflicting legacy memory must neither suppress a fresh stale nor become
  # churn evidence when a sibling is added or removed.
  for marker in hash stale; do
    printf '%s' "$(hash_text 'quiet pane for s:a.b')" > "$state/.$marker-s_a_b"
  done
  printf '99\n' > "$state/.count-s_a_b"
  for round in first second; do
    # Each child gets its own home and handles the fixture's acknowledged cycles.
    watch_bg "$state" "$fakebin" "$out" env FM_HOME="$dir" \
      FM_CONFIG_OVERRIDE="$dir/config" FM_WATCH_HANDLING_SUCCESSOR=1
    pid=$!
    if ! wait_for_exit "$pid" 150; then
      reap "$pid"
      fail "colliding endpoints never independently went stale in round $round"
    fi
    endpoint=s:a.b
    [ "$round" != second ] || endpoint=s:a_b
    grep -F "stale: $endpoint" "$out" >/dev/null \
      || fail "round $round did not wake for $endpoint"
    [ "$(wedge_stale_wakes "$state" "$endpoint")" -eq 1 ] \
      || fail "$endpoint did not queue exactly one independent stale wake"
    FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" ack_stopped_cycle "$state" \
      || fail "could not acknowledge round $round"
  done
  first_key=$(watch_window_key s:a.b); second_key=$(watch_window_key s:a_b)
  [ "$first_key" != "$second_key" ] || fail "colliding legacy spellings still share a key"
  for endpoint in s:a.b s:a_b; do
    key=$(watch_window_key "$endpoint")
    [ "$(cat "$state/.hash-$key")" = "$(hash_text "quiet pane for $endpoint")" ] \
      || fail "$endpoint lost its pane history"
    [ "$(cat "$state/.count-$key")" -ge 2 ] || fail "$endpoint did not accumulate stable polls"
    [ "$(cat "$state/.stale-$key")" = "$(cat "$state/.hash-$key")" ] \
      || fail "$endpoint lost its stale suppressor"
  done
  mv "$state/second.meta" "$dir/second.meta"
  [ "$(watch_window_key s:a.b)" = "$first_key" ] || fail "removing sibling changed identity"
  watch_bg "$state" "$fakebin" "$out" env FM_HOME="$dir" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_WATCH_HANDLING_SUCCESSOR=1
  pid=$!
  wait_poll_cycle "$state" "$pid" || fail "remaining endpoint reawakened after sibling removal"
  reap "$pid"
  mv "$dir/second.meta" "$state/second.meta"
  [ "$(watch_window_key s:a.b)" = "$first_key" ] || fail "adding sibling changed identity"
  watch_bg "$state" "$fakebin" "$out" env FM_HOME="$dir" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_WATCH_HANDLING_SUCCESSOR=1
  pid=$!
  wait_poll_cycle "$state" "$pid" || fail "restored sibling woke: $(cat "$out")"
  reap "$pid"
  [ "$(cat "$state/.count-s_a_b")" = 99 ] || fail "legacy memory was reused"
  pass "legacy-colliding endpoints wake independently and never revert to legacy memory"
)

test_long_endpoint_keeps_stale_history() (
  unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
  unset FM_WATCH_HANDLING_SUCCESSOR FM_WATCH_DELIVERED_REASON FM_FAKE_CREW_STATE
  unset FM_FAKE_TMUX_WINDOWS FM_FAKE_TMUX_WINDOW FM_FAKE_TMUX_CAPTURE
  local dir state fakebin out session task window key capture_file pid marker
  local LC_ALL=C
  dir=$(make_case long-window-key); state="$dir/state"; fakebin="$dir/fakebin"
  mkdir -p "$dir/config" "$dir/data"
  session=$(printf '%180s' '' | tr ' ' s)
  task=$(printf '%64s' '' | tr ' ' t)
  window="$session:fm-$task"
  [ "${#window}" -eq 248 ] || fail "long endpoint fixture has the wrong byte length"
  key=$(watch_window_key "$window")
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  printf 'quiet long-endpoint pane\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/$task.meta"
  watch_bg "$state" "$fakebin" "$out" env FM_HOME="$dir" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_WATCH_HANDLING_SUCCESSOR=1 FM_FAKE_TMUX_WINDOW="$window" \
    FM_FAKE_TMUX_CAPTURE="$capture_file" 2> "$dir/watch.err"
  pid=$!
  if ! wait_for_exit "$pid" 150; then
    reap "$pid"
    fail "long endpoint never produced a stale wake: $(sed -n '1,3p' "$dir/watch.err")"
  fi
  grep -Fx "stale: $window" "$out" >/dev/null || fail "long endpoint stale was not surfaced"
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 1 ] || fail "long endpoint stale was not queued"
  for marker in ".hash-$key" ".count-$key" ".stale-$key"; do
    [ "${#marker}" -le 255 ] || fail "watcher marker exceeds 255 bytes"
    [ -s "$state/$marker" ] || fail "long endpoint lost $marker"
  done
  [ "$(cat "$state/.hash-$key")" = "$(hash_text "$(cat "$capture_file")")" ] \
    || fail "long endpoint lost its pane history"
  [ "$(cat "$state/.count-$key")" -ge 2 ] || fail "long endpoint did not accumulate stable polls"
  [ "$(cat "$state/.stale-$key")" = "$(cat "$state/.hash-$key")" ] \
    || fail "long endpoint lost its stale suppressor"
  FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" ack_stopped_cycle "$state" \
    || fail "could not acknowledge long endpoint stale"
  pass "a 180-byte session and 64-byte task retain bounded markers and produce a stale wake"
)

test_pi_model_progress_and_legacy_fallback() {
  local dir state fakebin out capture_file window key gen pid mode enabled
  for mode in enabled disabled stale malformed closed replaced; do
    dir=$(make_case "pi-anchor-$mode"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-anchor-$mode"
    key=$(watch_window_key "$window")
    printf 'Working...' > "$capture_file"
    printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/stream.meta"
    record_pi_busy "$state" stream
    gen=$(cat "$state/stream.busy-gen")
    "$ROOT/bin/fm-busy-event.sh" stream "$state" stream open --gen "$gen" --request 1
    if [ "$mode" != closed ] && [ "$mode" != replaced ]; then
      "$ROOT/bin/fm-busy-event.sh" stream "$state" stream progress --gen "$gen" --request 1
      "$ROOT/bin/fm-busy-event.sh" stream "$state" stream close --gen "$gen" --request 1
    else
      printf 'v1 gen=%s request=1 rev=1 ts=%s\n' "$gen" "$(( $(date +%s) - 600 ))" > "$state/stream.model-stream"
    fi
    case "$mode" in
      stale) printf 'v1 gen=obsolete request=1 rev=1 ts=%s\n' "$(date +%s)" > "$state/stream.model-progress" ;;
      malformed) printf 'invalid\n' > "$state/stream.model-progress" ;;
    esac
    touch -t 200001010000 "$state/stream.meta"
    printf 'working: setup complete\n' > "$state/stream.status"
    seen_sig "$state/stream.status" > "$state/.seen-stream_status"
    enabled=300
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_STREAM_SILENT_MAX_SECS=300 FM_BUSY_TURN_MAX_SECS=60 \
      FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$WATCH" > "$out" &
    pid=$!
    wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "anchor $mode escalated early"; }
    if [ "$mode" = enabled ] || [ "$mode" = disabled ]; then
      [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "recent model progress did not postpone legacy bound"; }
    else
      [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "anchor $mode failed to start timer"; }
    fi
    reap "$pid"
    ack_stopped_cycle "$state" || fail "anchor stop acknowledgement failed"
    case "$mode" in
      enabled) continue ;;
      disabled) enabled=0 ;;
      closed) "$ROOT/bin/fm-busy-event.sh" stream "$state" stream close --gen "$gen" --request 1 ;;
      replaced) "$ROOT/bin/fm-busy-event.sh" stream "$state" stream open --gen "$gen" --request 2 ;;
    esac
    # Aged past the fork's 3600s exponential-backoff ceiling: the seeded count of 7 backs the ladder off to it.
    echo $(( $(date +%s) - 4000 )) > "$state/.stale-since-$key"
    echo 7 > "$state/.wedge-escalations-$key"
    if [ "$mode" = closed ] || [ "$mode" = replaced ]; then
      date +%s > "$state/.wedge-permanent-$key"
      date +%s > "$state/.wedge-terminal-queued-$key"
    fi
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_STREAM_SILENT_MAX_SECS="$enabled" FM_BUSY_TURN_MAX_SECS=60 \
      FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$WATCH" > "$out" &
    pid=$!
    if [ "$mode" = closed ] || [ "$mode" = replaced ]; then
      wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "$mode inherited obsolete stream timer: $(cat "$out")"; }
      [ "$(cat "$state/.stale-since-$key")" -gt "$(( $(date +%s) - 100 ))" ] || { reap "$pid"; fail "$mode timer not reset"; }
      [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "$mode inherited stream escalation count"; }
      [ ! -e "$state/.wedge-permanent-$key" ] && [ ! -e "$state/.wedge-terminal-queued-$key" ] || { reap "$pid"; fail "$mode retained old stream cap markers"; }
      reap "$pid"
    else
      wait_for_exit "$pid" 100 || { reap "$pid"; fail "$mode legacy bound did not inspect"; }
      grep -F 'possible wedge' "$out" >/dev/null || fail "$mode missing legacy inspection"
      if grep -F 'model stream silent' "$out" >/dev/null; then fail "$mode used obsolete stream reason"; fi
    fi
  done
  pass "model progress extends only opted-in bounds and obsolete stream episodes reset before legacy fallback"
}

test_pi_stream_counter_write_failures() {
  local mode dir state fakebin out capture_file window key gen pid cap status real_rm queue_before
  for mode in uncapped post_append terminal truncation; do
    dir=$(make_case "pi-counter-$mode"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-counter-$mode"
    key=$(watch_window_key "$window")
    printf 'Working...' > "$capture_file"
    printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/stream.meta"
    record_pi_busy "$state" stream
    gen=$(cat "$state/stream.busy-gen")
    "$ROOT/bin/fm-busy-event.sh" stream "$state" stream open --gen "$gen" --request 1
    printf 'v1 gen=%s request=1 rev=1 ts=%s\n' "$gen" "$(( $(date +%s) - 600 ))" > "$state/stream.model-stream"
    printf 'working: setup complete\n' > "$state/stream.status"
    seen_sig "$state/stream.status" > "$state/.seen-stream_status"
    cap=1
    case "$mode" in uncapped) cap=0 ;; post_append) cap=2 ;; esac
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_STREAM_SILENT_MAX_SECS=300 FM_BUSY_TURN_MAX_SECS=99999 \
      FM_WEDGE_MAX_ESCALATIONS="$cap" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$WATCH" > "$out" &
    pid=$!
    wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "$mode admission failed"; }
    reap "$pid"
    ack_stopped_cycle "$state" || fail "$mode admission acknowledgement failed"
    if [ "$mode" = truncation ]; then
      real_rm=$(command -v rm)
      cat > "$fakebin/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "$state/.stale-since-$key" ] && [ -e "$state/.wedge-permanent-$key" ]; then
    "$real_rm" -f "$state/.wedge-escalations-$key"
    mkdir -p "$state/.wedge-escalations-$key"
    touch "$dir/fault-fired"
  fi
done
exec "$real_rm" "\$@"
SH
      chmod +x "$fakebin/rm"
    else
      mkdir "$state/.wedge-escalations-$key"
    fi
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_STREAM_SILENT_MAX_SECS=300 FM_BUSY_TURN_MAX_SECS=99999 \
      FM_WEDGE_MAX_ESCALATIONS="$cap" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$WATCH" > "$out" &
    pid=$!
    status=0
    wait_for_exit "$pid" 100 || status=$?
    [ -d "$state/.wedge-escalations-$key" ] || fail "$mode counter write fault was not exercised"
    [ "$(awk -F '\t' '$3 == "stale" { n++ } END { print n+0 }' "$state/.wake-queue")" -eq 1 ] || fail "$mode lost or duplicated its published notification"
    grep -F 'model stream silent for' "$state/.wake-queue" >/dev/null || fail "$mode did not exercise the stream publication route"
    case "$mode" in
      terminal|truncation) grep -F PERMANENTLY-WEDGED "$state/.wake-queue" >/dev/null || fail "$mode did not publish the terminal row" ;;
      *) grep -F 'possible wedge' "$state/.wake-queue" >/dev/null || fail "$mode did not publish the regular escalation" ;;
    esac
    if [ "$mode" = uncapped ]; then
      [ "$status" -eq 0 ] || fail "uncapped write failure stopped delivery with status $status"
      grep -F 'escalation 1' "$out" >/dev/null || fail "uncapped write failure suppressed escalation"
      grep -F 'escalation counter write FAILED' "$state/.watch-triage.log" >/dev/null || fail "uncapped write failure was not reported"
      [ ! -e "$state/.wedge-rollback-failed-$key" ] && [ ! -e "$state/.wedge-permanent-$key" ] || fail "uncapped write failure installed suppression"
    else
      [ "$status" -eq 1 ] || fail "$mode expected controlled exit 1, got $status"
      [ -s "$state/.wedge-rollback-failed-$key" ] && [ -s "$state/.stale-since-$key" ] || fail "$mode did not roll back and publish its sentinel"
      [ ! -s "$out" ] || fail "$mode delivered inline after its failed count write"
      if [ "$mode" = truncation ]; then
        [ -e "$dir/fault-fired" ] && [ -s "$state/.wedge-permanent-$key" ] || fail "cap-fire truncation was not reached"
        grep -F 'reset FAILED AND rollback ALSO FAILED' "$state/.watch-triage.log" >/dev/null || fail "truncation failure missed rollback defense"
      else
        [ ! -e "$state/.wedge-permanent-$key" ] || fail "$mode committed a cap after its count write failed"
        grep -F 'escalation counter write FAILED' "$state/.watch-triage.log" >/dev/null || fail "$mode failure missed count defense"
      fi
    fi
    ack_stopped_cycle "$state" || fail "$mode fault acknowledgement failed"
    queue_before=$(cat "$state/.wake-queue" 2>/dev/null || true)
    if [ "$mode" = uncapped ]; then
      "$ROOT/bin/fm-busy-event.sh" stream "$state" stream close --gen "$gen" --request 1
    fi
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_STREAM_SILENT_MAX_SECS=300 FM_BUSY_TURN_MAX_SECS=99999 \
      FM_WEDGE_MAX_ESCALATIONS="$cap" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$WATCH" > "$out" &
    pid=$!
    wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "$mode failed to continue safely after count failure"; }
    [ ! -s "$out" ] && [ "$(cat "$state/.wake-queue" 2>/dev/null || true)" = "$queue_before" ] || { reap "$pid"; fail "$mode republished a failed or obsolete episode"; }
    if [ "$mode" != uncapped ]; then
      [ -s "$state/.wedge-rollback-failed-$key" ] || { reap "$pid"; fail "$mode retry consumed its sentinel"; }
      grep -F 'rollback-failed sentinel active' "$state/.watch-triage.log" >/dev/null || { reap "$pid"; fail "$mode retry did not exercise sentinel suppression"; }
    fi
    reap "$pid"
  done
  pass "stream count writes and cap truncation defend failures while uncapped delivery continues"
}

test_pi_stream_publication_lock_revalidation() {
  local dir state fakebin out capture_file window key gen pid lock_kind action lock real_mkdir real_cat
  local uninterrupted=${1:-0} terminal=${2:-0}
  for lock_kind in queue recovery; do
    for action in close progress replace; do
      dir=$(make_case "pi-publication-$uninterrupted-terminal-$terminal-$lock_kind-$action"); state="$dir/state"; fakebin="$dir/fakebin"
      out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-publication-$lock_kind-$action"
      key=$(watch_window_key "$window")
      printf 'Working...' > "$capture_file"
      printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/stream.meta"
      record_pi_busy "$state" stream
      gen=$(cat "$state/stream.busy-gen")
      "$ROOT/bin/fm-busy-event.sh" stream "$state" stream open --gen "$gen" --request 1
      printf 'v1 gen=%s request=1 rev=1 ts=%s\n' "$gen" "$(( $(date +%s) - 600 ))" > "$state/stream.model-stream"
      printf 'working: setup complete\n' > "$state/stream.status"
      seen_sig "$state/stream.status" > "$state/.seen-stream_status"
      PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
        FM_STATE_OVERRIDE="$state" FM_STREAM_SILENT_MAX_SECS=300 FM_BUSY_TURN_MAX_SECS=99999 \
        FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
        "$WATCH" > "$out" &
      pid=$!
      wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "publication admission failed"; }
      if [ "$uninterrupted" -eq 0 ]; then
        reap "$pid"
        ack_stopped_cycle "$state" || fail "publication stop acknowledgement failed"
      else
        [ ! -e "$state/.watcher-down" ] || { reap "$pid"; fail "fresh watcher unexpectedly has recovery marker"; }
      fi
      lock="$state/.wake-queue.lock"
      [ "$lock_kind" != recovery ] || lock="$state/.watcher-down.lock"
      real_mkdir=$(command -v mkdir)
      real_cat=$(command -v cat)
      cat > "$fakebin/cat" <<SH
#!/usr/bin/env bash
if [ "\${!#}" = "$lock/pid" ] && [ -d "$lock" ]; then printf '1\n' > "$dir/append-blocked"; fi
exec "$real_cat" "\$@"
SH
      chmod +x "$fakebin/cat"
      mv "$fakebin/tmux" "$fakebin/tmux-base"
      cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = display-message ]; then
  if [ ! -e "$dir/lock-created" ]; then
    cat "$state/.watcher-down" > "$dir/prior-recovery" 2>/dev/null || : > "$dir/prior-recovery"
    "$real_mkdir" "$lock"
    printf '%s\n' '$$' > "$lock/pid"
    touch "$dir/lock-created"
  fi
  exit 1
fi
exec "$fakebin/tmux-base" "\$@"
SH
      chmod +x "$fakebin/tmux"
      if [ "$terminal" -eq 1 ]; then
        printf "1\n" > "$state/.wedge-escalations-$key"
      fi
      echo $(( $(date +%s) - 1500 )) > "$state/.stale-since-$key"
      if [ "$uninterrupted" -eq 0 ]; then
        PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
        FM_STATE_OVERRIDE="$state" FM_STREAM_SILENT_MAX_SECS=300 FM_BUSY_TURN_MAX_SECS=99999 \
        FM_WEDGE_MAX_ESCALATIONS="$terminal" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
        "$WATCH" > "$out" &
        pid=$!
      fi
      wait_numeric_file "$dir/append-blocked" 100 || { reap "$pid"; fail "$lock_kind publication wait not exercised"; }
      date +%s > "$state/.wedge-permanent-$key"
      date +%s > "$state/.wedge-terminal-queued-$key"
      case "$action" in
        close) "$ROOT/bin/fm-busy-event.sh" stream "$state" stream close --gen "$gen" --request 1 ;;
        progress) "$ROOT/bin/fm-busy-event.sh" stream "$state" stream progress --gen "$gen" --request 1 ;;
        replace) "$ROOT/bin/fm-busy-event.sh" stream "$state" stream open --gen "$gen" --request 2 ;;
      esac
      rm -f "$lock/pid"
      rmdir "$lock"
      wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "$lock_kind/$action published obsolete inspection: $(cat "$out")"; }
      [ ! -s "$out" ] && [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "obsolete publication survived lock wait"; }
      [ ! -e "$state/.stale-since-$key" ] && [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "rejected publication retained escalation"; }
      [ "$(cat "$state/.watcher-down" 2>/dev/null || true)" = "$(cat "$dir/prior-recovery")" ] || { reap "$pid"; fail "$lock_kind/$action rejected append changed prior recovery marker"; }
      [ ! -e "$state/.wedge-permanent-$key" ] && [ ! -e "$state/.wedge-terminal-queued-$key" ] || { reap "$pid"; fail "obsolete terminal append retained cap"; }
      reap "$pid"
    done
  done
  pass "stream close, progress, and replacement cancel publication after queue and recovery lock waits"
}

test_pi_stream_resume_restarts_capped_episode() {
  local dir state fakebin out capture_file window key gen pid round snapshot
  dir=$(make_case pi-stream-restall); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window=test:fm-stream-restall
  key=$(watch_window_key "$window")
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/stream.meta"
  record_pi_busy "$state" stream
  gen=$(cat "$state/stream.busy-gen")
  "$ROOT/bin/fm-busy-event.sh" stream "$state" stream open --gen "$gen" --request 1
  printf 'working: setup complete\n' > "$state/stream.status"
  seen_sig "$state/stream.status" > "$state/.seen-stream_status"
  for round in first resumed; do
    if [ "$round" = resumed ]; then
      "$ROOT/bin/fm-busy-event.sh" stream "$state" stream progress --gen "$gen" --request 1
    fi
    snapshot=$(cat "$state/stream.model-stream")
    printf '%s ts=%s\n' "${snapshot% ts=*}" "$(( $(date +%s) - 600 ))" > "$state/stream.model-stream"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_STREAM_SILENT_MAX_SECS=300 FM_BUSY_TURN_MAX_SECS=99999 \
      FM_WEDGE_MAX_ESCALATIONS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$WATCH" > "$out" &
    pid=$!
    wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "$round stream did not start a new inspection timer"; }
    [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "$round stream missing inspection timer"; }
    [ ! -e "$state/.wedge-permanent-$key" ] && [ ! -e "$state/.wedge-terminal-queued-$key" ] || { reap "$pid"; fail "$round stream inherited prior cap"; }
    reap "$pid"
    ack_stopped_cycle "$state" || fail "$round admission acknowledgement failed"
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_STREAM_SILENT_MAX_SECS=300 FM_BUSY_TURN_MAX_SECS=99999 \
      FM_WEDGE_MAX_ESCALATIONS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 100 || { reap "$pid"; fail "$round stream did not reach cap"; }
    grep -F PERMANENTLY-WEDGED "$out" >/dev/null || fail "$round stream missing terminal notification"
    [ -s "$state/.wedge-permanent-$key" ] && [ -s "$state/.wedge-terminal-queued-$key" ] || fail "$round stream missing cap markers"
    ack_stopped_cycle "$state" || fail "$round cap acknowledgement failed"
  done
  pass "a capped stream that resumes and stalls before rearming starts a fresh episode"
}

test_pi_stream_silence_uses_inspection_timer() {
  local dir state fakebin out capture_file window key gen snapshot pid mode enabled
  for mode in enabled disabled negative invalid_option leading maximum overflow closed foreign fresh malformed stale resumed racing; do
    dir=$(make_case "pi-stream-$mode"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-stream-$mode"
    key=$(watch_window_key "$window")
    printf 'Working...' > "$capture_file"
    printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/stream.meta"
    record_pi_busy "$state" stream
    gen=$(cat "$state/stream.busy-gen")
    "$ROOT/bin/fm-busy-event.sh" stream "$state" stream open --gen "$gen" --request 1
    # Backdate the owned protocol fixture, not production source or a UI guess.
    snapshot="v1 gen=$gen request=1 rev=1 ts=$(( $(date +%s) - 600 ))"
    printf '%s\n' "$snapshot" > "$state/stream.model-stream"
    printf 'working: setup complete\n' > "$state/stream.status"
    seen_sig "$state/stream.status" > "$state/.seen-stream_status"
    enabled=300
    case "$mode" in
      disabled) enabled=0 ;;
      negative) enabled=-1 ;;
      invalid_option) enabled=invalid ;;
      leading) enabled=00300 ;;
      maximum) enabled=999999999 ;;
      overflow) enabled=1000000000 ;;
      closed) "$ROOT/bin/fm-busy-event.sh" stream "$state" stream close --gen "$gen" --request 1 ;;
      foreign) printf 'window=%s\nkind=ship\nharness=claude\n' "$window" > "$state/stream.meta"
               "$ROOT/bin/fm-busy-event.sh" apply "$state" stream busy --gen "$gen" --source claude-hook --event start ;;
      fresh) "$ROOT/bin/fm-busy-event.sh" stream "$state" stream progress --gen "$gen" --request 1 ;;
      malformed) printf 'malformed\n' > "$state/stream.model-stream" ;;
      stale) record_pi_busy "$state" stream
             printf '%s\n' "$snapshot" > "$state/stream.model-stream" ;;
    esac
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_STREAM_SILENT_MAX_SECS="$enabled" FM_BUSY_TURN_MAX_SECS=99999 \
      FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$WATCH" > "$out" &
    pid=$!
    wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "stream case $mode surfaced before inspection delay: $(cat "$out")"; }
    if [ "$mode" = enabled ] || [ "$mode" = leading ] || [ "$mode" = resumed ] || [ "$mode" = racing ]; then
      [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "expired stream did not enter inspection timer"; }
    else
      [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "$mode stream started inspection timer"; }
    fi
    reap "$pid"
    if [ "$mode" = enabled ] || [ "$mode" = resumed ] || [ "$mode" = racing ]; then
      ack_stopped_cycle "$state" || fail "cannot acknowledge test stop"
      echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
      printf 'Working... next tick' > "$capture_file"
      if [ "$mode" = resumed ]; then
        "$ROOT/bin/fm-busy-event.sh" stream "$state" stream progress --gen "$gen" --request 1
      elif [ "$mode" = racing ]; then
        # The recovery-grade endpoint read runs inside the escalation path.
        # Close the request there to exercise the final evidence revalidation.
        mv "$fakebin/tmux" "$fakebin/tmux-base"
        cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = display-message ]; then
  date +%s > "$state/.wedge-permanent-$key"
  date +%s > "$state/.wedge-terminal-queued-$key"
  "$ROOT/bin/fm-busy-event.sh" stream "$state" stream close --gen "$gen" --request 1
  touch "$dir/race-fired"
  exit 1
fi
exec "$fakebin/tmux-base" "\$@"
SH
        chmod +x "$fakebin/tmux"
      fi
      PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
        FM_STATE_OVERRIDE="$state" FM_STREAM_SILENT_MAX_SECS=300 FM_BUSY_TURN_MAX_SECS=99999 \
        FM_WEDGE_MAX_ESCALATIONS=0 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
        "$WATCH" > "$out" &
      pid=$!
      if [ "$mode" = enabled ]; then
        wait_for_exit "$pid" 100 || { reap "$pid"; fail "expired stream never surfaced"; }
        grep -F 'model stream silent for' "$out" >/dev/null || fail "stream reason missing: $(cat "$out")"
        grep -F 'possible wedge' "$out" >/dev/null || fail "stream bypassed inspection reason"
      else
        wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "$mode request published obsolete stream inspection: $(cat "$out")"; }
        [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "$mode request retained obsolete timer"; }
        [ ! -s "$out" ] || { reap "$pid"; fail "$mode request produced a wake"; }
        if [ "$mode" = racing ]; then
          [ -e "$dir/race-fired" ] && [ ! -e "$state/stream.model-stream" ] || { reap "$pid"; fail "notification-time close was not exercised"; }
        fi
        [ ! -e "$state/.wedge-permanent-$key" ] && [ ! -e "$state/.wedge-terminal-queued-$key" ] || { reap "$pid"; fail "$mode retained old cap markers"; }
        reap "$pid"
      fi
    fi
  done
  pass "opted-in current stream silence uses inspection delay across changing panes; disabled, tool, and foreign phases do not"
}

test_pi_stream_terminal_publication() {
  test_pi_stream_publication_lock_revalidation 0 1
}

test_pi_stream_uninterrupted_publication() {
  test_pi_stream_publication_lock_revalidation 1
}

test_window_keys_encode_supported_endpoint_bytes() {
  local endpoint key keys='' prior
  for endpoint in 's:a.b' 's:a_b' 's:a/b' 's:a:b' 's:a%2fb' 's:a%2eb' \
    's:a%25b' 's:a%b' 's:a-b' 's:a b' 's:a!b' 's:船.员' 's:船_员'; do
    key=$(watch_window_key "$endpoint")
    case "$key" in
      */*|'') fail "endpoint key is not a filename suffix: $endpoint" ;;
    esac
    # Legacy normalization strips every dot, so a dot proves a disjoint namespace.
    case "$key" in *.*) ;; *) fail "endpoint key can alias legacy evidence: $endpoint" ;; esac
    while IFS= read -r prior; do
      [ "$key" != "$prior" ] || fail "endpoint bytes collided: $endpoint"
    done <<EOF
$keys
EOF
    keys="${keys}${key}
"
    [ "$(watch_window_key "$endpoint")" = "$key" ] || fail "endpoint key was unstable"
  done
  pass "punctuation, percent escapes and Unicode have distinct stable filename keys"
}


test_status_span_actionable_classifier
test_status_span_survives_a_later_routine_append
test_status_span_respects_decision_closure
test_status_span_closure_from_an_offset
test_malformed_seen_signature_reads_the_whole_log
test_stale_is_terminal_classifier
test_classifier_primitives
test_unrecognized_status_prefix_is_visible
test_crew_is_provably_working_classifier
test_status_is_paused_classifier
test_crew_absorb_class_classifier
test_crew_worktree_written_since_classifier
test_empty_write_prune_widens_the_probe
test_empty_write_prune_from_the_environment_widens_the_probe
test_worktree_write_probe_is_wall_clock_bounded
test_signal_crew_provably_working_classifier
test_secondmate_status_routine_absorbed_routed_surfaced_classifier
test_provably_working_signal_absorbed
test_benign_absorb_marker_is_presentation_record
test_covered_status_absorbs_beside_benign_sibling
test_afk_procevent_covered_signal_queued_not_absorbed
test_turn_ended_provably_working_absorbed
test_turn_ended_not_working_surfaced
test_turn_ended_churning_pane_absorbed
test_turn_ended_churn_resets_prior_stale_classification
test_fresh_watcher_seeds_idle_clock_from_stop_record
test_first_observation_seed_survives_failed_first_capture
test_churned_pane_ignores_old_stop_record_for_idle_clock
test_turn_ended_churn_resets_wedge_state_before_stale_poll
test_turn_ended_churn_existing_marker_absorbed
test_turn_ended_still_pane_surfaced
test_turn_ended_malformed_prior_hash_surfaced
test_unknown_alive_stale_is_bounded_after_its_first_alarm
test_unknown_alive_stale_without_progress_keeps_surfacing
test_turn_ended_trailing_newline_prior_hash_surfaced
test_secondmate_turn_ended_churning_pane_surfaced
test_turn_ended_colliding_window_key_surfaced
test_turn_ended_duplicate_endpoint_records_surfaced
test_turn_ended_mixed_positive_evidence_batch_absorbed
test_turn_ended_mixed_positive_evidence_batch_default_off
test_status_and_turn_end_batch_never_uses_churn_evidence
test_turn_ended_churn_absorb_off_by_default
test_turn_ended_churn_absorb_bounded
test_turn_ended_churn_timer_write_failure_surfaced
test_turn_ended_invalid_churn_bound_surfaced
test_turn_ended_oversized_churn_bound_surfaced
test_turn_ended_invalid_churn_deadline_surfaced
test_turn_ended_surfaced_batch_opens_no_partial_deadline
test_working_note_not_working_surfaced
test_secondmate_status_note_surfaced_despite_busy_agent
test_secondmate_routine_progress_absorbed_then_note_surfaced
test_secondmate_buried_block_wakes_despite_busy_agent
test_self_announced_close_does_not_rewake_but_next_note_does
test_self_announced_close_after_open_decisions_fold_does_not_rewake
test_folded_worker_decision_without_home_append_still_wakes
test_separate_self_announced_answers_after_fold_wake_once
test_self_announced_close_after_fold_still_surfaces_folded_worker_failure
test_self_announced_close_after_fold_still_surfaces_folded_secondmate_lines
test_actionable_signal_surfaced
test_needs_decision_signal_payload_marked_for_branch_exclusion
test_needs_decision_reconciliation_required_still_marked
test_captain_held_signal_payload_marked_for_branch_exclusion
test_pending_reply_escalation_signal_payload_marked_for_branch_exclusion
test_ordinary_blocked_signal_payload_remains_branch_eligible
test_routine_signal_payload_not_marked_needs_decision
test_actionable_signal_survives_a_later_routine_append
test_keyed_decision_signal_reads_only_the_new_span
test_release_completion_survives_a_later_routine_append
test_routine_appends_after_a_classified_event_stay_absorbed
test_unreadable_status_reports_once_per_file_state
test_permission_recovery_surfaces_preserved_status
test_terminal_stale_surfaced
test_stale_terminal_status_overridden_by_active_run
test_nonterminal_stale_provably_working_absorbed_then_escalated
test_wedge_escalation_marks_demand_deep_inspection_after_threshold
test_wedge_escalation_resets_when_pane_becomes_active
test_wedge_escalation_prompt_first_fire
test_wedge_escalation_reset_on_nonterminal_surface
test_wedge_escalation_reset_on_terminal_absorb
test_wedge_escalation_reset_on_terminal_surface
test_wedge_escalation_reset_on_nonterminal_working_absorb
test_wedge_escalation_backs_off_after_first_fire
test_wedge_escalation_backoff_is_capped
test_wedge_escalation_backoff_resets_to_prompt_on_activity
test_gone_endpoint_reports_once_instead_of_escalating_forever
test_live_and_unproven_endpoints_still_wedge_escalate
test_wedge_guards_absent_config_keeps_the_unchanged_ladder
test_wedge_guard_critical_defers_one_window_at_a_time_up_to_the_cap
test_wedge_guard_failures_fail_open
test_wedge_guard_never_defers_a_gone_endpoint
test_gone_report_rearms_when_the_endpoint_comes_back
test_second_death_after_a_same_window_relaunch_reports_in_full
test_identical_dead_display_of_a_successor_still_reports
test_term_stops_a_watcher_blocked_inside_a_poll
test_term_stops_a_watcher_whose_cleanup_marker_lock_is_held
test_cleanup_marker_lock_bound_is_decimal_with_zero_default
test_busy_pane_below_turn_age_bound_is_absorbed
test_busy_pane_stable_hash_escalates_past_turn_age_bound
test_busy_pane_changing_hash_escalates_past_turn_age_bound
test_busy_pane_turn_end_touch_resets_age
test_busy_pane_native_progress_resets_age
test_busy_pane_repeated_escalation_reaches_demand_deep_inspection
test_busy_pane_default_turn_age_bound_is_3600s
test_busy_declared_pause_is_rechecked_not_wedge_escalated
test_afk_busy_declared_pause_hands_off_plain_stale
test_afk_busy_declared_pause_ticking_pane_hands_off_once
test_nonterminal_stale_not_working_surfaced
test_nonterminal_stale_paused_absorbed_then_resurfaced
test_exited_declared_pause_is_bounded_but_live_gate_surfaces
test_own_work_wait_keeps_first_alert_then_long_cadence
test_absorbed_replacement_wait_does_not_inherit_the_old_throttle
test_live_declared_wait_churn_honors_the_resurface_throttle
test_afk_heartbeat_preserves_idle_accounting
test_colliding_endpoints_keep_independent_stale_history
test_long_endpoint_keeps_stale_history
test_pi_model_progress_and_legacy_fallback
test_pi_stream_counter_write_failures
test_pi_stream_publication_lock_revalidation
test_pi_stream_resume_restarts_capped_episode
test_pi_stream_silence_uses_inspection_timer
test_pi_stream_terminal_publication
test_pi_stream_uninterrupted_publication
test_window_keys_encode_supported_endpoint_bytes
