#!/usr/bin/env bash
# tests/fm-primary-watchdog.test.sh - unit coverage for
# bin/fm-primary-watchdog.sh (report data/overnight-supervisor-mode-design
# section 11). Sources the script in library mode (BASH_SOURCE != 0) and
# redefines its backend/context-usage dependencies with test doubles rather
# than driving a real tmux/herdr pane, matching the portable-regression half
# of firstmate-coding-guidelines' harness-dependent-check split; the rendered
# usage-limit signature itself still needs live verification per that same
# section, which is out of scope for this fast unit file.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0
fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }

TMPHOME=$(mktemp -d "${TMPDIR:-/tmp}/fm-watchdog-test.XXXXXX")
mkdir -p "$TMPHOME/state" "$TMPHOME/config"
export FM_HOME="$TMPHOME" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$TMPHOME/state" FM_CONFIG_OVERRIDE="$TMPHOME/config"
export TMUX_PANE="test:0.0"

# shellcheck source=bin/fm-primary-watchdog.sh
. "$ROOT/bin/fm-primary-watchdog.sh"

# shellcheck disable=SC2329 # Invoked indirectly via the EXIT trap.
cleanup() { rm -rf "$TMPHOME"; }
trap cleanup EXIT

TMUX_STUB_DIR="$TMPHOME/stubbin"
mkdir -p "$TMUX_STUB_DIR"
cat >"$TMUX_STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = display-message ]; then
  case "$*" in *pane_id*) head -1 "$TMUX_STUB_PANES" ;; *) printf 'firstmate:main\n' ;; esac
  exit 0
fi
if [ "$1" = list-panes ]; then cat "$TMUX_STUB_PANES"; exit 0; fi
exit 1
STUB
chmod +x "$TMUX_STUB_DIR/tmux"
export TMUX_STUB_PANES="$TMPHOME/stub-panes"
printf '%%12\n' >"$TMUX_STUB_PANES"
PATH="$TMUX_STUB_DIR:$PATH"
PATH_SAVED="$PATH"

# --- 1. blocked-detection matching -----------------------------------------
fm_backend_target_exists() { return 0; }
fm_backend_agent_alive() { printf 'alive'; }
fm_backend_capture() { printf 'some ordinary output\nnothing unusual here\n'; }
if fm_watchdog_primary_blocked "test:0" "tmux"; then
  fail "blocked-detection: ordinary output must not match"
else
  pass "blocked-detection: ordinary output does not match"
fi

fm_backend_capture() { printf 'Claude usage limit reached, resets 3am\n'; }
if fm_watchdog_primary_blocked "test:0" "tmux"; then
  pass "blocked-detection: limit signature matches"
else
  fail "blocked-detection: limit signature must match"
fi

fm_backend_target_exists() { return 1; }
if fm_watchdog_primary_blocked "test:0" "tmux"; then
  pass "blocked-detection: gone target counts as blocked"
else
  fail "blocked-detection: gone target must count as blocked"
fi
# shellcheck disable=SC2329 # Invoked indirectly by the sourced script under test.
fm_backend_target_exists() { return 0; }

# --- 2. reset-wait timing calculation ---------------------------------------
CANNED="$TMPHOME/quota.json"
cat >"$CANNED" <<'EOF'
{"providers":[{"provider":"claude","windows":[{"id":"five_hour","resetsAt":"2026-01-01T01:00:00+00:00"}]}]}
EOF
export FM_WATCHDOG_QUOTA_JSON="$CANNED"
now_epoch=$(date -d "2026-01-01T00:00:00+00:00" +%s)
export FM_WATCHDOG_NOW="$now_epoch"
export FM_WATCHDOG_RESET_JITTER=30
got=$(fm_watchdog_reset_wait_seconds)
if [ "${got% *}" = "3630" ]; then
  pass "reset-wait: 1h to reset + 30s jitter = 3630s"
else
  fail "reset-wait: expected 3630, got $got"
fi
unset FM_WATCHDOG_QUOTA_JSON FM_WATCHDOG_NOW FM_WATCHDOG_RESET_JITTER

