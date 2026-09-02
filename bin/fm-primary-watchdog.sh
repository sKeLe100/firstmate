#!/usr/bin/env bash
# fm-primary-watchdog.sh - primary continuity watchdog (report.md
# data/overnight-supervisor-mode-design section 11): a small, presence-gated
# loop that runs as a SEPARATE OS process from the primary firstmate session
# and gets a usage-limit-blocked (or crashed) primary back to a working
# session at reset, without a captain having to notice and intervene.
#
# Armed always-on through bin/fm-watch-arm.sh (the same Stop-hook auto-arm
# chain that keeps the watcher alive), independent of the /afk lifecycle, and
# reuses the afk/supervise-daemon machinery's pane
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
#                               FM_WATCHDOG_STOW_WINDOW seconds (default
#                               1800, comfortably longer than a full
#                               secondmate cascade)
#                               for completion evidence (state/.stow-last-run,
#                               written by bin/fm-stow-cascade.sh once a pass's
#                               own sweep is done, newer than the inject time);
#                               on timeout, log
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
#                                      foreground until killed. Normally
#                                      reached through `arm`, not run bare.
#   fm-primary-watchdog.sh arm        Idempotent always-on arming: attach to a
#                                      live loop for this home or start one
#                                      detached (setsid) and verify it came
#                                      up. Called best-effort from
#                                      bin/fm-watch-arm.sh so the watchdog
#                                      rides the same Stop-hook auto-arm chain
#                                      that keeps the watcher alive
#                                      (bin/fm-claude-stop-autoarm.sh),
#                                      independent of /afk state - the
#                                      captain's 2026-09-01 always-on
#                                      decision.
#   fm-primary-watchdog.sh cycle      Run exactly one detect-or-idle pass and
#                                      exit; used by tests and by callers that
#                                      want to drive the loop externally.
#   fm-primary-watchdog.sh enabled    Print "1" and exit 0 if the presence
#                                      gate allows arming, "0" and exit 1
#                                      otherwise.
#
# Test seams: FM_WATCHDOG_POLL_INTERVAL (loop cadence, default 60s),
# FM_WATCHDOG_RESET_JITTER (default 30s), FM_WATCHDOG_STOW_WINDOW (default
# 1800s), FM_WATCHDOG_LAUNCH_CMD (overrides the fresh-session launch command,
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
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_WATCHDOG_DIR/fm-composer-lib.sh"

log() { printf '[fm-primary-watchdog] %s\n' "$*" >&2; }

# fm_watchdog_enabled: the presence gate described in the header comment
# above. Presence of config/primary-continuity opts OUT; absence leaves the
# always-on default enabled.
# FM_WATCHDOG_DISABLE=1 is a process-scoped test seam so suites that exercise
# the arm chain (tests/fm-watch-arm.test.sh) never spawn a real detached loop;
# operators use the durable config flag, not this env.
fm_watchdog_enabled() {
  [ "${FM_WATCHDOG_DISABLE:-0}" != 1 ] || return 1
  [ ! -e "$FM_WATCHDOG_CONFIG/primary-continuity" ]
}

# fm_watchdog_verified_target: resolve and print "target backend". Returns 1
# (refuse to arm, nothing printed) when the primary's own pane cannot be
# identified at all - the afk daemon's refuse-to-arm-when-unverifiable rule
# (bin/fm-supervise-daemon.sh's startup discovery via
# discover_supervisor_target). Returns 2 when the identity IS known but the
# pane does not currently resolve: that is the harness-gone condition, still
# printed so the caller can act on it. The backend comes from
# discover_supervisor_backend so an FM_SUPERVISOR_BACKEND exported alongside
# FM_SUPERVISOR_TARGET by the daemon is honored rather than re-detected from
# this process's own environment.
fm_watchdog_verified_target() {
  local target backend
  target=$(discover_supervisor_target) || {
    log "refusing to arm: cannot identify the primary's own pane"
    return 1
  }
  backend=$(discover_supervisor_backend 2>/dev/null || true)
  [ -n "$backend" ] || backend=tmux
  printf '%s %s\n' "$target" "$backend"
  fm_backend_target_exists "$backend" "$target" || {
    log "verified target does not currently resolve (target=$target backend=$backend)"
    return 2
  }
}

