#!/usr/bin/env bash
# tests/fm-backend-herdr-input-part.sh - fake-herdr-CLI cases for workspace_find
# and list_live scoping, target parsing, capture and key delivery, busy_state,
# composer_state, wait_for_working, send_text_submit, and the never-idle cursor
# harness. Sourced by tests/fm-backend-herdr.test.sh after its fakes and
# helpers, which also runs every case.

# --- workspace_find: scoped to THIS home's own label, not just any match ----

test_workspace_find_matches_only_this_homes_own_label() {
  local dir log resp fb out home
  dir="$TMP_ROOT/find-scoped"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  home="$TMP_ROOT/find-scoped-home"; mkdir -p "$home"; printf 'bravo-b2\n' > "$home/.fm-secondmate-home"
  # A workspace list carrying BOTH the primary's "firstmate" space and this
  # secondmate's own "2ndmate-bravo-b2" space (as would be true once several
  # homes share one herdr session) - find must pick the one matching THIS
  # home's own label, never the primary's or a sibling secondmate's.
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"2ndmate-bravo-b2"},{"workspace_id":"w3","label":"2ndmate-alpha-a1"}]}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  # shellcheck disable=SC2153 # ROOT is supplied by fm-backend-herdr.test.sh when sourcing this part.
  out=$( PATH="$fb:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_find fmtest' "$ROOT" )
  [ "$out" = "w2" ] || fail "workspace_find should have matched this home's own label (2ndmate-bravo-b2 -> w2), got '$out'"
  pass "fm_backend_herdr_workspace_find: matches only THIS home's own label among several coexisting workspaces"
}

# --- list_live: scoped to this home's own workspace only ---------------------

test_list_live_scoped_to_this_homes_workspace_only() {
  local dir log resp fb out home
  dir="$TMP_ROOT/list-live-scoped"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  home="$TMP_ROOT/list-live-scoped-home"; mkdir -p "$home"; printf 'bravo-b2\n' > "$home/.fm-secondmate-home"
  # 1: workspace_find's `workspace list` - two homes coexist, secondmate's is w2
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"2ndmate-bravo-b2"}]}}\n' > "$resp/1.out"
  # 2: tab list --workspace w2 (this secondmate's own tabs only)
  printf '{"result":{"tabs":[{"tab_id":"w2:t1","label":"fm-secondmatetask"}]}}\n' > "$resp/2.out"
  # 3: pane_for_tab's `pane list --workspace w2`
  printf '{"result":{"panes":[{"pane_id":"w2:p1","tab_id":"w2:t1"}]}}\n' > "$resp/3.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_list_live fmtest' "$ROOT" )
  [ "$out" = $'fmtest:w2:p1\tfm-secondmatetask' ] || fail "list_live should report only this home's own tab, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''list'$'\x1f''--workspace'$'\x1f''w2' \
    "list_live did not scope the tab list call to this home's own workspace (w2)"
  assert_not_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''list'$'\x1f''--workspace'$'\x1f''w1' \
    "list_live must never query the primary's (or a sibling secondmate's) workspace"
  pass "fm_backend_herdr_list_live: scoped to this home's own workspace, never a sibling home's"
}

# --- target parsing, key normalization ---------------------------------------

test_parse_target() {
  ( . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_parse_target "default:w1:p2" || exit 1
    [ "$FM_BACKEND_HERDR_SESSION" = default ] || { echo "session mismatch: $FM_BACKEND_HERDR_SESSION" >&2; exit 1; }
    [ "$FM_BACKEND_HERDR_PANE" = "w1:p2" ] || { echo "pane mismatch: $FM_BACKEND_HERDR_PANE" >&2; exit 1; }
  ) || fail "fm_backend_herdr_parse_target did not split session:pane on the first colon only"
  pass "fm_backend_herdr_parse_target: splits '<session>:<pane_id>' on the FIRST colon (pane_id itself contains one)"
}

test_session_prefixed_pane_ids_are_normalized_for_read_and_close() {
  local dir log resp fb out
  dir="$TMP_ROOT/session-prefixed-pane"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf 'idle composer\n' > "$resp/1.out"
  : > "$resp/2.out"
  printf '{"error":{"code":"pane_not_found"}}\n' > "$resp/3.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_capture default:default:w2M:p2 200' "$ROOT" )
  [ "$out" = 'idle composer' ] || fail "session-prefixed pane target did not read through the bare pane id, got '$out'"
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_explicit_close_pane_confirmed default default:w2M:p2' "$ROOT"
  expect_code 0 $? "session-prefixed pane id should close after normalization"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''read'$'\x1f''w2M:p2' \
    "pane read passed a session-prefixed pane id to Herdr"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close'$'\x1f''w2M:p2' \
    "pane close passed a session-prefixed pane id to Herdr"
  pass "session-prefixed Herdr pane ids normalize for pane read and close"
}

test_session_prefixed_pane_ids_are_normalized_for_seeded_tab_prune() {
  local dir log resp fb
  dir="$TMP_ROOT/session-prefixed-prune"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w2M:t1","label":"1"},{"tab_id":"w2M:t2","label":"fm-task"}]}}\n' > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"default:w2M:p2","tab_id":"w2M:t1"}]}}\n' > "$resp/2.out"
  printf '{"error":{"code":"agent_not_found"}}\n' > "$resp/3.out"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_prune_seeded_default_tab default w2M w2M:t1' "$ROOT"
  expect_code 0 $? "seeded-tab prune should succeed with a session-prefixed pane id"
  assert_contains "$(cat "$log")" $'\x1f''agent'$'\x1f''get'$'\x1f''w2M:p2' \
    "seeded-tab prune passed a session-prefixed pane id to agent get"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close'$'\x1f''w2M:p2' \
    "seeded-tab prune passed a session-prefixed pane id to pane close"
  pass "session-prefixed Herdr pane ids normalize for seeded-tab prune"
}

test_normalize_key() {
  ( . "$ROOT/bin/backends/herdr.sh"
    [ "$(fm_backend_herdr_normalize_key Enter)" = enter ] || exit 1
    [ "$(fm_backend_herdr_normalize_key Escape)" = escape ] || exit 1
    [ "$(fm_backend_herdr_normalize_key C-c)" = ctrl+c ] || exit 1
    [ "$(fm_backend_herdr_normalize_key ctrl+c)" = ctrl+c ] || exit 1
  ) || fail "fm_backend_herdr_normalize_key did not map firstmate's key vocabulary to herdr's verified names"
  pass "fm_backend_herdr_normalize_key: Enter/Escape/C-c map to herdr's verified enter/escape/ctrl+c"
}

# --- capture / send_key / kill / current_path --------------------------------

test_capture_calls_pane_read() {
  local dir log resp fb out
  dir="$TMP_ROOT/capture"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf 'line one\nline two\nline three\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  # Requesting 250 (already >= the 200 floor) passes straight through as the
  # fetch bound; the adapter then trims to the caller's requested 250 lines
  # locally, so all 3 fake lines survive.
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_capture default:w1:p2 250' "$ROOT" )
  [ "$out" = $'line one\nline two\nline three' ] || fail "capture did not pass through pane read output, got '$out'"
  assert_contains "$(cat "$log")" "HERDR_SESSION=default"$'\x1f''pane'$'\x1f''read'$'\x1f''w1:p2'$'\x1f''--source'$'\x1f''recent'$'\x1f''--lines'$'\x1f''250' \
    "capture did not call pane read with the right pane id and line bound"
  pass "fm_backend_herdr_capture: calls 'pane read <pane> --source recent --lines N' with the session set"
}

test_capture_works_around_small_lines_bug() {
  local dir log resp fb out
  # Verified herdr v0.7.1 bug (herdr-verification-p2.md): `pane read --lines N`
  # for a small N (below the pane's viewport height) returns EMPTY, not the
  # last N lines. The adapter must never ask herdr for a small --lines bound -
  # it always fetches >= 200 and trims locally with tail.
  dir="$TMP_ROOT/capture-small"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf 'a\nb\nc\nd\ne\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_capture default:w1:p2 2' "$ROOT" )
  [ "$out" = $'d\ne' ] || fail "a small --lines request should still return the last N lines (trimmed locally), got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''--lines'$'\x1f''200' \
    "capture should request a generous fetch (>=200), never the caller's small N, from herdr's own --lines flag"
  pass "fm_backend_herdr_capture: works around the verified small-N '--lines' bug by over-fetching and trimming locally"
}

test_capture_preserves_pane_read_failure() {
  local dir log resp fb out status
  dir="$TMP_ROOT/capture-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_capture default:w1:p2 2' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail when pane read fails, got output '$out'"
  assert_contains "$(cat "$log")" "HERDR_SESSION=default"$'\x1f''status'$'\x1f''--json' \
    "capture did not ensure the herdr server before reading the pane"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''read'$'\x1f''w1:p2' \
    "capture did not try to read the requested pane"
  pass "fm_backend_herdr_capture: ensures the session and preserves pane read failure"
}

test_send_key_normalizes_and_targets_pane() {
  local dir log resp fb
  dir="$TMP_ROOT/sendkey"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_key default:w1:p2 Escape' "$ROOT"
  expect_code 0 $? "send_key should succeed"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''escape' "send_key did not normalize Escape to escape"
  pass "fm_backend_herdr_send_key: normalizes the key and targets the right pane"
}

test_kill_is_best_effort() {
  local dir log resp fb
  dir="$TMP_ROOT/kill"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_target_ready() { fm_backend_herdr_parse_target "$1"; }
      fm_backend_herdr_presentation_session_lock_path() { printf "/tmp/fm-herdr-test-lock"; }
      fm_lock_try_acquire() { return 0; }
      fm_lock_release() { return 0; }
      fm_backend_herdr_kill default:w1:p2
    ' "$ROOT"
  expect_code 0 $? "kill must be best-effort (never fail even when the pane close call itself fails)"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close'$'\x1f''w1:p2' "kill did not call pane close on the right pane"
  pass "fm_backend_herdr_kill: calls pane close and stays best-effort on failure"
}

test_current_path_reads_cwd() {
  local dir log resp fb out
  dir="$TMP_ROOT/cwd"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Verified pitfall (herdr-verification-p2.md): .result.pane.cwd is frozen at
  # pane-creation time and never updates; .foreground_cwd tracks the live
  # running process (e.g. a treehouse get subshell) and is what must be read.
  printf '{"result":{"pane":{"cwd":"/tmp/pane-creation-dir","foreground_cwd":"/tmp/fake-worktree"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_current_path default:w1:p2' "$ROOT" )
  [ "$out" = "/tmp/fake-worktree" ] || fail "current_path should read foreground_cwd (the live process), not the frozen creation-time cwd, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''get'$'\x1f''w1:p2' "current_path did not call pane get"
  pass "fm_backend_herdr_current_path: reads pane foreground_cwd (the live running process), not the frozen creation-time cwd"
}

