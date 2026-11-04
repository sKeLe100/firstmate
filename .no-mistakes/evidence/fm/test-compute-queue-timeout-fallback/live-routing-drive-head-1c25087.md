# Live drive of `bin/fm-test-compute.sh` at HEAD 1c25087a (round 6)
This supersedes the earlier-round transcripts in this directory: those were captured
against a pre-`1c25087a` router whose `--help` still read "Hosted faults fail closed with exit 77".

The product driven here is the real `bin/fm-test-compute.sh` from the run worktree,
byte-identical to HEAD (`cmp` verified in the fixture). It runs inside a throwaway git
repository (copy of HEAD, `origin` = `https://github.com/example/firstmate.git`,
`origin/main` one commit behind a committed fixture change, worktree clean) and talks
real HTTP, real JSON and real artifact ZIPs to a disposable localhost emulator of the
GitHub Actions and GitLab APIs. `gh-axi` and `glab` on `PATH` are thin clients of that
emulator; no hosted service, credential, fleet home or operator checkout was touched.
The local admission tier is the real `bin/fm-pc02-test-offload.sh` (offload disabled) and
the real `bin/fm-lint.sh` changed-file lint, so the fallback result is a genuine lint run.

`harness/` holds the emulator, the two clients and the scenario driver so the drive is
reproducible; `logs-after/` and `logs-before/` hold every transcript, exit code and hosted
request trace.

## Scenarios: after the change (HEAD 1c25087a)

| scenario | expected | observed | verdict |
|---|---|---|---|
| `lint-queue-timeout` | 0 | 0 | pass |
| `lint-queue-timeout-cancel-refused` | 77 | 77 | pass |
| `lint-ambiguous-dispatch` | 0 | 0 | pass |
| `lint-accepted-undiscovered` | 77 | 77 | pass |
| `test-accepted-undiscovered` | 77 | 77 | pass |
| `lint-completed-cancelled-green` | 77 | 77 | pass |
| `lint-gitlab-monitoring-fault` | 77 | 77 | pass |
| `lint-receipt-failure` | 1 | 1 | pass |
| `help` | 0 | 0 | pass |

### lint-queue-timeout — lint mode, hosted run stays queued past the 180s bound (2s here), cancellation confirmed

Expected: falls through GitLab (unauthenticated here) to PC02/PC01 admission and the real changed-file `bin/fm-lint.sh` decides the result: exit 0, no hosted lint verdict.

```
fm-test-compute: https://github.com/example/firstmate/actions/runs/123 (queued)
fm-test-compute: GitHub unavailable; trying GitLab
fm-test-compute: hosted tiers unavailable; falling back to local admission
fm-pc02-test-offload: offload disabled (FM_PC02_OFFLOAD_DISABLE=1); running on PC01
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint.sh: local changed-file mode; ShellCheck source following disabled
fm-lint-workflows.sh: actionlint 1.7.12 (pinned 1.7.12)
fm-lint-workflows.sh: 4 workflow files valid
fm-lint-test-size.sh: tests/*.test.sh sizes ok (16 allowlisted)
fm-lint-nomistakes-config.sh: /tmp/fm-live-compute.zErwAH/repo/.no-mistakes.yaml ok
[exit 0]
```

Hosted calls made (localhost emulator):

```
GET /repos/example/firstmate
GET /repos/example/firstmate/actions/workflows/test-compute.yml
POST /repos/example/firstmate/actions/workflows/test-compute.yml/dispatches
GET /repos/example/firstmate/actions/workflows/test-compute.yml/runs?event=workflow_dispatch&per_page=100
GET /repos/example/firstmate/actions/runs/123
GET /repos/example/firstmate/actions/runs/123
POST /repos/example/firstmate/actions/runs/123/cancel
GET /repos/example/firstmate/actions/runs/123
```

### lint-queue-timeout-cancel-refused — lint mode, queued run past the bound and the cancel request is refused

Expected: exit 77 with a named reason, no local admission, no lint verdict.