# Known rendered-output phrasing for Claude Code's usage-limit notice. This is
# a harness-dependent check per firstmate-coding-guidelines "Harness-dependent
# checks": it must be verified against the real harness, not assumed from this
# comment. FM_WATCHDOG_LIMIT_SIGNATURE overrides it for tests and for a future
# harness whose wording differs; keep this default narrow (specific phrases)
# rather than a broad word like "limit" that could false-positive on ordinary
# conversation text.
# The stow request is deliberately prose, not a bare "/stow": every injection
# here goes through the operational-input envelope, and a marker-prefixed line
# reaches the harness as chat rather than as a parser command (bin/fm-send.sh
# header), so a leading slash would never invoke the skill.
FM_WATCHDOG_STOW_REQUEST=${FM_WATCHDOG_STOW_REQUEST:-"run the /stow skill now to checkpoint durable state; this session is about to be restarted for context"}

FM_WATCHDOG_TRANSCRIPT_PIN="$FM_WATCHDOG_STATE/.primary-watchdog.transcript"

FM_WATCHDOG_LIMIT_SIGNATURE_DEFAULT='usage limit reached|5-hour limit reached|limit reached.*resets'

# fm_watchdog_liveness_target: the target form the backend's liveness readers
# (fm_backend_agent_state / fm_backend_busy_state) accept. discover_supervisor_
# target pins a tmux pane as a bare pane id ("%12"), which the tmux adapter
# rejects as unreadable, so resolve it to the session:window that adapter reads.
# A session:window target is only accepted when that window holds exactly the
# pinned pane: a window with a split redirects every read to whichever pane is
# active (bin/fm-supervisor-target-lib.sh, the 2026-08-26 inject wedge), so an
# ambiguous window is reported unresolvable and every caller refuses to act.
# A window target supplied directly (FM_SUPERVISOR_TARGET=firstmate:main) is
# redirectable the same way, so it gets the same exactly-one-pane check, and a
# target naming a pane index (session:window.0) is resolved to its pane id and
# put through that same check rather than passed to a reader that would read
# "main.0" as a window name and report it missing.
# Prints the usable target, or returns 1 when it cannot be resolved.
fm_watchdog_liveness_target() {  # <target> <backend>
  local target=$1 backend=$2 resolved panes pane
  case "$backend" in
    tmux) ;;
    *) printf '%s\n' "$target"; return 0 ;;
  esac
  case "$target" in
    %*|*:*.[0-9]*)
      pane=$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null) || return 1
      resolved=$(tmux display-message -p -t "$target" '#{session_name}:#{window_name}' 2>/dev/null) || return 1
      [ -n "$pane" ] && [ -n "$resolved" ] || return 1
      panes=$(tmux list-panes -t "$resolved" -F '#{pane_id}' 2>/dev/null) || return 1
      [ "$panes" = "$pane" ] || return 1
      printf '%s\n' "$resolved"
      ;;
    *:*)
      panes=$(tmux list-panes -t "$target" -F '#{pane_id}' 2>/dev/null) || return 1
      case "$panes" in ''|*[!%0-9]*) return 1 ;; esac
      printf '%s\n' "$target"
      ;;
    *) return 1 ;;
  esac
}

# fm_watchdog_agent_state: the backend's liveness verdict for the primary,
# read through the normalized liveness target. Prints alive|dead|unknown.
fm_watchdog_agent_state() {  # <target> <backend>
  local live
  live=$(fm_watchdog_liveness_target "$1" "$2") || { printf 'unknown\n'; return 0; }
  fm_backend_agent_alive "$2" "$live" 2>/dev/null || printf 'unknown\n'
}