# --- busy_state (semantic agent state) ---------------------------------------

test_busy_state_working_maps_to_busy() {
  local dir log resp fb out
  dir="$TMP_ROOT/busy-working"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_busy_state default:w1:p2' "$ROOT" )
  [ "$out" = busy ] || fail "agent_status=working should map to busy, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''agent'$'\x1f''get'$'\x1f''w1:p2' "busy_state did not call agent get"
  pass "fm_backend_herdr_busy_state: working -> busy"
}

test_busy_state_done_and_blocked_map_to_idle() {
  local dir log resp fb out
  dir="$TMP_ROOT/busy-done"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"done"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_busy_state default:w1:p2' "$ROOT" )
  [ "$out" = idle ] || fail "agent_status=done should map to idle, got '$out'"

  dir="$TMP_ROOT/busy-blocked"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_busy_state default:w1:p2' "$ROOT" )
  [ "$out" = idle ] || fail "agent_status=blocked should map to idle (stuck waiting on the human, not grinding), got '$out'"
  pass "fm_backend_herdr_busy_state: done -> idle, blocked -> idle (surfaced like a stale pane, not suppressed as busy)"
}

test_busy_state_unknown_on_no_agent() {
  local dir log resp fb out
  dir="$TMP_ROOT/busy-unknown"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_busy_state default:w1:p2' "$ROOT" )
  [ "$out" = unknown ] || fail "a failed agent get should report unknown (the fallback-to-regex cue), got '$out'"
  pass "fm_backend_herdr_busy_state: unparseable/absent agent state reports unknown, the regex-fallback cue"
}

# --- composer_state: structural border-row classification --------------------

test_composer_state_bare_prompt_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-bare"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  ╭────────────────────────╮\n  │ ❯                      │\n  ╰──────── Composer ──────╯\n\n  Shift+Tab:mode\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "a bare prompt glyph should read as empty, got '$out'"
  pass "fm_backend_herdr_composer_state: a bare '❯' composer row reads empty"
}

test_composer_state_styled_placeholder_draft_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-ghost"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  ╭────────────────────────╮\n  │ ❯ Type a message...    │\n  ╰──────── Composer ──────╯\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "bright placeholder-like text in a styled capture should remain pending, got '$out'"
  pass "fm_backend_herdr_composer_state: bright placeholder-like text stays pending rather than being mistaken for an idle ghost"
}

test_composer_state_real_text_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-pending"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  ╭────────────────────────╮\n  │ ❯ hello captain        │\n  ╰──────── Composer ──────╯\n\n  Enter:send\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "real unsubmitted text should read as pending, got '$out'"
  pass "fm_backend_herdr_composer_state: real composer text reads pending"
}

# Issue #3436: Grok 1.0.5's real bottom border is three columns wider than
# the aligned top and content rows. Herdr has no cursor anchor, so the old
# geometry verdict was unknown even when this composer was genuinely idle.
test_composer_state_grok_oversized_title_preserves_safe_verdicts() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-grok-oversized-title"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' \
    '  ╭──────────────────────────────────────────────────────────────────────────╮' \
    '  │ ❯                                                                        │' \
    '  ╰────────────────────────────────────────────────────────── Grok 4.6 (xhigh) ─╯' \
    '' \
    '  Shift+Tab:mode  │  Ctrl+x:shortcuts' > "$resp/1.out"
  printf '%s\n' \
    '  ╭──────────────────────────────────────────────────────────────────────────╮' \
    '  │ ❯ deploy the fix                                                         │' \
    '  ╰────────────────────────────────────────────────────────── Grok 4.6 (xhigh) ─╯' > "$resp/2.out"
  printf '%s\n' \
    '  ╭──────────────────────────────────────────────────────────────────────────╮' \
    '  │ ❯                                                                        │' \
    '  ╰────────────────────────────────────────────────────────── unknown surface ─╯' > "$resp/3.out"
  fb=$(make_herdr_fakebin "$dir")

  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "issue #3436's idle Grok/Herdr composer should read empty, got '$out'"
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "typed text inside Grok's oversized box should stay pending, got '$out'"
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = unknown ] || fail "an oversized unrecognized title should stay unknown, got '$out'"
  pass "fm_backend_herdr_composer_state: Grok's exact title overhang is empty while pending and unproved panes remain safe"
}

# Live-verified incident (2026-07-03, real grok 0.2.82 on herdr, isolated
# session): typing "/compact" opens the completion popup; the FIRST Enter
# closes the popup and EXPANDS the composer into an argument-hint placeholder
# ("/compact compaction instructions") rather than submitting - the composer
# still reads real, unsubmitted text and the footer still shows "Enter:send".
# A prior raw-diff verification saw the popup vanish and the text change and
# declared this "submitted". The structural composer-row read must still call
# this pending.
test_composer_state_popup_placeholder_fill_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-popup-placeholder"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  ╭──────────────────────────────────────╮\n  │ ❯ /compact compaction instructions   │\n  ╰──────────────── Composer ────────────╯\n\n  Enter:send\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "a popup-close-with-placeholder-fill must still read as pending (not yet submitted), got '$out'"
  pass "fm_backend_herdr_composer_state: a slash-command popup's argument-hint placeholder still reads pending (the incident fix)"
}

test_composer_state_unknown_on_capture_failure() {
  local dir log resp fb out status
  dir="$TMP_ROOT/composer-capture-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  status=$?
  [ "$status" -eq 0 ] || fail "composer_state should not itself fail the caller"
  [ "$out" = unknown ] || fail "an unreadable pane should read as unknown, got '$out'"
  pass "fm_backend_herdr_composer_state: reports unknown when the pane cannot be captured"
}

test_composer_state_inactive_session_fails_fast_without_server_autostart() {
  local dir log resp fb out status
  dir="$TMP_ROOT/composer-inactive-session"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # status --json reports stopped server
  printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":false}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state nonexistent:w1:p2' "$ROOT" )
  status=$?
  [ "$status" -eq 0 ] || fail "composer_state should exit 0 on inactive session"
  [ "$out" = unknown ] || fail "composer_state on inactive session should read unknown, got '$out'"
  assert_not_contains "$(cat "$log")" $'\x1f''server' "composer probe on inactive session must never autostart a herdr server"
  pass "fm_backend_herdr_composer_state: fails fast to unknown for inactive session without starting server"
}

# shellcheck disable=SC2016
test_composer_state_piped_reader_does_not_hang() {
  local out rc=0
  out=$( timeout 3s bash -c '. "$0/bin/fm-backend.sh"; ( fm_backend_composer_state herdr nonexistent-session:p2 ) 2>&1 | head -20' "$ROOT" ) || rc=$?
  [ "$rc" -eq 0 ] || fail "piped composer probe on bad target hung or failed with rc=$rc"
  [ "$out" = unknown ] || fail "piped composer probe should print unknown, got '$out'"
  pass "fm_backend_composer_state (herdr): piped probe on bad target does not hang EOF-sensitive readers"
}

test_composer_state_unknown_when_no_composer_row_found() {
  local dir log resp fb out glyph idx=1
  dir="$TMP_ROOT/composer-no-row"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  for glyph in '>' '$' '%' '#'; do
    printf '%s \n' "$glyph" > "$resp/$idx.out"
    idx=$((idx + 1))
  done
  fb=$(make_herdr_fakebin "$dir")
  for glyph in '>' '$' '%' '#'; do
    out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
    [ "$out" = unknown ] || fail "a bare shell prompt '$glyph' should read as unknown, got '$out'"
  done
  pass "fm_backend_herdr_composer_state: reports unknown for bare shell prompts with no composer row"
}

# Real Pi 0.80.7 on Herdr 0.7.3 renders no prompt glyph and no side border.
# Its content is the row(s) between two blue horizontal separators; the idle row
# carries only a reverse-video cursor. This exact shape was `unknown` for 4555s
# during the 2026-07-14 incident, so the safe injector never attempted submit.
test_composer_state_pi_separator_idle_is_empty() {
  local dir log resp fb out calls
  dir="$TMP_ROOT/composer-pi-separated-idle"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '│ stale bordered transcript row │\n\x1b[0m\x1b[38;2;129;162;190m─────────────────────────────────────────────────────\x1b[0m\n\x1b[0m\x1b[7m \x1b[0m                                                    \n\x1b[0m\x1b[38;2;129;162;190m─────────────────────────────────────────────────────\x1b[0m\n\x1b[0m\x1b[38;2;102;102;102m~/synthetic-primary (main)\x1b[0m\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state lab:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "an idle native Pi separator composer should read empty, got '$out'"
  calls=$(grep -c $'\x1f''agent'$'\x1f''get' "$log")
  [ "$calls" -eq 1 ] || fail "Pi separator recognition must corroborate identity exactly once, made $calls agent calls"
  pass "fm_backend_herdr_composer_state: a native idle Pi separator composer reads empty"
}

test_composer_state_pi_dollar_status_footer_is_empty() {
  # `$0.000 (sub) 5.4%/272k (auto)` at column 0 made herdr composer_state
  # unknown, so exit and relaunch refused on an otherwise idle Pi pane.
  local dir log resp fb out
  dir="$TMP_ROOT/composer-pi-dollar-status"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' $'transcript\n─────────────────────────────────────────────────────\n\n─────────────────────────────────────────────────────\n$0.000 (sub) 5.4%/272k (auto)' > "$resp/1.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state lab:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "an idle Pi composer with a dollar-first status footer should read empty, got '$out'"
  pass "fm_backend_herdr_composer_state: a dollar-first Pi status footer reads empty, not a dead shell"
}