```
fm-test-compute: https://github.com/example/firstmate/actions/runs/123 (queued)
fm-test-compute: waiting for owned run cancellation (1/6)
fm-test-compute: waiting for owned run cancellation (2/6)
fm-test-compute: waiting for owned run cancellation (3/6)
fm-test-compute: waiting for owned run cancellation (4/6)
fm-test-compute: waiting for owned run cancellation (5/6)
fm-test-compute: waiting for owned run cancellation (6/6)
fm-test-compute: GitHub run 123 cancellation was not confirmed; failing closed
fm-test-compute: waiting for owned run cancellation (1/6)
fm-test-compute: waiting for owned run cancellation (2/6)
fm-test-compute: waiting for owned run cancellation (3/6)
fm-test-compute: waiting for owned run cancellation (4/6)
fm-test-compute: waiting for owned run cancellation (5/6)
fm-test-compute: waiting for owned run cancellation (6/6)
[exit 77]
```

Hosted calls made (localhost emulator):

```
GET /repos/example/firstmate
GET /repos/example/firstmate/actions/workflows/test-compute.yml
POST /repos/example/firstmate/actions/workflows/test-compute.yml/dispatches
GET /repos/example/firstmate/actions/workflows/test-compute.yml/runs?event=workflow_dispatch&per_page=100
GET /repos/example/firstmate/actions/runs/123
GET /repos/example/firstmate/actions/runs/123
GET /repos/example/firstmate/actions/runs/123
POST /repos/example/firstmate/actions/runs/123/cancel
GET /repos/example/firstmate/actions/runs/123
GET /repos/example/firstmate/actions/runs/123
GET /repos/example/firstmate/actions/runs/123
GET /repos/example/firstmate/actions/runs/123
GET /repos/example/firstmate/actions/runs/123
GET /repos/example/firstmate/actions/runs/123
POST /repos/example/firstmate/actions/runs/123/cancel
GET /repos/example/firstmate/actions/runs/123
GET /repos/example/firstmate/actions/runs/123
GET /repos/example/firstmate/actions/runs/123
GET /repos/example/firstmate/actions/runs/123
GET /repos/example/firstmate/actions/runs/123
GET /repos/example/firstmate/actions/runs/123
```

### lint-ambiguous-dispatch — lint mode (reported incident 2), dispatch POST died mid-flight and no run is listed within the bound

Expected: treated as not started: falls through to PC02/PC01 admission, real local lint returns exit 0, never 'failing closed' with exit 1.

```
fm-test-compute: GitHub dispatch outcome is ambiguous; looking for the run
fm-test-compute: GitHub dispatch outcome stayed ambiguous and no run appeared within 2s; treating as not started
fm-test-compute: GitHub unavailable; trying GitLab
fm-test-compute: hosted tiers unavailable; falling back to local admission
fm-pc02-test-offload: offload disabled (FM_PC02_OFFLOAD_DISABLE=1); running on PC01
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint.sh: local changed-file mode; ShellCheck source following disabled
fm-lint-workflows.sh: actionlint 1.7.12 (pinned 1.7.12)
fm-lint-workflows.sh: 4 workflow files valid
fm-lint-test-size.sh: tests/*.test.sh sizes ok (16 allowlisted)
fm-lint-nomistakes-config.sh: /tmp/fm-live-compute.zErwAH/repo/.no-mistakes.yaml ok
[exit 0]
```

Hosted calls made (localhost emulator):

```
GET /repos/example/firstmate
GET /repos/example/firstmate/actions/workflows/test-compute.yml
POST /repos/example/firstmate/actions/workflows/test-compute.yml/dispatches
GET /repos/example/firstmate/actions/workflows/test-compute.yml/runs?event=workflow_dispatch&per_page=100
GET /repos/example/firstmate/actions/workflows/test-compute.yml/runs?event=workflow_dispatch&per_page=100
```

### lint-accepted-undiscovered — lint mode, dispatch confirmed accepted (ambiguous=0) but no run is ever listed

