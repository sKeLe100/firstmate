# Round 5 live validation — fixture primary-watchdog leak fix

Branch `fm/fm-supervision-host-test-watchdog-leak` at `8756f1c7` (base `92183c12`).
Change under validation: fixture primary-watchdog reaping in `tests/lib.sh`
(`fm_test_fixture_watchdog_pids`, `fm_test_reap_fixture_watchdogs`, the marked
runner-root stale sweep `fm_test_run_roots` / `fm_test_fixture_markers` /
`fm_test_reap_stale_fixture_watchdogs`, wired into `fm_test_cleanup` and the
start-up orphan sweep), the run-exit counterpart in `bin/fm-test-run.sh`
(run-scoped serial TMPDIR, canonicalised and marked `RUN_TMP`,
`FM_TEST_RUN_ROOT` export, `reap_run_fixture_watchdogs` on EXIT cleanup), the
`tests/fm-supervision-host.test.sh` teardown that stops each home's
`state/.primary-watchdog.pid` and asserts no fixture loop survives, and the
behavior test `tests/fm-test-lib-watchdog-reap.test.sh`.

## Scenarios driven live

| Scenario | Result | Evidence |
| --- | --- | --- |
| Behavior test driven directly: fixture loop found/stopped by FM_HOME fixture scope, outside loop spared, TERM mid-run leaves none, hard-killed runner's loop + fixture root swept by the next runner-launched run, KILLed concurrent and serial runner runs reaped | pass | `r5-reaper-behavior.log` (4/4 ok, exit 0) |
| Same behavior driven through the configured `bin/fm-test-run.sh`, together with `tests/fm-test-fixture-cleanup.test.sh` and `tests/fm-test-run.test.sh` | pass | `r5-targeted-runner.log` (total=3 failed=0) |
| A real `bin/fm-primary-watchdog.sh run` loop under a disposable fixture home is detected and stopped by `fm_test_reap_fixture_watchdogs`, while a real loop outside every fixture root and the operator's real loop keep running | pass | `r5-real-watchdog-reap.log` |
| Incident shape reproduced: with `TMUX_PANE` set (as under the tmux-hosted full run), `tests/fm-supervision-host.test.sh` armed a real fixture primary-watchdog (`.../hook-successor-closed-before-return`), and after the suite was cut by TERM its teardown left zero fixture watchdog loops and zero fixture roots | pass | `r5-supervision-host-teardown.log`, `r5-supervision-host-direct.log` (22 ok before the cut) |
| `tests/fm-supervision-host.test.sh` launched through the runner with a per-script bound: the run was terminated and the runner's exit cleanup left no fixture watchdog loop and no run root | pass | `r5-supervision-host-bounded-runner.log` |

The bounded runner run stopped at a pre-existing load-sensitive hook wait
("closed successor: the Stop hook did not finish") while the host was at
load ~21-27; that same wait passes in the direct run and was already recorded
as an ignored, pre-existing flake. No fixture loop or run root survived it.

## Configured command

`bin/fm-test-run.sh --changed --exclude-family real-herdr-gated --pc02-if-idle`
selects ~301 scripts (roughly 176 minutes of serial work) and cannot finish
inside the 60-minute test step. Earlier rounds recorded 108/301 scripts clean
at the cut, and that run was stopped deliberately; this round used targeted
suites covering every changed file instead (see table).

## Final state

`r5-final-process-state.log`: no validation-owned watchdog loop or temp dir
remains, the operator loop (pid 133690) is alive, `git status --porcelain` is
empty. No source or test files were modified by validation.
