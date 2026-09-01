#!/usr/bin/env bash
# fm-primary-watchdog.sh - primary continuity watchdog (report.md
# data/overnight-supervisor-mode-design section 11): a small, presence-gated
# loop that runs as a SEPARATE OS process from the primary firstmate session
# and gets a usage-limit-blocked (or crashed) primary back to a working
# session at reset, without a captain having to notice and intervene.
#
# Hosted alongside the afk/supervise-daemon machinery: reuses its pane
# discovery (bin/fm-supervisor-target-lib.sh), backend dispatch
# (bin/fm-backend.sh), busy-line matching (bin/fm-busy-lib.sh), and the
# operational-input envelope (bin/fm-operational-input.sh) rather than
# reinventing pane targeting or injection safety. It does NOT reuse
# inject_msg() from bin/fm-supervise-daemon.sh directly because that helper is
# presence-gated on away mode (state/.afk); this watchdog is meant to run
# always-on regardless of away mode, so fm_watchdog_inject() below repeats
# inject_msg's busy-guard/composer-guard/verified-submit steps without the
# afk_active gate.
#
# Loop (one pass per invocation of fm_watchdog_cycle; fm_watchdog_main wraps it
# in a sleep loop):
#   1. fm_watchdog_primary_blocked - cheap poll: pane alive but rendered output
#      matches the usage-limit signature (same technique as the daemon's busy
#      guard: tail the pane, match known text), or the harness process/target
#      is gone entirely.
#   2. fm_watchdog_reset_wait_seconds - on a positive match, ask quota-axi for
#      the account's five_hour session window resetsAt and sleep until reset
#      plus jitter (same anchor technique the generated, private
#      state/debrief-trigger.check.sh already uses).
#   3. At reset: fm_watchdog_handle_reset reads the primary's context band via
#      bin/fm-context-usage.sh under the primary's FM_HOME.
#        band=ok            -> inject one operational-prefix nudge so queued
#                               wakes get handled in the existing session.
#        band=warn|restart  -> inject /stow, wait up to
#                               FM_WATCHDOG_STOW_WINDOW seconds (default 600)
#                               for completion evidence (state/.stow-last-run
#                               newer than the inject time); on timeout, log
#                               the skip and proceed anyway - durable records,
#                               not the stow turn, are the source of truth for
#                               carryover (captain-accepted, report 11.4 open
#                               question 6).
#                            Either way, then exit the old harness process
#                            (graceful exit first, kill only on timeout) and
#                            launch a FRESH primary session in the same pane -
#                            NEVER --resume/--continue. The fresh session's own
#                            SessionStart hook (bin/fm-session-start.sh)
#                            already provides correct carryover.
#
# Presence gate: config/primary-continuity. Per captain decision 2026-09-01
# (report 11.4 open question 5), the watchdog runs ALWAYS ON, not just during
# a nightwatch posture - this deliberately INVERTS the repo's usual
# presence-enables convention for a config/* flag (compare config/calm,
# config/trace-context, config/upstream-autosync, all presence-enables). Here,
# presence of config/primary-continuity OPTS OUT (disables); its absence
# leaves the watchdog enabled. This polarity is intentional and documented
# here and in docs/configuration.md - do not "fix" it to match the other
# flags without a captain decision, since flipping it would silently disable
# the always-on default this section implements.
#
# Safety, non-negotiable:
#   - Only ever acts on the VERIFIED primary pane: refuses to arm when
#     discover_supervisor_target cannot identify the primary's own pane,
#     exactly like the afk daemon's refuse-to-arm rule. Never targets a
#     worker/crewmate pane - there is no worker-targeting code path here at
#     all.
#   - Restart authority is scoped strictly to the usage-limit/high-context
#     condition detected in step 1-2 above. This script has no merge,
#     credential, or destructive-action capability, and no other trigger path
#     reaches fm_watchdog_restart_primary.
#
# Usage:
#   fm-primary-watchdog.sh run        Run the poll/sleep loop in the
#                                      foreground until killed. Intended to be
#                                      hosted by bin/fm-afk-launch.sh /
#                                      bin/fm-supervise-daemon.sh alongside the
#                                      existing daemon process, not run bare.
#   fm-primary-watchdog.sh cycle      Run exactly one detect-or-idle pass and
#                                      exit; used by tests and by callers that
#                                      want to drive the loop externally.
#   fm-primary-watchdog.sh enabled    Print "1" and exit 0 if the presence
#                                      gate allows arming, "0" and exit 1
#                                      otherwise.
#
# Test seams: FM_WATCHDOG_POLL_INTERVAL (loop cadence, default 60s),
# FM_WATCHDOG_RESET_JITTER (default 30s), FM_WATCHDOG_STOW_WINDOW (default
# 600s), FM_WATCHDOG_LAUNCH_CMD (overrides the fresh-session launch command,
# default "claude" with no --resume/--continue flag ever appended),
# FM_WATCHDOG_NOW (epoch seconds override for reset-wait math),
# FM_WATCHDOG_QUOTA_JSON (path to a canned quota-axi --json response instead
# of shelling out, for deterministic tests).
set -u

