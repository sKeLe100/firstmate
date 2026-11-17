#!/usr/bin/env bash
# tests/fm-backend-herdr.test.sh - fake-herdr-CLI unit tests for the herdr
# session-provider adapter (bin/backends/herdr.sh), P2 of
# data/fm-backend-design-d7 (herdr-addendum.md). Mirrors tests/fm-backend.test.sh's
# fakebin/command-log convention, but herdr has no pre-refactor baseline to
# diff against (it is new in this task), so these are direct behavior
# assertions against a small, LOG-based, canned-response fake `herdr` + real
# `jq` (jq itself is a real required tool for this backend, not faked).
# The real-binary smoke test lives in tests/fm-backend-herdr-smoke.test.sh,
# gated on the herdr binary actually being installed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"
# shellcheck source=tests/herdr-client-pair-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-client-pair-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# These cases script a canned fake CLI; a Herdr pane identity leaked in from the
# developer's own terminal would make the adapter resolve a launcher that this
# fake never models. The launcher cases below set HERDR_PANE_ID themselves.
herdr_forget_inherited_pane

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-tests)
# Pin the ambient-home default to a marker-free fixture: FM_HOME resolves to
# the suite's own root when unset, and a secondmate-marked checkout (any
# treehouse crew home carries .fm-secondmate-home) would flip the default
# workspace label to 2ndmate-*, silently changing placement behavior for
# every test that does not set FM_HOME itself. Per-test FM_HOME prefixes
# still override this default.
mkdir -p "$TMP_ROOT/ambient-home"
export FM_HOME="$TMP_ROOT/ambient-home"
export FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0

# make_herdr_fakebin: a `herdr` stub that logs every invocation (one line,
# unit-separated args, to $FM_HERDR_LOG) and returns the canned response for
# that call read from $FM_HERDR_RESPONSES/<n>.out, consumed IN ORDER (call 1
# reads 1.out, call 2 reads 2.out, ...) so a test can script a short sequence
# of calls precisely. A missing response file means "succeed with empty
# stdout" (mirrors send-text/send-keys/pane close/tab close, which are silent
# on success in the real CLI - verified in herdr-verification-p2.md).
make_herdr_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
RESP="${FM_HERDR_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ] && [ "${FM_HERDR_SCRIPT_STATUS:-0}" != 1 ]; then
  printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
  exit 0
fi
if [ "${1:-}" = terminal ] && [ "${2:-}" = title ] && [ "${3:-}" = clear ]; then
  reason=${FM_FAKE_HERDR_FOREGROUND_REASON:-no_foreground_client}
  printf '{"result":{"reason":"%s"}}\n' "$reason"
  exit 0