# A pi worker parked on an interactive prompt (permission dialog, question
# menu, trust dialog) reports agent_status=blocked: it is waiting on a human
# keystroke. The menu is drawn ABOVE the separator pair, so the composer region
# itself is blank and structure alone looks like a free composer. Typing there
# does not compose a message - the menu consumes the keys and Enter selects the
# highlighted default, so the text is discarded and a decision nobody made is
# recorded (issue #2797). Every "is it safe to type here?" consumer reads this
# verdict: the away-mode injection guard (bin/fm-supervise-daemon.sh) and
# fm-send's pre-type refusal both proceed ONLY on an affirmative `empty`.
test_composer_state_pi_parked_prompt_is_not_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-pi-parked-prompt"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf 'Should I keep going?\n  1. Yes, continue\n\x1b[7m  2. Stop, do not act\x1b[0m\n\x1b[0m\x1b[38;2;129;162;190m─────────────────────────────────────────────────────\x1b[0m\n\x1b[0m\x1b[7m \x1b[0m                                                    \n\x1b[0m\x1b[38;2;129;162;190m─────────────────────────────────────────────────────\x1b[0m\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"blocked"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state lab:w1:p2' "$ROOT" )
  [ "$out" != empty ] \
    || fail "a pi pane parked on a prompt must not report an affirmatively empty composer, got '$out'"
  pass "fm_backend_herdr_composer_state: a blocked pi pane parked on a prompt is not an empty composer"
}

test_composer_state_pi_separator_real_text_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-pi-separated-pending"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\x1b[38;2;129;162;190m─────────────────────────────────────────────────────\x1b[0m\nprivacy safe human draft\x1b[7m \x1b[0m\n\x1b[38;2;129;162;190m─────────────────────────────────────────────────────\x1b[0m\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"done"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state lab:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "real text in a native Pi separator composer should read pending, got '$out'"
  pass "fm_backend_herdr_composer_state: real Pi composer text remains pending"
}

test_composer_state_pi_incomplete_separator_below_stale_generic_is_unknown() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-pi-separated-incomplete"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '│   │\n─────────────────────────────────────────────────────\n\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state lab:w1:p2' "$ROOT" )
  [ "$out" = unknown ] || fail "an incomplete Pi separator below a stale generic row should remain unknown, got '$out'"
  pass "fm_backend_herdr_composer_state: an incomplete lower Pi separator cannot inherit a stale empty row"
}

test_composer_state_pi_separator_requires_safe_native_identity() {
  local dir log resp fb out status case_id idx=0
  for case_id in working non-pi unreadable over-tall; do
    dir="$TMP_ROOT/composer-pi-separated-$case_id"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
    if [ "$case_id" = over-tall ]; then
      {
        printf '─────────────────────────────────────────────────────\n'
        for idx in $(seq 1 9); do printf 'line %s\n' "$idx"; done
        printf '─────────────────────────────────────────────────────\n'
      } > "$resp/1.out"
    else
      printf '─────────────────────────────────────────────────────\n\n─────────────────────────────────────────────────────\n' > "$resp/1.out"
    fi
    case "$case_id" in
      working) printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/2.out" ;;
      non-pi) printf '{"result":{"agent":{"agent":"shell","agent_status":"idle"}}}\n' > "$resp/2.out" ;;
      unreadable) printf '1\n' > "$resp/2.exit" ;;
      over-tall) printf '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}}\n' > "$resp/2.out" ;;
    esac
    fb=$(make_herdr_fakebin "$dir")
    out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state lab:w1:p2' "$ROOT" )
    [ "$out" = unknown ] || fail "unsafe Pi separator case '$case_id' must remain unknown, got '$out'"
  done
  pass "fm_backend_herdr_composer_state: Pi separators never authorize working, non-Pi, unreadable, or over-tall targets"
}

# --- composer_state: unbordered (bare) composer rows -------------------------
# Regression coverage for the away-mode redelivery-loop incident
# (docs/herdr-backend.md "Incident (2026-07-07)"): real claude and codex
# composer rows carry NO border glyph at all - the fixtures below are captured
# verbatim (character-for-character) from a real herdr session running real
# `claude`/`codex` (see the dated evidence entry). Before the fix these all
# read "unknown" (claude/codex fixtures) or produced a false "empty" from a
# stale decorative box (the banner-priority fixture) - none of them correctly
# tracked the live composer, which is exactly what caused
# bin/fm-supervise-daemon.sh's fm_backend_herdr_send_text_submit to never
# confirm a landed injection, so escalate_flush never cleared
# state/.subsuper-escalations and the same digest was redelivered every cycle.

test_composer_state_claude_unbordered_prompt_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-claude-bare-empty"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  20\n  21\n\n\xe2\x9c\xbb Worked for 2s\n\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  Opus 4.8 (1M context)   \xe2\x96\x8d               3%%\n  \xe2\x86\x90 for agents\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "a genuinely idle, unbordered real-claude '❯' prompt row (no border glyph anywhere in view) should read empty, got '$out' (regression: this used to read 'unknown' forever, which is exactly what broke escalate_flush's buffer-clear)"
  pass "fm_backend_herdr_composer_state: a real-claude unbordered '❯' prompt row (no border box in view) reads empty"
}

test_composer_state_claude_unbordered_prompt_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-claude-bare-pending"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  20\n  21\n\n\xe2\x9c\xbb Worked for 2s\n\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf hello there this is a test message\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "real unsubmitted text in an unbordered real-claude prompt row should read pending, got '$out'"
  pass "fm_backend_herdr_composer_state: a real-claude unbordered '❯ <text>' prompt row reads pending"
}

# The exact incident shape: a bordered decorative box (claude's own startup
# welcome banner) is STILL in the capture window, sitting ABOVE the live,
# unbordered "❯" prompt. Before the fix, the bordered branch was the ONLY one
# ever consulted, so the LAST bordered row (the banner's own blank interior
# spacer row, immediately above its closing ╰──╯) won by construction and was
# misread as the live composer - which happened to strip to empty here, but
# for the same reason never tracks the REAL composer once real text is typed
# below the banner (see the daemon-level E2E evidence in
# docs/herdr-backend.md). The live, bottom-most row must win regardless of
# shape.
test_composer_state_bare_prompt_below_stale_bordered_banner_wins() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-banner-priority"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x95\xad\xe2\x94\x80 Claude Code \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82           Welcome back Kun!           \xe2\x94\x82\n\xe2\x94\x82                                       \xe2\x94\x82\n\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf\n\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf still typing captain\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "the live unbordered prompt row below a stale bordered banner must win (pending, real text present), got '$out'"
  pass "fm_backend_herdr_composer_state: a live unbordered prompt row below a stale bordered decorative box still wins (not misread as the box's own row)"
}

# THE OVERNIGHT WEDGE regression (task afk-herdr-false-pending). Captured
# read-only from the live primary claude-on-herdr pane default:w1:p3 on
# 2026-07-10: an idle composer whose only content is claude's rotating
# prompt-suggestion GHOST, rendered SGR-2 dim after the bare "❯" prompt
# ("❯ \033[0m\033[2m<suggestion>\033[0m"). herdr's `pane read --format ansi`
# preserves the dim attribute. The pre-fix herdr classifier stripped ALL ANSI
# and read the suggestion as real pending text (its only faint check matched
# codex's bold-wrapped "\033[1m❯ \033[0m\033[2m", which this shape is NOT), so
# every away-mode injection deferred with "pending input (non-empty composer)"
# all night (6524 lifetime defers; wedge 30623s undelivered). The shared
# ANSI-aware owner now drops the dim ghost and the row reads empty (safe to
# inject).
test_composer_state_claude_dim_prompt_suggestion_ghost_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-claude-dim-ghost"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x9c\xbb Brewed for 2m 40s\n\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf \x1b[0m\x1b[2mwhat did the wheelhouse healing verification find?\x1b[0m\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  Fable 5                 80%%\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p3' "$ROOT" )
  [ "$out" = empty ] || fail "the overnight shape - claude's SGR-2 dim prompt-suggestion ghost after a bare '❯' - must read empty, got '$out' (regression: this false-pending wedged away-mode injection all night)"
  pass "fm_backend_herdr_composer_state: claude's dim prompt-suggestion ghost (the overnight wedge shape) reads empty"
}

# Same prompt row, but the text after "❯" is REAL (normal intensity, no dim) -
# it must still read pending, so the ghost fix never weakens real-input
# protection.
test_composer_state_claude_dim_ghost_row_with_real_text_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-claude-dim-ghost-real"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf land pr 416 now\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  Fable 5                 80%%\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p3' "$ROOT" )
  [ "$out" = pending ] || fail "real normal-intensity text after '❯' must still read pending, got '$out'"
  pass "fm_backend_herdr_composer_state: real typed text on the same claude prompt row still reads pending"
}

# grok's TRUECOLOR placeholder gap (harness-adapters "Known gap"), now covered by
# the same owner. grok renders its composer inside a bordered box whose border
# and placeholder/hint text use a dark, muted truecolor foreground (verified live
# against grok 0.2.93: border 38;2;86;82;110, muted 38;2;50;47;70, hint
# 38;2;110;106;134; real input is the BRIGHT 38;2;224;222;244), while the "❯"
# prompt glyph stays bright. The dark placeholder drops and the row reads empty.
test_composer_state_grok_dark_truecolor_placeholder_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-grok-truecolor-ghost"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  \x1b[38;2;86;82;110m\xe2\x95\xad\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae\x1b[39m\n  \x1b[38;2;86;82;110m\xe2\x94\x82\x1b[38;2;224;222;244m \xe2\x9d\xaf \x1b[38;2;50;47;70mType a message...\x1b[38;2;86;82;110m \xe2\x94\x82\x1b[39m\n  \x1b[38;2;86;82;110m\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf\x1b[39m\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "a grok bordered composer whose only content is a dark-truecolor placeholder must read empty, got '$out'"
  pass "fm_backend_herdr_composer_state: grok's dark-truecolor placeholder (the TRUECOLOR gap) reads empty"
}

# grok's bordered composer with REAL bright typed input must still read pending.
test_composer_state_grok_bright_truecolor_real_text_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-grok-truecolor-real"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  \x1b[38;2;86;82;110m\xe2\x95\xad\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae\x1b[39m\n  \x1b[38;2;86;82;110m\xe2\x94\x82\x1b[38;2;224;222;244m \xe2\x9d\xaf fix the login bug \x1b[38;2;86;82;110m\xe2\x94\x82\x1b[39m\n  \x1b[38;2;86;82;110m\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf\x1b[39m\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "real bright typed text in a grok bordered composer must read pending, got '$out'"
  pass "fm_backend_herdr_composer_state: grok's real bright typed input still reads pending"
}

test_composer_state_codex_bare_prompt_glyph_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-codex-bare"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x80\xa2 You have 2 usage limit resets available.\n\n\xe2\x80\xba\n\n  gpt-5.5 xhigh \xc2\xb7 Context 100%% left\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "a bare '›' (codex) prompt glyph with no trailing text should read empty, got '$out'"
  pass "fm_backend_herdr_composer_state: a real-codex unbordered '›' prompt row reads empty"
}