FM_WATCHDOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_WATCHDOG_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_WATCHDOG_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_WATCHDOG_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$FM_WATCHDOG_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$FM_WATCHDOG_DIR/fm-backend.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$FM_WATCHDOG_DIR/fm-operational-input.sh"

log() { printf '[fm-primary-watchdog] %s\n' "$*" >&2; }

# fm_watchdog_enabled: the presence gate described in the header comment
# above. Presence of config/primary-continuity opts OUT; absence leaves the
# always-on default enabled.
fm_watchdog_enabled() {
  [ ! -e "$FM_WATCHDOG_CONFIG/primary-continuity" ]
}

# fm_watchdog_verified_target: resolve and print "target backend", or return 1
# when the primary's own pane cannot be identified. Mirrors the afk daemon's
# refuse-to-arm-when-unverifiable rule (bin/fm-supervise-daemon.sh's startup
# discovery via discover_supervisor_target).
fm_watchdog_verified_target() {
  local target backend
  target=$(discover_supervisor_target) || {
    log "refusing to arm: cannot identify the primary's own pane"
    return 1
  }
  backend=$(fm_backend_detect 2>/dev/null || printf 'tmux')
  fm_backend_target_exists "$backend" "$target" || {
    log "refusing to arm: verified target does not resolve (target=$target backend=$backend)"
    return 1
  }
  printf '%s %s\n' "$target" "$backend"
}

# Known rendered-output phrasing for Claude Code's usage-limit notice. This is
# a harness-dependent check per firstmate-coding-guidelines "Harness-dependent
# checks": it must be verified against the real harness, not assumed from this
# comment. FM_WATCHDOG_LIMIT_SIGNATURE overrides it for tests and for a future
# harness whose wording differs; keep this default narrow (specific phrases)
# rather than a broad word like "limit" that could false-positive on ordinary
# conversation text.
FM_WATCHDOG_LIMIT_SIGNATURE_DEFAULT='usage limit reached|5-hour limit reached|limit reached.*resets'

# fm_watchdog_primary_blocked: 0 when the verified target shows the
# usage-limit signature or the target itself no longer resolves (harness
# process gone); 1 when neither condition holds (primary looks fine).
fm_watchdog_primary_blocked() {  # <target> <backend>
  local target=$1 backend=$2 tail
  fm_backend_target_exists "$backend" "$target" || {
    log "primary target gone (target=$target backend=$backend)"
    return 0
  }
  tail=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || return 1
  printf '%s' "$tail" | grep -qEi "${FM_WATCHDOG_LIMIT_SIGNATURE:-$FM_WATCHDOG_LIMIT_SIGNATURE_DEFAULT}"
}

