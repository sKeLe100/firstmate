#!/usr/bin/env bash
# fm-pc02-test-offload.sh - single owner of routing a heavy fm-test-run.sh or
# fm-lint.sh invocation to PC02 unless the captain's personal-use switch says
# otherwise. PC02 is sized to serve a model and run the test slots together
# (16 threads, ~22 GiB free, six slots; a Qwen lane uses the GPU plus CPU MoE
# offload), so a live PC02 model worker is NOT test-offload occupancy: it never
# blocks or pushes a test run back to PC01. The per-slot locks decide admission
# and a run waits for a free slot under one bound; it falls back to PC01 only
# when PC02 is personally in use, unreachable, unready, the transfer fails, or
# that bound expires.
#
# Why: on PC01 the no-mistakes test step (bin/fm-test-run.sh --changed
# --exclude-family real-herdr-gated --exclude-quarantined) can outrun the
# test-agent deadline under host load, and the canonical lint step's exhaustive
# ShellCheck audit is equally load-sensitive. PC02 has stronger hardware and,
# when the captain is not using it personally (gaming, etc.), has room for both
# a model and the six test slots.
# fm-test-run.sh's --pc02-if-idle flag tries hosted compute first, then
# reaches this script through fm-test-compute.sh; this script decides
# local vs remote and, for remote, owns the transfer and execution mechanics
# for tests and canonical lint.
#
# Reused rather than reinvented:
#   - ssh access ("ssh pc02" lands in PC02's WSL) is the path documented in
#     docs/pc02-outage-runbook.md.
#   - git-dir/git-common-dir resolution is fm-primary-scope-lib.sh's
#     fm_resolve_git_path, needed because this script's own worktree is
#     typically a linked git worktree (bin/fm-spawn.sh's isolated task
#     worktree), whose ".git" is a pointer file rather than the real store.
#
# Personal-use routing (captain-authorized 2026-09-24, "There will need to be
# a check or switch in place for when PC02 is being used for personal use or
# not"; restated 2026-11-04, "PC02 should be saturated with test work and PC01
# relieved"): the captain's manual switch is the only thing that stops PC02
# testing. It is a flag file in PC02's own home directory
# (bin/fm-pc02-personal-use.sh owns the PC01-side on/off/status toggle;
# docs/pc02-outage-runbook.md documents the captain's no-terminal Windows
# desktop toggle that writes the same file); when it is on, the run routes to
# PC01 at once and logs the reason. A live PC02 model worker and a loaded
# llama-swap do not count: they share the host with the test slots rather than
# holding them, and the slot locks below are the only occupancy signal.
#
# The switch also stops a run that is already under way. While the run waits
# for a slot and while its remote suite executes, it watches the same flag on
# PC02; when the flag appears it ends only the process session it started,
# releases its slot, removes its mirror, and reports `stopped: personal use`
# with exit 77 (no verdict) rather than a test failure. Non-test processes are
# never signalled.
#
# Every readiness check is local or one bounded ssh call; a stuck or slow
# probe times out and this script falls back to running locally rather than
# hanging waiting on PC02. Once a check has committed to a remote run it
# never also runs the selected command again locally (the two would double
# whatever time budget the caller enforces, such as the no-mistakes test-agent
# deadline); the remote execution itself is still bounded
# (FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS, enforced by `timeout` on PC02 itself so
# the remote command's session is killed there rather than orphaned
# behind a dropped ssh client), and a run that hits this bound is reported
# as a failure rather than silently doubling the budget with a second local
# run. An orphaned background process a test leaves running can otherwise
# hold the ssh channel open long after fm-test-run.sh itself has finished on
# PC02 - observed empirically running this repo's own full --changed suite
# through this script, not a hypothetical - so as soon as fm-test-run.sh
# exits there, the rest of its session is killed and its own exit code
# is returned. The per-run PC02 mirror - including the runner's own TMPDIR,
# which is placed inside that mirror - and any of its processes still running
# are removed on every exit path, including an interrupt and the run timeout;
# read-only directories test fixtures leave behind are made owner-writable
# first. This is why an offloaded suite cannot leak /tmp/fm-test-run.* into
# PC02's tmpfs.
#
# Remote run conditions (always applied to an offloaded run, test or lint):
#   - Parallel, per-script bounded: an explicit caller --jobs is capped to
#     floor(threads / slots) workers per slot, where threads comes from PC02's
#     own nproc (getconf _NPROCESSORS_ONLN fallback), so concurrent slots
#     together cannot exceed PC02's thread count; a caller asking for less
#     keeps its value. Absent --jobs, the remote fm-test-run.sh keeps its own
#     automatic scheduler (only proven-isolated scripts and recorded
#     concurrent family proofs run in parallel; unproven scripts stay serial)
#     with its worker ceiling set to min(FM_PC02_OFFLOAD_JOBS (default 8),
#     the per-slot bound), so the auto path keeps the invariant; an explicitly
#     set FM_PC02_OFFLOAD_JOBS is an operator override honoured verbatim and
#     may oversubscribe by choice.
#     Isolation phases, family caps and serial tails remain enforced; curated
#     lanes keep their contracts. The per-script cap defaults to 3000s
#     (FM_PC02_OFFLOAD_SCRIPT_TIMEOUT_SECS) and overrides the caller's
#     per-script timeout. The whole run defaults to 7200s
#     (FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS); exceeding it exits 124 rather than
#     rerunning locally. Lint mode keeps bin/fm-lint.sh's own worker count and
#     partition selection untouched, but runs the canonical partitions
#     concurrently so an idle PC02 finishes them in about one partition's
#     time: at most min(configured slots, floor(threads / 2)) partitions at
#     once, the second term keeping each partition's two default ShellCheck
#     workers inside PC02's thread count. Each partition writes its own log,
#     and the aggregate exit status keeps the serial semantics (any failing
#     partition fails the run, and every partition still runs); the whole-run
#     bound applies to it too.
#   - Pre-claim capacity: before any slot is claimed, the run reads PC02's
#     MemAvailable, TMP_ROOT (/tmp) free space and home-disk free space fresh.
#     A reading under its floor routes the run local and names the resource, the
#     observed value and the floor; an unreadable reading is treated as unclear
#     and routes local too, never as free. The gate only reads: this run never
#     removes another run's root. bin/fm-pc02-hygiene-lib.sh owns the readings,
#     the floors and the read-only stale-root inventory that
#     bin/fm-pc02-hygiene.sh reports.
#   - Host slots: the one slot count is PC02's own
#     ${XDG_CONFIG_HOME:-$HOME/.config}/firstmate/pc02-offload-slots file (one
#     integer from 1 to 16; a trailing newline is optional). The claim reads it
#     on PC02, fresh on every run, so a changed count applies to the next Test
#     or Lint step without restarting the no-mistakes daemon; PC01's own
#     settings never supply it. A missing, unreadable or malformed file is a
#     configuration error that exits 2. Nonblocking flocks on PC02's
#     ~/.fm-pc02-test-slot-<n>.lock, one per concurrent test suite or lint
#     run, cover transfer and execution. A run takes the first free slot.
#     With every slot held it keeps polling while printing that it is
#     waiting. The slot wait draws on one FM_PC02_OFFLOAD_SLOT_WAIT_SECS
#     bound (default 600, ten minutes), after which the run routes local;
#     FM_PC02_OFFLOAD_SLOT_WAIT_SECS=0 restores the immediate local fallback,
#     and a forwarded --max-wall-ms budget also zeroes the wait because that
#     wall clock belongs to the run itself. An unclear claim routes local at
#     once. PC02 being unreachable, personally in use, or missing a tool still
#     routes local before any wait begins; an environment-parity mismatch
#     routes local as soon as it is compared. The files are never unlinked: a
#     dead owner's kernel lock is released automatically, so a leftover file
#     or process name is harmless. The remote suite carries
#     FM_PC02_OFFLOAD_REMOTE=1, so it is governed by these slot locks rather
#     than PC01's one-heavy-run admission.
#     A GitHub-dispatched partition on a PC02 self-hosted runner enters this
#     same pool through --runner-slot: it runs the same claim, sets the same
#     FM_PC02_OFFLOAD_REMOTE marker, and runs the worker under it. So a
#     self-hosted job and a local offload can never exceed the slot count
#     together, and two GitHub partitions run in parallel once two slots are
#     free. A runner job has no local fallback, so it waits up to 9000s (150
#     minutes, inside the 180-minute job timeout) and then exits 75 (no
#     verdict); the personal-use flag exits 75 at once.
#   - The remote fm-test-run.sh prints its own environment record before its
#     first test, so an offloaded run records PC02's PATH and the limits the
#     suite actually runs with.
#   - Before taking a slot, PC01 and PC02 compare versions of git, bash,
#     python3, jq, node, shellcheck, actionlint, ruby, chromium, herdr, pi, and
#     tmux, LC_ALL/LANG/TZ, and the version and sorted dependency sonames of
#     the browser fm-test-chrome.sh picks on that host. A differing value, a
#     version a host cannot establish, and an unresolved browser library all
#     route the run locally with both hosts' values. CPU count, RAM, ulimit -u,
#     no-mistakes daemon version, /usr/bin/env provider, and shell availability
#     (including zsh) are intentionally excluded as resources or documented
#     test differences. Every parity step is hard-bounded on either host: tool
#     and selected-browser version probes get 15 seconds, browser dependency
#     and wrapper-resolution probes 10, each killed outright if it ignores the
#     first signal, and the whole probe runs under
#     FM_PC02_OFFLOAD_PARITY_TIMEOUT_SECS. Any expiry routes the run locally.
#     PC02's open-file limit must be at least PC01's; a higher limit is an
#     allowed resource difference. Missing or invalid limits route locally.
#     Both the parity probe and the remote command first raise PC02's soft
#     open-file limit to its hard limit best effort, so a low soft limit
#     inherited from the login shell neither blocks admission nor limits the
#     run.
#   - Sizing evidence: two simultaneous four-worker offloads of
#     fm-supervision-host, fm-captain-hold-lifecycle (one file then; now
#     tests/fm-captain-hold-*.test.sh),
#     fm-remote-secondmate-lifecycle-e2e, and fm-spawn-dispatch-profile passed
#     in 2382s total on 16 threads; peak load5 was 25.54 and minimum
#     MemAvailable was 24.4 GiB of ~27 GiB. A separate PR #215 full 183-script
#     run took 4274s test wall / 4305s whole. The 7200s cap remains a hang
#     bound.
#   - Slot-count sizing after the "6 slots now" decision (2026-11-03): with 6
#     slots the per-slot auto ceiling is floor(16 / 6) = 2 workers, so six
#     concurrent offloads reach 12 workers on a 16-thread / 27 GB host. That
#     is within the thread budget, but it is deliberately lighter per run than
#     the measured two-run shape below instead of a measured six-run result;
#     raise the whole-run cap only with fresh evidence, and lower the slots
#     file if PC02's memory or the shared admission shows pressure. At that
#     per-slot ceiling a full --all selection can exceed the 7200s run cap and
#     fail with exit 124, so full-suite runs belong on the hosted tier
#     (backlog item test-compute-full-suite-hosted).
#   - Two-full-selection measurement (2026-11-03, 316 test scripts, no
#     --jobs, so the auto scheduler with FM_PC02_OFFLOAD_JOBS=8, two slots
#     started 5s apart on an otherwise idle 16-thread / 27 GB PC02): both runs
#     reached 303 of 316 scripts and were stopped by the 7200s cap (exit 124,
#     wall 7220s each), so two concurrent full selections do NOT fit the cap.
#     Peak load1 was 21.06 (mean 4.26) and peak memory use 12.5 GB, so the
#     host was never memory-bound; the wall is dominated by serial unproven
#     scripts. Each run also failed the same 3 scripts (fm-extension-binding,
#     fm-procevent-quota, fm-public-followup) plus 2 start-up-contention
#     failures that passed on the other run; none involve the excluded parity
#     fields. An explicit --jobs with --all is refused by fm-test-run.sh for
#     unproven scripts, so the per-slot --jobs cap applies to selections that
#     are proven concurrent.
#
# Usage:
#   fm-pc02-test-offload.sh <fm-test-run.sh args...>
#   fm-pc02-test-offload.sh --lint-partitions
#   fm-pc02-test-offload.sh --runner-slot <command...>   (PC02 self-hosted
#     runner only: claim a local slot lock, then exec the command with
#     FM_PC02_OFFLOAD_REMOTE=1 so a GitHub-dispatched partition shares the same
#     slot pool as a local offload instead of taking the one-heavy-run
#     admission)
# The lint mode routes every canonical lint partition to PC02 under the same
# admission lock and whole-run timeout, with no test-runner-only arguments.
# When PC02 cannot be used, PC01's last-resort lint runs bin/fm-lint.sh with
# that checkout's changed-file selection instead of the canonical partitions.
# The run-root name comes from bin/fm-pc02-run-root-lib.sh, which
# bin/fm-test-run-stop.sh also sources, so the two never disagree about it.
#
# Env overrides:
#   FM_PC02_OFFLOAD_DISABLE=1          always run locally, skipping every
#                                      PC02 check
#   FM_PC02_OFFLOAD_HOST                ssh target (default: pc02)
#   FM_PC02_OFFLOAD_PROBE_TIMEOUT_SECS  bound for the reachability/personal-use/
#                                      tool probe and the post-sync HEAD check,
#                                      and the ssh ConnectTimeout of each rsync
#                                      transfer (default: 15)
#   FM_PC02_OFFLOAD_PARITY_TIMEOUT_SECS bound for the PC01/PC02 environment
#                                      parity probe on either host (default:
#                                      300). Its per-command deadlines (twelve
#                                      tool and one selected-browser version at
#                                      15s, three dependency probes at 10s) sum
#                                      to under 260s worst case, so this is a
#                                      hang tripwire rather than a deadline
#                                      that cuts a slow-but-identical host.
#   FM_PC02_OFFLOAD_SYNC_TIMEOUT_SECS   bound for each rsync transfer
#                                      (default: 180). The working-tree
#                                      transfer carries only the tree git sees
#                                      (tracked plus untracked-but-not-ignored
#                                      files), so git-ignored caches, private
#                                      data and project clones never inflate
#                                      the payload past this bound.
#   (the PC02 slot file)                ${XDG_CONFIG_HOME:-$HOME/.config}/firstmate/pc02-offload-slots
#                                      on PC02 holds one integer from 1 to
#                                      16, the number of concurrent test
#                                      suites or lint runs; a trailing newline
#                                      is optional. There is no default and no
#                                      override: a missing, unreadable or
#                                      malformed file is a configuration
#                                      error that exits 2 without running the
#                                      selected command.
#   FM_PC02_OFFLOAD_SLOT_WAIT_SECS      bound, in seconds, on the total wait
#                                      for a free PC02 slot before routing
#                                      local (default: 600, ten minutes;
#                                      9000 for --runner-slot). 0
#                                      restores the immediate local fallback,
#                                      and a forwarded --max-wall-ms budget
#                                      also zeroes the wait: the caller gave
#                                      that wall clock to the run, so the
#                                      expected local run time is the whole
#                                      budget and none of it is spent
#                                      waiting. Each wait is printed once
#                                      with its reason; the slot host is
#                                      polled every
#                                      FM_PC02_OFFLOAD_SLOT_WAIT_INTERVAL_SECS.
#   FM_PC02_OFFLOAD_SLOT_WAIT_INTERVAL_SECS
#                                      seconds between slot retries while
#                                      waiting (default: 5). Must be a
#                                      positive integer; any other value is a
#                                      configuration error that exits 2.
#   FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS    bound for the actual remote run, test
#                                      or lint (default: 7200); a hang
#                                      tripwire, not a deadline. PR #215's
#                                      full --changed selection (183 scripts)
#                                      measured 4274s test wall / 4305s whole
#                                      at jobs=4. Exceeding it fails the run
#                                      (exit 124)
#                                      rather than falling back, since the
#                                      remote work already spent is not worth
#                                      discarding blind
#   FM_PC02_OFFLOAD_JOBS                remote auto-scheduler worker ceiling
#                                      (default: 8); when unset it is capped
#                                      to floor(PC02 nproc / SLOTS) like an
#                                      explicit --jobs, while a set value is
#                                      an operator override honoured verbatim
#   FM_PC02_OFFLOAD_SCRIPT_TIMEOUT_SECS per-script cap (default: 3000)
#   FM_PC02_OFFLOAD_REMOTE_BASE         remote base directory, relative to
#                                      the ssh target's home, holding one
#                                      private mirror (worktree + git store)
#                                      per offload run, removed when the run
#                                      ends so concurrent runs never share one.
#                                      Keep it short and dot-free: the run's
#                                      TMPDIR lives below it and socket/git-ref
#                                      path limits apply (default: fmp;
#                                      bin/fm-pc02-run-root-lib.sh owns the
#                                      budget)
#   FM_PC02_OFFLOAD_REQUIRED_TOOLS      space-separated tool list PC02 must
#                                      have (default: see REQUIRED_TOOLS
#                                      below); override only to reflect a
#                                      real, verified change in what the
#                                      selected command needs, never to make
#                                      a tool-short PC02 pass anyway.
#   FM_PC02_OFFLOAD_PERSONAL_USE_FLAG   the manual switch's flag file path on
#                                      PC02, relative to its $HOME (default:
#                                      .fm-pc02-personal-use); present = on.
#                                      This is the only thing that stops PC02
#                                      testing.
#   FM_PC02_OFFLOAD_CLEANUP_TIMEOUT_SECS
#                                      bound for removing this run's PC02
#                                      mirror (default: 120)
#   FM_PC02_OFFLOAD_TMP_ROOT            PC02 tmp directory (default: /tmp)
#   FM_PC02_OFFLOAD_MEMINFO             PC02 meminfo path (default:
#                                      /proc/meminfo)
#   FM_PC02_OFFLOAD_MEM_MIN_FREE_MB     PC02 MemAvailable floor in MiB
#                                      (default: 4096; 0 disables)
#   FM_PC02_OFFLOAD_TMP_MIN_FREE_MB     PC02 TMP_ROOT free-space floor in MiB
#                                      (default: 2048; 0 disables)
#   FM_PC02_OFFLOAD_DISK_MIN_FREE_MB    PC02 home-disk free-space floor in MiB
#                                      (default: 5120; 0 disables)
#
# Exit status: the status of the command that actually ran: fm-test-run.sh for
# tests, the aggregate of every canonical lint partition on PC02, and
# bin/fm-lint.sh's changed-file lint on PC01; or 124 if the remote run itself
# exceeded FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS; or 77 with a `stopped: personal
# use` message when the captain's PC02 switch turned on while this run was in
# flight (no verdict: rerun when PC02 is free, never a test or lint failure);
# or 2 for a missing or malformed PC02 pc02-offload-slots file, a malformed
# wait setting, a malformed FM_PC02_OFFLOAD_CLEANUP_TIMEOUT_SECS, or a
# malformed capacity floor setting, which runs nothing at all.
# --runner-slot returns the command's status; or 75 (no verdict) when every
# slot stays busy or the personal-use switch is on; or 2 for a missing command,
# a missing or malformed slot file, an unopenable slot lock, or a malformed
# wait setting.
# A readiness check that cannot clear by waiting (PC02 personally in use,
# unreachable, missing a required tool, or a sync/verification failure) falls
# back to a local run at once. A full set of PC02 slots waits under the bound
# first; a capacity floor also falls back to a local run. Either way the local
# fallback never changes the result the selected command itself reports.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# shellcheck source=bin/fm-pc02-run-root-lib.sh
. "$SELF_DIR/fm-pc02-run-root-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SELF_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-pc02-hygiene-lib.sh
. "$SELF_DIR/fm-pc02-hygiene-lib.sh"