test_composer_state_codex_faint_suggestion_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-codex-faint-suggestion"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x80\xa2 You have 2 usage limit resets available. Run /usage\nto use one.\n\n\x1b[0m\x1b[1m\xe2\x80\xba \x1b[0m\x1b[2mFind and fix a bug in @filename\x1b[0m\n\n  gpt-5.5 xhigh \xc2\xb7 Context 100%% left\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "a faint real-codex ghost suggestion should read empty, not pending, got '$out'"
  pass "fm_backend_herdr_composer_state: a faint real-codex ghost suggestion reads empty"
}

test_composer_state_codex_non_faint_same_text_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-codex-non-faint-same-text"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x80\xa2 You have 2 usage limit resets available. Run /usage\nto use one.\n\n\x1b[0m\x1b[1m\xe2\x80\xba \x1b[0mFind and fix a bug in @filename\n\n  gpt-5.5 xhigh \xc2\xb7 Context 100%% left\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "the same words without faint styling should still protect real typed input, got '$out'"
  pass "fm_backend_herdr_composer_state: non-faint codex prompt text still reads pending"
}

# --- wait_for_working: the native agent-state poll-and-classify primitive ---
# Direct unit coverage for fm_backend_herdr_wait_for_working, the helper
# fm_backend_herdr_send_text_submit now uses instead of composer scraping
# (docs/herdr-backend.md "Native agent-state submit confirmation").

test_wait_for_working_returns_busy_on_first_poll() {
  local dir log resp fb out calls
  dir="$TMP_ROOT/wait-busy-first"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_for_working default w1:p2 1 5' "$ROOT" )
  [ "$out" = busy ] || fail "wait_for_working should report busy once 'working' is observed, got '$out'"
  calls=$(grep -c $'\x1f''agent'$'\x1f''get' "$log")
  [ "$calls" -eq 1 ] || fail "wait_for_working should short-circuit on the FIRST busy poll instead of consuming the whole budget, made $calls call(s)"
  pass "fm_backend_herdr_wait_for_working: reports 'busy' immediately on the first poll, without spending the rest of the budget"
}

test_wait_for_working_catches_a_slow_transition_mid_window() {
  local dir log resp fb out calls
  dir="$TMP_ROOT/wait-busy-slow"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Two idle samples, then working on the third - a transition that would be
  # MISSED by a single check-at-the-end design (the old composer approach's
  # shape) but is caught here because the budget is sampled repeatedly.
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/3.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_for_working default w1:p2 0.03 3' "$ROOT" )
  [ "$out" = busy ] || fail "wait_for_working should catch a transition that lands on a later sample within the SAME window, got '$out'"
  calls=$(grep -c $'\x1f''agent'$'\x1f''get' "$log")
  [ "$calls" -eq 3 ] || fail "expected exactly 3 agent-get polls (idle, idle, working), got $calls"
  pass "fm_backend_herdr_wait_for_working: a slow transition landing on a later sample within one window is still caught (robust against the 'slow transition' failure direction)"
}

test_wait_for_working_samples_budget_endpoint_without_final_sleep() {
  local dir log resp fb out sleep_log sleeps
  dir="$TMP_ROOT/wait-budget-endpoint"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; sleep_log="$dir/sleeps"; : > "$log"; : > "$sleep_log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/3.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_SLEEP_LOG="$sleep_log" \
    bash -c '. "$0/bin/backends/herdr.sh"; sleep() { printf "sleep:%s\n" "$1" >> "$FM_SLEEP_LOG"; }; fm_backend_herdr_wait_for_working default w1:p2 0.5 6' "$ROOT" )
  [ "$out" = idle ] || fail "wait_for_working should report idle when every endpoint-spread poll is readable-idle, got '$out'"
  sleeps=$(grep -c '^sleep:0.1000$' "$sleep_log")
  [ "$sleeps" -eq 5 ] || fail "six polls across a 0.5s budget should sleep five times at 0.1000s, got $sleeps matching sleeps; log: $(cat "$sleep_log")"
  pass "fm_backend_herdr_wait_for_working: spreads six samples across the full budget endpoint without a final trailing sleep"
}

test_send_text_submit_applies_herdr_minimum_confirm_budget() {
  local dir log resp fb out sleep_log sleeps
  dir="$TMP_ROOT/submit-min-budget"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; sleep_log="$dir/sleeps"; : > "$log"; : > "$sleep_log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/6.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/7.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/8.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/9.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_SLEEP_LOG="$sleep_log" FM_BACKEND_HERDR_SUBMIT_POLLS=6 FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.6 \
    bash -c '. "$0/bin/backends/herdr.sh"; sleep() { printf "sleep:%s\n" "$1" >> "$FM_SLEEP_LOG"; }; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 1 0.4 0' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should catch a slow-but-valid transition inside the herdr minimum budget, got '$out'"
  sleeps=$(grep -c '^sleep:0.1200$' "$sleep_log")
  [ "$sleeps" -eq 5 ] || fail "a 0.4s caller budget should be expanded to five 0.1200s sleeps across the 0.6s herdr floor, got $sleeps; log: $(cat "$sleep_log")"
  [ "$(grep -c '^sleep:0.0800$' "$sleep_log")" -eq 0 ] || fail "send_text_submit used the caller's too-short 0.4s budget instead of the herdr floor: $(cat "$sleep_log")"
  pass "fm_backend_herdr_send_text_submit: applies the herdr minimum confirmation budget before polling agent-state"
}

test_wait_for_working_returns_idle_when_never_busy_but_readable() {
  local dir log resp fb out
  dir="$TMP_ROOT/wait-idle"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_for_working default w1:p2 0.02 2' "$ROOT" )
  [ "$out" = idle ] || fail "wait_for_working should report idle when the target was legibly read but never busy, got '$out'"
  pass "fm_backend_herdr_wait_for_working: reports 'idle' (readable, genuinely not yet working) when 'busy' never appears"
}

test_wait_for_working_returns_unknown_when_never_readable() {
  local dir log resp fb out
  dir="$TMP_ROOT/wait-unknown"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  printf '1\n' > "$resp/2.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_for_working default w1:p2 0.02 2' "$ROOT" )
  [ "$out" = unknown ] || fail "wait_for_working should report unknown when every poll fails to read the target, got '$out'"
  pass "fm_backend_herdr_wait_for_working: reports 'unknown' (a hard read failure, not a timing race) only when EVERY poll in the window fails"
}

test_wait_for_working_treats_blocked_as_submit_active() {
  local dir log resp fb out
  dir="$TMP_ROOT/wait-blocked"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_for_working default w1:p2 0.01 1' "$ROOT" )
  [ "$out" = busy ] || fail "wait_for_working should treat a post-Enter blocked state as submit-active, got '$out'"
  pass "fm_backend_herdr_wait_for_working: treats blocked as submit-active for confirmation without changing watcher busy-state semantics"
}

# --- send_text_submit: native agent-state (agent get) verify-and-retry ------
# Rewritten for the 2026-07-07 incident (docs/herdr-backend.md): confirmation
# no longer reads composer content in the normal idle-baseline path, so a
# harness whose IDLE composer shows dynamic tip text (real codex) can no
# longer misread as "pending" and block/mis-confirm a send.
# FM_BACKEND_HERDR_SUBMIT_POLLS=1 pins most tests
# below to exactly one agent-get sample per Enter attempt for simple,
# deterministic call-count assertions; the multi-sample behavior itself is
# covered above by the wait_for_working tests and by
# test_send_text_submit_slow_transition_within_one_enter_needs_no_extra_enter.

test_send_text_submit_detects_landed_send() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-ok"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: send-text (literal, no output)
  # 2: agent get - pre-Enter baseline is idle
  # 3: send-keys enter
  # 4: agent get - agent_status working (a real turn started: submitted)
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should report empty (submitted) once agent_status reports working, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''send-text'$'\x1f''w1:p2'$'\x1f''hello captain' "send_text_submit did not type the literal text first"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "send_text_submit should not need a second Enter for a plain message with no popup, sent $enter_count Enter(s)"
  [ "$(grep -c $'\x1f''pane'$'\x1f''read' "$log")" -eq 0 ] || fail "send_text_submit must never read the composer/pane content for confirmation anymore"
  pass "fm_backend_herdr_send_text_submit: reports 'empty' once agent_status reports working after one Enter, without ever reading the composer"
}

test_send_text_submit_detects_swallowed_enter() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-swallow"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Every post-Enter agent-get read still reports idle, and the composer still
  # holds the typed text: a genuine swallow, not a queued Enter.
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '  \xe2\x9d\xaf hello captain\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/7.out"
  printf '  \xe2\x9d\xaf hello captain\n' > "$resp/8.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/9.out"
  printf '  ready\n' > "$resp/10.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 2 0.01 0.01' "$ROOT" )
  [ "$out" = pending ] || fail "send_text_submit should report pending once retries are exhausted with agent_status never going busy and the composer still holding the text, got '$out'"
  pass "fm_backend_herdr_send_text_submit: reports 'pending' when agent_status stays idle and the composer still holds unsent text after retried Enters (swallowed)"
}

test_send_text_submit_replays_literal_send_stderr() {
  local dir log resp fb out err
  dir="$TMP_ROOT/submit-send-stderr"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  err="$dir/stderr"
  # 1: agent get (a non-Claude identity skips the payload proof)
  # 2: send-text fails the way an oversized argument does, before herdr runs
  printf '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}\n' > "$resp/1.out"
  printf 'herdr: Argument list too long\n' > "$resp/2.err"
  printf '126\n' > "$resp/2.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 3 0.01 0.01' "$ROOT" 2>"$err" )
  [ "$out" = send-failed ] || fail "a failed literal send should report send-failed, got '$out'"
  grep -F 'Argument list too long' "$err" >/dev/null \
    || fail "the literal send's stderr was not replayed to the caller: $(cat "$err")"
  [ "$(grep -c $'\x1f''pane'$'\x1f''send-keys' "$log")" -eq 0 ] \
    || fail "no Enter may follow a failed literal send"
  pass "fm_backend_herdr_send_text_submit: a failed literal send reports send-failed and replays the transport's stderr"
}

