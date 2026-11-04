# Round 6 live validation — fixture primary-watchdog leak fix

Branch `fm/fm-supervision-host-test-watchdog-leak` at `8756f1c7` (base `92183c12`).
Change: fixture primary-watchdog reaping in `tests/lib.sh`, the run-exit
counterpart in `bin/fm-test-run.sh`, the `tests/fm-supervision-host.test.sh`
teardown/leak assertion, and `tests/fm-test-lib-watchdog-reap.test.sh`.

## Configured command

`bin/fm-test-run.sh --changed --exclude-family real-herdr-gated --pc02-if-idle`
ran to completion on PC02 in this test step: `total=249 failed=2
skipped_gate=31 duration_ms=5165023`. The two failures are the captain-ruled
pre-existing suites `tests/fm-extension-binding.test.sh` and
`tests/fm-public-followup.test.sh`; `fm-extension-binding.test.sh` passes when
run alone on this branch. Every changed/relevant suite in that same run passed:
`fm-test-run`, `fm-watch-arm`, `fm-test-fixture-cleanup`,
`fm-test-lib-watchdog-reap`, and `fm-supervision-host` (548.9s, exit 0, so its
new leak assertion did not fire).

## Scenarios driven live

| Scenario | Result | Evidence |
| --- | --- | --- |
| A real `bin/fm-primary-watchdog.sh run` under a disposable fixture home is detected and reaped; a real loop outside the fixture roots and the operator's fleet loop survive | pass | `r6-real-watchdog-reap.log` |
| The new behavior test passes directly: fixture-root scoping, TERM mid-run, hard-killed-run next-run sweep, KILLed concurrent/serial runner cleanup | pass | `r6-watchdog-reap-direct.log` |
| The same behavior test and fixture-cleanup suite pass through `bin/fm-test-run.sh` | pass | `r6-targeted-runner.log` |
| The configured PC02 run completes the changed supervision-host suite and leaves zero fixture watchdog loops (only the operator loop remains) | pass | `r6-configured-run-summary.log`, `r6-post-configured-process-state.log` |
| A local supervision-host suite cut mid-run by TERM runs its teardown without firing the leak assertion (60 ok, 0 not ok, 0 FAIL) and leaves no fixture watchdog loop | pass | `r6-supervision-host-suite.log` |
| Adversarial scope guard: the configured run's only failures are the captain-ruled ones, and `fm-extension-binding` passes alone | pass | `r6-configured-run-summary.log`, `r6-extension-binding-alone.log` |

## Final state

`r6-final-process-state.log`: no fixture watchdog loop, no validation temp root,
no stale child suite; only the operator fleet loop remains; `git status
--porcelain` is empty.