# fm_watchdog_primary_blocked: 0 with the reason printed on stdout when the
# primary needs the watchdog, 1 (nothing printed) when it looks fine. Reasons:
#   limit        - the pane is alive and renders the usage-limit signature.
#   gone-harness - the pane is alive but its agent process is authoritatively
#                  dead (a crashed/exited harness, the actionable half of
#                  intent requirement 1); a fresh session can be launched right
#                  there, with no quota reset to wait for.
#   gone-pane    - the pane itself no longer resolves. Nothing can be typed
#                  into it, so the caller reports rather than acts.
fm_watchdog_primary_blocked() {  # <target> <backend>
  local target=$1 backend=$2 tail
  fm_backend_target_exists "$backend" "$target" || {
    log "primary target gone (target=$target backend=$backend)"
    printf 'gone-pane\n'
    return 0
  }
  if [ "$(fm_watchdog_agent_state "$target" "$backend")" = dead ]; then
    log "primary harness process gone (target=$target backend=$backend)"
    printf 'gone-harness\n'
    return 0
  fi
  tail=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || return 1
  printf '%s' "$tail" | grep -qEi "${FM_WATCHDOG_LIMIT_SIGNATURE:-$FM_WATCHDOG_LIMIT_SIGNATURE_DEFAULT}" || return 1
  printf 'limit\n'
}

# fm_watchdog_epoch_of: epoch seconds for an ISO-8601 resetsAt, on GNU date and
# on BSD/macOS date. The offset-bearing form must be tried FIRST and with its
# colon removed ("+00:00" -> "+0000"), because BSD %z does not accept a
# colon-bearing offset and the offset-less format would otherwise match the
# leading characters and silently reinterpret the timestamp as local time.
fm_watchdog_epoch_of() {  # <iso-8601>
  local raw=$1 base offset epoch
  if [ "$(date -d 2001-02-03T04:05:06Z +%s 2>/dev/null)" = 981173106 ]; then
    epoch=$(date -d "$raw" +%s 2>/dev/null) && [ -n "$epoch" ] && { printf '%s\n' "$epoch"; return 0; }
  fi
  base=${raw%%.*}
  case "$raw" in
    *Z|*z)
      base=${base%[Zz]}
      offset='+0000'
      ;;
    *[+-][0-9][0-9]:[0-9][0-9])
      offset=${raw: -6}
      offset=${offset/:/}
      base=${base%[+-][0-9][0-9]:[0-9][0-9]}
      ;;
    *[+-][0-9][0-9][0-9][0-9])
      offset=${raw: -5}
      base=${base%[+-][0-9][0-9][0-9][0-9]}
      ;;
    *) offset='' ;;
  esac
  if [ -n "$offset" ]; then
    epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$base$offset" +%s 2>/dev/null) \
      && [ -n "$epoch" ] && { printf '%s\n' "$epoch"; return 0; }
    return 1
  fi
  epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$base" +%s 2>/dev/null) \
    && [ -n "$epoch" ] && { printf '%s\n' "$epoch"; return 0; }
  return 1
}

# fm_watchdog_reset_wait_seconds: seconds to sleep until the account's
# five_hour session window resets, plus jitter. Reads quota-axi --json (or a
# canned file at FM_WATCHDOG_QUOTA_JSON for tests) and requires `jq`. Prints
# "<seconds-to-sleep> <reset-epoch>" on stdout - the seconds are clamped at 0
# for an already-past reset, while the epoch stays the unclamped identity of
# the reset window so a caller can tell one window from the next. Returns 1 if
# resetsAt cannot be determined.
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
  reset_epoch=$(fm_watchdog_epoch_of "$reset_epoch") || return 1
  [ -n "$reset_epoch" ] || return 1
  now=${FM_WATCHDOG_NOW:-$(date +%s)}
  jitter=${FM_WATCHDOG_RESET_JITTER:-30}
  wait=$((reset_epoch - now + jitter))
  [ "$wait" -lt 0 ] && wait=0
  printf '%s %s\n' "$wait" "$reset_epoch"
}