# --- 3. context-band branch --------------------------------------------------
RESTART_CALLED=""
fm_watchdog_restart_primary() { RESTART_CALLED=1; }
fm_watchdog_inject() { printf 'inject: %s\n' "$3" >>"$TMPHOME/injects.log"; return 0; }

fm_watchdog_context_band() { printf 'ok'; }
: >"$TMPHOME/injects.log"
fm_watchdog_handle_reset "test:0" "tmux"
if grep -q 'check queued wakes' "$TMPHOME/injects.log" && [ -z "$RESTART_CALLED" ]; then
  pass "context-band ok: nudges without restarting"
else
  fail "context-band ok: expected a nudge and no restart"
fi

fm_watchdog_context_band() { printf 'warn'; }
fm_watchdog_wait_for_stow() { return 0; }
RESTART_CALLED=""
: >"$TMPHOME/injects.log"
fm_watchdog_handle_reset "test:0" "tmux"
if grep -q '/stow' "$TMPHOME/injects.log" && [ -n "$RESTART_CALLED" ]; then
  pass "context-band warn: stows then restarts"
else
  fail "context-band warn: expected a stow inject and a restart"
fi

# --- 4. bounded-stow-timeout fallback ----------------------------------------
fm_watchdog_context_band() { printf 'restart'; }
fm_watchdog_wait_for_stow() { return 1; }  # simulate timeout, never completed
RESTART_CALLED=""
STDERR_LOG="$TMPHOME/watchdog-stderr.log"
fm_watchdog_handle_reset "test:0" "tmux" 2>"$STDERR_LOG"
if [ -n "$RESTART_CALLED" ]; then
  pass "bounded-stow-timeout: restarts anyway after the window elapses"
else
  fail "bounded-stow-timeout: must restart even when stow never completes"
fi
if grep -q "proceeding to restart anyway" "$STDERR_LOG"; then
  pass "bounded-stow-timeout: skip is logged"
else
  fail "bounded-stow-timeout: skip must be logged"
fi

# --- 5. fresh launch never uses --resume/--continue --------------------------
# Re-source to restore the real fm_watchdog_restart_primary (test 3 shadowed it
# with a stub; `unset -f` cannot bring back the original definition).
. "$ROOT/bin/fm-primary-watchdog.sh"
SENT_LOG="$TMPHOME/sent.log"
fm_backend_send_text_submit() { printf '%s\n' "$3" >>"$SENT_LOG"; printf 'empty'; }
# shellcheck disable=SC2329 # Invoked indirectly by the sourced script under test.
fm_backend_busy_state() { printf 'idle'; }
# shellcheck disable=SC2329 # Invoked indirectly by the sourced script under test.
fm_backend_agent_alive() { printf 'dead'; }

: >"$SENT_LOG"
FM_WATCHDOG_LAUNCH_CMD="claude --resume" fm_watchdog_restart_primary "test:0" "tmux"
rc=$?
if [ "$rc" -ne 0 ] && ! grep -q -- '--resume\|--continue' "$SENT_LOG"; then
  pass "no-resume: refuses a --resume launch command and never types it"
else
  fail "no-resume: must refuse --resume without sending it"
fi

: >"$SENT_LOG"
fm_watchdog_restart_primary "test:0" "tmux"
if grep -q '^claude$' "$SENT_LOG" && ! grep -q -- '--resume\|--continue' "$SENT_LOG"; then
  pass "no-resume: default restart launches plain claude, no resume flags"
else
  fail "no-resume: expected a plain 'claude' launch with no resume flags"
fi

# --- config polarity: presence of config/primary-continuity opts OUT --------
if fm_watchdog_enabled; then
  pass "polarity: absent config/primary-continuity leaves the watchdog enabled"
else
  fail "polarity: absence must mean enabled"
fi
: >"$TMPHOME/config/primary-continuity"
if fm_watchdog_enabled; then
  fail "polarity: presence must opt out"
else
  pass "polarity: presence of config/primary-continuity opts out"
fi
rm -f "$TMPHOME/config/primary-continuity"

