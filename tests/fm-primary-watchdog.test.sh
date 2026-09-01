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

cleanup() { rm -rf "$TMPHOME"; }
trap cleanup EXIT

# --- 1. blocked-detection matching -----------------------------------------
fm_backend_target_exists() { return 0; }
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
if [ "$got" = "3630" ]; then
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
fm_backend_busy_state() { printf 'idle'; }

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

if [ "$FAILED" -eq 0 ]; then
  echo "all tests passed"
  exit 0
else
  echo "some tests failed"
  exit 1
fi