# Regression coverage for the 2026-07-03 incident using the NEW mechanism: a
# slash command's first Enter can close a completion popup and fill an
# argument-hint placeholder WITHOUT submitting. In the idle-baseline path,
# filling a placeholder never starts a turn, so agent_status simply stays idle
# for Enter #1, and the retry loop sends a genuine second Enter exactly as it
# would for any other swallowed Enter.
test_send_text_submit_popup_autocomplete_requires_second_enter() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-popup-autocomplete"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: send-text "/compact"
  # 2: agent get - pre-Enter baseline is idle
  # 3: send-keys enter (#1) - closes the popup, fills the placeholder; no turn starts
  # 4: agent get -> idle (not submitted yet)
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  # 5: composer still holds the placeholder fill; native idle falls through
  #    to the shared composer verdict, which retries rather than confirming.
  printf '  \xe2\x9d\xaf /compact\n' > "$resp/5.out"
  # 6: send-keys enter (#2) - actually submits
  # 7: agent get -> working (submitted)
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/7.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "/compact" 3 0.01 1.2' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should eventually report empty once the SECOND Enter actually starts a turn, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 2 ] || fail "send_text_submit must send a SECOND Enter after the popup-placeholder fill's agent_status still reads idle, got $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: a slash-command popup's placeholder fill on Enter #1 never flips agent_status to working, so it does not short-circuit as submitted; Enter #2 is retried and lands it"
}

test_send_text_submit_refuses_confirming_enter_on_exit_picker() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-exit-picker"; mkdir -p "$dir/responses" "$dir/tmp"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  herdr_submit_claude_prefix "$resp" "/exit"
  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' > "$resp/7.out"
  printf '%s\n' \
    'Background work is running' \
    '❯ 1. Exit and stop tasks' \
    'The following will stop when you exit:' \
    'shell · sleep 300' \
    '  2. Move to background and exit' \
    '  3. Stay' \
    'Enter to confirm · Esc to cancel' > "$resp/8.out"
  herdr_submit_preflight_prefix "$resp"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    TMPDIR="$dir/tmp" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_text_submit herdr default:w1:p2 "/exit" 3 0.01 0.01' "$ROOT" )
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log" || true)
  [ "$out" = unknown ] || fail "the exit picker should stop the retry as unknown, got '$out'; log: $(cat "$log")"
  [ "$enter_count" -eq 1 ] || fail "the exit picker should get one Enter, got $enter_count; log: $(cat "$log")"
  [ -z "$(ls -A "$dir/tmp")" ] || fail "the submit left its dialog record behind: $(ls -A "$dir/tmp")"
  pass "fm_backend_herdr_send_text_submit: the Claude background-task exit picker gets no confirming Enter"
}

# Herdr can report `blocked` for a picker the submitting Enter opened. The
# submit then reports delivery with no composer read, so the picker is named
# only by the caller's next composer read, the one fm-control exit takes when
# its wait for the agent to stop times out.
test_blocked_submit_leaves_the_exit_picker_to_the_next_composer_read() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-blocked-picker"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  herdr_submit_claude_prefix "$resp" "/exit"
  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent":"claude","agent_status":"blocked"}}}\n' > "$resp/7.out"
  printf '%s\n' \
    'Background work is running' \
    '❯ 1. Exit and stop tasks' \
    'The following will stop when you exit:' \
    'shell · sleep 300' \
    '  2. Move to background and exit' \
    '  3. Stay' \
    'Enter to confirm · Esc to cancel' > "$resp/8.out"
  herdr_submit_preflight_prefix "$resp"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    FM_COMPOSER_DIALOG_SINK="$dir/sink" \
    bash -c '. "$0/bin/fm-backend.sh"
      verdict=$(fm_backend_send_text_submit herdr default:w1:p2 "/exit" 3 0.01 0.01)
      printf "%s|%s|" "$verdict" "$(cat "$FM_COMPOSER_DIALOG_SINK")"
      fm_backend_composer_state herdr default:w1:p2 >/dev/null
      cat "$FM_COMPOSER_DIALOG_SINK"' "$ROOT" )
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log" || true)
  [ "$out" = 'empty||Claude background-task exit picker' ] \
    || fail "a blocked submit should report delivery unnamed and the next composer read should name the picker, got '$out'; log: $(cat "$log")"
  [ "$enter_count" -eq 1 ] || fail "a blocked submit should send one Enter, got $enter_count; log: $(cat "$log")"
  [ -f "$dir/sink" ] || fail "a submit must not remove a dialog record its caller owns"
  pass "fm_backend_send_text_submit (herdr): a picker behind a blocked verdict is named by the caller's next composer read"
}

test_send_text_submit_confirms_blocked_after_enter() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-blocked"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/3.out"
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/4.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "needs approval" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should treat a blocked state after Enter as a confirmed delivered prompt, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "blocked after Enter must not provoke a retry into the prompt, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: a post-Enter blocked state confirms delivery without retrying into the prompt"
}

test_send_text_submit_preexisting_working_pending_is_queued_enter() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-preexisting-working-queued"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Native working + proven pending after the retry budget is the OpenCode
  # busy-queued Enter: the harness accepted Enter and will submit when the
  # current turn ends. Footer transition is not the confirmation path here
  # because the pre-Enter native status is already working.
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/2.out"
  printf '  ready\n' > "$resp/3.out"
  printf '  \xe2\x9d\xaf hello captain\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/6.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 1 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "a working native baseline plus proven pending after retries is a queued Enter, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "queued-Enter confirmation should use the configured retry count, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: native working + proven pending after retries reports empty (queued Enter)"
}

test_send_text_submit_preexisting_working_does_not_confirm_failed_enter() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-preexisting-working-enter-failed"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/2.out"
  printf '  ready\n' > "$resp/3.out"
  printf '1\n' > "$resp/4.exit"
  printf '  \xe2\x9d\xaf hello captain\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/6.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 1 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "a failed Enter must not be reported as queued delivery merely because native status is working, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "send_text_submit should attempt the configured number of Enters, made $enter_count attempt(s)"
  pass "fm_backend_herdr_send_text_submit: a failed Enter cannot borrow preexisting working state as queued-delivery proof"
}

test_send_text_submit_idle_baseline_does_not_confirm_failed_enter() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-idle-enter-failed"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '1\n' > "$resp/3.exit"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 1 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "a failed Enter must not borrow a later native transition as delivery proof, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "send_text_submit should attempt the configured number of Enters, made $enter_count attempt(s)"
  [ "$(grep -c $'\x1f''agent'$'\x1f''get' "$log")" -eq 2 ] || fail "a failed Enter must not run native delivery confirmation beyond the identity and baseline reads"
  pass "fm_backend_herdr_send_text_submit: a failed Enter cannot borrow a later native transition as delivery proof"
}

test_send_text_submit_idle_native_empty_composer_confirms_delivery() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-idle-native-empty-composer"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Live Claude on Herdr 0.8.0 keeps agent_status idle through a landed turn.
  # After Enter, native wait_for_working stays idle and the composer clears:
  # that empty verdict is positive delivery, not a swallow.
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '  \xe2\x9d\xaf\n' > "$resp/5.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "an idle native status plus a cleared composer must confirm delivery, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "a cleared composer should confirm without extra Enters, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: idle native agent-state plus empty composer reports empty (landed Claude turn)"
}

test_send_text_submit_idle_native_pending_plus_rendered_busy_is_queued() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-idle-native-rendered-busy-queued"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Idle native baseline (Claude never leaves idle) with proven pending text
  # and a generating footer after retries is a queued follow-up Enter.
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '  \xe2\x9d\xaf hello captain\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/6.out"
  printf 'thinking... esc to interrupt\n' > "$resp/7.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 1 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "idle native + proven pending + rendered busy after retries is a queued Enter, got '$out'"
  pass "fm_backend_herdr_send_text_submit: idle native baseline uses a rendered busy footer to confirm a queued Enter"
}

# --- the never-idle-native-state harness (real cursor on herdr) --------------
# Measured live on cursor-agent 2026.08.11-e8db854 under herdr: `agent get`
# reports a cursor pane `blocked` in EVERY state - idle, mid-turn, and after -
# so the idle-baseline native path is structurally unreachable and every typed
# send lands in the composer branch. Cursor's mid-turn composer row renders its own
# `Add a follow-up` placeholder beside a right-aligned `ctrl+c to stop`, so the
# content verdict is `pending` on a composer holding no user text, and every
# typed steer reported delivery unconfirmed on a message that had actually landed.
# The bytes below are the real captures from that pane.

# The idle capture: no busy token anywhere, which is the pre-Enter baseline.
herdr_cursor_idle_plain() {
  printf '%b' ' ▄▄▄▄▄▄▄▄▄▄\n  → Add a follow-up\n ▀▀▀▀▀▀▀▀▀▀\n  Cursor Grok 4.5 High · 7%%           Run Everything\n  ~/.treehouse/curhd-ae68cd/1/curhd · 39418af\n'
}

# The mid-turn capture, plain: the spinner verb rotates, the `ctrl+c to stop`
# token does not, which is why the token is what the matcher keys on.
herdr_cursor_midturn_plain() {
  printf '%b' ' ⠘⠆ Running  59 tokens\n ▄▄▄▄▄▄▄▄▄▄\n  → Add a follow-up                   ctrl+c to stop\n ▀▀▀▀▀▀▀▀▀▀\n  1 task\n  Cursor Grok 4.5 High · 7%%           Run Everything\n  ~/.treehouse/curhd-ae68cd/1/curhd · 39418af\n'
}

# The same mid-turn rows as herdr renders them with styling: the glyph and the
# placeholder tail are dim, the cell under the parked terminal cursor is
# reverse video, and the busy token trails on the SAME row.
herdr_cursor_midturn_ansi() {
  printf '%b' ' \033[0m\033[38;2;21;21;21m▄▄▄▄▄▄▄▄▄▄\033[0m\r\n \033[0m\033[48;2;21;21;21m \033[0m\033[2m\033[48;2;21;21;21m→ \033[0m\033[7m\033[48;2;21;21;21mA\033[0m\033[2m\033[48;2;21;21;21mdd a follow-up\033[0m\033[48;2;21;21;21m                   \033[0m\033[2m\033[48;2;21;21;21mctrl+c to stop\033[0m\033[48;2;21;21;21m \033[0m\r\n \033[0m\033[38;2;21;21;21m▀▀▀▀▀▀▀▀▀▀\033[0m\r\n  \033[0m\033[38;5;4m1 task\033[0m\r\n  \033[0m\033[2mCursor Grok 4.5 High\033[0m \033[0m\033[2m·\033[0m \033[0m\033[2m7%%\033[0m           \033[0m\033[38;5;5mRun Everything\033[0m\r\n  \033[0m\033[2m~/.treehouse/curhd-ae68cd/1/curhd · 39418af\033[0m\r\n'
}