# --- 6. cycle-level regressions ----------------------------------------------
. "$ROOT/bin/fm-primary-watchdog.sh"
export FM_WATCHDOG_SKIP_SLEEP=1 FM_SUPERVISOR_TARGET="test:0"
CANNED="$TMPHOME/quota.json"
export FM_WATCHDOG_QUOTA_JSON="$CANNED"
FM_WATCHDOG_NOW="$(date -d "2026-01-01T00:00:00+00:00" +%s)"
export FM_WATCHDOG_NOW
HANDLED=""
fm_watchdog_handle_reset() { HANDLED="$1 $2"; }
fm_backend_capture() { printf 'some ordinary output\n'; }

# shellcheck disable=SC2329 # Invoked indirectly by the sourced script under test.
fm_backend_agent_alive() { printf 'alive'; }

# 6a. a crashed harness in a live pane is detected and relaunched immediately,
# without waiting on an unrelated quota reset
LAUNCHED=""
fm_watchdog_launch_primary() { LAUNCHED="$1 $2"; }
fm_backend_target_exists() { return 0; }
fm_backend_agent_alive() { printf 'dead'; }
rm -f "$TMPHOME/state/.watchdog-last-action" "$TMPHOME/state/.watchdog-dead-streak"
HANDLED=""
fm_watchdog_cycle 2>/dev/null
if [ -z "$LAUNCHED" ]; then
  pass "cycle: one dead reading alone does not relaunch (captain at a shell prompt)"
else
  fail "cycle: a single dead observation must not relaunch"
fi
fm_watchdog_cycle 2>/dev/null
if [ "$LAUNCHED" = "test:0 tmux" ] && [ -z "$HANDLED" ]; then
  pass "cycle: a confirmed crashed harness launches a fresh session without a reset wait"
else
  fail "cycle: a confirmed crashed harness must launch a fresh session immediately"
fi

# 6a1. a live reading between two dead readings resets the confirmation streak
LAUNCHED=""
rm -f "$TMPHOME/state/.watchdog-last-action" "$TMPHOME/state/.watchdog-dead-streak"
fm_watchdog_cycle 2>/dev/null
# shellcheck disable=SC2329 # Invoked indirectly by the sourced script under test.
fm_backend_agent_alive() { printf 'alive'; }
fm_watchdog_cycle 2>/dev/null
fm_backend_agent_alive() { printf 'dead'; }
fm_watchdog_cycle 2>/dev/null
if [ -z "$LAUNCHED" ]; then
  pass "cycle: an intervening live reading clears the dead-confirmation streak"
else
  fail "cycle: a non-consecutive dead reading must not relaunch"
fi
rm -f "$TMPHOME/state/.watchdog-last-action" "$TMPHOME/state/.watchdog-dead-streak"

# 6a2. a destroyed pane is reported, never driven
fm_backend_target_exists() { return 1; }
rm -f "$TMPHOME/state/.watchdog-last-action"
LAUNCHED=""; HANDLED=""
fm_watchdog_cycle 2>/dev/null
if [ -z "$LAUNCHED" ] && [ -z "$HANDLED" ]; then
  pass "cycle: a destroyed pane is not typed into"
else
  fail "cycle: a destroyed pane must not be typed into"
fi
fm_backend_target_exists() { return 0; }
fm_backend_agent_alive() { printf 'alive'; }
fm_backend_capture() { printf 'Claude usage limit reached, resets 3am\n'; }
rm -f "$TMPHOME/state/.watchdog-last-action"
HANDLED=""
fm_watchdog_cycle 2>/dev/null
if [ -n "$HANDLED" ]; then
  pass "cycle: a limit-blocked primary reaches the reset path"
else
  fail "cycle: a limit-blocked primary must reach the reset path"
fi

# 6b. after acting, the cooldown suppresses the next cycle
HANDLED=""
fm_watchdog_cycle 2>/dev/null
if [ -z "$HANDLED" ]; then
  pass "cycle: cooldown suppresses a repeat action within the window"
else
  fail "cycle: must not act again inside the cooldown window"
fi