ARGS=("$@")
LINT_PARTITIONS=0
if [ "$#" = 1 ] && [ "$1" = --lint-partitions ]; then
  LINT_PARTITIONS=1
fi

# A caller that declares a wall clock with --max-wall-ms gives that budget to
# the run itself, so the expected local run time is the whole declared budget
# and no part of it may be spent waiting on PC02.
CALLER_WALL_BUDGET=0
for ((budget_i = 0; budget_i < ${#ARGS[@]}; budget_i++)); do
  case "${ARGS[budget_i]}" in
    --max-wall-ms|--max-wall-ms=*) CALLER_WALL_BUDGET=1 ;;
  esac
done

HOST="${FM_PC02_OFFLOAD_HOST:-pc02}"
PROBE_TIMEOUT="${FM_PC02_OFFLOAD_PROBE_TIMEOUT_SECS:-15}"
# rsync's remote shell gets the same non-interactive, bounded connect as the
# readiness probe. A bare `-e ssh` can sit on a host-key or authentication
# prompt, or on an unanswered connect, until the transfer timeout kills it
# (exit 124) instead of failing fast like this script's probes.
RSYNC_SSH="ssh -o BatchMode=yes -o ConnectTimeout=$PROBE_TIMEOUT -o ConnectionAttempts=1"
PARITY_TIMEOUT="${FM_PC02_OFFLOAD_PARITY_TIMEOUT_SECS:-300}"
SYNC_TIMEOUT="${FM_PC02_OFFLOAD_SYNC_TIMEOUT_SECS:-180}"
RUN_TIMEOUT="${FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS:-7200}"
SCRIPT_TIMEOUT="${FM_PC02_OFFLOAD_SCRIPT_TIMEOUT_SECS:-3000}"
REMOTE_JOBS="${FM_PC02_OFFLOAD_JOBS:-8}"
SLOT_WAIT_DEFAULT=600
[ "${1:-}" != --runner-slot ] || SLOT_WAIT_DEFAULT=9000
SLOT_WAIT="${FM_PC02_OFFLOAD_SLOT_WAIT_SECS:-$SLOT_WAIT_DEFAULT}"
SLOT_WAIT_INTERVAL="${FM_PC02_OFFLOAD_SLOT_WAIT_INTERVAL_SECS:-5}"
REMOTE_RUN="$(fm_pc02_remote_run_prefix "$ROOT")"$$
REMOTE_WORKTREE="$REMOTE_RUN/worktree"
REMOTE_COMMON="$REMOTE_RUN/common.git"
REMOTE_TMP="$REMOTE_RUN/tmp"
REMOTE_RUN_CREATED=0
claim_pid=
claim_open=0
claim_tmp=
mirror_list=
PERSONAL_USE_FLAG="${FM_PC02_OFFLOAD_PERSONAL_USE_FLAG:-.fm-pc02-personal-use}"
CLEANUP_TIMEOUT="${FM_PC02_OFFLOAD_CLEANUP_TIMEOUT_SECS:-120}"
TMP_ROOT="${FM_PC02_OFFLOAD_TMP_ROOT:-/tmp}"
MEMINFO_PATH="${FM_PC02_OFFLOAD_MEMINFO:-/proc/meminfo}"
MEM_MIN_FREE_MB="${FM_PC02_OFFLOAD_MEM_MIN_FREE_MB:-$FM_PC02_DEFAULT_MEM_MIN_FREE_MB}"
TMP_MIN_FREE_MB="${FM_PC02_OFFLOAD_TMP_MIN_FREE_MB:-$FM_PC02_DEFAULT_TMP_MIN_FREE_MB}"
DISK_MIN_FREE_MB="${FM_PC02_OFFLOAD_DISK_MIN_FREE_MB:-$FM_PC02_DEFAULT_DISK_MIN_FREE_MB}"

# Tools whose absence hard-fails a real test rather than gracefully
# gate-skipping it - actionlint and shellcheck are pinned versions
# bin/fm-lint.sh refuses to run without, perl is required outright by that
# same script for its bounded worker cleanup (it exits 127 without it), ruby
# is required outright by tests/fm-ci-workflow.test.sh (`command -v ruby ||
# fail ...`), and chromium is required outright by
# tests/fm-calm-pi-extension.test.sh's rendered-export guard, none of them
# optional capabilities. A host missing any of these would fail differently
# than PC01, not just thinner, so no-mistakes would judge a different outcome.
# Require them on PC02 too rather than risk that.
REQUIRED_TOOLS="${FM_PC02_OFFLOAD_REQUIRED_TOOLS:-git bash python3 jq node shellcheck actionlint perl ruby chromium}"

case "$SLOT_WAIT" in
  ''|*[!0-9]*) echo "fm-pc02-test-offload: FM_PC02_OFFLOAD_SLOT_WAIT_SECS must be a non-negative integer, got '$SLOT_WAIT'" >&2; exit 2 ;;
esac
case "$SLOT_WAIT_INTERVAL" in
  ''|*[!0-9]*) echo "fm-pc02-test-offload: FM_PC02_OFFLOAD_SLOT_WAIT_INTERVAL_SECS must be a positive integer, got '$SLOT_WAIT_INTERVAL'" >&2; exit 2 ;;