Expected: exit 77 fail-closed, no GitLab contact, no local admission (anti-duplication guard).

```
fm-test-compute: GitHub dispatch was accepted but no run appeared within 2s; failing closed
[exit 77]
```

Hosted calls made (localhost emulator):

```
GET /repos/example/firstmate
GET /repos/example/firstmate/actions/workflows/test-compute.yml
POST /repos/example/firstmate/actions/workflows/test-compute.yml/dispatches
GET /repos/example/firstmate/actions/workflows/test-compute.yml/runs?event=workflow_dispatch&per_page=100
GET /repos/example/firstmate/actions/workflows/test-compute.yml/runs?event=workflow_dispatch&per_page=100
GET /repos/example/firstmate/actions/workflows/test-compute.yml/runs?event=workflow_dispatch&per_page=100
```

### test-accepted-undiscovered — test mode, same accepted-but-undiscovered dispatch

Expected: exit 77 fail-closed, no local admission (guard holds on the test path too).

```
fm-test-run: FM_TEST_QUARANTINE_EVIDENCE_INCOMPLETE tests/fm-wake-pair-dedup.test.sh
fm-test-run: FM_TEST_QUARANTINE_EVIDENCE_INCOMPLETE tests/fm-backend-herdr.test.sh
fm-test-run: FM_TEST_QUARANTINE_EVIDENCE_INCOMPLETE tests/fm-procevent.test.sh
fm-test-run: FM_TEST_QUARANTINE_EVIDENCE_INCOMPLETE tests/fm-watch-triage.test.sh
fm-test-run: FM_TEST_QUARANTINE_EVIDENCE_INCOMPLETE tests/fm-calm-pi-extension.test.sh
fm-test-run: FM_TEST_QUARANTINE_EVIDENCE_INCOMPLETE tests/fm-wake-queue.test.sh
fm-test-run: FM_TEST_QUARANTINE_EVIDENCE_INCOMPLETE tests/fm-secondmate-harness.test.sh
fm-test-run: FM_TEST_QUARANTINE_EVIDENCE_INCOMPLETE tests/fm-remote-transport-lanes.test.sh
fm-test-run: FM_TEST_QUARANTINE_EVIDENCE_INCOMPLETE tests/fm-composer-codex-idle-live-e2e.test.sh
fm-test-run: FM_TEST_QUARANTINE_EVIDENCE_INCOMPLETE tests/fm-remote-secondmate-lifecycle-e2e.test.sh
fm-test-run: FM_TEST_QUARANTINE_EVIDENCE_INCOMPLETE tests/fm-agy-harness.test.sh
fm-test-run: FM_TEST_QUARANTINE_EVIDENCE_INCOMPLETE tests/fm-extension-binding.test.sh
fm-test-compute: GitHub dispatch was accepted but no run appeared within 2s; failing closed
[exit 77]
```

Hosted calls made (localhost emulator):

```
GET /repos/example/firstmate
GET /repos/example/firstmate/actions/workflows/test-compute.yml
POST /repos/example/firstmate/actions/workflows/test-compute.yml/dispatches
GET /repos/example/firstmate/actions/workflows/test-compute.yml/runs?event=workflow_dispatch&per_page=100
GET /repos/example/firstmate/actions/workflows/test-compute.yml/runs?event=workflow_dispatch&per_page=100
```

### lint-completed-cancelled-green — hosted run completes `cancelled` while every downloaded receipt verifies green

Expected: receipts verify, then exit 77 naming the conclusion; no local fallback, no lint verdict.

```
fm-test-compute: https://github.com/example/firstmate/actions/runs/123 (completed)
receipts: verified
head: ab9fb6195df3599f086c65aecd6e8875a315c9c7
fm-test-compute: GitHub run 123 finished cancelled with verified receipts; failing closed
hosted evidence for lint-1
hosted evidence for lint-2
hosted evidence for lint-3
hosted evidence for lint-4
[exit 77]
```

Hosted calls made (localhost emulator):

