# Hosted Test compute round trip — verification

## Driven now through the pinned Test caller

Command (the configured no-mistakes Test baseline):

```
bin/fm-test-run.sh --changed --exclude-family real-herdr-gated --pc02-if-idle
```

It routed through `bin/fm-test-compute.sh test --changed --exclude-family real-herdr-gated`
and dispatched a real GitHub Actions workflow:

- caller stderr: `fm-test-compute: https://github.com/sKeLe100/firstmate/actions/runs/41762815174 (in_progress)`
- caller stdout: `receipts: verified` / `head: 6a069b09bfc5a386d50e2af61ba27bddac3819ca` / `result: success`
- exit status: 0
- hosted job: `Compute portable-serial-9of11`, runner `GitHub Actions 1000010362`, conclusion success
- returned receipt `result.json`: sha `6a069b09bfc5a386d50e2af61ba27bddac3819ca`, partition `portable-serial-9of11`, scripts `["tests/fm-documentation-audiences.test.sh"]`, exit 0
- streamed stdout contains the hosted runner's own `FM_TEST_ENV_RECORD` (`os=Linux kernel=7.0.0-1017-azure`, `~/...`), showing the downloaded hosted log reached the Test step.

## Documented citation checked against GitHub

`docs/configuration.md` cites `https://github.com/sKeLe100/firstmate/actions/runs/41759393085`
as the verified hosted round trip on 2026-11-04 UTC. Fetched from GitHub:

- run 41759393085: `workflow_dispatch`, status completed, conclusion success, created 2026-11-04T02:14:10Z
- job: `Compute portable-serial-2of11`, runner `GitHub Actions 1000010358`, conclusion success
- downloaded receipt `result.json`: sha `c49a3912243eaad9e5857fe9734e8d1b75bb0cab`, partition `portable-serial-2of11`,
  scripts `["tests/fm-agentsmd-size.test.sh"]`, exit 0
- its `run.log` shows a real hosted environment (`~/...`, Linux azure kernel), not a local fallback.

The citation is a genuine hosted execution with a matching partition receipt, and the claim's
scope ("one portable partition") matches the single dispatched job.