esac
[ "$SLOT_WAIT_INTERVAL" -ge 1 ] \
  || { echo "fm-pc02-test-offload: FM_PC02_OFFLOAD_SLOT_WAIT_INTERVAL_SECS must be a positive integer, got '$SLOT_WAIT_INTERVAL'" >&2; exit 2; }
[ "$CALLER_WALL_BUDGET" -eq 0 ] || SLOT_WAIT=0

# The one slot claim. It runs on PC02, either shipped to the offload's remote
# shell or called by --runner-slot, and leaves the claimed lock on the calling
# shell's fd 8. Each outcome is passed to <report command>.
pc02_claim_slot() {  # <report command> <personal-use flag> <wait secs> <interval secs>
  local report=$1 flag=$HOME/$2 wait_secs=$3 interval=$4
  local file=${XDG_CONFIG_HOME:-$HOME/.config}/firstmate/pc02-offload-slots
  local count='' held='' noticed=0 deadline now pause i
  if ! { IFS= read -r count < "$file" || [ -n "$count" ]; } 2>/dev/null; then
    "$report" config-error "cannot read the PC02 slot file $file (put one integer from 1 to 16)"
    return 2
  fi
  case "$count" in
    ''|*[!0-9]*) "$report" config-error "$file must be a positive integer, got '$count'"; return 2 ;;
  esac
  { [ "$count" -ge 1 ] && [ "$count" -le 16 ]; } \
    || { "$report" config-error "$file must be between 1 and 16, got '$count'"; return 2; }
  deadline=$(( $(date +%s) + wait_secs ))
  while :; do
    [ ! -f "$flag" ] || { "$report" stopped-personal-use; return 75; }
    i=1
    while [ "$i" -le "$count" ]; do
      exec 8> "$HOME/.fm-pc02-test-slot-$i.lock" \
        || { "$report" lock-error "$HOME/.fm-pc02-test-slot-$i.lock"; return 2; }
      if flock -n 8; then held=$i; break; fi
      exec 8>&-
      i=$((i + 1))
    done
    [ -z "$held" ] || break
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then "$report" busy "$count"; return 75; fi
    pause=$((deadline - now))
    [ "$pause" -le "$interval" ] || pause=$interval
    if [ "$noticed" -eq 0 ]; then "$report" waiting "$pause" "$count"; noticed=1; fi
    sleep "$pause"
  done
  [ ! -f "$flag" ] || { "$report" stopped-personal-use; return 75; }
  "$report" claimed "$held" of "$count"
}