# 6c. once the cooldown elapses, a reset window already handled is not redone
HANDLED=""
FM_WATCHDOG_NOW=$((FM_WATCHDOG_NOW + 1000)) fm_watchdog_cycle 2>/dev/null
if [ -z "$HANDLED" ]; then
  pass "cycle: an already-handled reset window is not acted on twice"
else
  fail "cycle: must not re-handle the same reset window"
fi

# 6c2. a new reset window is acted on again
cat >"$CANNED" <<'EOF'
{"providers":[{"provider":"claude","windows":[{"id":"five_hour","resetsAt":"2026-01-01T06:00:00+00:00"}]}]}
EOF
HANDLED=""
FM_WATCHDOG_NOW=$((FM_WATCHDOG_NOW + 1000)) fm_watchdog_cycle 2>/dev/null
if [ -n "$HANDLED" ]; then
  pass "cycle: a new reset window is acted on"
else
  fail "cycle: a new reset window must be acted on"
fi

# 6d. the opt-out flag is honored by the cycle itself, not only at startup
: >"$TMPHOME/config/primary-continuity"
rm -f "$TMPHOME/state/.watchdog-last-action" "$TMPHOME/state/.watchdog-last-reset"
HANDLED=""
fm_watchdog_cycle 2>/dev/null
if [ -z "$HANDLED" ]; then
  pass "cycle: config/primary-continuity opts out mid-loop"
else
  fail "cycle: must not act while config/primary-continuity is present"
fi
rm -f "$TMPHOME/config/primary-continuity" "$TMPHOME/state/.watchdog-last-action" "$TMPHOME/state/.watchdog-last-reset"
unset FM_WATCHDOG_QUOTA_JSON FM_WATCHDOG_NOW FM_WATCHDOG_SKIP_SLEEP FM_SUPERVISOR_TARGET
# shellcheck disable=SC2329 # Invoked indirectly by the sourced script under test.
fm_backend_target_exists() { return 0; }

# --- 7. unreadable context band is explicit, not a silent "ok" ---------------
. "$ROOT/bin/fm-primary-watchdog.sh"
cat >"$TMPHOME/fm-context-usage.sh" <<'STUB'
#!/usr/bin/env bash
printf 'no band token here\n'
STUB
chmod +x "$TMPHOME/fm-context-usage.sh"
BAND_DIR_SAVED="$FM_WATCHDOG_DIR"
FM_WATCHDOG_DIR="$TMPHOME"
: >"$TMPHOME/primary.jsonl"
export FM_WATCHDOG_TRANSCRIPT="$TMPHOME/primary.jsonl"
if fm_watchdog_context_band >/dev/null 2>&1; then
  fail "context-band: an output with no band token must not report success"
else
  pass "context-band: an output with no band token reports failure"
fi
BAND_LOG="$TMPHOME/band.log"
RESTART_CALLED=""
fm_watchdog_restart_primary() { RESTART_CALLED=1; }
fm_watchdog_inject() { return 0; }
fm_watchdog_handle_reset "test:0" "tmux" 2>"$BAND_LOG"
if grep -q "context band unreadable" "$BAND_LOG"; then
  pass "context-band: an unreadable band is logged before falling back"
else
  fail "context-band: an unreadable band must be logged"
fi
FM_WATCHDOG_DIR="$BAND_DIR_SAVED"

# --- 7b. the band is read from the PINNED primary transcript, never from
# whichever session happened to write last ----------------------------------
cat >"$TMPHOME/fm-context-usage.sh" <<'STUB'
#!/usr/bin/env bash
printf 'transcript=%s band=restart\n' "${1:-NONE}"
STUB
chmod +x "$TMPHOME/fm-context-usage.sh"
FM_WATCHDOG_DIR="$TMPHOME"
: >"$TMPHOME/other-session.jsonl"
band=$(fm_watchdog_context_band) || band="REFUSED"
seen_args="$TMPHOME/band-args"
cat >"$TMPHOME/fm-context-usage.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\${1:-NONE}" >"$seen_args"
printf 'band=restart\n'
STUB
chmod +x "$TMPHOME/fm-context-usage.sh"
fm_watchdog_context_band >/dev/null 2>&1
if [ "$band" = restart ] && [ "$(cat "$seen_args")" = "$TMPHOME/primary.jsonl" ]; then
  pass "context-band: the pinned primary transcript is passed explicitly"
