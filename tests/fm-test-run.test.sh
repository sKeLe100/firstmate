#!/usr/bin/env bash
# Contract tests for bin/fm-test-run.sh - the single owner of behavior suite
# selection, portable lane composition, proven-isolated --jobs, bounded
# concurrency, opt-in --fail-fast, budgets, timing markers, JSON artifacts,
# coverage guard, and aggregate exit status.
#
# These tests intentionally exercise the runner with fixtures, --list, and
# focused scheduler checks, not the complete Firstmate suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$RUNNER" "bin/fm-test-run.sh is missing"
[ -x "$RUNNER" ] || fail "bin/fm-test-run.sh must be executable"

# Pin the automatic scheduler's host-load input so every test below is
# deterministic regardless of the actual machine's contention; tests that
# specifically exercise load-aware behavior override this per invocation.
export FM_TEST_RUN_LOAD5_OVERRIDE=0
unset FM_TEST_RUN_AUTO_JOBS_MAX

# The case bodies live in two sourced suite files so this suite and each body
# stay under the per-file ceiling in bin/fm-lint-test-size.sh. They are sourced
# in the old in-file order; later definitions (fm_run_timed) still override
# earlier ones exactly as before.
# shellcheck source=tests/fm-test-run-selection-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-test-run-selection-lib.sh"
# shellcheck source=tests/fm-test-run-scheduling-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-test-run-scheduling-lib.sh"

# The environment-record case above separately exercises the real integration;
# these cases need neither installed-tool version probes nor browser startup.
FIXTURE_ROOT=$(fm_test_tmproot fm-test-run-subject-fixtures)
init_scheduler_fixture_repo "$FIXTURE_ROOT" fm-fixture.test.sh
FIXTURE_RUNNER="$FIXTURE_ROOT/bin/fm-test-run.sh"

# These three coverage assertions inspect different fields of the same real
# guard result. No case mutates the repository inventory, so run it once.
COVERAGE_REPORT=$("$RUNNER" --check-coverage) \
  || fail "real inventory coverage guard failed: $COVERAGE_REPORT"
# The real inventory does not change while this script runs, so snapshot the
# listings several cases assert against once instead of rescanning the whole
# tests/ inventory per case.
ALL_SUITE_LIST=$("$RUNNER" --list --all)
PURE_CONTRACT_LIST=$("$RUNNER" --list --family pure-contract-unit)
HERDR_FAMILY_LIST=$("$RUNNER" --list --family real-herdr-gated)
test_list_all_exact_suite_coverage
test_family_selection
test_single_script_selection
test_environment_record_is_compact_safe_and_emitted_once
test_changed_file_selection_is_conservative
test_task_marker_refuses_the_primary_checkout
test_changed_runner_surfaces_select_their_family
test_shell_line_ending_policy_selects_runner_contract
test_quarantine_list_change_selects_runner_contract
test_changed_dependency_selection_and_unmapped_failure
test_changed_bin_reference_selects_per_script_not_per_family
test_changed_reference_closure
test_changed_real_inventory_selection_bounds
test_changed_uses_bounded_automatic_concurrency
test_windows_posix_mode_emulation_does_not_fail_parallel_runs
test_script_list_uses_bounded_automatic_concurrency
test_family_proofs_run_in_separate_concurrent_phases
test_empty_selection_emits_summary
test_timing_markers_and_json
test_aggregate_exit_behavior
test_gate_skip_accounting
test_gate_skip_reason_is_recorded
test_a_run_that_ran_records_no_skip_reason
test_live_guards_expect_a_capability_skip_class
test_fail_on_gate_skip_token
test_exclude_family
test_exclude_quarantined
test_quarantine_diagnostics
test_list_scheduled_proven_isolated_uses_serial_weights
test_list_scheduled_non_lane_selections_use_serial_weights
test_portable_shard_union_and_coverage_guard
test_portable_parallel_lanes_stay_duration_balanced
test_portable_serial_shards_partition_the_serial_lane
test_portable_serial_hint_coverage_is_reported_and_bounded
test_portable_serial_packing_budget_boundary
test_portable_serial_shard_lane_refusals
test_jobs_requires_proven_isolated
test_jobs_admits_a_concurrent_safe_family
test_unmapped_new_test_never_inherits_family_concurrency
test_changed_shared_fixture_selects_its_readers
test_concurrent_runs_are_ordered_longest_first
test_per_script_timeout_bounds_a_hang
test_changed_bound_gives_slow_watcher_suites_headroom
test_portable_serial_lane_derives_per_script_timeout_from_hints
test_max_wall_ms_is_a_result_not_advice
test_jobs_parallel_scheduler_and_failure_propagation
test_herdr_ci_family_run_has_a_step_timeout
test_aggregate_json
test_check_hint_drift_flags_stale_hint
test_check_hint_drift_ignores_sub_floor_swings
test_fail_fast_stops_after_first_failure
test_fail_fast_jobs_stops_scheduling
test_fail_fast_skips_the_unproven_serial_tail
test_automatic_eight_jobs_preserves_isolation_phases
test_host_load_marker_and_scheduler_throttle
test_changed_default_timeout_scales_with_host_load
test_changed_watch_triage_gets_its_own_scaled_timeout
test_changed_captain_hold_gets_its_own_scaled_timeout
test_token_free_retry_recovers_load_sensitive_failure
test_token_free_retry_covers_exit_124_regardless_of_name
test_token_free_retry_skips_when_a_failure_is_not_load_plausible
test_cleanup_tolerates_read_only_run_dirs