# fm_watchdog_pane_busy: the daemon's pane_is_busy guard
# (bin/fm-supervise-daemon.sh), repeated here because fm_backend_busy_state is
# hardcoded to `unknown` on tmux and the rendered-tail match is the only real
# busy evidence there. It fails CLOSED: an unidentifiable harness (no busy-line
# pattern exists for it) or a failed capture reports BUSY, because this guard
# is what stands between an injection or an /exit and a live captain turn, and
# absence of evidence is not evidence of an idle pane.
fm_watchdog_pane_busy() {  # <target> <backend>
  local target=$1 backend=$2 native harness tail40
  native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)
  [ "$native" = busy ] && return 0
  harness=$("$FM_WATCHDOG_DIR/fm-harness.sh" 2>/dev/null || printf 'unknown')
  case "${harness:-unknown}" in
    unknown|'')
      log "treating the primary pane as busy: harness could not be identified, so no busy-line pattern applies"
      return 0
      ;;
  esac
  tail40=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || {
    log "treating the primary pane as busy: pane capture failed, so idleness is unproven"
    return 0
  }
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -12 \
    | fm_busy_lines_match "$harness"
}

# fm_watchdog_inject: repeats inject_msg's (bin/fm-supervise-daemon.sh)
# busy-guard, composer-guard, and verified-submit steps WITHOUT its
# afk_active() gate, because this watchdog must be able to inject regardless
# of away-mode state. Returns 2 when a guard DEFERRED (the pane must not be
# touched at all) and 1 when a submit was attempted and failed, so a caller can
# tell "do not act on this pane" from "the message did not land".
fm_watchdog_inject() {  # <target> <backend> <message>
  local target=$1 backend=$2 msg=$3 encoded verdict retries sleep_s composer
  fm_backend_target_exists "$backend" "$target" || return 1
  if fm_watchdog_pane_busy "$target" "$backend"; then
    log "inject deferred: primary pane busy"
    return 2
  fi
  composer=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
  if [ "$composer" != empty ]; then
    log "inject deferred: primary composer not confirmed-empty (state=${composer:-unknown})"
    return 2
  fi
  fm_operational_input_encode away-supervisor "$msg" encoded || return 1
  retries=${FM_INJECT_CONFIRM_RETRIES:-3}
  sleep_s=${FM_INJECT_CONFIRM_SLEEP:-2}
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$encoded" "$retries" "$sleep_s" "$sleep_s")
  [ "$verdict" = empty ]
}

# fm_watchdog_primary_transcript / fm_watchdog_pin_primary_transcript: the
# primary session's own transcript identity. bin/fm-context-usage.sh with no
# argument reads the most recently modified transcript for this home, which is
# NOT necessarily the primary: a limit-blocked primary stops appending, so any
# other session started in the same home overtakes it and its smaller context
# would be reported as the primary's band. Arming happens from inside the
# primary's own session (the Stop-hook chain), so the newest transcript at arm
# time is the primary's; it is pinned there and passed explicitly here.
# FM_WATCHDOG_TRANSCRIPT overrides the pin for tests.
fm_watchdog_primary_transcript() {
  local pinned=${FM_WATCHDOG_TRANSCRIPT:-}
  [ -n "$pinned" ] || pinned=$(cat "$FM_WATCHDOG_TRANSCRIPT_PIN" 2>/dev/null)
  [ -n "$pinned" ] && [ -f "$pinned" ] || return 1
  printf '%s\n' "$pinned"
}