```
GET /repos/example/firstmate
GET /repos/example/firstmate/actions/workflows/test-compute.yml
POST /repos/example/firstmate/actions/workflows/test-compute.yml/dispatches
GET /repos/example/firstmate/actions/workflows/test-compute.yml/runs?event=workflow_dispatch&per_page=100
GET /repos/example/firstmate/actions/runs/123
GET /repos/example/firstmate/actions/runs/123/artifacts
```

### lint-gitlab-monitoring-fault — lint mode, queue-timeout fallback reaches GitLab and the pipeline status read then fails (reported incident 1 path)

Expected: exit 77 naming the GitLab fault, no local admission, so the gate cannot report a lint failure.

```
fm-test-compute: https://github.com/example/firstmate/actions/runs/123 (queued)
fm-test-compute: GitHub unavailable; trying GitLab
fm-test-compute: GitLab pipeline 456 in sean.morden1993/firstmate-ci
glab: HTTP 500 Internal Server Error
Traceback (most recent call last):
  File "<string>", line 1, in <module>
    import json,sys; print(json.load(sys.stdin)["status"])
                           ~~~~~~~~~^^^^^^^^^^^
  File "/usr/lib/python3.14/json/__init__.py", line 298, in load
    return loads(fp.read(),
        cls=cls, object_hook=object_hook,
        parse_float=parse_float, parse_int=parse_int,
        parse_constant=parse_constant, object_pairs_hook=object_pairs_hook, **kw)
  File "/usr/lib/python3.14/json/__init__.py", line 352, in loads
    return _default_decoder.decode(s)
           ~~~~~~~~~~~~~~~~~~~~~~~^^^
  File "/usr/lib/python3.14/json/decoder.py", line 345, in decode
    obj, end = self.raw_decode(s, idx=_w(s, 0).end())
               ~~~~~~~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^
  File "/usr/lib/python3.14/json/decoder.py", line 363, in raw_decode
    raise JSONDecodeError("Expecting value", s, err.value) from None
json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)
fm-test-compute: GitLab pipeline 456 status unavailable; failing closed
[exit 77]
```

Hosted calls made (localhost emulator):

```
GET /repos/example/firstmate
GET /repos/example/firstmate/actions/workflows/test-compute.yml
POST /repos/example/firstmate/actions/workflows/test-compute.yml/dispatches
GET /repos/example/firstmate/actions/workflows/test-compute.yml/runs?event=workflow_dispatch&per_page=100
GET /repos/example/firstmate/actions/runs/123
GET /repos/example/firstmate/actions/runs/123
GET /repos/example/firstmate/actions/runs/123
POST /repos/example/firstmate/actions/runs/123/cancel
GET /repos/example/firstmate/actions/runs/123
GET /api/v4/projects/sean.morden1993%2Ffirstmate-ci
GET /api/v4/projects/sean.morden1993%2Ffirstmate-ci/repository/branches/firstmate-compute
POST /api/v4/projects/sean.morden1993%2Ffirstmate-ci/pipeline
GET /api/v4/projects/sean.morden1993%2Ffirstmate-ci/pipelines/456
POST /api/v4/projects/sean.morden1993%2Ffirstmate-ci/pipelines/456/cancel
```

### lint-receipt-failure — a hosted lint receipt that actually fails

Expected: stays a terminal verdict: exit 1, failing partition streamed, no local rerun.

```
fm-test-compute: https://github.com/example/firstmate/actions/runs/123 (completed)
Hosted partition failed: lint-1
hosted evidence for lint-1
hosted evidence for lint-2
hosted evidence for lint-3
hosted evidence for lint-4
[exit 1]
```

Hosted calls made (localhost emulator):

```
GET /repos/example/firstmate
GET /repos/example/firstmate/actions/workflows/test-compute.yml
POST /repos/example/firstmate/actions/workflows/test-compute.yml/dispatches
GET /repos/example/firstmate/actions/workflows/test-compute.yml/runs?event=workflow_dispatch&per_page=100
GET /repos/example/firstmate/actions/runs/123
GET /repos/example/firstmate/actions/runs/123/artifacts
```