# Non-vacuity anchor for the two submit tests below: the real mid-turn capture
# genuinely reads `pending`, so the confirmation those tests assert can only be
# coming from the rendered-footer transition and never from a softened composer
# verdict. The composer verdict is deliberately NOT relaxed - a right-aligned
# status token on the composer row is content the shared classifier must keep
# treating as content for every other caller.
test_composer_state_cursor_midturn_row_reads_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-cursor-midturn"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  herdr_cursor_midturn_ansi > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "cursor's mid-turn composer row carries a busy token and must stay 'pending' as composer CONTENT, got '$out'"
  pass "fm_backend_herdr_composer_state: cursor's mid-turn placeholder-plus-busy-token row reads pending (why delivery needs a separate signal)"
}

test_rendered_busy_state_reads_the_cursor_busy_token() {
  local dir log resp fb idle_out busy_out fail_out
  dir="$TMP_ROOT/rendered-busy"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  herdr_cursor_idle_plain > "$resp/1.out"
  herdr_cursor_midturn_plain > "$resp/2.out"
  printf '1\n' > "$resp/3.exit"
  fb=$(make_herdr_fakebin "$dir")
  idle_out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_rendered_busy_state default:w1:p2' "$ROOT" )
  busy_out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_rendered_busy_state default:w1:p2' "$ROOT" )
  fail_out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_rendered_busy_state default:w1:p2' "$ROOT" )
  [ "$idle_out" = idle ] || fail "an idle cursor pane renders no busy token and must read idle, got '$idle_out'"
  [ "$busy_out" = busy ] || fail "a mid-turn cursor pane renders 'ctrl+c to stop' and must read busy, got '$busy_out'"
  [ "$fail_out" = unknown ] || fail "an unreadable pane must read unknown, never idle, got '$fail_out'"
  pass "fm_backend_herdr_rendered_busy_state: busy/idle/unknown from the rendered footer, with an unreadable pane never reading idle"
}

test_send_text_submit_confirms_never_idle_native_state_via_footer_transition() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-cursor-footer-transition"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: send-text
  # 2: agent get - cursor is `blocked` even while idle, so the native
  #    idle-baseline path is unreachable and the composer branch runs
  # 3: pane read - rendered footer baseline: no busy token, so the pane was NOT
  #    mid-turn before our Enter
  # 4: send-keys enter
  # 5: pane read - composer content mid-turn: placeholder plus busy token
  # 6: pane read - rendered footer now busy: an idle-to-busy transition ACROSS
  #    our Enter, which is the submission proof
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/2.out"
  herdr_cursor_idle_plain > "$resp/3.out"
  herdr_cursor_midturn_ansi > "$resp/5.out"
  herdr_cursor_midturn_plain > "$resp/6.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "an idle-to-busy rendered-footer transition must confirm the submit for a harness whose native state never goes idle, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "a confirmed submit must not send a needless extra Enter, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: a rendered-footer idle-to-busy transition confirms delivery when native agent-state never reports idle"
}

test_send_text_submit_never_idle_native_state_keeps_pending_without_a_transition() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-cursor-no-transition"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # The pane was ALREADY mid-turn before our Enter, so its busy footer is not
  # evidence about OUR message: the verdict must stay pending rather than
  # borrowing someone else's turn as proof of our delivery.
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/2.out"
  herdr_cursor_midturn_plain > "$resp/3.out"
  herdr_cursor_midturn_ansi > "$resp/5.out"
  herdr_cursor_midturn_ansi > "$resp/7.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 2 0.01 0.01' "$ROOT" )
  [ "$out" = pending ] || fail "a pane already busy before our Enter must not confirm from that same busy footer, got '$out'"
  pass "fm_backend_herdr_send_text_submit: an already-busy footer baseline is never accepted as proof that this Enter landed"
}

# Regression for the submit-confirmation side of the 2026-07-07 incident:
# even if a Codex idle composer displays suggestion text, an idle-baseline
# submit must confirm from native agent-state rather than composer scraping.
# The pre-injection composer guard has its own faint-suggestion coverage below.
test_send_text_submit_confirms_despite_codex_idle_tip_composer() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-codex-idle-tip"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "reply with just OK" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should confirm via agent_status alone even for a harness whose idle composer shows dynamic tip text, got '$out'"
  [ "$(grep -c $'\x1f''pane'$'\x1f''read' "$log")" -eq 0 ] || fail "send_text_submit must never call 'pane read' - a codex-style dynamic idle-tip composer can never mislead a confirmation path that does not read it"
  pass "fm_backend_herdr_send_text_submit: confirms submission via native agent-state alone, immune to a codex-style dynamic idle-tip composer that would have misread as 'pending' under the old composer-based confirmation"
}

# Companion regression for the pre-injection empty-box guard itself
# (bin/fm-supervise-daemon.sh's pane_input_pending): a real Codex idle
# composer can show faint ghost suggestions after the bare `›` prompt.
# The guard must ignore that faint suggestion text, otherwise away-mode
# escalation delivery defers forever even though the human has typed nothing.
test_composer_state_codex_dynamic_idle_tip_reads_empty_when_faint() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-codex-dynamic-tip"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x80\xa2 OK\n\n\n\x1b[0m\x1b[1m\xe2\x80\xba \x1b[0m\x1b[2mSummarize recent commits\x1b[0m\n\n  gpt-5.5 xhigh \xc2\xb7 Context 97%% left \xc2\xb7 /private/tmp \xc2\xb7 2\xe2\x80\xa6\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "a faint real-codex dynamic idle-tip row should read empty, got '$out'"
  pass "fm_backend_herdr_composer_state: a faint real-codex dynamic idle-tip composer row reads empty"
}

# Regression guard for the PRE-injection empty-box guard itself
# (bin/fm-supervise-daemon.sh's pane_input_pending, dispatched via
# fm_backend_composer_state -> fm_backend_herdr_composer_state): this task
# changes ONLY submit confirmation, so genuine unsubmitted text in the
# composer must still read 'pending' and the guard must still refuse to
# inject into it.
test_composer_state_guard_still_refuses_real_pending_text_after_submit_confirmation_change() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-guard-still-refuses"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  \xe2\x9d\xaf hello there this is a test message\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_composer_state herdr default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "the pre-injection empty-box guard must still refuse real unsubmitted composer text after this change, got '$out'"
  pass "fm_backend_composer_state (herdr): the pre-injection empty-box guard still refuses a genuinely non-empty composer, unaffected by the submit-confirmation change"
}

# A slow transition landing partway through a single Enter attempt's own
# budget must not provoke a needless extra Enter - end-to-end through
# send_text_submit itself (test_wait_for_working_catches_a_slow_transition_mid_window
# above covers the primitive directly; this proves the caller wires it
# correctly).
test_send_text_submit_slow_transition_within_one_enter_needs_no_extra_enter() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-slow-transition"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: send-text  2: baseline idle  3: send-keys enter  4,5: agent get -> idle  6: agent get -> working
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/6.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=3 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 3 0.03 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should confirm once a later sample within the SAME Enter attempt observes working, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "a slow (but within-budget) transition must not provoke a needless extra Enter, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: a slow transition landing on a later sample within one Enter's budget is confirmed WITHOUT sending a needless extra Enter"
}

test_send_text_submit_send_failed() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "x" 2 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "send_text_submit should report send-failed when the literal send itself fails, got '$out'"
  pass "fm_backend_herdr_send_text_submit: reports 'send-failed' when the literal send-text call itself errors"
}

test_send_text_submit_unknown_on_capture_failure() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-read-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '1\n' > "$resp/4.exit"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "x" 2 0.01 0.01' "$ROOT" )
  [ "$out" = unknown ] || fail "send_text_submit should report unknown when the post-Enter agent-get read fails, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "send_text_submit must never retry past an unreadable target (that is a hard I/O failure, not a timing race), sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: reports 'unknown' when the post-Enter agent-get read fails (never retries past an unreadable target)"
}

test_send_text_submit_unknown_on_composer_capture_failure() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-composer-read-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '1\n' > "$resp/5.exit"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "x" 2 0.01 0.01' "$ROOT" )
  [ "$out" = unknown ] || fail "send_text_submit should report unknown when native status stays idle but the composer cannot be read, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "send_text_submit must not retry Enter after composer verification becomes unreadable, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: an unreadable composer stops Enter retries after native status stays idle"
}

# On a Claude pane, a long payload the selected composer still holds is
# submitted whole. A composer that kept only a suffix, a stale transcript head
# above that suffix, or a paste placeholder plus a literal remainder does not
# receive Enter, is cleared back to empty, and is not reported delivered.
herdr_long_payload() {  # <middle-length>
  awk -v n="$1" 'BEGIN { printf "HEAD"; for (i = 0; i < n; i++) printf "m"; printf "TAIL" }'
}

herdr_ctrl_u_count() {  # <log>
  grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''ctrl+u' "$1"
}

# herdr_wrapped_composer: a Claude composer holding <text> wrapped at <width>
# columns, with its first <drop> rows already deleted. Live Claude's Ctrl+U
# deletes one wrapped screen row per press, so a stub that clears a whole
# single-line draft with one press would hide an undercounted clear.
herdr_wrapped_composer() {  # <text> <width> <drop>
  local text=$1 width=$2 drop=$3 prefix='  \xe2\x9d\xaf '
  text=${text:$((drop * width))}
  [ -n "$text" ] || { printf '  \xe2\x9d\xaf\n'; return 0; }
  while [ -n "$text" ]; do
    printf "$prefix%s\n" "${text:0:$width}"
    text=${text:$width}
    prefix='    '
  done
}

# herdr_popup_composer_screen: a Claude Code 2.1.283-shaped screen after a
# typed slash command, with the command popup rendered BETWEEN the composer
# and the pane bottom. Verified live: the popup is ~19 menu rows, so the
# composer row lands outside a 20-row tail window - a bounded tail read
# reports the composer as empty while it holds typed text, which broke
# fm-control exit (the typed /exit was judged unsent and cleared). The
# composer reads capture the full visible viewport instead. The composer
# sits inside a solid-rule pair (rule above, rule below), exactly as live
# Claude draws it, with the menu rows below the closing rule; the rules are
# structural edge rows, so the composer's content block ends there and the
# menu rows never read as typed text.
herdr_popup_composer_screen() {  # <typed-text>
  local i typed=$1 rule
  rule=$(printf '%0.s\xe2\x94\x80' $(seq 1 60))
  printf ' \xe2\x95\xad\xe2\x94\x80\xe2\x94\x80 Claude Code v2.1.283 \xe2\x94\x80\xe2\x94\x80\xe2\x95\xae\n'
  printf '  %s\n' "$rule"
  printf '  \xe2\x9d\xaf %s\n' "$typed"
  printf '  %s\n' "$rule"
  printf '  %s    Exit the CLI\n' "$typed"
  for ((i = 0; i < 21; i++)); do
    printf '  /skill-%02d    A skill description long enough to read as a popup row\n' "$i"
  done
  printf '  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on\n'
}

