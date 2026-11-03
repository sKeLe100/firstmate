# Test-step evidence — fixture primary-watchdog leak fix (a8bb8bae)

Change under validation: `tests/lib.sh` fixture-watchdog reaping
(`fm_test_fixture_watchdog_pids`, `fm_test_reap_fixture_watchdogs`,
`fm_test_reap_stale_fixture_watchdogs`, hooked into `fm_test_cleanup` and the
start-up orphan sweep), the run-exit counterpart in `bin/fm-test-run.sh`
(run-scoped TMPDIR for serial scripts, canonicalised `RUN_TMP`,
`reap_run_fixture_watchdogs` on the EXIT cleanup), the
`tests/fm-supervision-host.test.sh` teardown + leak assertion, and the
regression test `tests/fm-test-lib-watchdog-reap.test.sh`.

## Configured gate command (PC02 offload)

`bin/fm-test-run.sh --changed --exclude-family real-herdr-gated --pc02-if-idle`

* Routed remotely: `fm-pc02-test-offload: claimed PC02 slot 2 of 2`,
  `PC02 idle and ready; running tests remotely on pc02`
  (`configured-run-r3.log`).
* 108 of the 301 selected scripts finished with `exit=0`; `grep -c '^not ok'`
  = 0. Includes the changed `tests/fm-test-run.test.sh` (exit=0, 85.7s),
  `tests/fm-watch-arm.test.sh` (exit=0, 128s) and `tests/fm-lint.test.sh`
  (exit=0, 165s).
* Every non-zero outcome in the selection is a recorded quarantine
  (`owner: sync-preexisting-test-failures`), e.g. `tests/fm-supervision-host.test.sh`
  (signature "a routine outcome a drain could not print must follow on the next
  drain"), `tests/fm-watch-triage.test.sh` (per-script bound). Those entries are
  part of the repo's quarantine table, which this change does not touch.
* Stopped at the step's wall-clock boundary at 108/301 (a 301-script selection
  cannot finish in a 60-minute step; PC02's documented full-selection figure is
  4274s for 183 scripts). Stopping released the PC02 slot and removed the
  remote mirror — no remote `fm-test-run.sh` and no remote
  `fm-primary-watchdog.sh run` remained.

## Targeted, change-specific scenarios (all driven live, PC01)

| Scenario | Command | Result |
| --- | --- | --- |
| Reaping test, direct | `bash tests/fm-test-lib-watchdog-reap.test.sh` | exit 0, 3/3 `ok` (`r3-watchdog-reap-test.log`) |
| Same through the runner | `bin/fm-test-run.sh tests/fm-test-run.test.sh tests/fm-test-lib-watchdog-reap.test.sh` | `total=2 failed=0`, exit 0 (`r3-runner-targeted.log`) |
| Supervision-host teardown via per-script TERM | `timeout --kill-after=30 -s TERM 780 bash tests/fm-supervision-host.test.sh` | 69 `ok`, 0 `not ok`, cut at the 780s bound (exit 124); no watchdog loop survived (`r3-supervision-host.log`) |
| Supervision-host full run | `timeout --kill-after=30 -s TERM 1560 bash tests/fm-supervision-host.test.sh` | exit 0, 75 `ok`, 0 `not ok`, 0 `FAIL` — the new leak assertion did not fire (`r3-supervision-host-full.log`) |
| Fail-before: suite killed past TERM grace, base runner | base 8c7c2efe `bin/fm-test-run.sh --jobs 2 --per-script-timeout-secs 3` | one `fm-primary-watchdog.sh run` loop (pid 4048848) survived the runner's exit (`r3-fail-before-base-runner.log`) |
| Pass-after: identical scenario, fixed runner | `bin/fm-test-run.sh --jobs 2 --per-script-timeout-secs 3` | no loop survived (`r3-pass-after-fixed-runner.log`) |
| Serial path (no `--jobs`) | `bin/fm-test-run.sh --per-script-timeout-secs 3` | fixture root landed at `<run root>/s0/tmp/...` and no loop survived (`r3-serial-path.log`) |
| Post-run process state | `pgrep -af 'fm-primary-watchdog.sh run'` | only the operator loop `133690` (`FM_HOME=~/firstmate`); zero fixture loops on PC01, zero on PC02 (`r3-final-process-state.log`) |

## Cleanup

Base-commit repro lab, fixture roots and the run root created by these checks
were removed; the worktree is clean (`git status --porcelain` empty). Two older
`/var/tmp/nm-daemon-tmp/fm-supervision-host.*` roots from earlier sessions and
five stale PC02 `~/.fm-pc02-test-offload/run-*` mirrors predate this turn and
were left untouched.

## Note

The TERM stop of the configured run used a pattern broad enough to also match a
concurrently running `setsid timeout --kill-after=10 7200 env
FM_TEST_RUN_AUTO_JOBS_MAX=8 bin/fm-test-run.sh --changed ...` process belonging
to another session on this host; that collateral process died and its suite may
have reported a failure. It is not part of this change or of this worktree.