fm_watchdog_pin_primary_transcript() {
  local munged proj newest
  munged=$(printf '%s' "$FM_HOME" | tr -c 'a-zA-Z0-9' '-')
  proj="$HOME/.claude/projects/$munged"
  [ -d "$proj" ] || return 1
  newest=$(find "$proj" -maxdepth 1 -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-)
  [ -n "$newest" ] || return 1
  mkdir -p "$FM_WATCHDOG_STATE" 2>/dev/null || return 1
  printf '%s\n' "$newest" >"$FM_WATCHDOG_TRANSCRIPT_PIN" 2>/dev/null || return 1
}

# fm_watchdog_context_band: prints the band word (ok|warn|restart) for the
# primary's own FM_HOME, via bin/fm-context-usage.sh (the designated
# real-usage source, CLAUDE.md "Context monitoring").
fm_watchdog_context_band() {
  local out band transcript
  transcript=$(fm_watchdog_primary_transcript) || {
    log "no pinned primary transcript; refusing to read some other session's context"
    return 1
  }
  out=$(FM_HOME="$FM_HOME" "$FM_WATCHDOG_DIR/fm-context-usage.sh" "$transcript" 2>/dev/null) || return 1
  band=$(printf '%s' "$out" | grep -oE 'band=[a-z]+' | head -1 | cut -d= -f2)
  case "$band" in
    ok|warn|restart) printf '%s\n' "$band" ;;
    *) return 1 ;;
  esac
}

# fm_watchdog_wait_for_stow: poll up to FM_WATCHDOG_STOW_WINDOW seconds
# (default 1800 - the marker is stamped only when the whole skill-driven
# cascade completes, which for a home with agent-transport secondmates
# includes each secondmate running its own /stow and reporting back) for
# evidence the injected /stow turn completed
# (state/.stow-last-run, the marker bin/fm-stow-cascade.sh writes once a pass's
# own sweep is complete, newer than the injection time). Returns 0 on evidence
# found, 1 on timeout - a timeout is NOT an error to the caller: report 11.4
# open question 6 (captain-accepted) says proceed to restart anyway.
fm_watchdog_wait_for_stow() {  # <injected-at-epoch>
  local injected_at=$1 window=${FM_WATCHDOG_STOW_WINDOW:-1800} interval=15 waited=0 marker
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
  fm_backend_target_exists "$backend" "$target" || {
    log "refusing to restart: target does not resolve (target=$target backend=$backend)"
    return 1
  }
  fm_watchdog_liveness_target "$target" "$backend" >/dev/null || {
    log "refusing to restart: liveness verdict unreadable for this target, so the old harness could never be confirmed exited (target=$target backend=$backend)"
    return 1
  }
  fm_backend_send_text_submit "$backend" "$target" "$exit_cmd" 3 2 2 >/dev/null 2>&1
  timeout=${FM_WATCHDOG_EXIT_TIMEOUT:-30}
  waited=0
  while [ "$waited" -lt "$timeout" ] && [ "$(fm_watchdog_agent_state "$target" "$backend")" != dead ]; do
    sleep 2
    waited=$((waited + 2))
  done
  if [ "$(fm_watchdog_agent_state "$target" "$backend")" != dead ]; then
    fm_backend_send_key "$backend" "$target" C-c >/dev/null 2>&1
    sleep "${FM_WATCHDOG_EXIT_SETTLE:-2}"
    if [ "$(fm_watchdog_agent_state "$target" "$backend")" != dead ]; then
      log "old harness not confirmed exited; refusing to type the launch command into a possibly live session"
      return 1
    fi
  fi
  fm_watchdog_launch_primary "$target" "$backend"
}

