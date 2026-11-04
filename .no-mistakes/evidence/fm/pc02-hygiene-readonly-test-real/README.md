# PC02 offload read-only reap — live test evidence

Change validated: `tests/fm-pc02-test-offload.test.sh`,
`tests/fm-test-fixture-cleanup.test.sh`,
`tests/fm-test-run-scheduling-lib.sh` on branch
`fm/pc02-hygiene-readonly-test-real` (target `c401c01e`).

Host: Linux, uid 1000 (non-root), umask 022, so `chmod 500`/`555` really
denies the owner write and the real `chmod`/`rm -rf` binaries are exercised.

## Scenarios

| # | Scenario | Result | Evidence |
|---|----------|--------|----------|
| 1 | PC02 offload success run reaps a read-only dir (real permissions) | pass | `s1s2-pc02-fixed-full.log` |
| 2 | PC02 offload timeout run reaps a read-only dir and exits 124 | pass | `s1s2-pc02-fixed-full.log` |
| 3 | Both PC02 cases fail if `remove_remote_run` loses `chmod -R u+w` (adversarial) | pass after repair | `final-mutation-nochmod-*.log` |
| 4 | Local runner reaps a read-only run root; fails if `cleanup_run` loses its chmod | pass | `s4s5-local-suites-final.log`, `mutation-nochmod-fm-runner-ro-only.log` |
| 5 | Fixture sweep reaps a read-only package tree; fails if `fm_test_remove_tree` loses its chmod | pass | `s4s5-local-suites-final.log`, `mutation-nochmod-fm-fixture-ro-only.log` |

## What the target commit's PC02 change missed

`c401c01e` moved `chmod 500 "$TMPDIR/ro"` after the file creation, but the
fixture's `$TMPDIR` is the *nested* `fm-test-run.sh` run-scoped TMPDIR
(`$RUN_TMP/sN/tmp`). The nested runner already reaps it with its own
`cleanup_run` (`chmod -R u+w "$RUN_TMP"; rm -rf "$RUN_TMP"`), so deleting the
offload mirror's `chmod -R u+w $run_q` still left both PC02 cases green. The
mutation run `mutation-nochmod-*.log` demonstrated that.

## Repair applied in this test phase

Both PC02 fixtures now also create a read-only dir (`offload-ro`) directly in
the offload mirror's temp root, published by the runner as
`dirname "$FM_TEST_RUN_ROOT"`, i.e. outside the nested runner's own run root.
Only `remove_remote_run`'s real `chmod -R u+w` can reap it. The test also
asserts the published mirror temp root and that `TMPDIR` is under it.

Verification: control (product chmod present) passes
(`final-control-*.log`); removing the offload `chmod -R u+w` fails with
"the run left its mirror behind" / "the timeout left a mirror behind"
(`final-mutation-nochmod-*.log`). Full suite with the repair:
`s1s2-pc02-fixed-full.log`.

## Commands

```
bin/fm-test-run.sh tests/fm-pc02-test-offload.test.sh
bin/fm-test-run.sh tests/fm-test-fixture-cleanup.test.sh tests/fm-test-run.test.sh
```

Adversarial mutation runs used a disposable copy of the repository under a
throwaway `/var/tmp` lab, with one `chmod` removed from the copied product
script/library at a time; the lab was deleted in the same evidence turn.