else
  fail "context-band: must pass the pinned transcript (band=$band arg=$(cat "$seen_args" 2>/dev/null))"
fi

unset FM_WATCHDOG_TRANSCRIPT
rm -f "$TMPHOME/state/.primary-watchdog.transcript"
if fm_watchdog_context_band >/dev/null 2>&1; then
  fail "context-band: an unpinned primary must not fall back to some other session"
else
  pass "context-band: an unpinned primary refuses rather than reading another session"
fi
FM_WATCHDOG_DIR="$BAND_DIR_SAVED"

# --- 7c. the busy guard fails CLOSED ---------------------------------------
. "$ROOT/bin/fm-primary-watchdog.sh"
fm_backend_busy_state() { printf 'unknown'; }
HARNESS_STUB_DIR="$TMPHOME/harnessbin"
mkdir -p "$HARNESS_STUB_DIR"
printf '#!/usr/bin/env bash\nprintf "unknown\\n"\n' >"$HARNESS_STUB_DIR/fm-harness.sh"
chmod +x "$HARNESS_STUB_DIR/fm-harness.sh"
BUSY_DIR_SAVED="$FM_WATCHDOG_DIR"
FM_WATCHDOG_DIR="$HARNESS_STUB_DIR"
fm_backend_capture() { printf 'idle-looking pane\n'; }
if fm_watchdog_pane_busy "test:0" tmux 2>/dev/null; then
  pass "busy-guard: an unidentifiable harness is treated as busy, not idle"
else
  fail "busy-guard: an unidentifiable harness must fail closed"
fi
printf '#!/usr/bin/env bash\nprintf "claude\\n"\n' >"$HARNESS_STUB_DIR/fm-harness.sh"
fm_backend_capture() { return 1; }
if fm_watchdog_pane_busy "test:0" tmux 2>/dev/null; then
  pass "busy-guard: a failed pane capture is treated as busy, not idle"
else
  fail "busy-guard: a failed capture must fail closed"
fi
FM_WATCHDOG_DIR="$BUSY_DIR_SAVED"
# shellcheck disable=SC2329 # Invoked indirectly by the sourced script under test.
fm_backend_capture() { printf 'ordinary\n'; }

# --- 8. restart never types the launch command into a live harness -----------
. "$ROOT/bin/fm-primary-watchdog.sh"
SENT_LOG="$TMPHOME/sent2.log"
: >"$SENT_LOG"
fm_backend_send_text_submit() { printf '%s\n' "$3" >>"$SENT_LOG"; printf 'empty'; }
fm_backend_send_key() { return 0; }
# shellcheck disable=SC2329 # Invoked indirectly by the sourced script under test.
fm_backend_busy_state() { printf 'idle'; }
# shellcheck disable=SC2329 # Invoked indirectly by the sourced script under test.
fm_backend_agent_alive() { printf 'alive'; }
FM_WATCHDOG_EXIT_SETTLE=0 fm_watchdog_restart_primary "test:0" "tmux" 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ] && ! grep -qx 'claude' "$SENT_LOG"; then
  pass "restart: a still-live harness blocks the launch command and fails loudly"
else
  fail "restart: must not type the launch command into a still-live harness"
fi

# --- 9. the blocked condition is re-verified after the reset sleep ----------
CAPTURE_COUNT="$TMPHOME/capture-calls"
: >"$CAPTURE_COUNT"
fm_backend_capture() {
  printf 'x\n' >>"$CAPTURE_COUNT"
  if [ "$(wc -l <"$CAPTURE_COUNT")" -le 1 ]; then
    printf 'Claude usage limit reached, resets 3am\n'
  else
    printf 'captain is working normally here\n'
  fi
}
fm_backend_target_exists() { return 0; }
fm_backend_agent_alive() { printf 'alive'; }
HANDLED=""
fm_watchdog_handle_reset() { HANDLED="$1 $2"; }
export FM_WATCHDOG_SKIP_SLEEP=1 FM_SUPERVISOR_TARGET="test:0" FM_WATCHDOG_QUOTA_JSON="$TMPHOME/quota.json"
rm -f "$TMPHOME/state/.watchdog-last-action" "$TMPHOME/state/.watchdog-last-reset"
fm_watchdog_cycle 2>/dev/null
if [ -z "$HANDLED" ] && [ ! -e "$TMPHOME/state/.watchdog-last-reset" ]; then
  pass "cycle: a primary no longer blocked at reset is left alone"