# fm_watchdog_launch_primary: launch a FRESH session in the pane, with no old
# harness to exit first (the crashed-harness path). Same never-resume rule.
fm_watchdog_launch_primary() {  # <target> <backend>
  local target=$1 backend=$2 launch_cmd
  launch_cmd=${FM_WATCHDOG_LAUNCH_CMD:-claude}
  case " $launch_cmd " in
    *' --resume '*|*' --continue '*)
      log "refusing to launch: launch command must never include --resume/--continue"
      return 1
      ;;
  esac
  fm_backend_target_exists "$backend" "$target" || {
    log "refusing to launch: target does not resolve (target=$target backend=$backend)"
    return 1
  }
  log "launching a fresh primary session (target=$target backend=$backend)"
  rm -f "$FM_WATCHDOG_TRANSCRIPT_PIN" 2>/dev/null || true
  fm_backend_send_text_submit "$backend" "$target" "$launch_cmd" 3 2 2 >/dev/null 2>&1
}

# fm_watchdog_handle_reset: the reset-time branch (context band -> nudge or
# stow -> restart). Exposed separately from fm_watchdog_cycle for testing.
fm_watchdog_handle_reset() {  # <target> <backend>
  local target=$1 backend=$2 band injected_at
  fm_watchdog_liveness_target "$target" "$backend" >/dev/null || {
    log "abandoning the pass: liveness verdict unreadable for this target, so a restart could never be confirmed (target=$target backend=$backend)"
    return 1
  }
  band=$(fm_watchdog_context_band) || {
    band=ok
    log "context band unreadable; treating as band=ok (nudge only)"
  }
  case "$band" in
    warn|restart)
      injected_at=$(date +%s)
      fm_watchdog_inject "$target" "$backend" "$FM_WATCHDOG_STOW_REQUEST"
      case $? in
        0) fm_watchdog_wait_for_stow "$injected_at" || log "stow window elapsed without completion evidence; proceeding to restart anyway (captain-accepted, report 11.4 Q6)" ;;
        2)
          log "abandoning the pass: an inject guard deferred, so the pane must not be exited"
          return 1
          ;;
        *) log "stow injection failed; proceeding to restart anyway" ;;
      esac
      ;;
    *)
      fm_watchdog_inject "$target" "$backend" "check queued wakes" || {
        log "nudge injection failed"
        return 1
      }
      return 0
      ;;
  esac
  fm_watchdog_restart_primary "$target" "$backend"
}

# fm_watchdog_cooldown_clear / fm_watchdog_record_action: bound how often a
# blocked verdict may act. The usage-limit banner typically stays rendered in
# the pane after a nudge or a relaunch, so without this the next poll matches
# the same scrollback, computes a now-past reset (clamped to 0) and acts again
# every poll interval. Clear (0) means the last recorded action is older than
# FM_WATCHDOG_COOLDOWN seconds and the caller may act; 1 means still cooling.
fm_watchdog_cooldown_clear() {
  local marker="$FM_WATCHDOG_STATE/.watchdog-last-action" last now cooldown
  cooldown=${FM_WATCHDOG_COOLDOWN:-900}
  [ -r "$marker" ] || return 0
  last=$(cat "$marker" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) return 0 ;; esac
  now=${FM_WATCHDOG_NOW:-$(date +%s)}
  if [ "$((now - last))" -lt "$cooldown" ]; then
    log "skipping: last watchdog action was $((now - last))s ago (cooldown ${cooldown}s)"
    return 1
  fi
  return 0
}

fm_watchdog_record_action() {
  mkdir -p "$FM_WATCHDOG_STATE" 2>/dev/null || return 0
  printf '%s\n' "${FM_WATCHDOG_NOW:-$(date +%s)}" >"$FM_WATCHDOG_STATE/.watchdog-last-action" 2>/dev/null || true
}

# fm_watchdog_reset_unhandled / fm_watchdog_record_reset: one reset window is
# acted on exactly once. The limit banner stays in the pane's scrollback after
# a nudge, so rate-limiting alone would let the same already-past reset be
# re-handled every cooldown window forever; the handled reset epoch is the
# identity that stops it.
fm_watchdog_reset_unhandled() {  # <reset-epoch>
  local handled marker="$FM_WATCHDOG_STATE/.watchdog-last-reset"
  [ -r "$marker" ] || return 0
  handled=$(cat "$marker" 2>/dev/null)
  if [ "$handled" = "$1" ]; then
    log "skipping: reset window $1 has already been handled"
    return 1
  fi
  return 0
}