# shellcheck disable=SC2329 # Invoked by name from pc02_claim_slot.
report_runner_claim() {
  case "$1" in
    config-error) echo "fm-pc02-test-offload: $2" >&2 ;;
    lock-error) echo "fm-pc02-test-offload: cannot open PC02 slot lock $2" >&2 ;;
    stopped-personal-use) echo "fm-pc02-test-offload: PC02 personal-use switch is on; not running a runner partition" >&2 ;;
    waiting) echo "fm-pc02-test-offload: all $3 PC02 test slots are busy; waiting up to ${SLOT_WAIT}s for a free slot" >&2 ;;
    busy) echo "fm-pc02-test-offload: all $2 PC02 test slots stayed busy through the ${SLOT_WAIT}s wait bound; not running a runner partition" >&2 ;;
    claimed) echo "fm-pc02-test-offload: runner partition claimed PC02 slot $2 of $4" >&2 ;;
  esac
}

if [ "${1:-}" = --runner-slot ]; then
  shift
  [ "$#" -ge 1 ] || { echo "fm-pc02-test-offload: --runner-slot requires a command to run" >&2; exit 2; }
  pc02_claim_slot report_runner_claim "$PERSONAL_USE_FLAG" "$SLOT_WAIT" "$SLOT_WAIT_INTERVAL" || exit
  FM_PC02_OFFLOAD_REMOTE=1 exec "$@"
fi

# A malformed hygiene bound is the same kind of configuration error: refuse
# rather than silently skipping a floor.
for setting in \
  "FM_PC02_OFFLOAD_CLEANUP_TIMEOUT_SECS:$CLEANUP_TIMEOUT" \
  "FM_PC02_OFFLOAD_MEM_MIN_FREE_MB:$MEM_MIN_FREE_MB" \
  "FM_PC02_OFFLOAD_TMP_MIN_FREE_MB:$TMP_MIN_FREE_MB" \
  "FM_PC02_OFFLOAD_DISK_MIN_FREE_MB:$DISK_MIN_FREE_MB"; do
  name=${setting%%:*}
  value=${setting#*:}
  case "$value" in
    '' | *[!0-9]*)
      echo "fm-pc02-test-offload: $name must be a non-negative integer, got '$value'" >&2
      exit 2
      ;;
  esac
done

release_claim() {
  if [ "$claim_open" -eq 1 ]; then
    exec 6>&- 7<&-
    claim_open=0
  fi
  if [ -n "$claim_pid" ]; then
    kill "$claim_pid" 2>/dev/null || true
    for _ in $(seq 1 100); do
      kill -0 "$claim_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$claim_pid" 2>/dev/null || true
    wait "$claim_pid" 2>/dev/null || true
    claim_pid=
  fi
  if [ -n "$claim_tmp" ]; then rm -rf "$claim_tmp"; claim_tmp=; fi
  if [ -n "$mirror_list" ]; then rm -f "$mirror_list"; mirror_list=; fi
}