else
  fail "cycle: must abandon the pass when the primary is no longer blocked"
fi
unset FM_WATCHDOG_SKIP_SLEEP FM_SUPERVISOR_TARGET FM_WATCHDOG_QUOTA_JSON

# --- 10. offset-bearing reset timestamps parse to the same instant ----------
. "$ROOT/bin/fm-primary-watchdog.sh"
want=$(date -u -d "2026-01-01T06:00:00" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%S' "2026-01-01T06:00:00" +%s)
ok_all=1
for stamp in "2026-01-01T06:00:00+00:00" "2026-01-01T06:00:00Z" "2026-01-01T06:00:00+0000" "2026-01-01T07:00:00+01:00"; do
  got=$(fm_watchdog_epoch_of "$stamp") || got=""
  [ "$got" = "$want" ] || ok_all=0
done
if [ "$ok_all" -eq 1 ]; then
  pass "reset-time parsing: every offset spelling resolves to the same instant"
else
  fail "reset-time parsing: an offset spelling resolved to the wrong instant"
fi

# --- 11. a bare tmux pane id is normalized before any liveness read ---------
printf '%%12\n' >"$TMUX_STUB_PANES"
SEEN_FILE="$TMPHOME/seen-target"
fm_backend_agent_alive() { printf '%s' "$2" >"$SEEN_FILE"; printf 'dead'; }
state=$(fm_watchdog_agent_state "%12" tmux)
SEEN_TARGET=$(cat "$SEEN_FILE" 2>/dev/null)
PATH="$PATH_SAVED"
if [ "$state" = dead ] && [ "$SEEN_TARGET" = "firstmate:main" ]; then
  pass "liveness: a bare tmux pane id is resolved to a readable session:window"
else
  fail "liveness: a bare tmux pane id must be resolved before the liveness read (state=$state target=$SEEN_TARGET)"
fi

printf '%%12\n%%13\n' >"$TMUX_STUB_PANES"
PATH="$TMUX_STUB_DIR:$PATH"
: >"$SEEN_FILE"
state=$(fm_watchdog_agent_state "%12" tmux)
PATH="$PATH_SAVED"
if [ "$state" = unknown ] && [ ! -s "$SEEN_FILE" ]; then
  pass "liveness: a split window yields unknown instead of a redirected verdict"
else
  fail "liveness: a split window must not produce a liveness verdict (state=$state)"
fi

# --- 13. an unreadable liveness verdict aborts before any injection ---------
printf '%%12\n%%13\n' >"$TMUX_STUB_PANES"
PATH="$TMUX_STUB_DIR:$PATH"
INJECTED=""
fm_watchdog_inject() { INJECTED="$3"; return 0; }
fm_watchdog_restart_primary() { INJECTED="${INJECTED}restart"; return 0; }
fm_watchdog_context_band() { printf 'warn'; }
fm_watchdog_handle_reset "%12" tmux >/dev/null 2>&1
rc=$?
PATH="$PATH_SAVED"
if [ "$rc" -ne 0 ] && [ -z "$INJECTED" ]; then
  pass "reset: an unreadable liveness target aborts before any injection"
else
  fail "reset: must abandon the pass before injecting when liveness is unreadable (rc=$rc injected=$INJECTED)"
fi

# --- 14. a bare window target gets the same ambiguity check -----------------
printf '%%12\n' >"$TMUX_STUB_PANES"
single=$(fm_watchdog_liveness_target "firstmate:main" tmux) || single="REFUSED"
printf '%%12\n%%13\n' >"$TMUX_STUB_PANES"
split=$(fm_watchdog_liveness_target "firstmate:main" tmux) || split="REFUSED"
pinned_split=$(fm_watchdog_liveness_target "firstmate:main.0" tmux) || pinned_split="REFUSED"
printf '%%12\n' >"$TMUX_STUB_PANES"
pinned=$(fm_watchdog_liveness_target "firstmate:main.0" tmux) || pinned="REFUSED"
if [ "$single" = "firstmate:main" ] && [ "$split" = "REFUSED" ] && [ "$pinned" = "firstmate:main" ] && [ "$pinned_split" = "REFUSED" ]; then
  pass "liveness: a bare window target is refused when the window has a split"
else
  fail "liveness: window-target ambiguity check wrong (single=$single split=$split pinned=$pinned pinned_split=$pinned_split)"
fi

# --- 15. a deferred inject guard must not exit the pane ---------------------
DEFER_RESTART=""
fm_watchdog_restart_primary() { DEFER_RESTART=1; }
fm_watchdog_inject() { return 2; }
fm_watchdog_context_band() { printf 'warn'; }
fm_watchdog_handle_reset "test:0" "tmux" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ] && [ -z "$DEFER_RESTART" ]; then
  pass "reset: a deferred stow inject abandons the pass instead of restarting"
