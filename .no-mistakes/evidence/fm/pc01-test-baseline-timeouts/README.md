# Test evidence: split of tests/fm-captain-hold-lifecycle.test.sh

Change: d8bbc142 `test(captain-hold): split the lifecycle suite into three themed suites`
Base: 64a3181d

## What was driven

1. `captain-hold-changed-bounded.{log,json}` - the real gate path. In a disposable
   clone whose only change touched the three split suites,
   `bin/fm-test-run.sh --changed --base HEAD~1` ran with the gate's changed-mode
   per-script bounds (`per_script_timeout_secs=1500 captain_hold_timeout_secs=1500`)
   and auto concurrency (`jobs=4`). All three passed:
   lifecycle 704,769 ms, reconcile 531,864 ms, merge-teardown 528,095 ms; whole
   run 11m58s. None came near the 1500 s bound that the former single file exceeded.
2. `captain-hold-suites.{log,json}` - the three suites named directly, run
   concurrently (jobs=4) under real host contention (load5 9-16, another full
   `--changed` gate run in flight): lifecycle 1,065,897 ms, reconcile 682,511 ms,
   merge-teardown 675,501 ms, all exit 0. Total wall 17m56s.
3. `captain-hold-case-traces.tsv` - per-case traces proving the split preserved
   every case: 29 + 15 + 19 = 63 cases, exactly the case set of the former single
   file, every case ended rc=0. 7 of the 63 are the pre-existing "skipped on
   markdown-only tasks-axi" notes because `bd` is not installed on this host
   (same as on the base commit).
4. Shared harness selection: in a disposable clone with a change only in
   `tests/fm-captain-hold-lib.sh`, `bin/fm-test-run.sh --list --changed --base HEAD~1`
   selected exactly the three suites.
5. `captain-hold-bound-scope.log` - adversarial bound-scope check. With a fixture
   runner whose default bound was 1 s and whose captain-hold bound stayed 1500 s,
   three 6 s fake captain-hold suites all survived (exit 0) while a lookalike
   `tests/fm-captain-window.test.sh` was terminated at the 1 s bound (exit 124),
   so the widened `fm-captain-hold-*.test.sh` match covers every split suite and
   does not leak to other scripts.
6. `lint-and-runner-suites.log` - `tests/fm-lint.test.sh` (the other script the
   intent names) 259,017 ms exit 0; `tests/fm-test-run.test.sh` 230,280 ms exit 0;
   `tests/fm-test-isolation-proof.test.sh` 7,435 ms exit 0;
   `tests/fm-lint-test-size.test.sh` 4,008 ms exit 0.
7. CI partition: `bin/fm-test-run.sh --check-coverage` reports
   `ok total=318 ... serial=279 serial_shards=10 serial_max_ms=1198033
   serial_budget_ms=1200000`, and all three suites are scheduled in
   `portable-serial-*`. `bin/fm-lint-test-size.sh --root .` reports
   `sizes ok (16 allowlisted)`, i.e. the retired allowlist entry is gone and the
   three new files are under the ceilings.

## Notes

- The `captain-hold-bound-scope` scenario's `--json` artifact could not be
  written: `retry_purge_record` in `bin/fm-test-run.sh` rewrites record rows with
  6 fields instead of 7, so a retried failure breaks JSON finalization. That is
  pre-existing (identical at the base commit) and unrelated to this change; the
  run log is the evidence for that scenario.
- Head's largest portable-serial shard packs 1,198,033 ms against the
  1,200,000 ms guard target (base: 1,163,663 ms), so the guard still passes with
  only ~2 s of headroom.
