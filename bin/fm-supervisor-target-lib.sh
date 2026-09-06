#!/usr/bin/env bash
# fm-supervisor-target-lib.sh - the single owner of supervisor-pane discovery.
#
# The away-mode daemon (bin/fm-supervise-daemon.sh) must know which pane runs
# firstmate itself, both to inject escalations into it and, for the daemon, to
# validate that target at startup. The script-owned away launcher
# (bin/fm-afk-launch.sh) must resolve the SAME captain pane BEFORE it creates a
# separate, non-visible terminal for the daemon, so it can pass that pane in as
# FM_SUPERVISOR_TARGET (otherwise the daemon, running in its own terminal, would
# auto-discover its OWN pane and inject there instead of into the captain's).
#
# Because both callers need the identical resolution, it lives here once. The
# function names and precedence are unchanged from when this logic lived inline
# in bin/fm-supervise-daemon.sh, so its unit tests (tests/fm-daemon.test.sh)
# keep exercising the same names after the daemon sources this file.

# Default supervisor pane target/backend when nothing is configured or detected.
# "firstmate:0" is a tmux session:window name, so the bare fallback (nothing
# configured, nothing detected) assumes tmux - matching the daemon's pre-herdr
# behavior byte-for-byte when run outside both tmux and herdr.
FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"
FM_SUPERVISOR_BACKEND_DEFAULT="tmux"

# Supervisor backends the daemon's injection primitives (and this validation)
# actually cover today. zellij, orca, and cmux are real backends elsewhere in
# firstmate (bin/fm-backend.sh) but have no verified composer/busy primitives
# wired up here yet - see docs/herdr-backend.md and AGENTS.md section 4's
# harness-verification discipline. Owned here (not in fm-supervise-daemon.sh)
# so the away-mode launcher's pre-arm check can share the exact same list.
FM_SUPERVISOR_SUPPORTED_BACKENDS="tmux herdr"

# validate_supervisor_target: the single owner of "is this backend+target a
# usable away-mode delivery path", shared by the daemon's own startup refusal
# and the launcher's pre-arm check so a target that would make the daemon
# refuse can never get as far as writing state/.afk in the first place
# (2026-08-27 afk-delivery-unreachable review). Two checks, cheapest first:
#   1. the backend is one FM_SUPERVISOR_SUPPORTED_BACKENDS covers.
#   2. the target actually resolves to a live pane under that backend
#      (fm_backend_target_exists - the same read-only probe the daemon uses).
# Prints a short machine-readable reason on failure for the caller to report
# in its own words; returns 0 on success.
validate_supervisor_target() {  # <backend> <target>
  local backend="$1" target="$2"
  if ! fm_backend_list_contains "$FM_SUPERVISOR_SUPPORTED_BACKENDS" "$backend"; then
    printf 'unsupported-backend'
    return 1
  fi
  if ! fm_backend_target_exists "$backend" "$target"; then
    printf 'target-not-found'
    return 1
  fi
  return 0
}

# discover_supervisor_target: resolve the pane running firstmate. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) - may be a tmux target or a
#      herdr "<session>:<pane-id>" target (paired with discover_supervisor_backend
#      to know which).
#   2. $TMUX_PANE - tmux sets this in every pane's environment; inherited by a
#      process launched from firstmate's own pane.
#   3. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr injects both into every process it
#      manages a pane for; compose the "<session>:<pane-id>" target from
#      $HERDR_SESSION (defaulting to "default", mirroring bin/backends/herdr.sh's
#      fm_backend_herdr_session) and $HERDR_PANE_ID. Checked after $TMUX_PANE so a
#      tmux pane nested inside herdr still resolves to tmux, matching
#      fm_backend_detect's innermost-first rule.
#   4. FM_SUPERVISOR_TARGET_DEFAULT - legacy tmux fallback (may not resolve if the
#      session is named differently). Returns 1 so the caller can warn.
discover_supervisor_target() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  # Legacy bare fallback, returned with status 1: every current caller treats
  # that non-zero status as fatal (bin/fm-supervise-daemon.sh refuses to arm
  # away mode when no source identified the primary's own pane;
  # bin/fm-afk-launch.sh aborts the launch), so the value below is diagnostic
  # only and is never armed into. It is kept - rather than collapsed into a
  # bare `return 1` - so any future caller that chooses to proceed anyway gets
  # the concrete pinned pane id instead of the redirectable window target.
  #
  # FM_SUPERVISOR_TARGET_DEFAULT ("firstmate:0") is a
  # tmux session:WINDOW target, not a pane. A window target resolves to
  # whichever pane is ACTIVE in that window at read time, so once the daemon
  # stores this into FM_SUPERVISOR_TARGET, a later focus change to a
  # different split in that window silently redirects every subsequent
  # composer read to the wrong pane forever (confirmed root cause of the
  # 2026-08-26 away-mode inject wedge: the daemon logged
  # target_source=FALLBACK(firstmate:0) and read an unrelated split's
  # content as "unknown" indefinitely). Resolve and pin the CONCRETE active
  # pane id now, at discovery time, so the caller stores an id a later focus
  # change cannot redirect. If tmux can't resolve it (not installed, no such
  # session), fall through to the legacy bare string unchanged.
  local pinned
  if pinned=$(tmux display-message -p -t "$FM_SUPERVISOR_TARGET_DEFAULT" '#{pane_id}' 2>/dev/null) && [ -n "$pinned" ]; then
    printf '%s' "$pinned"
    return 1
  fi
  printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"
  return 1
}

# discover_supervisor_backend: resolve the supervisor pane's BACKEND, independent
# of the target string so an explicit FM_SUPERVISOR_TARGET override still knows
# which primitives (tmux vs herdr) to dispatch through. Priority mirrors
# discover_supervisor_target and bin/fm-backend.sh's fm_backend_detect:
#   1. FM_SUPERVISOR_BACKEND env (explicit override).
#   2. $TMUX_PANE set - tmux.
#   3. $HERDR_ENV=1 (with $HERDR_PANE_ID present) - herdr.
#   4. FM_SUPERVISOR_BACKEND_DEFAULT (tmux) - matches the target fallback. Returns 1.
discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_BACKEND"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr'
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_BACKEND_DEFAULT"
  return 1
}
