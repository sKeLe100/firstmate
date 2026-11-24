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
test_changed_remote_inheritance_selects_generation_contract() {
  local tmp repo listed source
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-inheritance.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf '#!/usr/bin/env bash\n' >"$repo/tests/fm-remote-inherit-generation.test.sh"
  chmod +x "$repo/tests/fm-remote-inherit-generation.test.sh"
  for source in fm-remote-inherit-push.sh fm-remote-inherit.sh fm-secondmate-nudge-lib.sh; do
    : >"$repo/bin/$source"
  done
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm inheritance-fixture
  for source in fm-remote-inherit-push.sh fm-remote-inherit.sh fm-secondmate-nudge-lib.sh; do
    printf '\n' >>"$repo/bin/$source"
    listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
    assert_contains "$listed" "tests/fm-remote-inherit-generation.test.sh" \
      "$source change must select the generation regression"
    assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" \
      "$source change must retain secondmate coverage"
    assert_not_contains "$listed" "tests/fm-ask-user-authority.test.sh" \
      "$source change must not select the whole pure-contract-unit family"
    git -C "$repo" checkout -q -- "bin/$source"
  done
  rm -rf "$tmp"
  pass "changed inheritance sender, receiver and counter select the focused generation contract"
}

test_tern_family_selection() {
  local listed families
  families=$("$RUNNER" --list-families)
  printf '%s\n' "$families" | grep -qx tern || fail "--list-families must name the tern family"
  listed=$("$RUNNER" --list --family tern)
  assert_contains "$listed" "tests/fm-backend-tern.test.sh" "family tern must select the fake-CLI suite"
  assert_contains "$listed" "tests/fm-backend-tern-smoke.test.sh" "family tern must select the real-binary smoke test"
  assert_not_contains "$listed" "tests/tern-test-safety.sh" "the safety helper is a shared library, not a runnable suite"
  assert_not_contains "$listed" "tests/fm-backend-cmux.test.sh" "family tern must not absorb the cmux suite"
  # The scripts are real members of the portable lanes, so the coverage guard
  # (every tests/*.test.sh belongs to exactly one lane) sees them.
  "$RUNNER" --list-lanes >/dev/null || fail "--list-lanes failed with the tern scripts present"
  pass "fm-test-run: family tern selects the tern suite and smoke test, and the lane coverage guard accepts them"
}

test_portable_serial_packing_budget_boundary() {
  local tmp repo script weight out rc
  tmp=$(fm_test_tmproot fm-test-run-packing-boundary)
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  # Preserve the real inventory and packing policy without executing suites.
  # Give every inventory member a fixture hint so an unmeasured real script
  # cannot take the default weight and join the at-budget shard.
  while IFS= read -r script; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/$script"
  done < <("$RUNNER" --list --all)

  for weight in 1200000 1200001; do
    cp "$RUNNER" "$repo/bin/fm-test-run.sh"
    python3 - "$repo/bin/fm-test-run.sh" "$weight" <<'PY' \
      || fail "could not seed the fixture's measured timing input"
from pathlib import Path
import re, sys
runner = Path(sys.argv[1])
weight = sys.argv[2]
text = runner.read_text()
scripts = sorted(
    f"tests/{path.name}" for path in (runner.parent.parent / "tests").glob("*.test.sh")
)
if "tests/fm-watch-triage.test.sh" not in scripts:
    sys.exit("fixture inventory lost tests/fm-watch-triage.test.sh")
# Longest real serial member stays at the budget boundary; every other script
# gets 1ms so longest-processing-time packing cannot fill that shard.
lines = [
    f"{script} {weight if script == 'tests/fm-watch-triage.test.sh' else '1'}"
    for script in scripts
]
table = "\n".join(lines)
new, n = re.subn(
    r"(portable_serial_weight_hints\(\) \{\n  cat <<'EOF'\n).*?(\nEOF\n)",
    lambda match: match.group(1) + table + match.group(2),
    text,
    count=1,
    flags=re.S,
)
if n != 1:
    sys.exit("serial hint table not found")
runner.write_text(new)
PY
    out=$(bash "$repo/bin/fm-test-run.sh" --check-coverage 2>&1) && rc=0 || rc=$?
    if [ "$weight" -eq 1200000 ]; then
      expect_code 0 "$rc" "packing exactly at the budget must be accepted"
      assert_contains "$out" "FM_TEST_COVERAGE ok" "boundary coverage did not pass"
      assert_contains "$out" "serial_max_ms=1200000" "fixture did not pack exactly at the budget"
      assert_contains "$out" "serial_budget_ms=1200000" "fixture changed the packing budget"
    else
      expect_code 1 "$rc" "packing one millisecond above the budget must be refused"
      assert_contains "$out" "largest portable serial shard packs 1200001ms above the 1200000ms target" \
        "over-budget refusal did not explain the modeled excess"
      assert_not_contains "$out" "FM_TEST_COVERAGE ok" "over-budget packing reported success"
    fi
  done
  pass "serial packing accepts the exact budget and refuses one millisecond above it"
}

test_changed_t3_sources_select_their_readers() {
  local tmp repo listed
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-t3.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  mkdir -p "$repo/bin/backends"
  : >"$repo/bin/backends/t3code.sh"
  : >"$repo/tests/t3-fake-lib.sh"
  printf '#!/usr/bin/env bash\n# tests/lib.sh\n. tests/t3-fake-lib.sh\n' >"$repo/tests/fm-secondmate-restart.test.sh"
  chmod +x "$repo/tests/fm-secondmate-restart.test.sh"
  printf '# bin/backends/t3code.sh\n' >>"$repo/bin/fm-supervisor-target-lib.sh"
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm t3

  printf '\n' >>"$repo/tests/t3-fake-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-secondmate-restart.test.sh" \
    "a changed T3 fake selects the suite that sources it"
  git -C "$repo" checkout -q -- tests/t3-fake-lib.sh

  printf '\n' >>"$repo/bin/backends/t3code.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend.test.sh" \
    "a changed T3 adapter still selects backend-dispatch"
  assert_contains "$listed" "tests/fm-daemon.test.sh" \
    "a changed T3 adapter selects the curated family of a script that consumes it"

  rm -rf "$tmp"
  pass "a changed T3 fake or adapter selects the suites that read it beyond backend-dispatch"
}

test_list_all_exact_suite_coverage
test_family_selection
test_single_script_selection
test_environment_record_is_compact_safe_and_emitted_once
test_changed_file_selection_is_conservative
test_task_marker_refuses_the_primary_checkout
test_changed_runner_surfaces_select_their_family
test_shell_line_ending_policy_selects_runner_contract
test_quarantine_list_change_selects_runner_contract
test_changed_remote_inheritance_selects_generation_contract
test_changed_dependency_selection_and_unmapped_failure
test_changed_opencode_plugin_selects_its_covering_tests
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
test_tern_family_selection
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
test_changed_t3_sources_select_their_readers
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