remove_remote_run() {
  [ "$REMOTE_RUN_CREATED" -eq 1 ] || return 0
  REMOTE_RUN_CREATED=0
  local run_q cleanup_cmd
  run_q=$(printf '%q' "$REMOTE_RUN")
  cleanup_cmd="[ -f $run_q/pgid ] && pkill -KILL -s \"\$(cat $run_q/pgid)\" 2>/dev/null; chmod -R u+w $run_q 2>/dev/null || true; rm -rf $run_q"
  timeout "$CLEANUP_TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout="$PROBE_TIMEOUT" \
    -o ConnectionAttempts=1 "$HOST" "bash -lc $(printf '%q' "$cleanup_cmd")" >/dev/null 2>&1 \
    || echo "fm-pc02-test-offload: could not remove PC02 mirror $REMOTE_RUN" >&2
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
on_signal() {  # <exit code>
  exit "$1"
}
trap 'remove_remote_run; release_claim' EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

keep_real_parents() {  # NUL-separated $ROOT-relative paths on stdin
  local entry parent
  while IFS= read -r -d '' entry; do
    parent=$entry
    while [[ $parent == */* ]]; do
      parent=${parent%/*}
      [ -d "$ROOT/$parent" ] && [ ! -L "$ROOT/$parent" ] || continue 2
    done
    printf '%s\0' "$entry" || return 1
  done
}

run_local() {  # <reason>
  echo "fm-pc02-test-offload: $1; running on PC01" >&2
  remove_remote_run
  release_claim
  if [ "$LINT_PARTITIONS" = 1 ]; then exec "$SELF_DIR/fm-lint.sh"; fi
  exec "$SELF_DIR/fm-test-run.sh" ${ARGS[@]+"${ARGS[@]}"}
}

# The captain's switch turned on while this run was already in flight. Report
# it as a no-verdict stop rather than a test failure, so the caller reruns when
# PC02 is free instead of treating the stopped suite as a failing one. The EXIT
# trap removes this run's mirror and releases its claim.
stop_personal_use() {
  echo "fm-pc02-test-offload: stopped: personal use (the PC02 switch is on); no test verdict - rerun when PC02 is free" >&2
  exit 77
}

[ "${FM_PC02_OFFLOAD_DISABLE:-}" != "1" ] || run_local "offload disabled (FM_PC02_OFFLOAD_DISABLE=1)"
command -v ssh >/dev/null 2>&1 || run_local "ssh not available on PC01"
command -v rsync >/dev/null 2>&1 || run_local "rsync not available on PC01"

# PC02 may be asleep. Wake it before the bounded readiness probe; the helper
# returns immediately when SSH already answers and is a no-op for a host this
# home does not manage.
if [ "${FM_PC02_WAKE_OFFLOAD:-1}" != 0 ] && [ -x "$SELF_DIR/fm-pc02-wake.sh" ]; then
  "$SELF_DIR/fm-pc02-wake.sh" ensure --host "$HOST" --if-managed --quiet \
    || run_local "PC02 is asleep and did not answer a wake attempt"
fi

# 1. Is PC02 personally in use, tool-ready, and reachable? One bounded ssh
# call answers it so a stuck or slow probe cannot hang this script past
# PROBE_TIMEOUT seconds. The captain's manual switch is the only thing that
# stops PC02 testing; a live PC02 model worker and a loaded llama-swap share
# the host and are not occupancy (see the header). $HOME and $t below are
# escaped so they expand on PC02 inside the remote shell, never on PC01.
probe_cmd=$(cat <<PROBE
[ -f "\$HOME/$PERSONAL_USE_FLAG" ] && echo "personal-use:on"
for t in $REQUIRED_TOOLS; do command -v "\$t" >/dev/null 2>&1 || echo "missing:\$t"; done
echo "threads:\$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)"
PROBE
)
probe_out=$(timeout "$PROBE_TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout="$PROBE_TIMEOUT" \
  -o ConnectionAttempts=1 "$HOST" "bash -lc $(printf '%q' "$probe_cmd")" 2>&1)
probe_rc=$?
if [ "$probe_rc" -ne 0 ]; then
  echo "$probe_out" >&2
  run_local "PC02 unreachable (ssh probe exit $probe_rc)"
fi

personal_use=0
missing_tools=
remote_threads=
while IFS= read -r probe_line; do
  case "$probe_line" in
    personal-use:on) personal_use=1 ;;
    missing:*) missing_tools="$missing_tools ${probe_line#missing:}" ;;
    threads:*) remote_threads="${probe_line#threads:}" ;;
  esac
done <<PROBE_OUT
$probe_out
PROBE_OUT

# The manual switch (captain's 2026-09-24 request): flip with
# bin/fm-pc02-personal-use.sh from PC01 or the no-terminal Windows desktop
# toggle documented in docs/pc02-outage-runbook.md.
[ "$personal_use" -ne 1 ] || run_local "PC02 personal-use switch is on"

if [ -n "$missing_tools" ]; then
  run_local "PC02 missing required tool(s):$missing_tools"
fi

case "$remote_threads" in
  ''|*[!0-9]*) run_local "PC02 thread count unavailable (got '$remote_threads'); cannot bound concurrent slot workers" ;;
esac
[ "$remote_threads" -ge 1 ] || run_local "PC02 reported zero threads; cannot bound concurrent slot workers"

# 2b. Pre-claim capacity: read PC02's MemAvailable, TMP_ROOT free space and
# home-disk free space fresh, then check the floors. This gate only reads; a
# run never removes another run's root, and bin/fm-pc02-hygiene-lib.sh owns the
# readings and the floor rules.
capacity_script=$(fm_pc02_hygiene_capacity_script "$TMP_ROOT" "$MEMINFO_PATH")
capacity_out=$(timeout "$PROBE_TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout="$PROBE_TIMEOUT" \
  -o ConnectionAttempts=1 "$HOST" "bash -lc $(printf '%q' "$capacity_script")" 2>&1)
capacity_rc=$?
if [ "$capacity_rc" -ne 0 ]; then
  echo "$capacity_out" >&2
  run_local "PC02 pre-claim capacity read failed (ssh exit $capacity_rc)"
fi
capacity=$(printf '%s\n' "$capacity_out" | awk '$1 == "capacity" { sub(/^capacity /, ""); print; found = 1; exit } END { exit !found }') || {
  echo "$capacity_out" >&2
  run_local "PC02 pre-claim capacity reading unavailable"
}
mem_available_kb=''
tmp_free_kb=''
disk_free_kb=''
for field in $capacity; do
  key=${field%%=*}
  value=${field#*=}
  case "$key" in
    mem_available_kb) mem_available_kb=$value ;;
    tmp_free_kb) tmp_free_kb=$value ;;
    disk_free_kb) disk_free_kb=$value ;;
  esac
done
require_kb() {  # <label> <value>
  case "$2" in
    '' | *[!0-9]*) run_local "PC02 pre-claim capacity unclear (missing $1 reading)" ;;
  esac
}
require_kb MemAvailable "$mem_available_kb"
require_kb "/tmp free" "$tmp_free_kb"
require_kb "disk free" "$disk_free_kb"
mem_available_mib=$((mem_available_kb / 1024))
tmp_free_mib=$((tmp_free_kb / 1024))
disk_free_mib=$((disk_free_kb / 1024))
[ "$MEM_MIN_FREE_MB" -eq 0 ] || [ "$mem_available_mib" -ge "$MEM_MIN_FREE_MB" ] \
  || run_local "PC02 MemAvailable ${mem_available_mib} MiB is below the ${MEM_MIN_FREE_MB} MiB floor"
[ "$TMP_MIN_FREE_MB" -eq 0 ] || [ "$tmp_free_mib" -ge "$TMP_MIN_FREE_MB" ] \
  || run_local "PC02 $TMP_ROOT free ${tmp_free_mib} MiB is below the ${TMP_MIN_FREE_MB} MiB floor"
[ "$DISK_MIN_FREE_MB" -eq 0 ] || [ "$disk_free_mib" -ge "$DISK_MIN_FREE_MB" ] \
  || run_local "PC02 disk free ${disk_free_mib} MiB is below the ${DISK_MIN_FREE_MB} MiB floor"

# Compare test-relevant surfaces with the same probe on both hosts.
parity_probe="$(cat "$SELF_DIR/fm-test-chrome.sh")
$(cat <<'PARITY_PROBE'
# fm-pc02-environment-parity-probe
set -u
version() {
  local tool=$1 args=--version path value status=0
  [ "$tool" != tmux ] || args=-V
  path=$(type -P "$tool" 2>/dev/null || true)
  if [ -z "$path" ]; then printf 'tool.%s=absent\n' "$tool"; return; fi
  value=$(timeout --signal=TERM --kill-after=2 15 "$path" "$args" 2>&1 </dev/null) || status=$?
  # Keep the first line carrying a digit (shellcheck prints a banner first).
  value=$(printf '%s\n' "$value" | awk 'NR == 1 { first = $0 } /[0-9]/ { print; found = 1; exit } END { if (!found) print first }')
  [ -n "$value" ] || value=unavailable
  case "$status" in 124|137) value=timed-out ;; esac
  value=$(printf '%s' "$value" | tr '\r\n\t' '   ' | cut -c1-180)
  printf 'tool.%s=%s\n' "$tool" "$value"
}
for tool in git bash python3 jq node shellcheck actionlint ruby chromium herdr pi tmux; do version "$tool"; done
printf 'ulimit.open_files=%s\n' "$(ulimit -n 2>&1)"
printf 'locale.LC_ALL=%s\n' "${LC_ALL-}"
printf 'locale.LANG=%s\n' "${LANG-}"
printf 'locale.TZ=%s\n' "${TZ-}"
normalize_ldd() {
  local path=$1 output status=0 target trace
  [ -n "$path" ] || { printf 'UNRESOLVED:browser-absent\n'; return; }
  output=$(timeout --signal=TERM --kill-after=2 10 ldd "$path" 2>&1) || status=$?
  case "$status" in
    124|137) printf 'browser dependency probe timed out running ldd for %s\n' "$path" >&2; return 1 ;;
  esac
  if printf '%s' "$output" | grep -Eqi 'not a dynamic executable|statically linked|not dynamic'; then
    status=0
    trace=$(timeout --signal=TERM --kill-after=2 10 bash -x "$path" --version 2>&1 </dev/null) || status=$?
    case "$status" in
      124|137) printf 'browser dependency probe timed out resolving wrapper %s\n' "$path" >&2; return 1 ;;
    esac
    target=$(printf '%s\n' "$trace" | sed -nE 's/^\+ exec ([^[:space:]]+).*/\1/p' | tail -n 1)
    if [ -n "$target" ] && [ -x "$target" ]; then
      path=$(readlink -f "$target" 2>/dev/null || printf '%s' "$target")
      status=0
      output=$(timeout --signal=TERM --kill-after=2 10 ldd "$path" 2>&1) || status=$?
      case "$status" in
        124|137) printf 'browser dependency probe timed out running ldd for resolved executable %s\n' "$path" >&2; return 1 ;;
      esac
    else
      printf 'UNRESOLVED:wrapper-target (%s)\n' "${target:-unresolved}"
      return
    fi
  fi
  if printf '%s\n' "$output" | grep -q 'not found'; then
    printf '%s\n' "$output" | awk '
      /=>[[:space:]]+not found/ {gsub(/^[[:space:]]+/, ""); print "UNRESOLVED:" $1; next}
      index($0, "=>") {split($0, pair, "=>"); gsub(/^[[:space:]]+|[[:space:]]+$/, "", pair[1]); print pair[1]; next}
      $1 ~ /^\// {n=split($1, path, "/"); print path[n]; next}
      $1 ~ /^linux-vdso/ {print $1}
    ' | sort -u
  elif [ "$status" -ne 0 ]; then
    printf 'UNRESOLVED:ldd-error-%s\n' "$status"
  else
    printf '%s\n' "$output" | awk '
      index($0, "=>") {split($0, pair, "=>"); gsub(/^[[:space:]]+|[[:space:]]+$/, "", pair[1]); print pair[1]; next}
      $1 ~ /^\// {n=split($1, path, "/"); print path[n]; next}
      $1 ~ /^linux-vdso/ {print $1}
    ' | sort -u
  fi
}
browser=$(find_chrome 2>/dev/null || true)
if [ -n "$browser" ]; then browser=$(readlink -f "$browser" 2>/dev/null || printf '%s' "$browser"); fi
printf 'chromium.path=%s\n' "$browser"
if [ -n "$browser" ]; then
  browser_version_status=0
  browser_version=$(timeout --signal=TERM --kill-after=2 15 "$browser" --version 2>&1 </dev/null) || browser_version_status=$?
  browser_version=${browser_version%%$'\n'*}
  [ -n "$browser_version" ] || browser_version=unavailable
  case "$browser_version_status" in 124|137) browser_version=timed-out ;; esac
  browser_version=$(printf '%s' "$browser_version" | tr '\r\n\t' '   ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | cut -c1-180)
else
  browser_version=absent
fi
printf 'chromium.selected_version=%s\n' "$browser_version"
printf 'chromium.dependencies='
browser_dependencies=$(normalize_ldd "$browser") || exit 1
printf '%s\n' "$browser_dependencies" | paste -sd, -
PARITY_PROBE
)"
local_parity=$(timeout --signal=TERM --kill-after=5 "$PARITY_TIMEOUT" bash -c "$parity_probe" 2>&1) \
  || run_local "PC01 environment parity probe failed: $local_parity"
# shellcheck disable=SC2016 # The raise expands on PC02, not here.
remote_parity_raise='ulimit -Sn "$(ulimit -Hn)" 2>/dev/null || true'
remote_parity_cmd="$remote_parity_raise
$parity_probe"
remote_parity=$(timeout --signal=TERM --kill-after=5 "$PARITY_TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout="$PROBE_TIMEOUT" \
  -o ConnectionAttempts=1 "$HOST" "bash -lc $(printf '%q' "$remote_parity_cmd")" 2>&1) || {
  run_local "PC02 environment parity probe failed: $remote_parity"
}
open_file_limit_sufficient() { # <PC01 limit> <PC02 limit>
  local local_limit=$1 remote_limit=$2
  case "$local_limit" in
    unlimited) [ "$remote_limit" = unlimited ]; return ;;
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$remote_limit" in
    unlimited) return 0 ;;
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$remote_limit" -ge "$local_limit" ] 2>/dev/null
}

