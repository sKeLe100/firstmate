# Self-hosted runner fleet (reference notes)

Linux CI jobs run on the self-hosted runner fleet (see the `runs-on` routing in
`.github/workflows/ci.yml`): stateful/one-at-a-time lanes on
`[self-hosted, fm-exclusive]`, the parallel-safe bulk on
`[self-hosted, fm-parallel]`, and light lanes only on `[self-hosted, fm-pc02]`.
This file preserves what was learned while trialing and then rolling out
self-hosted runners for Linux CI jobs; the gotchas below apply to every
self-hosted lane.

## What is registered

Four self-hosted GitHub Actions runners are registered for this repo, each
running as an unprivileged local user with no passwordless `sudo`:

- `seansminipc` - labels `[self-hosted, Linux, X64, seansminipc, fm-parallel]`
- `seansminipc-2` - labels `[self-hosted, Linux, X64, fm-exclusive]`
- `seansminipc-3` - labels `[self-hosted, Linux, X64, fm-parallel]`
- `seansdesktop-pc02` - labels `[self-hosted, Linux, X64, fm-parallel, fm-pc02]`

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
- **Only one runner was registered during the initial trial**, so jobs queued
  on it ran strictly serially rather than in the hosted matrix's real
  parallelism - a full CI pass took hours instead of minutes. The `fm-parallel`
  and `fm-exclusive` labels above now span multiple runners so parallel-safe
  lanes can run concurrently again.

## Adding a new job to the self-hosted fleet

1. Pick the label matching the job's shape: `fm-exclusive` for a stateful,
   one-at-a-time lane, `fm-parallel` for parallel-safe bulk, or `fm-pc02` for a
   light lane only (never a large/slow test shard - see `.github/workflows/ci.yml`).
2. Set that job's `runs-on: [self-hosted, <label>]`.
3. Audit the job for every point above: PATH assumptions, absolute paths,
   `sudo` usage, and any state the job leaves in `$RUNNER_TEMP`/`$HOME` that
   must be scoped per-run and torn down on `if: always()`.
4. Gate the job to same-repo PRs
   (`github.event.pull_request.head.repo.full_name == github.repository`), as
   every job in `.github/workflows/ci.yml` already does: a self-hosted job
   runs on real hardware under a real user account, so fork PR code must
   never execute here.