fm_watchdog_record_reset() {  # <reset-epoch>
  mkdir -p "$FM_WATCHDOG_STATE" 2>/dev/null || return 0
  printf '%s\n' "$1" >"$FM_WATCHDOG_STATE/.watchdog-last-reset" 2>/dev/null || true
}

# fm_watchdog_dead_streak_bump / fm_watchdog_dead_streak_clear: consecutive
# observations of an authoritatively dead harness. A single dead reading is not
# acted on: the backend reports `dead` whenever the pane's foreground process
# group is only shells, which is exactly the captain exiting the harness to run
# shell work, and relaunching there would type the launch command at their
# prompt. FM_WATCHDOG_DEAD_CONFIRMATIONS (default 2) consecutive polls must see
# it before a relaunch; any other verdict clears the streak.
fm_watchdog_dead_streak_bump() {
  local marker="$FM_WATCHDOG_STATE/.watchdog-dead-streak" count
  count=$(cat "$marker" 2>/dev/null)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  count=$((count + 1))
  mkdir -p "$FM_WATCHDOG_STATE" 2>/dev/null || true
  printf '%s\n' "$count" >"$marker" 2>/dev/null || true
  printf '%s\n' "$count"
}

fm_watchdog_dead_streak_clear() {
  rm -f "$FM_WATCHDOG_STATE/.watchdog-dead-streak" 2>/dev/null || true
}

# fm_watchdog_cycle: one detect-or-idle pass. On a blocked verdict, sleeps
# until reset (real sleep in production; tests inject FM_WATCHDOG_NOW/a canned
# quota response and stub the sleep boundary via FM_WATCHDOG_SKIP_SLEEP=1
# instead of sleeping for real hours).
fm_watchdog_cycle() {
  local tb rc target backend wait reset reason streak
  fm_watchdog_enabled || return 0
  tb=$(fm_watchdog_verified_target)
  rc=$?
  [ "$rc" -ne 1 ] && [ -n "$tb" ] || return 1
  target=${tb% *}
  backend=${tb#* }
  reason=$(fm_watchdog_primary_blocked "$target" "$backend") || {
    fm_watchdog_dead_streak_clear
    return 0
  }
  [ "$reason" = gone-harness ] || fm_watchdog_dead_streak_clear
  case "$reason" in
    gone-pane)
      log "primary pane no longer exists; nothing to restart in place"
      return 1
      ;;
    gone-harness)
      streak=$(fm_watchdog_dead_streak_bump)
      if [ "$streak" -lt "${FM_WATCHDOG_DEAD_CONFIRMATIONS:-2}" ]; then
        log "harness read as gone (observation $streak); waiting for the next poll to confirm before relaunching"
        return 0
      fi
      fm_watchdog_cooldown_clear || return 0
      fm_watchdog_record_action
      fm_watchdog_launch_primary "$target" "$backend"
      rc=$?
      fm_watchdog_dead_streak_clear
      return "$rc"
      ;;
  esac
  fm_watchdog_cooldown_clear || return 0
  log "primary blocked (target=$target backend=$backend); computing reset wait"
  reset=$(fm_watchdog_reset_wait_seconds) || {
    log "could not determine reset time; deferring to next poll"
    return 1
  }
  wait=${reset% *}
  reset=${reset#* }
  fm_watchdog_reset_unhandled "$reset" || return 0
  if [ "${FM_WATCHDOG_SKIP_SLEEP:-0}" != 1 ] && [ "$wait" -gt 0 ]; then
    sleep "$wait"
  fi
  reason=$(fm_watchdog_primary_blocked "$target" "$backend") || {
    log "primary is no longer blocked at reset; abandoning this pass"
    return 0
  }
  [ "$reason" = limit ] || {
    log "primary condition changed to $reason at reset; abandoning this pass"
    return 0
  }
  fm_watchdog_record_action
  fm_watchdog_handle_reset "$target" "$backend" || return 1
  fm_watchdog_record_reset "$reset"
}