parity_mismatches=()
while IFS='=' read -r key local_value; do
  case "$key" in chromium.path|chromium.dependencies) continue ;; esac
  remote_value=$(printf '%s\n' "$remote_parity" | awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}')
  if [ "$key" = ulimit.open_files ]; then
    open_file_limit_sufficient "$local_value" "$remote_value" \
      || parity_mismatches+=("$key below PC01 or invalid (PC01='$local_value', PC02='$remote_value')")
  else
    [ "$local_value" = "$remote_value" ] || parity_mismatches+=("$key (PC01='$local_value', PC02='$remote_value')")
  fi
  case "$key" in
    tool.*|chromium.selected_version)
      case "$local_value:$remote_value" in
        absent:*|unavailable:*|timed-out:*|*:absent|*:unavailable|*:timed-out)
          parity_mismatches+=("$key version could not be established")
          ;;
      esac
      ;;
  esac
done <<< "$local_parity"
local_chrome=$(printf '%s\n' "$local_parity" | sed -n 's/^chromium.path=//p' | head -n 1)
remote_chrome=$(printf '%s\n' "$remote_parity" | sed -n 's/^chromium.path=//p' | head -n 1)
local_deps=$(printf '%s\n' "$local_parity" | sed -n 's/^chromium.dependencies=//p' | head -n 1)
remote_deps=$(printf '%s\n' "$remote_parity" | sed -n 's/^chromium.dependencies=//p' | head -n 1)
case "$local_deps" in *UNRESOLVED:*) parity_mismatches+=("PC01 Chromium at '$local_chrome' has unresolved dependencies '${local_deps//,/ }'") ;; esac
case "$remote_deps" in *UNRESOLVED:*) parity_mismatches+=("PC02 Chromium at '$remote_chrome' has unresolved dependencies '${remote_deps//,/ }'") ;; esac
[ "$local_deps" = "$remote_deps" ] || parity_mismatches+=("chromium.dependencies (PC01='$local_deps', PC02='$remote_deps')")
if [ "${#parity_mismatches[@]}" -gt 0 ]; then
  run_local "PC02 test environment differs from PC01: ${parity_mismatches[*]}"
fi

# The same SSH shell owns the slot while waiting for transfer, then runs the
# suite under it. It takes the first free slot, so up to SLOTS suites share
# PC02. When every slot is held it keeps retrying on the remote host until the
# wait budget left after any gate wait has passed, sending one progress line for
# the local side to print, then reports that every slot stayed busy and exits
# 75. EOF before execution releases the slot; EOF during execution cannot
# release it ahead of the bounded suite. No PID-file reclamation race.
# The gate wait and the slot wait draw on one SLOT_WAIT bound, so a run waits
# at most that long in total before it routes to PC01.
claim_budget=$SLOT_WAIT
# shellcheck disable=SC2016 # HOME and command expand on PC02.
claim_cmd="$(declare -f pc02_claim_slot)
flag=\$HOME/$(printf '%q' "$PERSONAL_USE_FLAG")
pc02_claim_slot echo $(printf '%q' "$PERSONAL_USE_FLAG") $claim_budget $SLOT_WAIT_INTERVAL || exit
"'IFS= read -r -t '"$((SYNC_TIMEOUT * 3 + PROBE_TIMEOUT * 5))"' command || exit 1
[ ! -f "$flag" ] || { printf "fm-pc02-test-offload: stopped: personal use\n"; exit 75; }
eval "$command"'
# FIFOs keep this compatible with stock macOS Bash (which has no coproc).
claim_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-pc02-claim.XXXXXX") || run_local "cannot prepare claim channel"
mkfifo "$claim_tmp/in" "$claim_tmp/out" || run_local "cannot prepare claim pipes"
exec 6<>"$claim_tmp/in"
timeout --kill-after=5 "$((SYNC_TIMEOUT * 3 + PROBE_TIMEOUT * 5 + claim_budget + RUN_TIMEOUT + 30))" \
  ssh -o BatchMode=yes -o ConnectTimeout="$PROBE_TIMEOUT" \
  "$HOST" "bash -lc $(printf '%q' "$claim_cmd")" \
  6>&- <"$claim_tmp/in" >"$claim_tmp/out" &
claim_pid=$!
exec 7<"$claim_tmp/out"
claim_open=1
claim_reply=
claim_waiting=0
claim_line_timeout=$PROBE_TIMEOUT
while :; do
  claim_line=
  if ! IFS= read -r -t "$claim_line_timeout" claim_line <&7 || [ -z "$claim_line" ]; then
    kill "$claim_pid" 2>/dev/null || true
    run_local "PC02 test slot claim unavailable"
  fi
  case "$claim_line" in
    "waiting "*)
      # The remote host keeps polling its slot locks; print the wait once so
      # a busy host is visible without flooding the caller's log.
      if [ "$claim_waiting" -eq 0 ]; then
        echo "fm-pc02-test-offload: all ${claim_line##* } PC02 test slots are busy; waiting up to ${claim_budget}s for a free slot" >&2
        claim_waiting=1
      fi
      claim_line_timeout=$((claim_budget + PROBE_TIMEOUT))
      ;;
    *)
      claim_reply=$claim_line
      break
      ;;
  esac
