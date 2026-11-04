# Live validation harness for `bin/fm-test-compute.sh`

`drive.sh` copies `bin/fm-test-compute.sh` unmodified out of the run worktree
into a throwaway git repository in `$TMPDIR`, then puts local `gh-axi` and
`glab` stand-ins on `PATH`. Those stand-ins serve synthetic GitHub Actions and
GitLab API responses (dispatch, run discovery, monitoring, cancellation,
pipelines, jobs, artifact zips), so the real router is driven end to end
without contacting any hosted service or touching real fleet state.

Each run writes `<NN>-<scenario>.log` with the command, exit code, stdout,
stderr, every hosted API call made, and the pass/fail checks. The emulator lab
directory is removed at exit; only the transcripts are kept.

Run it with `bash drive.sh` (defaults to the gate worktree at
`{run-worktree}`;
override with `WORKTREE=<path>`).

`10-repo-test-suite.log` is the change's own focused suite
(`bash tests/fm-test-compute.test.sh`) run from the worktree.
`11-contract-vs-driven-behavior.md` maps the public contract to the transcript
that exercised it.