fi
n=$next
echo "$n" > "$COUNT_FILE"
[ -f "$RESP/$n.err" ] && cat "$RESP/$n.err" >&2
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# herdr_submit_shift: move every canned response <by> slots later, so a
# fixture numbered from the literal send can take new calls in front of it.
herdr_submit_shift() {  # <resp-dir> <by>
  local resp=$1 by=$2 n ext f sorted
  local -a found=()
  shopt -s nullglob
  for f in "$resp"/*.out "$resp"/*.exit; do
    n=$(basename "$f")
    n=${n%%.*}
    found+=("$n")
  done
  shopt -u nullglob
  [ "${#found[@]}" -gt 0 ] || return 0
  sorted=$(printf '%s\n' "${found[@]}" | sort -rn -u)
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    for ext in out exit; do
      f="$resp/$n.$ext"
      if [ -f "$f" ]; then
        mv "$f" "$resp/$((n + by)).$ext"
      fi
    done
  done <<EOF
$sorted
EOF
}

# herdr_submit_identity_prefix: submit first asks `agent get` which harness
# the pane runs. A non-Claude harness skips the payload proof, so a fixture
# numbered for the old send-text-first sequence moves one slot later.
herdr_submit_identity_prefix() {  # <resp-dir> <agent>
  herdr_submit_shift "$1" 1
  printf '{"result":{"agent":{"agent":"%s","agent_status":"idle"}}}\n' "$2" > "$1/1.out"
}

# herdr_submit_claude_prefix: a Claude pane adds the identity probe, an empty
# composer read before the send, and a composer read after it. Call 1 is the
# identity, call 2 the empty composer, call 3 the literal send, and call 4 the
# composer holding <text>. Old call N (N >= 2) moves to N + 3.
herdr_submit_claude_prefix() {  # <resp-dir> <typed-text>
  local resp=$1 text=$2
  herdr_submit_shift "$resp" 3
  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' > "$resp/1.out"
  printf '  \xe2\x9d\xaf\n' > "$resp/2.out"
  printf '  \xe2\x9d\xaf %s\n' "$text" > "$resp/4.out"
}

# herdr_submit_preflight_prefix: fm_backend_send_text_submit reads the composer
# once before the adapter types. That read is call 1 and shows an empty
# composer, so every adapter call moves one slot later.
herdr_submit_preflight_prefix() {  # <resp-dir>
  herdr_submit_shift "$1" 1
  printf '  \xe2\x9d\xaf\n' > "$1/1.out"
}

# make_herdr_server_env_fakebin: a stateful server stub that records only the
# long-lived server launch environment, then reports the server as running.
make_herdr_server_env_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status)
    if [ -e "$FM_HERDR_SERVER_MARKER" ]; then
      printf '{"server":{"running":true}}\n'
    else
      printf '{"server":{"running":false}}\n'
    fi
    ;;
  server)
    {
      for name in FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE CURSOR_AGENT CURSOR_INVOKED_AS CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT FM_SUPERVISION_MODEL FM_HERDR_SENTINEL HERDR_SESSION; do
        eval 'value=${'"$name"'-<unset>}'
        printf '%s=%s\n' "$name" "$value"
      done
      printf 'args=%s\n' "$*"
    } > "$FM_HERDR_SERVER_ENV_LOG"
    : > "$FM_HERDR_SERVER_MARKER"
    ;;
esac
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# make_herdr_statefake: a STATEFUL `herdr` stub that models the parts of herdr's
# real container behavior the workspace-leak fix (and the default-tab-prune
# safety fix) depend on, so a full spawn->teardown cycle can be replayed
# repeatedly and the "one persistent firstmate workspace, no orphans"
# invariant asserted end to end (the canned, call-numbered make_herdr_fakebin
# above cannot model state carried ACROSS calls). Backed by a JSON state file
# ($FM_FAKE_HERDR_STATE) mutated with real jq. Modeled behaviors, all
# verified real-herdr facts recorded in docs/herdr-backend.md: `workspace
# create` seeds the new workspace with one auto-created default tab (label
# "1") and returns that tab's tab_id/pane_id in the SAME response
# (`.result.tab.tab_id` / `.result.root_pane.pane_id`, verified empirically
# against the real binary); `pane close` removes the pane's single-pane tab
# (closing a tab's only pane closes the tab); `workspace list` / `tab list` /
# `pane list` reflect live state; `agent get <pane>` reports the pane's preset
# agent_status (set via fake_herdr_set_agent_status, never through a CLI
# call - mirrors an out-of-band agent registering itself) or an
# agent_not_found error when none was preset (verified real-herdr behavior for
# a pane with no registered agent). Every call is logged to $FM_HERDR_LOG in
# the same unit-separated form as make_herdr_fakebin.
make_herdr_statefake() {  # <dir> -> echoes fakebin dir; seeds an empty state file
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  printf '{"next":1,"workspaces":[],"tabs":[],"agent_status":{}}\n' > "$dir/state.json"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
STATE="${FM_FAKE_HERDR_STATE:?}"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

jq_state() { jq "$@" "$STATE"; }
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }

cmd=${1:-}; sub=${2:-}
ws=""; label=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
  esac
done

case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    ;;
  "terminal title")
    printf '{"result":{"reason":"no_foreground_client"}}\n'
    ;;
  "workspace list")
    jq_state '{result:{workspaces:.workspaces}}'
    ;;
  "workspace create")
    n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
    jq_state --arg wsid "$wsid" --arg wlabel "$label" \
      --arg tabid "$wsid:t$dn" --arg paneid "$wsid:p$dn" \
      '.workspaces += [{workspace_id:$wsid, label:$wlabel}]
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid}]
       | .next = (.next + 2)' | save
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$wsid" "$label" "$wsid:t$dn" "$wsid:p$dn"
    ;;
  "tab list")
    jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}'
    ;;
  "tab create")
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg wlabel "$label" --arg tabid "$tabid" --arg paneid "$paneid" \
      '.tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid}]
       | .next = (.next + 1)' | save
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid"
    ;;
  "pane list")
    jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id, tab_id:.tab_id}]}}'
    ;;
  "pane close")
    pane=${3:-}
    jq_state --arg p "$pane" '.tabs |= [.[]|select(.pane_id != $p)]' | save
    ;;
  "tab close")
    tab=${3:-}
    jq_state --arg t "$tab" '.tabs |= [.[]|select(.tab_id != $t)]' | save
    ;;
  "agent get")
    pane=${3:-}
    status=$(jq_state -r --arg p "$pane" '.agent_status[$p] // empty')
    if [ -n "$status" ]; then
      printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$status"
    else
      printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "$pane"
    fi
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# fake_herdr_set_agent_status: preset <pane_id>'s agent_status in the
# stateful fake's state file, mirroring an agent registering itself
# out-of-band (never through a CLI call the adapter itself would make).
# Used to exercise fm_backend_herdr_workspace_prune_seeded_default_tab's
# defense-in-depth refuse-if-busy check.
fake_herdr_set_agent_status() {  # <state-file> <pane_id> <status>
  local state=$1 pane=$2 status=$3 tmp="$1.tmp.$$"
  jq --arg p "$pane" --arg s "$status" '.agent_status[$p] = $s' "$state" > "$tmp" && mv "$tmp" "$state"
}

# herdr_case <name> -> sets up FM_HERDR_LOG/FM_HERDR_RESPONSES/fb for one test,
# registers cleanup-free tmp dirs under TMP_ROOT.
herdr_env() {  # <name>
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/responses"
  : > "$dir/log"
  printf '%s\n%s\n' "$dir/log" "$dir/responses"
}

# The cases, split by adapter surface so no single file outgrows the test-size
# ceiling. Every part is sourced before the run list below, so a case may call a
# helper defined beside the cases of another part.
# shellcheck source=tests/fm-backend-herdr-placement-part.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-backend-herdr-placement-part.sh"
# shellcheck source=tests/fm-backend-herdr-presentation-part.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-backend-herdr-presentation-part.sh"
# shellcheck source=tests/fm-backend-herdr-input-part.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-backend-herdr-input-part.sh"
# shellcheck source=tests/fm-backend-herdr-events-part.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-backend-herdr-events-part.sh"

test_version_check_accepts_current_protocol
test_version_check_refuses_old_protocol
test_version_check_refuses_missing_herdr
test_workspace_label_primary_home_no_marker
test_workspace_label_secondmate_home_uses_marker_id
test_workspace_label_secondmate_marker_trims_whitespace
test_workspace_label_empty_marker_falls_back_to_primary
test_workspace_label_different_secondmates_get_different_labels
test_cli_helper_sets_env_and_appends_trailing_session_flag
test_cli_helper_places_session_flag_before_agent_separator
test_agent_state_bypasses_a_stale_client_shadowing_a_compatible_one
test_recovery_grade_read_widens_only_at_its_own_boundary
test_stale_registration_over_a_shell_only_pane_is_agent_free
test_stale_registration_ignores_status_and_reads_the_process
test_pane_agent_session_ref_reports_a_resumable_reference_with_its_agent
test_pane_agent_session_ref_degrades_to_nothing_when_not_resumable
test_registered_agent_with_a_live_foreground_process_stays_alive
test_registered_agent_with_a_non_shell_foreground_process_stays_alive
test_transient_prompt_helper_settles_into_stale_agent
test_exhausted_settle_window_keeps_a_non_shell_foreground_live
test_registered_agent_with_an_agent_descendant_outside_the_foreground_stays_alive
test_agent_descendant_under_a_spaced_install_path_stays_alive
test_registered_agent_with_an_unreadable_process_view_is_unknown
test_registered_agent_with_an_empty_foreground_over_a_real_shell_settles_via_descendant_walk
test_projection_reclaim_rollback_refuses_a_stale_registration
test_busy_state_never_reports_a_shell_only_pane_busy
test_cli_caches_the_selected_client_within_a_process
test_cli_scopes_the_selected_client_to_its_session
test_cli_unrelated_failure_never_triggers_reselection
test_cli_single_client_pays_no_selection_read
test_client_status_reads_both_status_shapes
test_launcher_identity_absent_without_a_herdr_pane
test_launcher_identity_absent_when_herdr_env_alone_is_set
test_launcher_identity_resolves_the_exact_pane_tab_and_workspace
test_launcher_identity_refuses_a_pane_from_another_session_name
test_launcher_identity_refuses_a_missing_server_socket
test_launcher_identity_refuses_a_pane_from_another_server_socket
test_launcher_identity_refuses_an_unreadable_pane
test_launcher_identity_refuses_a_pane_and_tab_that_disagree
test_launcher_identity_refuses_a_workspace_missing_from_the_session
test_workspace_ensure_prefers_the_launcher_over_the_first_label_match
test_workspace_ensure_refuses_an_ambiguous_label_with_no_launcher
test_workspace_ensure_other_home_ignores_the_launcher_identity
test_container_ensure_refuses_an_ambiguous_home_label
test_container_ensure_starts_server_and_workspace
test_server_ensure_scrubs_home_and_harness_identity
test_container_ensure_reuses_existing_workspace
test_container_ensure_creates_with_no_focus_flag
test_container_ensure_uses_secondmate_home_label
test_workspace_ensure_prunes_default_tab
test_repeated_cycles_reuse_one_workspace_no_orphans
test_adopted_workspace_never_prunes_default_tab
test_label_collision_startup_workspace_leaves_live_tab_alone
test_prune_refuses_a_working_agent_pane_defense_in_depth
test_create_task_refuses_duplicate_label
test_create_task_refuses_duplicate_label_when_agent_live
test_create_task_refuses_when_any_duplicate_label_is_live
test_create_task_closes_and_replaces_dead_pane_husk
test_create_task_closes_and_replaces_no_agent_husk
test_create_task_closes_all_duplicate_husks_after_replacement
test_create_task_refuses_when_preexisting_husk_tab_remains
test_create_task_refuses_when_agent_state_ambiguous
test_create_task_husk_replacement_creates_before_closing
test_create_task_creates_and_parses_ids
test_create_task_creates_with_no_focus_flag
test_presentation_defaults_on_at_or_above_the_floor
test_presentation_default_falls_back_below_the_floor
test_presentation_unreadable_release_falls_back
test_presentation_explicit_opt_in_survives_the_floor
test_presentation_explicit_off_opts_out
test_presentation_unrecognized_value_warns_and_keeps_the_default
test_presentation_floor_warning_is_one_per_release
test_presentation_floor_warning_marker_is_atomic_and_symlink_safe
test_presentation_running_server_release_is_load_bearing
test_release_floor_verdict_matches_the_measured_releases
test_release_floor_verdict_survives_losing_either_signal
test_presentation_preference_reports_three_distinct_states
test_projection_journal_is_atomic_and_uses_128_bit_token
test_projection_journal_v2_binds_and_advances_exact_endpoint
test_projection_create_uses_exact_response_ids_and_leaves_one_task_pane
test_projection_create_never_closes_a_concurrent_same_label_tab
test_projection_focus_snapshot_requires_exact_workspace_and_tab
test_projection_close_restores_exact_prior_focus
test_projection_close_refuses_active_tab
test_projection_close_refuses_unknown_foreground_reason
test_projection_close_allows_stale_active_tab_without_foreground_client
test_projection_close_reports_focus_restore_failure
test_projection_close_rechecks_required_agent_state_at_boundary
test_projection_close_rechecks_foreground_client_after_agent_validation
test_projection_close_rechecks_target_focus_after_planning
test_projection_close_preserves_live_focus_that_switched_away_from_target
test_projection_close_emptying_after_focus_uses_pane_death_without_move
test_projection_close_emptying_before_focus_repositions_then_uses_pane_death
test_projection_close_emptying_before_last_focus_needs_no_move
test_projection_close_emptying_last_workspace_needs_no_move
test_projection_close_non_emptying_stays_plain_without_proof_or_move
test_projection_close_plain_without_move_requires_structured_removal
test_projection_close_ambiguous_positions_fall_back_to_plain_close
test_projection_close_move_failure_falls_back_to_plain_close
test_projection_close_busy_pane_falls_back_to_plain_close
test_projection_close_transient_prompt_helper_settles_then_uses_pane_death
test_projection_close_death_escalates_sigkill_after_sighup_survival
test_projection_close_death_failure_falls_back_to_plain_close
test_projection_close_death_still_restores_a_stolen_focus
test_projection_close_death_never_sigkills_a_reused_pid
test_projection_close_failed_removal_rolls_back_the_reposition
test_kill_emptying_non_focused_uses_pane_death
test_kill_focused_workspace_stays_plain_close
test_endpoint_confirmed_gone_gates_on_structured_presence
test_kill_refuses_when_presentation_lock_is_unavailable
test_projection_seeded_prune_refuses_active_tab
test_projection_label_builder_uses_corner_and_strips_owner_prefixes
test_projection_order_moves_only_exact_new_workspace_and_preserves_relative_order
test_projection_order_secondmate_parent_block
test_projection_order_group_key_places_new_task_inside_its_group
test_projection_order_foreign_legacy_child_is_read_only
test_projection_order_allows_intervening_parent_child_block
test_projection_order_human_spaces_never_move_targets
test_projection_order_failure_warns_without_cleanup_or_spawn_failure
test_projection_order_ambiguous_existing_block_is_read_only
test_projection_order_anchors_the_parent_by_exact_id
test_projection_order_foreign_new_child_before_parent_is_read_only
test_projection_order_missing_parent_is_read_only
test_presentation_session_lock_path_is_shared_across_homes
test_presentation_session_lock_path_rejects_malformed_socket
test_projection_order_rejects_malformed_socket
test_projection_reclaim_refusal_matrix_is_non_mutating
test_projection_reclaim_replaces_only_exact_husk_and_advances_binding
test_projection_recovery_is_read_only_and_refuses_live_duplicate_risk
test_workspace_find_matches_only_this_homes_own_label
test_list_live_scoped_to_this_homes_workspace_only
test_parse_target
test_session_prefixed_pane_ids_are_normalized_for_read_and_close
test_session_prefixed_pane_ids_are_normalized_for_seeded_tab_prune
test_normalize_key
test_capture_calls_pane_read
test_capture_works_around_small_lines_bug
test_capture_preserves_pane_read_failure
test_send_key_normalizes_and_targets_pane
test_kill_is_best_effort
test_current_path_reads_cwd
test_busy_state_working_maps_to_busy
test_busy_state_done_and_blocked_map_to_idle
test_busy_state_unknown_on_no_agent
test_composer_state_bare_prompt_is_empty
test_composer_state_styled_placeholder_draft_is_pending
test_composer_state_real_text_is_pending
test_composer_state_grok_oversized_title_preserves_safe_verdicts
test_composer_state_popup_placeholder_fill_is_pending
test_composer_state_unknown_on_capture_failure
test_composer_state_inactive_session_fails_fast_without_server_autostart
test_composer_state_piped_reader_does_not_hang
test_composer_state_unknown_when_no_composer_row_found
test_composer_state_pi_parked_prompt_is_not_empty
test_composer_state_pi_separator_idle_is_empty
test_composer_state_pi_dollar_status_footer_is_empty
test_composer_state_pi_separator_real_text_is_pending
test_composer_state_pi_incomplete_separator_below_stale_generic_is_unknown
test_composer_state_pi_separator_requires_safe_native_identity
test_composer_state_claude_unbordered_prompt_is_empty
test_composer_state_claude_unbordered_prompt_is_pending
test_composer_state_bare_prompt_below_stale_bordered_banner_wins
test_composer_state_claude_dim_prompt_suggestion_ghost_is_empty
test_composer_state_claude_dim_ghost_row_with_real_text_is_pending
test_composer_state_grok_dark_truecolor_placeholder_is_empty
test_composer_state_grok_bright_truecolor_real_text_is_pending
test_composer_state_codex_bare_prompt_glyph_is_empty
test_composer_state_codex_faint_suggestion_is_empty
test_composer_state_codex_non_faint_same_text_is_pending
test_wait_for_working_returns_busy_on_first_poll
test_wait_for_working_catches_a_slow_transition_mid_window
test_wait_for_working_samples_budget_endpoint_without_final_sleep
test_send_text_submit_applies_herdr_minimum_confirm_budget
test_wait_for_working_returns_idle_when_never_busy_but_readable
test_wait_for_working_returns_unknown_when_never_readable
test_wait_for_working_treats_blocked_as_submit_active
test_send_text_submit_detects_landed_send
test_send_text_submit_detects_swallowed_enter
test_send_text_submit_replays_literal_send_stderr
test_send_text_submit_popup_autocomplete_requires_second_enter
test_send_text_submit_refuses_confirming_enter_on_exit_picker
test_blocked_submit_leaves_the_exit_picker_to_the_next_composer_read
test_send_text_submit_confirms_blocked_after_enter
test_send_text_submit_preexisting_working_pending_is_queued_enter
test_send_text_submit_preexisting_working_does_not_confirm_failed_enter
test_send_text_submit_idle_baseline_does_not_confirm_failed_enter
test_send_text_submit_idle_native_empty_composer_confirms_delivery
test_send_text_submit_idle_native_pending_plus_rendered_busy_is_queued
test_composer_state_cursor_midturn_row_reads_pending
test_rendered_busy_state_reads_the_cursor_busy_token
test_send_text_submit_confirms_never_idle_native_state_via_footer_transition
test_send_text_submit_never_idle_native_state_keeps_pending_without_a_transition
test_send_text_submit_confirms_despite_codex_idle_tip_composer
test_composer_state_codex_dynamic_idle_tip_reads_empty_when_faint
test_composer_state_guard_still_refuses_real_pending_text_after_submit_confirmation_change
test_send_text_submit_slow_transition_within_one_enter_needs_no_extra_enter
test_send_text_submit_send_failed
test_send_text_submit_unknown_on_capture_failure
test_send_text_submit_unknown_on_composer_capture_failure
test_send_text_submit_long_literal_submits_when_composer_holds_every_byte
test_send_text_submit_refuses_enter_when_composer_holds_only_the_suffix
test_send_text_submit_refused_suffix_that_will_not_clear_is_unknown
test_send_text_submit_clears_a_wrapped_suffix_one_row_per_press
test_send_text_submit_refused_suffix_then_clean_retry_submits_only_the_message
test_send_text_submit_claude_refuses_to_type_into_a_nonempty_composer
test_send_text_submit_refuses_suffix_when_transcript_still_shows_the_head
test_send_text_submit_accepts_marked_payloads_whose_read_back_drops_u2063
test_send_text_submit_refuses_marked_digest_missing_its_head
test_composer_state_claude_slash_popup_pushes_composer_above_tail_window
test_send_text_submit_claude_slash_popup_composer_is_still_proven_and_submitted
test_send_text_submit_claude_grey_slash_command_is_proven_and_submitted
test_send_text_submit_claude_wrapped_doorbell_under_titled_rule_is_submitted
test_send_text_submit_lone_paste_placeholder_submits_the_long_payload
test_send_text_submit_multiline_paste_placeholder_submits_the_long_payload
test_send_text_submit_refuses_placeholder_followed_by_a_literal_remainder
test_send_text_submit_three_paste_placeholders_submit_the_long_payload
test_send_text_submit_non_claude_skips_the_payload_proof
test_dispatch_routes_herdr_backend
test_dispatch_busy_state_unknown_for_tmux
test_dispatch_composer_state_routes_by_backend
test_scripts_route_explicit_target_through_meta_backend
test_normalize_event_leaves_from_empty
test_escalation_marker_keys_like_watcher
test_apply_transition_blocked_requires_commit_to_dedupe
test_apply_transition_working_clears_marker
test_clear_transition_removes_task_marker
test_apply_transition_defer_and_fallback_are_noops
test_wait_transition_no_panes_returns_2
test_wait_transition_not_capable_returns_2
test_wait_transition_reconcile_blocked_returns_record
test_wait_transition_subscribes_before_reconcile
test_wait_transition_reconcile_dedupes_when_marked
test_wait_transition_stream_blocked_returns_record
test_wait_transition_stream_absorb_clears_then_timeout
test_wait_transition_reader_failure_returns_2
test_wait_transition_bad_ack_returns_2_and_cleans_up
test_wait_transition_clean_timeout_returns_1
test_agent_state_stopped_server_is_missing
test_agent_state_failed_server_probe_is_unreadable
test_agent_state_unparseable_server_probe_is_unreadable
test_agent_state_running_server_with_live_agent_is_alive
test_pane_agent_state_unknown_status_with_bare_idle_shell_is_dead
test_pane_agent_state_unknown_status_without_bare_shell_proof_stays_unknown