done
case "$claim_reply" in
  "claimed "*) echo "fm-pc02-test-offload: claimed PC02 slot ${claim_reply#claimed }" >&2 ;;
  "stopped-personal-use") stop_personal_use ;;
  "config-error "*)
    echo "fm-pc02-test-offload: ${claim_reply#config-error }" >&2
    exit 2
    ;;
  "busy "*)
    kill "$claim_pid" 2>/dev/null || true
    if [ "$claim_budget" -le 0 ]; then
      run_local "all ${claim_reply#busy } PC02 test slots are busy; running locally"
    else
      run_local "all ${claim_reply#busy } PC02 test slots stayed busy through the ${claim_budget}s wait bound; running locally"
    fi
    ;;
  *)
    kill "$claim_pid" 2>/dev/null || true
    run_local "PC02 test slot claim unavailable (reply: '$claim_reply')"
    ;;
esac

# Cap explicit caller --jobs and the default auto-scheduler ceiling per slot
# so the sum across concurrently held slots cannot oversubscribe PC02: each
# slot may use at most floor(threads / slots) workers. The thread count comes
# from the remote host's own nproc (getconf fallback), never a hard-coded
# figure, so a different PC02 or a changed CPU count adjusts the cap
# automatically. A caller asking for less than the cap keeps its value, and
# an explicitly set FM_PC02_OFFLOAD_JOBS stays an operator override honoured
# verbatim. An unreadable count is an unclear host read and routes local, like
# every other unclear probe.
SLOTS=${claim_reply##* }
jobs_cap=$((remote_threads / SLOTS))
[ "$jobs_cap" -ge 1 ] || jobs_cap=1
if [ -z "${FM_PC02_OFFLOAD_JOBS:-}" ] && [ "$REMOTE_JOBS" -gt "$jobs_cap" ]; then
  REMOTE_JOBS=$jobs_cap
fi

# 3. Mirror the current worktree onto PC02: the working tree as git sees it,
# this worktree's own per-worktree git-dir (HEAD, index, refs, logs), and the
# shared object/ref store it points at (fm-primary-scope-lib.sh's
# fm_resolve_git_path handles both a linked task worktree and a plain
# checkout, where git-dir and git-common-dir are the same path). The mirror
# is a real, self-contained repo on PC02, not a copy of the ".git" pointer
# file a linked worktree actually has, so its own commondir is rewritten to
# point at the mirrored common store below.
#
# The working-tree transfer is listed from git (tracked files plus untracked
# files git does not ignore) instead of walking the whole directory. A
# worktree can accumulate multi-gigabyte git-ignored content - a primary
# home's data/ and projects/, node_modules, tool caches, scratch stores - and
# a whole-tree transfer of that exceeds FM_PC02_OFFLOAD_SYNC_TIMEOUT_SECS and
# falls back locally (observed: 13.5 GiB / 317k files for a primary checkout
# versus 33 MiB / 1.2k files for the same checkout's git-visible tree). Tests
# never read ignored content, and it must not leave PC01, so the mirror
# carries only what git sees; the explicit file list also skips the walk of
# those trees entirely. A file deleted from the working tree is still in the
# index, so --ignore-missing-args keeps that a skip like the old whole-tree
# walk, not a sync failure.
git_dir=$(fm_resolve_git_path "$ROOT" --git-dir) || run_local "could not resolve this worktree's git-dir"
git_common_dir=$(fm_resolve_git_path "$ROOT" --git-common-dir) || run_local "could not resolve this worktree's git-common-dir"

mirror_list=$(mktemp "${TMPDIR:-/tmp}/fm-pc02-mirror.XXXXXX") || run_local "could not create the mirror file list"
(
  set -o pipefail
  { git -C "$ROOT" ls-files -z && git -C "$ROOT" ls-files -z --others --exclude-standard; } \
    | keep_real_parents > "$mirror_list"
) || run_local "could not list the working tree for the PC02 mirror"

mkdir_cmd="mkdir -p $(printf '%q' "$REMOTE_WORKTREE") $(printf '%q' "$REMOTE_COMMON") $(printf '%q' "$REMOTE_TMP")"
REMOTE_RUN_CREATED=1
mkdir_out=$(timeout "$PROBE_TIMEOUT" ssh "$HOST" "bash -lc $(printf '%q' "$mkdir_cmd")" 2>&1)
mkdir_rc=$?
if [ "$mkdir_rc" -ne 0 ]; then
  echo "$mkdir_out" >&2
  run_local "could not create PC02 mirror directories (exit $mkdir_rc)"
fi

sync_log=$(timeout "$SYNC_TIMEOUT" rsync -az --delete --from0 --files-from="$mirror_list" \
  --ignore-missing-args -e "$RSYNC_SSH" "$ROOT/" "$HOST:$REMOTE_WORKTREE/" 2>&1)
sync_rc=$?
if [ "$sync_rc" -eq 0 ]; then
  sync_log2=$(timeout "$SYNC_TIMEOUT" rsync -az --delete -e "$RSYNC_SSH" --exclude=commondir --exclude=gitdir \
    "$git_dir/" "$HOST:$REMOTE_WORKTREE/.git/" 2>&1)
  sync_rc=$?
  sync_log="$sync_log
$sync_log2"
fi
if [ "$sync_rc" -eq 0 ]; then
  sync_log3=$(timeout "$SYNC_TIMEOUT" rsync -az --delete -e "$RSYNC_SSH" --exclude=worktrees \
    "$git_common_dir/" "$HOST:$REMOTE_COMMON/" 2>&1)
  sync_rc=$?
  sync_log="$sync_log
$sync_log3"
fi
if [ "$sync_rc" -ne 0 ]; then
  echo "$sync_log" >&2
  run_local "rsync to PC02 failed or timed out (exit $sync_rc)"
fi

# The mirrored per-worktree git-dir still has its original commondir/gitdir
# pointers excluded above (a stale one would point back at a PC01-only
# path); point commondir at the sibling common-store mirror instead.
retarget_cmd="printf '%s' '../../common.git' > $(printf '%q' "$REMOTE_WORKTREE/.git/commondir")"
retarget_out=$(timeout "$PROBE_TIMEOUT" ssh "$HOST" "bash -lc $(printf '%q' "$retarget_cmd")" 2>&1)
retarget_rc=$?
if [ "$retarget_rc" -ne 0 ]; then
  echo "$retarget_out" >&2
  run_local "could not retarget PC02 mirror's git commondir (exit $retarget_rc)"
fi

# 3b. Verify the mirror actually resolves to the same commit before spending
# the real test budget on it; a mismatch means the reconstructed repo is
# broken, not that PC02 has a different (or newer) commit to test.
local_head=$(git -C "$ROOT" rev-parse HEAD 2>&1) || run_local "could not read local HEAD"
head_cmd="cd $(printf '%q' "$REMOTE_WORKTREE") && git rev-parse HEAD"
remote_head=$(timeout "$PROBE_TIMEOUT" ssh "$HOST" "bash -lc $(printf '%q' "$head_cmd")" 2>&1)
head_rc=$?
if [ "$head_rc" -ne 0 ] || [ "$remote_head" != "$local_head" ]; then
  echo "$remote_head" >&2
  run_local "PC02 mirror HEAD verification failed (local=$local_head remote=$remote_head rc=$head_rc)"
fi

# 4. Run the exact same command invocation on PC02, streaming its output
# live; its exit code becomes this script's exit code unchanged. Lint mode
# reuses this whole transfer/lock/streaming path and swaps only the command,
# so partition selection stays exactly what the caller asked for.
# Bounded by RUN_TIMEOUT on PC02 itself: an orphaned background process a
# test leaves running there can hold the ssh channel open long after
# fm-test-run.sh itself exits (see header), so this is not merely defensive.
# The remote `timeout` bounds the run; the wrapper kills its session when
# the command returns, including nested per-script timeout groups, so a
# straggler cannot pin the channel;
# the local one is only a backstop for a wedged ssh connection. A run
# that hits this bound fails outright (exit 124) rather than falling back to
# a second local run, which would silently double the caller's time budget.
if [ "$LINT_PARTITIONS" = 1 ]; then
  echo "fm-pc02-test-offload: PC02 idle and ready; running lint remotely on $HOST" >&2
  # Lint partitions are independent canonical jobs, so fan them out instead of
  # paying their sum serially. Bound the fan-out by both the configured slot
  # ceiling and the host thread count: each partition keeps fm-lint.sh's two
  # default workers, so floor(threads / 2) partitions fill the host without
  # oversubscribing it, and no more partitions run than configured slots exist.
  # local-lint caps the value at the canonical partition count.
  lint_parallel=$SLOTS
  lint_thread_cap=$((remote_threads / 2))
  [ "$lint_thread_cap" -ge 1 ] || lint_thread_cap=1
  [ "$lint_parallel" -le "$lint_thread_cap" ] || lint_parallel=$lint_thread_cap
  echo "fm-pc02-test-offload: running up to $lint_parallel canonical lint partition(s) concurrently" >&2
  remote_suite_cmd="setsid timeout --kill-after=10 $(printf '%q' "$RUN_TIMEOUT") env FM_PC02_OFFLOAD_REMOTE=1 FM_PC02_LINT_PARALLEL=$(printf '%q' "$lint_parallel") bin/fm-test-compute.sh local-lint"
else
  echo "fm-pc02-test-offload: PC02 idle and ready; running tests remotely on $HOST" >&2
  has_jobs=0
  for a in ${ARGS[@]+"${ARGS[@]}"}; do
    case "$a" in --jobs|--jobs=*) has_jobs=1 ;; esac
  done
  # Rewrite only an explicit caller --jobs, and only downward to the per-slot
  # cap; every other argument passes through byte-for-byte. Both caller forms
  # (--jobs N and --jobs=N) keep their shape. A non-numeric value is left for
  # fm-test-run.sh to reject as it always did.
  remote_args=()
  if [ "$has_jobs" -eq 0 ]; then
    if [ "${#ARGS[@]}" -gt 0 ]; then
      remote_args=("${ARGS[@]}")
    fi
  else
    jobs_i=0
    while [ "$jobs_i" -lt "${#ARGS[@]}" ]; do
      a=${ARGS[$jobs_i]}
      case "$a" in
        --jobs)
          v=${ARGS[$((jobs_i + 1))]:-}
          case "$v" in
            ''|*[!0-9]*) ;;
            *)
              if [ "$v" -gt "$jobs_cap" ]; then
                echo "fm-pc02-test-offload: capping --jobs $v to $jobs_cap (${remote_threads} PC02 threads across ${SLOTS} slot(s))" >&2
                v=$jobs_cap
              fi
              ;;
          esac
          remote_args+=("--jobs" "$v")
          jobs_i=$((jobs_i + 2))
          continue
          ;;
        --jobs=*)
          v=${a#--jobs=}
          case "$v" in
            ''|*[!0-9]*) ;;
            *)
              if [ "$v" -gt "$jobs_cap" ]; then
                echo "fm-pc02-test-offload: capping --jobs $v to $jobs_cap (${remote_threads} PC02 threads across ${SLOTS} slot(s))" >&2
                v=$jobs_cap
              fi
              ;;
          esac
          remote_args+=("--jobs=$v")
          jobs_i=$((jobs_i + 1))
          continue
          ;;
      esac
      remote_args+=("$a")
      jobs_i=$((jobs_i + 1))
    done
  fi
  remote_suite_cmd="setsid timeout --kill-after=10 $(printf '%q' "$RUN_TIMEOUT") env FM_PC02_OFFLOAD_REMOTE=1"
  if [ "$has_jobs" -eq 0 ]; then
    remote_suite_cmd="$remote_suite_cmd FM_TEST_RUN_AUTO_JOBS_MAX=$(printf '%q' "$REMOTE_JOBS")"
  fi
  remote_suite_cmd="$remote_suite_cmd bin/fm-test-run.sh"
  for a in ${remote_args[@]+"${remote_args[@]}"}; do
    remote_suite_cmd="$remote_suite_cmd $(printf '%q' "$a")"
  done
  # No --jobs is forced: fm-test-run.sh's own scheduler admits only
  # proven-concurrent work, exactly as a local run does; only its worker
  # ceiling and the per-script bound are pinned. An explicit caller --jobs is
  # capped above so all the slots together stay within PC02's thread
  # count.
  remote_suite_cmd="$remote_suite_cmd --per-script-timeout-secs $(printf '%q' "$SCRIPT_TIMEOUT")"