else
  fail "reset: a guard deferral must not restart the pane (rc=$rc restart=$DEFER_RESTART)"
fi

# --- 17. a stale dead-streak cannot stand in for a fresh observation --------
. "$ROOT/bin/fm-primary-watchdog.sh"
rm -f "$TMPHOME/state/.watchdog-dead-streak"
FM_WATCHDOG_NOW=1000000 fm_watchdog_dead_streak_bump >/dev/null
streak=$(FM_WATCHDOG_NOW=2000000 fm_watchdog_dead_streak_bump)
if [ "$streak" = 1 ]; then
  pass "dead-streak: an observation from a stopped loop is discarded, not counted"
else
  fail "dead-streak: a stale streak must not carry over (streak=$streak)"
fi
streak=$(FM_WATCHDOG_NOW=2000030 fm_watchdog_dead_streak_bump)
if [ "$streak" = 2 ]; then
  pass "dead-streak: two consecutive in-window observations confirm"
else
  fail "dead-streak: consecutive observations must confirm (streak=$streak)"
fi
rm -f "$TMPHOME/state/.watchdog-dead-streak"

# --- 18. the transcript pin self-heals after the watchdog's own launch ------
. "$ROOT/bin/fm-primary-watchdog.sh"
unset FM_WATCHDOG_TRANSCRIPT
HOME_SAVED="$HOME"
export HOME="$TMPHOME/fakehome"
PROJ="$HOME/.claude/projects/$(printf '%s' "$FM_HOME" | tr -c 'a-zA-Z0-9' '-')"
mkdir -p "$PROJ"
: >"$PROJ/old-session.jsonl"
touch -d '@1000000' "$PROJ/old-session.jsonl"
printf '%s\n' "$PROJ/old-session.jsonl" >"$TMPHOME/state/.primary-watchdog.transcript"
fm_backend_target_exists() { return 0; }
fm_backend_send_text_submit() { printf 'empty'; }
FM_WATCHDOG_NOW=2000000 fm_watchdog_launch_primary "test:0" tmux >/dev/null 2>&1
if [ ! -e "$TMPHOME/state/.primary-watchdog.transcript" ] \
  && ! fm_watchdog_primary_transcript >/dev/null 2>&1; then
  pass "transcript-pin: the dead session's pin is dropped and not resurrected"
else
  fail "transcript-pin: a launch must drop the pin and refuse the old transcript"
fi

: >"$PROJ/new-session.jsonl"
touch -d '@2000100' "$PROJ/new-session.jsonl"
got=$(fm_watchdog_primary_transcript) || got="REFUSED"
if [ "$got" = "$PROJ/new-session.jsonl" ] && [ ! -e "$TMPHOME/state/.primary-watchdog.repin-after" ]; then
  pass "transcript-pin: the loop re-pins the fresh session's own transcript"
else
  fail "transcript-pin: must re-pin the post-launch transcript (got=$got)"
