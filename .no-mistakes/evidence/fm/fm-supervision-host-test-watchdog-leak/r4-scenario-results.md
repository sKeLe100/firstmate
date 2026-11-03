# Round 4 live validation — fixture primary-watchdog leak fix

Branch: `fm/fm-supervision-host-test-watchdog-leak` at `a8bb8bae` (base `8c7c2efe`).

## What changed

- `tests/lib.sh`: `fm_test_fixture_watchdog_pids` / `fm_test_reap_fixture_watchdogs`
  find live `fm-primary-watchdog.sh run` loops whose exported `FM_HOME` is under
  a fixture root registered by the current run, TERM then KILL them, and run from
  `fm_test_cleanup`; `fm_test_reap_stale_fixture_watchdogs` sweeps loops left by
  an owner that is gone at suite start.
- `bin/fm-test-run.sh`: canonicalizes `RUN_TMP`, runs every script (serial
  included) with a run-scoped `TMPDIR` under `$RUN_TMP`, and reaps fixture
  watchdogs under `$RUN_TMP` in `cleanup_run` so a script KILLed past the TERM
  grace cannot leak its loop.
- `tests/fm-supervision-host.test.sh`: teardown stops the home's
  `state/.primary-watchdog.pid` and asserts no fixture watchdog outlives it.
- `tests/fm-test-lib-watchdog-reap.test.sh`: new behavior test for the scope,
  TERM path, and KILLed concurrent/serial runner paths.

## Scenarios driven

| Scenario | Result | Evidence |
| --- | --- | --- |
| New reaper behavior test: fixture loops reaped, outside loop spared, TERM mid-run, KILLed concurrent and serial runner runs, symlinked TMPDIR | pass | `r4-reaper-behavior.log` |
| Real `bin/fm-primary-watchdog.sh run` under a disposable fixture home is detected and reaped while the operator's real loop survives | pass | `r4-real-watchdog-reap.log` |
| Regression reproduction: base runner leaks the detached loop of a KILLed suite; fixed runner leaves none (serial path, fixture root under run-scoped TMPDIR) | pass | `r4-repro-base-leak-state.log`, `r4-repro-base-runner.log`, `r4-repro-fixed-leak-state.log`, `r4-repro-fixed-runner.log` |
| `tests/fm-supervision-host.test.sh` executes many real arm/watchdog/home fixtures and its teardown leaves zero fixture watchdog loops and no leftover fixture root | pass | `r4-supervision-host-suite.log`, `r4-supervision-host-suite-rerun.log`, `r4-partial-suite-process-state.log` |
| Previous configured-run failure `tests/fm-extension-binding.test.sh` on this branch | pass when run alone (full suite) and pass on the base checkout | `r4-extension-binding-branch-full-rerun.log`, `r4-extension-binding-base-full.log` |

## Notes on the configured `--changed` command

`bin/fm-test-run.sh --changed` selects 301 scripts (every suite that names
`tests/lib.sh`), with a hint table summing to roughly 176 minutes of serial
work; the prior round's evidence (`configured-run-budget.log`) records that it
cannot finish inside the test step's 60-minute budget and was deliberately
stopped. This run therefore used the targeted validation above rather than the
full 301-script selection.

The two full-suite runs both stopped at the same pre-existing, timing-sensitive
test (`test_claude_stop_hook_rewakes_a_present_captain_beside_a_quiet_record`):
its 25-second `wait_until` expired while another agent's full suite saturated
the host (load ~20–29 on 16 cores). The same test passes on its own on this
branch (`r4-hook-quiet-single-test.log`, 22.5s), and the base checkout's suite
fails at a different hook-timing wait under the same load
(`r4-base-supervision-host-suite.log`). The change does not touch that wait or
the code path it exercises; the failure is load-induced and pre-existing.

## Final state

`r4-final-process-state.log`: no live watchdog loop has an `FM_HOME` under a
test-fixture prefix, the operator loop (pid 133690) is alive, all disposable
`/tmp/fm-r4-*` and base/branch checkouts were removed, and the worktree is clean.