# fm_watchdog_reset_wait_seconds: seconds to sleep until the account's
# five_hour session window resets, plus jitter. Reads quota-axi --json (or a
# canned file at FM_WATCHDOG_QUOTA_JSON for tests) and requires `jq`. Prints
# the number of seconds (>= 0) on stdout; returns 1 if resetsAt cannot be
# determined.
fm_watchdog_reset_wait_seconds() {
  local json now reset_epoch wait jitter
  if [ -n "${FM_WATCHDOG_QUOTA_JSON:-}" ]; then
    json=$(cat "$FM_WATCHDOG_QUOTA_JSON") || return 1
  else
    json=$(quota-axi --provider claude --json 2>/dev/null) || return 1
  fi
  reset_epoch=$(printf '%s' "$json" \
    | jq -r '.providers[]? | select(.provider=="claude") | .windows[]? | select(.id=="five_hour") | .resetsAt' \
    | head -1) || return 1
  [ -n "$reset_epoch" ] && [ "$reset_epoch" != null ] || return 1
  reset_epoch=$(date -d "$reset_epoch" +%s 2>/dev/null) || return 1
  now=${FM_WATCHDOG_NOW:-$(date +%s)}
  jitter=${FM_WATCHDOG_RESET_JITTER:-30}
  wait=$((reset_epoch - now + jitter))
  [ "$wait" -lt 0 ] && wait=0
  printf '%s\n' "$wait"
}

# fm_watchdog_inject: repeats inject_msg's (bin/fm-supervise-daemon.sh)
# busy-guard, composer-guard, and verified-submit steps WITHOUT its
# afk_active() gate, because this watchdog must be able to inject regardless
# of away-mode state.
fm_watchdog_inject() {  # <target> <backend> <message>
  local target=$1 backend=$2 msg=$3 encoded verdict retries sleep_s composer
  fm_backend_target_exists "$backend" "$target" || return 1
  if fm_backend_busy_state "$backend" "$target" 2>/dev/null | grep -q busy; then
    log "inject deferred: primary pane busy"
    return 1
  fi
  composer=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
  if [ "$composer" != empty ]; then
    log "inject deferred: primary composer not confirmed-empty (state=${composer:-unknown})"
    return 1
  fi
  fm_operational_input_encode away-supervisor "$msg" encoded || return 1
  retries=${FM_INJECT_CONFIRM_RETRIES:-3}
  sleep_s=${FM_INJECT_CONFIRM_SLEEP:-2}
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$encoded" "$retries" "$sleep_s" "$sleep_s")
  [ "$verdict" = empty ]
}

# fm_watchdog_context_band: prints the band word (ok|warn|restart) for the
# primary's own FM_HOME, via bin/fm-context-usage.sh (the designated
# real-usage source, CLAUDE.md "Context monitoring").
fm_watchdog_context_band() {
  local out
  out=$(FM_HOME="$FM_HOME" "$FM_WATCHDOG_DIR/fm-context-usage.sh" 2>/dev/null) || return 1
  printf '%s' "$out" | grep -oE 'band=[a-z]+' | cut -d= -f2
}

# fm_watchdog_wait_for_stow: poll up to FM_WATCHDOG_STOW_WINDOW seconds
# (default 600) for evidence the injected /stow turn completed
# (state/.stow-last-run newer than the injection time). Returns 0 on evidence
# found, 1 on timeout - a timeout is NOT an error to the caller: report 11.4
# open question 6 (captain-accepted) says proceed to restart anyway.
fm_watchdog_wait_for_stow() {  # <injected-at-epoch>
  local injected_at=$1 window=${FM_WATCHDOG_STOW_WINDOW:-600} interval=15 waited=0 marker
  marker="$FM_WATCHDOG_STATE/.stow-last-run"
  while [ "$waited" -lt "$window" ]; do
    if [ -e "$marker" ]; then
      local mtime
      mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null)
      [ -n "$mtime" ] && [ "$mtime" -ge "$injected_at" ] && return 0
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done
  return 1
}