# --- always-on singleton + arm ----------------------------------------------
# One loop per home, tracked in a pidfile under this home's state/. The pid
# read is advisory (pid reuse is possible after a crash); the cooldown and
# reset-identity guards above bound the harm of a rare duplicate, and `arm` is
# the only spawner so steady state converges to exactly one loop.
FM_WATCHDOG_PIDFILE="$FM_WATCHDOG_STATE/.primary-watchdog.pid"

# Prints the live holder's pid and returns 0, or returns 1 when no live loop
# holds this home's pidfile.
fm_watchdog_singleton_live() {
  local pid
  [ -r "$FM_WATCHDOG_PIDFILE" ] || return 1
  pid=$(cat "$FM_WATCHDOG_PIDFILE" 2>/dev/null)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}

# fm_watchdog_arm: idempotent, best-effort, home-scoped. Attaches to a live
# loop, or starts one detached in its own session (setsid, so the caller's -
# typically a Stop hook's - process-group teardown cannot reap it) and
# verifies the loop claimed the pidfile. A refusal to arm (disabled flag,
# unverifiable primary pane) is reported, never retried in a tight loop.
fm_watchdog_arm() {
  local live pid i
  fm_watchdog_enabled || { log "primary-continuity watchdog disabled (config/primary-continuity present)"; return 0; }
  fm_watchdog_pin_primary_transcript || log "could not pin the primary's transcript; context bands will be unreadable until the next arm"
  if live=$(fm_watchdog_singleton_live); then
    printf 'primary-watchdog: attached pid=%s\n' "$live"
    return 0
  fi
  mkdir -p "$FM_WATCHDOG_STATE" 2>/dev/null || return 1
  setsid "$FM_WATCHDOG_DIR/fm-primary-watchdog.sh" run \
    >>"$FM_WATCHDOG_STATE/.primary-watchdog.log" 2>&1 </dev/null &
  pid=$!
  i=0
  while [ "$i" -lt 20 ]; do
    if live=$(fm_watchdog_singleton_live); then
      printf 'primary-watchdog: started pid=%s\n' "$live"
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
    i=$((i + 1))
  done
  printf 'primary-watchdog: FAILED - loop did not come up (see %s)\n' "$FM_WATCHDOG_STATE/.primary-watchdog.log"
  return 1
}

fm_watchdog_main() {
  local live
  fm_watchdog_enabled || { log "primary-continuity watchdog disabled (config/primary-continuity present)"; return 0; }
  fm_watchdog_verified_target >/dev/null
  [ "$?" -ne 1 ] || return 1
  if live=$(fm_watchdog_singleton_live) && [ "$live" != "$$" ]; then
    log "another watchdog loop (pid $live) already owns this home; exiting"
    return 0
  fi
  mkdir -p "$FM_WATCHDOG_STATE" 2>/dev/null || return 1
  printf '%s\n' "$$" >"$FM_WATCHDOG_PIDFILE" || return 1
  while true; do
    fm_watchdog_cycle
    sleep "${FM_WATCHDOG_POLL_INTERVAL:-60}"
  done
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-run}" in
    run) fm_watchdog_main ;;
    arm) fm_watchdog_arm ;;
    cycle) fm_watchdog_cycle ;;
    enabled)
      if fm_watchdog_enabled; then printf '1\n'; exit 0; else printf '0\n'; exit 1; fi
      ;;
    *)
      echo "usage: fm-primary-watchdog.sh [run|arm|cycle|enabled]" >&2
      exit 2
      ;;
  esac
fi