### help — `bin/fm-test-compute.sh --help`

Expected: the CLI serves the exit contract this run observed.

```
fm-test-compute.sh - hosted Test/lint routing, then existing PC02/PC01 fallback.

Usage:
  fm-test-compute.sh test --changed --exclude-family real-herdr-gated [--exclude-quarantined]
  fm-test-compute.sh lint
  fm-test-compute.sh local-lint                   (PC02/local worker only)
  fm-test-compute.sh restore <payload-file>       (hosted worker only)
  fm-test-compute.sh worker <partition> <output-dir> <payload-file>
  fm-test-compute.sh --help

The pinned no-mistakes Test command enters through --pc02-if-idle.
Only that exact baseline, with or without the canonical --exclude-quarantined
selection filter, is distributed; other arguments (including --json,
inspection and custom selection) retain the existing PC02/local behavior.
The baseline selection is split into hosted-capable and local-only scripts;
no tests are omitted. The hosted subset is partitioned by the lanes reported
by fm-test-run.sh --list-lanes, only non-empty partitions are dispatched, and
an exact partition check gates dispatch. `test` dispatches portable test
partitions only; `lint` runs the four canonical lint partitions alone on
hosted compute or PC02, while PC01's last-resort lint is the changed-file
subset.

GitHub Actions standard ubuntu-latest is tried first, then GitLab.com on a
dedicated project, only after `glab auth status` succeeds, then PC02/PC01.
This first delivery accepts only public firstmate repositories on github.com;
private repositories and other projects use the existing local path, never a
public relay or mirror. No paid runner label or quota purchase is requested.

A clean committed HEAD travels as a git bundle over the dispatch inputs,
without publishing a GitHub ref. The payload is capped at 60000 bytes (below
GitHub's 65535-character input limit); dirty/large/unsupported snapshots fall
back before dispatch. The bundle requires the locally known origin/main base
to be fetchable from the source repository. The workflow must first land on
the source default branch; before that, dispatch automatically falls back.

GitLab uses an existing dedicated project (default below), bootstrapping its
empty repository with the public CI template on firstmate-compute. An existing
project must have that dedicated branch installed; other branches are preserved.
It never creates projects
or accounts. Pipeline variables carry the same bounded public-source snapshot.
No token is read, printed or saved by this script; glab owns authentication.

Three scripts depend on local host facilities that the hosted runners do not
provide: tests/fm-devin-harness.test.sh (jq/config-writer),
tests/fm-calm-pi-extension.test.sh (ANSI yellow), and
tests/fm-captain-hold-lifecycle.test.sh (request retirement). They are removed
from the hosted payload and run through the existing PC02/PC01 admission path
after the hosted subset succeeds; every other selected script keeps the
GitHub then GitLab order. A local-only failure fails the routed run too.

Result receipts bind every hosted partition to HEAD and the exact selected
scripts. A test/lint failure is terminal, never grounds for a greener local
rerun. Indeterminate infrastructure and monitoring faults fail closed with
exit 77 so a gate can tell infrastructure from a test or lint verdict.
Unavailable tiers fall through to local admission instead: GitHub workflow
state, startup failure, or dispatch rejection; a GitHub ambiguous POST whose
run never appears within the queue bound (treated as not started, so it may
race a later tier); GitLab authentication, project reads, dispatch rejection,
quota rejection, or missing receipts; and a cancellation confirmed after a
queue timeout or a GitLab execution timeout. An accepted GitHub dispatch
that stays undiscovered fails closed rather than being duplicated.
Every API call is bounded. Interrupts cancel only this invocation's run.
stdout forwards suite evidence; routing diagnostics go to stderr.

Environment:
  FM_TEST_COMPUTE_DISABLE=1   bypass hosted tiers (also in hosted workers)
GitHub/GitLab CI environments bypass automatically; generic CI=true does not
disable routing because no-mistakes may use it for its pre-push commands.
  FM_TEST_COMPUTE_QUEUE_SECS  pending admission bound (default 180)
  FM_TEST_COMPUTE_RUN_SECS    execution/monitor bound (default 10800)
  FM_TEST_COMPUTE_POLL_SECS   foreground poll cadence (default 10)
  FM_TEST_COMPUTE_API_SECS    per API request bound (default 30)
  FM_TEST_COMPUTE_GITLAB_PROJECT existing dedicated GitLab project
                             (default sean.morden1993/firstmate-ci)
Exit: 0 proven success; 1 failed hosted evidence or a failed hosted receipt;
2 usage error; 77 indeterminate hosted outcome that is never a test or lint
verdict (GitHub discovery, monitoring, receipt, and undiscovered-dispatch
faults; GitLab bootstrap, pipeline-response, monitoring, and artifact
faults; or a dispatched run that may still be executing).
Unavailable hosted tiers fall through to PC02/PC01 admission:
Test and remote lint return the executed command's status, while PC01's
last-resort lint returns bin/fm-lint.sh's changed-file status.
[exit 0]
```