# fm_watchdog_restart_primary: exits the old harness process (its own graceful
# exit command typed via the verified-submit primitive; kill only after
# FM_WATCHDOG_EXIT_TIMEOUT seconds if the pane is still occupied) and launches
# a FRESH session in the same pane. Never passes --resume/--continue. There is
# no task-id/meta record for the primary (bin/fm-control.sh is worker-scoped),
# so this drives the pane directly rather than through that script.
fm_watchdog_restart_primary() {  # <target> <backend>
  local target=$1 backend=$2 launch_cmd exit_cmd waited timeout
  launch_cmd=${FM_WATCHDOG_LAUNCH_CMD:-claude}
  case " $launch_cmd " in
    *' --resume '*|*' --continue '*)
      log "refusing to restart: launch command must never include --resume/--continue"
      return 1
      ;;
  esac
  exit_cmd=${FM_WATCHDOG_EXIT_CMD:-/exit}
  fm_backend_send_text_submit "$backend" "$target" "$exit_cmd" 3 2 2 >/dev/null 2>&1
  timeout=${FM_WATCHDOG_EXIT_TIMEOUT:-30}
  waited=0
  while [ "$waited" -lt "$timeout" ] && fm_backend_busy_state "$backend" "$target" 2>/dev/null | grep -q busy; do
    sleep 2
    waited=$((waited + 2))
  done
  fm_backend_send_text_submit "$backend" "$target" "$launch_cmd" 3 2 2 >/dev/null 2>&1
}

# fm_watchdog_handle_reset: the reset-time branch (context band -> nudge or
# stow -> restart). Exposed separately from fm_watchdog_cycle for testing.
fm_watchdog_handle_reset() {  # <target> <backend>
  local target=$1 backend=$2 band injected_at
  band=$(fm_watchdog_context_band) || band=ok
  case "$band" in
    warn|restart)
      injected_at=$(date +%s)
      if fm_watchdog_inject "$target" "$backend" "/stow"; then
        fm_watchdog_wait_for_stow "$injected_at" || log "stow window elapsed without completion evidence; proceeding to restart anyway (captain-accepted, report 11.4 Q6)"
      else
        log "stow injection failed; proceeding to restart anyway"
      fi
      ;;
    *)
      fm_watchdog_inject "$target" "$backend" "check queued wakes" || log "nudge injection failed"
      return 0
      ;;
  esac
  fm_watchdog_restart_primary "$target" "$backend"
}

# fm_watchdog_cycle: one detect-or-idle pass. On a blocked verdict, sleeps
# until reset (real sleep in production; tests inject FM_WATCHDOG_NOW/a canned
# quota response and stub the sleep boundary via FM_WATCHDOG_SKIP_SLEEP=1
# instead of sleeping for real hours).
fm_watchdog_cycle() {
  local tb target backend wait
  tb=$(fm_watchdog_verified_target) || return 1
  target=${tb% *}
  backend=${tb#* }
  fm_watchdog_primary_blocked "$target" "$backend" || return 0
  log "primary blocked (target=$target backend=$backend); computing reset wait"
  wait=$(fm_watchdog_reset_wait_seconds) || {
    log "could not determine reset time; deferring to next poll"
    return 1
  }
  if [ "${FM_WATCHDOG_SKIP_SLEEP:-0}" != 1 ] && [ "$wait" -gt 0 ]; then
    sleep "$wait"
  fi
  fm_watchdog_handle_reset "$target" "$backend"
}

fm_watchdog_main() {
  fm_watchdog_enabled || { log "primary-continuity watchdog disabled (config/primary-continuity present)"; return 0; }
  fm_watchdog_verified_target >/dev/null || return 1
  while true; do
    fm_watchdog_cycle
    sleep "${FM_WATCHDOG_POLL_INTERVAL:-60}"
  done
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-run}" in
    run) fm_watchdog_main ;;
    cycle) fm_watchdog_cycle ;;
    enabled)
      if fm_watchdog_enabled; then printf '1\n'; exit 0; else printf '0\n'; exit 1; fi
      ;;
    *)
      echo "usage: fm-primary-watchdog.sh [run|cycle|enabled]" >&2
      exit 2
      ;;
  esac
fi
