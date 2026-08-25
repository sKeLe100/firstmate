# Local self-hosted runner (reference notes)

CI runs on GitHub-hosted runners today (the repo is public, so hosted minutes
are free). This file preserves what was learned while trialing a self-hosted
runner for Linux CI jobs, in case that direction is revisited.

## What was registered

A self-hosted GitHub Actions runner was registered for this repo:
name `seansminipc`, labels `[self-hosted, linux, x64, seansminipc]`, running
as an unprivileged local user with no passwordless `sudo`.

## Things that broke and why

- **PATH is minimal and host-specific.** The runner service's captured PATH
  did not include `npm`, `jq`, or other tools that ambient interactive
  shells on the host have via `~/.local/bin` or similar. Any workflow step
  that shells out to a tool not already verified on PATH needs either an
  explicit install step or a PATH bootstrap (`echo "$dir" >> "$GITHUB_PATH"`)
  before it runs - do not assume hosted-runner preinstalled tooling.
- **Node's TypeScript support is host-specific.** This host's system Node
  build did not support `node --input-type=module` stripping TypeScript,
  unlike `ubuntu-latest`'s bundled Node. Pin Node explicitly with
  `actions/setup-node` in any job that needs a specific Node capability
  instead of relying on whatever the host happens to have.
- **The runner reuses its `_work` directory and `$HOME` across every job.**
  Nothing resets state between runs the way a fresh hosted VM does. Any job
  that leaves scratch state (config roots, session directories, lock files,
  PID files) needs its own explicit setup/teardown scoped to a unique
  per-run path (e.g. keyed on `run_id`/`run_attempt`), and teardown must
  verify liveness before killing or deleting anything - a stale PID or a
  bare `rm -rf` can hit another job's or the live host's state.
- **No passwordless `sudo`.** Steps must not assume `sudo` is available;
  install tools into user-writable locations (`$RUNNER_TEMP`, `~/.local/bin`)
  instead.
- **Only one runner was registered**, so jobs queued on it ran strictly
  serially rather than in the hosted matrix's real parallelism - a full CI
  pass took hours instead of minutes.

## Re-enabling self-hosted for a job

1. Register a runner with labels including `self-hosted` and `linux`.
2. Set that job's `runs-on: [self-hosted, linux]`.
3. Audit the job for every point above: PATH assumptions, absolute paths,
   `sudo` usage, and any state the job leaves in `$RUNNER_TEMP`/`$HOME` that
   must be scoped per-run and torn down on `if: always()`.
4. Consider fork-PR exposure before enabling on any workflow trigger that
   fork PRs can reach: a self-hosted job runs on real hardware under a real
   user account, so gate it to same-repo PRs
   (`github.event.pull_request.head.repo.full_name == github.repository`)
   unless the repo is private and has no outside collaborators.