fi
rm -rf "$TMPHOME/fakehome" "$TMPHOME/state/.primary-watchdog.transcript" "$TMPHOME/state/.primary-watchdog.repin-after"
export HOME="$HOME_SAVED"

# --- 19. a permanently unidentifiable harness is surfaced once --------------
. "$ROOT/bin/fm-primary-watchdog.sh"
fm_backend_busy_state() { printf 'unknown'; }
fm_backend_capture() { printf 'ordinary\n'; }
UNK_DIR="$TMPHOME/unkbin"
mkdir -p "$UNK_DIR"
printf '#!/usr/bin/env bash\nprintf "unknown\\n"\n' >"$UNK_DIR/fm-harness.sh"
chmod +x "$UNK_DIR/fm-harness.sh"
ESC_DIR_SAVED="$FM_WATCHDOG_DIR"
FM_WATCHDOG_DIR="$UNK_DIR"
rm -f "$TMPHOME/state/.watchdog-harness-unknown"
ESC1="$TMPHOME/esc1.log"; ESC2="$TMPHOME/esc2.log"
fm_watchdog_pane_busy "test:0" tmux 2>"$ESC1"
fm_watchdog_pane_busy "test:0" tmux 2>"$ESC2"
if grep -q ESCALATION "$ESC1" && ! grep -q ESCALATION "$ESC2"; then
  pass "harness-unknown: the permanent no-op is escalated once, not every poll"
else
  fail "harness-unknown: expected exactly one escalation across two polls"
fi
printf '#!/usr/bin/env bash\nprintf "claude\\n"\n' >"$UNK_DIR/fm-harness.sh"
ESC3="$TMPHOME/esc3.log"
fm_watchdog_pane_busy "test:0" tmux >/dev/null 2>&1
printf '#!/usr/bin/env bash\nprintf "unknown\\n"\n' >"$UNK_DIR/fm-harness.sh"
fm_watchdog_pane_busy "test:0" tmux 2>"$ESC3"
if grep -q ESCALATION "$ESC3"; then
  pass "harness-unknown: a recovered then relapsed harness escalates again"
else
  fail "harness-unknown: a relapse after recovery must escalate again"
fi
FM_WATCHDOG_DIR="$ESC_DIR_SAVED"
rm -f "$TMPHOME/state/.watchdog-harness-unknown"

# --- 16. always-on arming: singleton pidfile + idempotent arm ---------------
# The disable seam turns the presence gate off without touching config.
if FM_WATCHDOG_DISABLE=1 fm_watchdog_enabled; then
  fail "arm: FM_WATCHDOG_DISABLE=1 must disable the presence gate"
else
  pass "arm: FM_WATCHDOG_DISABLE=1 disables the presence gate"
fi

# A live pid recorded in the pidfile makes arm attach instead of spawning.
sleep 300 & HOLDER=$!
printf '%s\n' "$HOLDER" >"$TMPHOME/state/.primary-watchdog.pid"
out=$(fm_watchdog_arm)
if [ "$out" = "primary-watchdog: attached pid=$HOLDER" ]; then
  pass "arm: attaches to a live loop instead of spawning a second one"
else
  fail "arm: expected attach to pid $HOLDER, got: $out"
fi

# A dead pid in the pidfile is not a live singleton.
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
if fm_watchdog_singleton_live >/dev/null; then
  fail "arm: a dead pidfile holder must not read as a live singleton"
else
  pass "arm: a dead pidfile holder does not read as a live singleton"
fi

# main defers to another live loop owning the pidfile.
sleep 300 & HOLDER=$!
printf '%s\n' "$HOLDER" >"$TMPHOME/state/.primary-watchdog.pid"
fm_watchdog_verified_target() { printf 'test:0 tmux\n'; }
if fm_watchdog_main >/dev/null 2>&1; then
  pass "run: a second loop defers to the live pidfile owner and exits"
else
  fail "run: deferring to a live pidfile owner must exit 0"
fi
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
rm -f "$TMPHOME/state/.primary-watchdog.pid"

if [ "$FAILED" -eq 0 ]; then
  echo "all tests passed"
  exit 0
else
  echo "some tests failed"
  exit 1
fi
