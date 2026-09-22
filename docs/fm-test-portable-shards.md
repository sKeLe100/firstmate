# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Balance hints come from serial runs of the real lanes on `ubuntu-latest`.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

The retained hints are the slowest completed value each script reached across six CI runs on 2026-09-10: [34459949083](https://github.com/kunchenguid/firstmate/actions/runs/34459949083), [34460760299](https://github.com/kunchenguid/firstmate/actions/runs/34460760299), [34462530836](https://github.com/kunchenguid/firstmate/actions/runs/34462530836), [34462758357](https://github.com/kunchenguid/firstmate/actions/runs/34462758357), [34466966385](https://github.com/kunchenguid/firstmate/actions/runs/34466966385), and [34470382458](https://github.com/kunchenguid/firstmate/actions/runs/34470382458).
Shard 2 completed in all six, so its scripts come from the uploaded `fm-test-timing-portable-parallel-2` artifacts.
Shard 1 was cancelled at its job cap in five of the six, so its scripts come from the `FM_TEST_END duration_ms=` markers in each cancelled job's log, which record every script that finished before the cancellation, plus the one complete `fm-test-timing-portable-parallel-1` artifact from run 34462758357.
Observed maxima provide conservative packing weights, not an upper bound on future durations.

The measurements cover all 24 candidates, with six samples per script except:

| Samples | Scripts |
|---:|---|
| 4 | `tests/fm-lint.test.sh` |
| 3 | `tests/fm-pi-primary-types.test.sh`, `tests/fm-review-diff.test.sh` |
| 1 | `tests/fm-brief.test.sh`, `tests/fm-transition-lib.test.sh` |

The two scripts with one sample are the tail of shard 1 that only the complete run reached.
Collect completed per-script measurements for every member before calculating a split.
A cancelled lane's elapsed duration is only a lower bound; its unfinished scripts have no completed duration for that invocation.
The complete historical run supplies tail-script hints, not a completion time for any later cancelled invocation or for the rebalanced jobs.

## Parallel lanes

The two parallel lanes use longest-processing-time assignment over those hints.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships and lane-specific prerequisite constraints beside `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap and its rationale are owned by [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the lane sums to differ by no more than five percent of the larger sum.
Its scheduling regressions also check stored parallel lane order and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `portable_parallel_weight_hints` with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-parallel-*` artifacts whenever the parallel set gains scripts or a member grows materially.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against the 20-minute job timeout in force at the time.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The embedded hints include the slowest measurements retained from the `fm-test-timing-portable-serial-*` artifacts of three green CI runs on 2026-09-01, [33558082172](https://github.com/kunchenguid/firstmate/actions/runs/33558082172), [33523597838](https://github.com/kunchenguid/firstmate/actions/runs/33523597838), and [33463326167](https://github.com/kunchenguid/firstmate/actions/runs/33463326167), the completed-script measurements from [run 34342484144](https://github.com/kunchenguid/firstmate/actions/runs/34342484144), plus the 5121 ms native-Windows focused runner measurement for `tests/fm-pi-windows-shell-invocation.test.sh` from 2026-09-06T21:02Z.
The 40 scripts the 2026-09-14 upstream sync brought into the lane without a hint (26 fork-only scripts and 14 upstream scripts) take the slowest `fm-test-timing-portable-serial-*` measurement across three green fork runs on 2026-09-14, [34898264601](https://github.com/sKeLe100/firstmate/actions/runs/34898264601), [34892839508](https://github.com/sKeLe100/firstmate/actions/runs/34892839508), and [34888276335](https://github.com/sKeLe100/firstmate/actions/runs/34888276335), and three green upstream runs the same day, [34905271653](https://github.com/kunchenguid/firstmate/actions/runs/34905271653), [34905197169](https://github.com/kunchenguid/firstmate/actions/runs/34905197169), and [34884602287](https://github.com/kunchenguid/firstmate/actions/runs/34884602287).
Taking the slowest of several CI runs rather than a single run keeps the balance honest on a slow runner.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default; the coverage guard's `--check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so hint drift fails the coverage guard instead of silently pushing one shard into its job cap.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured or understated scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
That is not hypothetical: by 2026-09-14 the previously recorded hints (last refreshed 2026-09-01, 139 of then-160 scripts hinted) had drifted so far that `fm-watch-triage` measured 444-484 s against a table entry of 262.6 s and `fm-teardown` measured 136-161 s against 97.6 s, and the lane's serial shard 1 ran 19.75 of its 30-minute cap on the 2026-09-14 red main (run history: 3 of the last 100 GHA runs failed on exactly this 600 s per-script tripwire, not a real hang).
`bin/fm-test-run.sh --check-coverage` also verifies the coverage of every currently unhinted or unmeasured script; see "Coverage guard" below for the additional drift check on measured-vs-hinted duration.
Refresh the hints whenever the serial lane gains scripts, or whenever the coverage guard's staleness check (below) reports drift, rather than waiting for the per-script or job tripwire to trip.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size, shard composition, and balance rather than a copied table.
Run 34342484144 observed a shard reach about 20 minutes of passing work, so the 40-minute job cap keeps meaningful hang-tripwire margin for job setup and runner-speed spread.

The single longest script, `tests/fm-watch-triage.test.sh`, is the floor for any shard count.
Its hint is the 600031 ms floor measured on the 2026-09-14 upstream sync (run 34911977448 terminated it at the then-600s per-script bound after both parents measured 414-564 s), so refresh it from the next green serial timing artifacts.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs and replacing `bin/fm-test-run-portable-serial-hints.tsv` with the slowest measured `duration_ms` per `path`:

Run this from the home's own clone so `gh` resolves the repository whose CI
produced the artifacts (this home's runs live in its own fork, not the upstream
template); pass `-R <owner>/<repo>` only to target a different repository.

```sh
for run in <run-id> <run-id> <run-id>; do
  gh run download "$run" --pattern 'fm-test-timing-portable-serial-*' -D "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) printf "%s\t%s\n", p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard uploads no artifact, so pick runs where every serial shard is green or the lane's slowest scripts go unmeasured in exactly the shard that needs them most.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It reports the unmeasured serial share as `serial_unhinted=` and refuses when that share exceeds `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so the shards stay balanced on evidence rather than on the default weight.

`--check-coverage` only proves the shard partition is complete and disjoint; it says nothing about whether a *present* hint is still an honest number, so a hint could go stale for months without ever failing anything.
`bin/fm-test-run.sh --check-hint-drift [--hint-drift-history <path>] <lane.json> [more lane.json...]` closes that gap: given a green run's per-lane timing artifacts, it takes the slowest measured `duration_ms` per script across every input and flags it when that measured duration exceeds the script's recorded hint by more than `PORTABLE_SERIAL_HINT_DRIFT_MULTIPLIER` (1.5x).
A script that drifts on only one run is logged as a `::warning::`, not a failure - shared-runner noise can swing a single ordinary green run past the margin without the hint actually being stale (this is what forced the multiplier to 2x for a while; see git history). `--hint-drift-history` persists this run's drift set to `<path>` and compares it against what was persisted there on the previous run; the check refuses only when the *same* script drifts on two consecutive runs, so a genuine, sustained regression still gets caught while a lone noisy run no longer produces a false red. Without `--hint-drift-history` nothing can ever be confirmed twice, so the check can only warn.
`.github/workflows/ci.yml`'s `Behavior timing aggregate` job runs this automatically against the just-completed portable-serial shard artifacts, after `tests-portable-serial`, restoring and saving the history file across runs via `actions/cache` (keyed per run, with a prefix `restore-keys` to pick up the latest prior one) so a hint drifting stale for two consecutive runs (as `fm-watch-triage`'s 262.6 s hint did against a real 444-484 s, and `fm-teardown`'s 97.6 s did against a real 136-161 s, both undetected until the 2026-09-14 red main) fails CI instead of only costing shard balance.
Refresh the table per the procedure above when this check fails.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | job `timeout-minutes: 10` | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-5 | job `timeout-minutes: 40`; per-script bound derived by `bin/fm-test-run.sh` | Current runners can take about 20 minutes; the 40-minute cap remains a hang tripwire while leaving margin for job setup and runner-speed spread, and diverges from the upstream template's 20 minutes because this fork's merged lane measured a shard at 26.5 minutes (run 34911977448). The per-script bound is a deliberate second tripwire, added after a single wedged script (a rare bash signal/trap race surfacing during `tests/fm-watch-triage.test.sh`, see run [33776418360](https://github.com/kunchenguid/firstmate/actions/runs/33776418360)) silently consumed the whole job with no captured output before GitHub cancelled it. `bin/fm-test-run.sh` derives that bound itself for any `portable-serial` or `portable-serial-<k>of<n>` lane, at `PORTABLE_SERIAL_TIMEOUT_MULTIPLIER` (2x) the slowest hint in `portable_serial_weight_hints`, so `.github/workflows/ci.yml` no longer hard-codes a literal that a hint refresh can leave stale - today that derivation is 2 x 600031 ms rounded up, 1201s, comfortably below the 40-minute job cap while still failing a wedged script with its output before the job cap. Pass `--per-script-timeout-secs` explicitly to override the derived bound for one invocation. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finished around 7 minutes before this lane gained `fm-backend-herdr-focus-flash-e2e`, which measures about 2 minutes against a real lab locally, so the step bound is still the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. Refresh this figure from the lane's uploaded timing artifact. |

Timeouts are hang tripwires rather than expected healthy durations; a passing coverage guard does not establish a healthy job duration.
`.github/workflows/ci.yml` owns the job-level numbers; `bin/fm-test-run.sh` owns the portable-serial per-script bound, derived from the hint table so it cannot lose margin independently of a hint refresh.

The suspected mechanism behind the wedged script that motivated the per-script bound above is a rare bash async-signal/trap race in `bin/fm-wake-lib.sh`'s lock-wait/handoff path (`_fm_lock_acquire_wait_handoff`, `fm_lock_acquire_wait_bounded`) under external process-group kill; it has not been reproduced locally and `fm-wake-lib.sh` is safety-critical, so no fix has been attempted there pending real reproduction.