test_send_text_submit_long_literal_submits_when_composer_holds_every_byte() {
  local dir log resp fb out enter_count text
  dir="$TMP_ROOT/submit-long-exact"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 1492)
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
  herdr_submit_claude_prefix "$resp" "$text"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = empty ] || fail "a composer holding the full long payload should confirm delivery, got '$out'"
  [ "${#text}" -eq 1500 ] || fail "the long payload fixture was ${#text} chars, not 1500"
  assert_contains "$(cat "$log")" $'\x1f'"$text" "send_text_submit did not type the full long payload"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "a fully observed long payload should be submitted once, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq 0 ] || fail "a proven payload must not be cleared"
  pass "fm_backend_herdr_send_text_submit: a 1500-character payload a Claude composer still holds is submitted whole"
}

test_send_text_submit_refuses_enter_when_composer_holds_only_the_suffix() {
  local dir log resp fb out enter_count text suffix
  dir="$TMP_ROOT/submit-long-suffix"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 1492)
  suffix=${text: -480}
  herdr_submit_claude_prefix "$resp" "$text"
  printf '  \xe2\x9d\xaf %s\n' "$suffix" > "$resp/4.out"
  printf '  \xe2\x9d\xaf\n' > "$resp/6.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/7.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = send-failed ] || fail "a composer holding only the payload suffix, cleared back to empty, should report send-failed, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 0 ] || fail "a suffix must not be submitted, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq 1 ] || fail "the refused suffix should be cleared with one Ctrl+U, sent $(herdr_ctrl_u_count "$log")"
  [ "$(grep -c $'\x1f''agent'$'\x1f''get' "$log")" -eq 1 ] || fail "a refused suffix must not be confirmed by a later working status"
  pass "fm_backend_herdr_send_text_submit: a long payload whose Claude composer kept only the tail is not submitted, is cleared, and reports send-failed"
}

test_send_text_submit_refused_suffix_that_will_not_clear_is_unknown() {
  local dir log resp fb out enter_count text suffix cap n
  dir="$TMP_ROOT/submit-long-suffix-stuck"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 1492)
  suffix=${text: -480}
  herdr_submit_claude_prefix "$resp" "$text"
  printf '  \xe2\x9d\xaf %s\n' "$suffix" > "$resp/4.out"
  cap=$(( 1500 / 40 + 8 ))
  for ((n = 6; n <= 4 + 2 * cap; n += 2)); do
    printf '  \xe2\x9d\xaf %s\n' "$suffix" > "$resp/$n.out"
  done
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = unknown ] || fail "a refused suffix that stays in the composer must not claim nothing was typed, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 0 ] || fail "a suffix must not be submitted, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq "$cap" ] || fail "a leftover that will not clear should get a bounded $cap Ctrl+U presses, sent $(herdr_ctrl_u_count "$log")"
  pass "fm_backend_herdr_send_text_submit: a refused suffix whose clear cannot be verified reports unknown, not send-failed"
}

test_send_text_submit_clears_a_wrapped_suffix_one_row_per_press() {
  local dir log resp fb out enter_count text suffix drop
  dir="$TMP_ROOT/submit-long-suffix-wrapped"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 1492)
  suffix=${text: -480}
  herdr_submit_claude_prefix "$resp" "$text"
  for drop in 0 1 2 3 4 5; do
    herdr_wrapped_composer "$suffix" 96 "$drop" > "$resp/$((4 + 2 * drop)).out"
  done
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = send-failed ] || fail "a refused suffix wrapped over five rows, cleared row by row, should report send-failed, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 0 ] || fail "a suffix must not be submitted, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq 5 ] || fail "a five-row wrapped suffix should take five Ctrl+U presses, sent $(herdr_ctrl_u_count "$log")"
  pass "fm_backend_herdr_send_text_submit: a refused 480-character suffix wrapped over five rows is cleared one row per Ctrl+U and reports send-failed"
}

test_send_text_submit_refused_suffix_then_clean_retry_submits_only_the_message() {
  local dir log resp fb out enter_count text suffix
  dir="$TMP_ROOT/submit-long-suffix-retry"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 1492)
  suffix=${text: -480}
  herdr_submit_claude_prefix "$resp" "$text"
  printf '  \xe2\x9d\xaf %s\n' "$suffix" > "$resp/4.out"
  printf '  \xe2\x9d\xaf\n' > "$resp/6.out"
  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' > "$resp/7.out"
  printf '  \xe2\x9d\xaf\n' > "$resp/8.out"
  printf '  \xe2\x9d\xaf %s\n' "$text" > "$resp/10.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/11.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/13.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"
      first=$(fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01)
      second=$(fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01)
      printf "%s %s" "$first" "$second"' "$ROOT" "$text" )
  [ "$out" = "send-failed empty" ] || fail "a refused send followed by a resend should report 'send-failed empty', got '$out'"
  [ "$(grep -c $'\x1f''pane'$'\x1f''send-text'$'\x1f''w1:p2'$'\x1f'"$text" "$log")" -eq 2 ] || fail "each attempt should type the full message exactly once"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "only the clean retry should be submitted, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: after a refused suffix is cleared, a resend starts from an empty Claude composer and submits only the message"
}

test_send_text_submit_claude_refuses_to_type_into_a_nonempty_composer() {
  local dir log resp fb out text
  dir="$TMP_ROOT/submit-claude-leftover"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 1492)
  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' > "$resp/1.out"
  printf '  \xe2\x9d\xaf %s\n' "${text: -480}" > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = send-failed ] || fail "a Claude composer that already holds text should refuse the send, got '$out'"
  [ "$(grep -c $'\x1f''pane'$'\x1f''send-text' "$log")" -eq 0 ] || fail "nothing may be typed after a leftover tail, or Enter would submit tail plus message"
  [ "$(grep -c $'\x1f''pane'$'\x1f''send-keys' "$log")" -eq 0 ] || fail "a refused pre-send composer must not receive any key"
  pass "fm_backend_herdr_send_text_submit: a Claude composer holding leftover text is refused before anything is typed"
}

test_send_text_submit_refuses_suffix_when_transcript_still_shows_the_head() {
  local dir log resp fb out enter_count text suffix
  dir="$TMP_ROOT/submit-stale-head"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 1492)
  suffix=${text: -480}
  herdr_submit_claude_prefix "$resp" "$text"
  {
    printf '%s\n' "$text"
    printf '  \xe2\x9d\xaf %s\n' "$suffix"
  } > "$resp/4.out"
  printf '  \xe2\x9d\xaf\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = send-failed ] || fail "a stale transcript head above a suffix composer should report send-failed, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 0 ] || fail "a transcript head must not authorize Enter for a suffix composer, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: a matching head in the transcript does not prove the current composer"
}

# Away-mode digests and marked firstmate steers carry U+2063, which Claude's
# composer read-back on Herdr drops (verified live). The rest of the payload,
# byte for byte, is still proof; a missing message head is still refused.
test_send_text_submit_accepts_marked_payloads_whose_read_back_drops_u2063() {
  local kind dir log resp fb out enter_count text shown
  for kind in digest steer; do
    dir="$TMP_ROOT/submit-u2063-$kind"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
    if [ "$kind" = digest ]; then
      text=$(bash -c '. "$0/bin/fm-operational-input.sh"; fm_operational_input_encode away-supervisor "$1" out; printf "%s" "$out"' \
        "$ROOT" "$(herdr_long_payload 1492)")
    else
      text=$(bash -c '. "$0/bin/fm-operational-input.sh"; printf "%s %s" "$FM_FROMFIRST_MARK" "$1"' "$ROOT" "please rebase onto main")
    fi
    shown=${text//$'\xe2\x81\xa3'/}
    [ "$shown" != "$text" ] || fail "the $kind fixture did not carry U+2063"
    printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
    printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
    herdr_submit_claude_prefix "$resp" "$text"
    printf '  \xe2\x9d\xaf\xc2\xa0%s\n' "$shown" > "$resp/4.out"
    fb=$(make_herdr_fakebin "$dir")
    out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
    [ "$out" = empty ] || fail "a marked $kind whose read-back only lacks U+2063 should be submitted, got '$out'"
    assert_contains "$(cat "$log")" $'\x1f'"$text" "the marked $kind was not typed with its U+2063"
    enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
    [ "$enter_count" -eq 1 ] || fail "a marked $kind should be submitted once, sent $enter_count Enter(s)"
    [ "$(herdr_ctrl_u_count "$log")" -eq 0 ] || fail "an accepted marked $kind must not be cleared"
  done
  pass "fm_backend_herdr_send_text_submit: an away-mode digest and a marked steer are submitted when Claude's read-back only drops U+2063"
}

test_send_text_submit_refuses_marked_digest_missing_its_head() {
  local dir log resp fb out enter_count text shown
  dir="$TMP_ROOT/submit-u2063-suffix"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(bash -c '. "$0/bin/fm-operational-input.sh"; fm_operational_input_encode away-supervisor "$1" out; printf "%s" "$out"' \
    "$ROOT" "$(herdr_long_payload 1492)")
  shown=${text//$'\xe2\x81\xa3'/}
  herdr_submit_claude_prefix "$resp" "$text"
  printf '  \xe2\x9d\xaf\xc2\xa0%s\n' "${shown: -480}" > "$resp/4.out"
  printf '  \xe2\x9d\xaf\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = send-failed ] || fail "a marked digest whose composer kept only the tail should report send-failed, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 0 ] || fail "a marked digest tail must not be submitted, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq 1 ] || fail "the refused marked digest tail should be cleared"
  pass "fm_backend_herdr_send_text_submit: dropping U+2063 does not let a marked digest missing its head be submitted"
}

# Claude Code 2.1.283 renders a slash-command popup between the composer and
# the pane bottom, pushing the composer row outside a 20-row tail window. The
# composer reads must capture the full visible viewport: the old bounded read
# reported the composer empty, so the typed /exit was judged unsent, cleared,
# and never submitted (fm-control exit never exited).
test_composer_state_claude_slash_popup_pushes_composer_above_tail_window() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-claude-slash-popup"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  herdr_popup_composer_screen '/exit' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "a composer above a slash-command popup must read pending, got '$out'"
  grep -F $'\x1f''pane'$'\x1f''read'$'\x1f''w1:p2'$'\x1f''--source'$'\x1f''visible' "$log" >/dev/null \
    || fail "the composer state read must use the visible viewport"
  [ "$(grep -c $'\x1f''--lines' "$log")" -eq 0 ] || fail "the composer state read must not be a bounded --lines tail"
  pass "fm_backend_herdr_composer_state: a slash-command popup cannot hide a typed composer"
}

test_send_text_submit_claude_slash_popup_composer_is_still_proven_and_submitted() {
  local dir log resp fb out enter_count text
  dir="$TMP_ROOT/submit-claude-slash-popup"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text='/exit'
  herdr_submit_claude_prefix "$resp" "$text"
  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/7.out"
  herdr_popup_composer_screen "$text" > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = empty ] || fail "a composer proven above a slash-command popup must be submitted, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "the proven typed command should be submitted once, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq 0 ] || fail "a proven composer must not be cleared"
  grep -F $'\x1f''pane'$'\x1f''read'$'\x1f''w1:p2'$'\x1f''--source'$'\x1f''visible' "$log" >/dev/null \
    || fail "the payload proof must use the visible viewport"
  [ "$(grep -c $'\x1f''--lines' "$log")" -eq 0 ] || fail "no composer read may be a bounded --lines tail"
  pass "fm_backend_herdr_send_text_submit: a typed slash command hidden behind its popup is still proven and submitted"
}