## Same scenarios replayed against the pre-change router (30853b7)

For a regression oracle, the identical driver ran against a second fixture identical to the
first except `bin/fm-test-compute.sh` is the base-commit revision. Nothing else about the
scenario changes, so a row that flips between the two tables isolates this change.

| scenario | expected | observed (before) | verdict |
|---|---|---|---|
| `lint-queue-timeout` | 0 | 0 | pass |
| `lint-queue-timeout-cancel-refused` | 77 | 1 | fail |
| `lint-ambiguous-dispatch` | 0 | 1 | fail |
| `lint-accepted-undiscovered` | 77 | 1 | fail |
| `test-accepted-undiscovered` | 77 | 1 | fail |
| `lint-completed-cancelled-green` | 77 | 1 | fail |
| `lint-gitlab-monitoring-fault` | 77 | 1 | fail |
| `lint-receipt-failure` | 1 | 1 | pass |
| `help` | 0 | 0 | fail |

Two incident reproductions, before the change:

```
# reported incident 2 (2026-11-04 09:40Z) -- ambiguous lint dispatch refused to fall back
$ bin/fm-test-compute.sh lint        # pre-change router
fm-test-compute: GitHub dispatch outcome is ambiguous; failing closed
[exit 1]

# reported incident 1 path -- queued lint run, cancellation never confirmed
$ bin/fm-test-compute.sh lint        # pre-change router
fm-test-compute: https://github.com/example/firstmate/actions/runs/123 (queued)
fm-test-compute: waiting for owned run cancellation (1/6)
fm-test-compute: waiting for owned run cancellation (2/6)
fm-test-compute: waiting for owned run cancellation (3/6)
fm-test-compute: waiting for owned run cancellation (4/6)
fm-test-compute: waiting for owned run cancellation (5/6)
fm-test-compute: waiting for owned run cancellation (6/6)
fm-test-compute: GitHub run 123 cancellation was not confirmed; failing closed
fm-test-compute: waiting for owned run cancellation (1/6)
fm-test-compute: waiting for owned run cancellation (2/6)
fm-test-compute: waiting for owned run cancellation (3/6)
fm-test-compute: waiting for owned run cancellation (4/6)
fm-test-compute: waiting for owned run cancellation (5/6)
fm-test-compute: waiting for owned run cancellation (6/6)
[exit 1]
```

Both are now 0 (falls back, local lint decides) and 77 (indeterminate, no lint verdict)
respectively; see `logs-after/`. A hosted receipt that really fails still exits 1 on both
revisions (`lint-receipt-failure`), so the change did not turn verdicts into infrastructure
faults.

## Focused suite

`bash tests/fm-test-compute.test.sh` (the change's own suite, mock-level) passes:
see `tests-fm-test-compute-suite.log`. The configured baseline
`bin/fm-test-run.sh --changed --exclude-family real-herdr-gated --exclude-quarantined --pc02-if-idle`
already ran green for this change.