fi
# The watcher reads the ssh stdin: if the transport drops, EOF kills the
# command session. The lock (fd 8) is held by the run itself, so a surviving
# old run keeps the slot until it actually terminates.
# Keep job control off: setsid must exec in place so $! is the session ID
# written to pgid and used to clean up the complete command session.
remote_test_cmd="exec 5<&0
ulimit -Sn \"\$(ulimit -Hn)\" 2>/dev/null || true
# Keep every run-scoped temp root inside this run's mirror, so the mirror
# cleanup below is the one owner of reaping it even when the suite is killed
# outright and its own EXIT trap never gets to run. REMOTE_RUN is relative to
# PC02's $HOME, so resolve it to an absolute path, create the temp root, and
# only then change into the worktree; a failed resolution must stop the run
# rather than silently leave TMPDIR empty.
run_dir=\$(cd $(printf '%q' "$REMOTE_RUN") && pwd) || exit 1
mkdir -p \"\$run_dir/tmp\" || exit 1
printf '%s\\n' $(printf '%q' "$ROOT") > \"\$run_dir/local-root\" || exit 1
export TMPDIR=\"\$run_dir/tmp\"
cd \"\$run_dir/worktree\" || exit 1
flag=\$HOME/$(printf '%q' "$PERSONAL_USE_FLAG")
$remote_suite_cmd &
pgid=\$!
echo \"\$pgid\" > \"\$run_dir/pgid\"
(exec 8>&-; while read -r _; do :; done; pkill -KILL -s \"\$pgid\" 2>/dev/null) <&5 &
watcher=\$!
# Watch the same flag the admission probe read, so a flip after the run started
# stops this run's own process session instead of letting a full suite keep
# holding PC02 while the captain uses it.
( exec 8>&-; while kill -0 \"\$pgid\" 2>/dev/null; do
    if [ -f \"\$flag\" ]; then
      : > \"\$run_dir/stopped\"
      pkill -TERM -s \"\$pgid\" 2>/dev/null
      sleep 5
      pkill -KILL -s \"\$pgid\" 2>/dev/null
      exit 0
    fi
    sleep 2
  done ) &
flag_watcher=\$!
wait \"\$pgid\"
rc=\$?
kill \"\$watcher\" \"\$flag_watcher\" 2>/dev/null
pkill -KILL -s \"\$pgid\" 2>/dev/null
if [ -e \"\$run_dir/stopped\" ]; then
  printf '%s\\n' 'fm-pc02-test-offload: stopped: personal use'
fi
exit \"\$rc\""
# printf %q keeps the multiline command as one protocol line. Execution is
# inside the lock-owning SSH shell, so its descendants also retain the lock.
printf '%s\n' "$(printf '%q' bash) -c $(printf '%q' "$remote_test_cmd")" >&6 || exit 1
tee "$claim_tmp/stream" <&7 6>&- &
stream_pid=$!
wait "$claim_pid"
rc=$?
claim_pid=
wait "$stream_pid" || true
if [ "$rc" -eq 124 ]; then
  echo "fm-pc02-test-offload: remote run on PC02 exceeded ${RUN_TIMEOUT}s (FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS); failing rather than doubling the budget with a local retry" >&2
fi
if grep -qxF 'fm-pc02-test-offload: stopped: personal use' "$claim_tmp/stream" 2>/dev/null; then
  stop_personal_use
fi

# A --json artifact lands on PC02's mirror; pull it back so callers reading the
# local path (no-mistakes evidence, hint-drift checks) still see it.
json_path=
prev=
for a in ${ARGS[@]+"${ARGS[@]}"}; do
  [ "$prev" != "--json" ] || json_path="$a"
  case "$a" in
    --json=*) json_path="${a#--json=}" ;;
  esac
  prev="$a"
done
if [ -n "$json_path" ]; then
  case "$json_path" in
    /*) remote_json="$json_path"; local_json="$json_path" ;;
    *) remote_json="$REMOTE_WORKTREE/$json_path"; local_json="$ROOT/$json_path" ;;
  esac
  mkdir -p "$(dirname "$local_json")" 2>/dev/null || true
  timeout "$SYNC_TIMEOUT" rsync -az -e "$RSYNC_SSH" "$HOST:$remote_json" "$local_json" >/dev/null 2>&1 \
    || echo "fm-pc02-test-offload: could not retrieve --json artifact from PC02 ($json_path)" >&2
fi

exit "$rc"