# Live Claude Code 2.1.283 draws a recognized typed slash command in muted
# truecolor grey (38;2;112;112;112, luminance 112), below the grok-tuned
# dark-foreground ghost threshold. Claude's own ghost suggestion is SGR-2 dim,
# so the Claude payload proof must not strip the grey command and judge the
# typed /exit unsent (the fm-control exit breakage, reproduced live).
test_send_text_submit_claude_grey_slash_command_is_proven_and_submitted() {
  local dir log resp fb out enter_count text rule head
  dir="$TMP_ROOT/submit-claude-grey-slash"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text='/exit'
  herdr_submit_claude_prefix "$resp" "$text"
  rule=$(printf '%0.s\xe2\x94\x80' $(seq 1 60))
  head=$(printf '%0.s\xe2\x94\x80' $(seq 1 19))
  {
    printf '  \x1b[0m\x1b[38;2;112;112;112m/\x1b[0m\x1b[1m\x1b[38;2;112;112;112mexit\x1b[0m\x1b[38;2;112;112;112m    Exit the CLI\x1b[0m\n'
    printf '\x1b[0m\x1b[38;2;121;129;134m%s Firstmate operational input 1790546042 \xe2\x94\x80\x1b[0m\n' "$head"
    printf '\xe2\x9d\xaf\xc2\xa0\x1b[0m\x1b[38;2;112;112;112m/exit\x1b[0m\n'
    printf '\x1b[0m\x1b[38;2;121;129;134m%s\x1b[0m\n' "$rule"
    printf '  \x1b[0m\x1b[38;2;86;93;96m\xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on\x1b[0m\n'
  } > "$resp/4.out"
  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/7.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = empty ] || fail "a typed /exit drawn in Claude's grey slash-command colour must be proven and submitted, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "the proven grey slash command should be submitted once, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq 0 ] || fail "a proven grey slash command must not be cleared"
  pass "fm_backend_herdr_send_text_submit: a typed slash command Claude draws in muted truecolor grey is proven and submitted"
}

# A named Claude session titles its composer's top rule, and the away-mode
# doorbell is wider than most panes, so the typed doorbell wraps onto
# continuation rows above the closing rule. The payload proof must read that
# wrapped draft and submit it once: reading it `unknown` cleared every
# doorbell it typed and returned send-failed, so away mode delivered nothing.
test_send_text_submit_claude_wrapped_doorbell_under_titled_rule_is_submitted() {
  local dir log resp fb out enter_count text rule head row first=1
  dir="$TMP_ROOT/submit-claude-titled-wrapped"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(bash -c '. "$0/bin/fm-operational-input.sh"; printf "%s%s%s" "$FM_OPERATIONAL_DOORBELL_PREFIX" "$1" "$FM_OPERATIONAL_DOORBELL_SUFFIX"' \
    "$ROOT" "/home/fm/state/operational-inbox/1794626926-0123456789abcdef.msg")
  herdr_submit_claude_prefix "$resp" "$text"
  rule=$(printf '%0.s\xe2\x94\x80' $(seq 1 60))
  head=$(printf '%0.s\xe2\x94\x80' $(seq 1 19))
  {
    printf '\x1b[0m\x1b[38;2;136;136;136m%s Firstmate operational input 1790546042 \xe2\x94\x80\x1b[0m\n' "$head"
    printf '\xe2\x9d\xaf\xc2\xa0\n'
    printf '\x1b[0m\x1b[38;2;136;136;136m%s\x1b[0m\n' "$rule"
    printf '  \x1b[0m\x1b[38;2;86;93;96m\xe2\x8f\xb5\xe2\x8f\xb5 auto mode on\x1b[0m\n'
  } > "$resp/2.out"
  {
    printf '\x1b[0m\x1b[38;2;136;136;136m%s Firstmate operational input 1790546042 \xe2\x94\x80\x1b[0m\n' "$head"
    while IFS= read -r row; do
      if [ "$first" = 1 ]; then printf '\xe2\x9d\xaf\xc2\xa0%s\n' "$row"; first=0; else printf '  %s\n' "$row"; fi
    done <<EOF
$(printf '%s\n' "$text" | fold -s -w 56)
EOF
    printf '\x1b[0m\x1b[38;2;136;136;136m%s\x1b[0m\n' "$rule"
    printf '  \x1b[0m\x1b[38;2;86;93;96m\xe2\x8f\xb5\xe2\x8f\xb5 auto mode on\x1b[0m\n'
  } > "$resp/4.out"
  [ "$(grep -c '' "$resp/4.out")" -ge 6 ] || fail "the doorbell fixture should wrap onto continuation rows"
  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/7.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = empty ] || fail "a doorbell wrapped under a titled top rule must be proven and submitted, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "the proven wrapped doorbell should be submitted once, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq 0 ] || fail "a proven wrapped doorbell must not be cleared"
  pass "fm_backend_herdr_send_text_submit: an away-mode doorbell wrapped under a titled Claude top rule is proven and submitted"
}

test_send_text_submit_lone_paste_placeholder_submits_the_long_payload() {
  local dir log resp fb out enter_count text
  dir="$TMP_ROOT/submit-paste-placeholder"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 1492)
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
  herdr_submit_claude_prefix "$resp" "$text"
  printf '  \xe2\x9d\xaf [Pasted text #1]\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = empty ] || fail "a lone paste placeholder for the whole burst should still be submitted, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f'"$text" "the typed payload was not the full long text"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "a lone paste placeholder should be submitted once, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: a lone paste placeholder still submits the full long payload"
}

# Live Claude 2.1.278 collapses a long multi-line paste into
# `[Pasted text #N +M lines]` and expands it on submit, like the one-line form.
test_send_text_submit_multiline_paste_placeholder_submits_the_long_payload() {
  local dir log resp fb out enter_count text
  dir="$TMP_ROOT/submit-multiline-placeholder"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(awk 'BEGIN { for (i = 1; i <= 42; i++) printf "steer line %02d with enough words to be a real instruction\n", i }')
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
  herdr_submit_claude_prefix "$resp" "$text"
  printf '  \xe2\x9d\xaf [Pasted text #4 +40 lines]\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = empty ] || fail "a lone multi-line paste placeholder for the whole burst should be submitted, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "a lone multi-line paste placeholder should be submitted once, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq 0 ] || fail "an accepted multi-line placeholder must not be cleared"
  pass "fm_backend_herdr_send_text_submit: a lone multi-line paste placeholder still submits the long multi-line payload"
}

test_send_text_submit_refuses_placeholder_followed_by_a_literal_remainder() {
  local dir log resp fb out enter_count text suffix
  dir="$TMP_ROOT/submit-paste-remainder"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 1492)
  suffix=${text: -480}
  herdr_submit_claude_prefix "$resp" "$text"
  printf '  \xe2\x9d\xaf [Pasted text #1]%s\n' "$suffix" > "$resp/4.out"
  printf '  \xe2\x9d\xaf\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = send-failed ] || fail "a paste placeholder followed by a literal remainder should report send-failed, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 0 ] || fail "a placeholder plus remainder must not be submitted, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq 1 ] || fail "the refused placeholder and remainder should be cleared"
  pass "fm_backend_herdr_send_text_submit: a paste placeholder followed by a literal remainder is not submitted and is cleared"
}

test_send_text_submit_three_paste_placeholders_submit_the_long_payload() {
  local dir log resp fb out enter_count text
  dir="$TMP_ROOT/submit-three-placeholders"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 2992)
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
  herdr_submit_claude_prefix "$resp" "$text"
  printf '  \xe2\x9d\xaf [Pasted text #1][Pasted text #2][Pasted text #3]\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = empty ] || fail "three paste placeholders with no literal remainder should be submitted, got '$out'"
  [ "${#text}" -eq 3000 ] || fail "the 3000-character fixture was ${#text} chars"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "three placeholders should be submitted once, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: three paste placeholders with no literal remainder submit the long payload"
}

# A non-Claude harness keeps the unproven type-then-Enter path: its composer
# is never read before Enter, so a harness-specific placeholder or an
# unselectable composer cannot turn a landed send into send-failed.
test_send_text_submit_non_claude_skips_the_payload_proof() {
  local agent dir log resp fb out enter_count text
  text=$(herdr_long_payload 1492)
  for agent in codex missing; do
    dir="$TMP_ROOT/submit-non-claude-$agent"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
    printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/3.out"
    printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/5.out"
    if [ "$agent" = missing ]; then
      printf '1\n' > "$resp/1.exit"
    else
      printf '{"result":{"agent":{"agent":"%s","agent_status":"idle"}}}\n' "$agent" > "$resp/1.out"
    fi
    fb=$(make_herdr_fakebin "$dir")
    out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
    [ "$out" = empty ] || fail "a $agent pane should keep the type-then-Enter path and confirm from agent_status, got '$out'"
    [ "$(grep -c $'\x1f''pane'$'\x1f''read' "$log")" -eq 0 ] || fail "a $agent pane must not have its composer read before Enter"
    enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
    [ "$enter_count" -eq 1 ] || fail "a $agent pane should be submitted once, sent $enter_count Enter(s)"
  done
  pass "fm_backend_herdr_send_text_submit: non-Claude and unidentified panes keep the pre-proof type-then-Enter behavior"
}
