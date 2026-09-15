# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-08-20 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 45356 | `tests/fm-backend-herdr.test.sh` |
| 35415 | `tests/fm-x-mode.test.sh` |
| 35095 | `tests/fm-captain-hold-lifecycle.test.sh` |
| 27529 | `tests/fm-arm-pretool-check.test.sh` |
| 20922 | `tests/fm-test-run.test.sh` |
| 17558 | `tests/fm-crew-state.test.sh` |
| 16582 | `tests/fm-cd-pretool-check.test.sh` |
| 9766 | `tests/fm-lint.test.sh` |
| 9562 | `tests/fm-herdr-lab.test.sh` |
| 6768 | `tests/fm-grok-harness.test.sh` |
| 6290 | `tests/fm-pr-merge.test.sh` |
| 5569 | `tests/fm-composer-ghost.test.sh` |
| 4563 | `tests/fm-send-popup-settle.test.sh` |
| 4021 | `tests/fm-tmux-submit-busy.test.sh` |
| 3544 | `tests/fm-composer-lib.test.sh` |
| 3025 | `tests/fm-send-strict.test.sh` |
| 2753 | `tests/fm-send-settle.test.sh` |
| 2166 | `tests/fm-review-diff.test.sh` |
| 1315 | `tests/fm-brief.test.sh` |
| 975 | `tests/fm-spawn-batch.test.sh` |
| 598 | `tests/fm-pi-primary-types.test.sh` |
| 513 | `tests/fm-ensure-agents-md.test.sh` |
| 331 | `tests/fm-supervision-instructions.test.sh` |
| 99 | `tests/fm-transition-lib.test.sh` |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 134295 ms (~134.3 s) |
| `portable-parallel-2` | 13 | 126020 ms (~126.0 s) |
| imbalance | | 8275 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against the 20-minute job timeout in force at the time.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The 184 current hints are the slowest measurements retained from the `fm-test-timing-portable-serial-*` artifacts of four green CI runs on 2026-09-15, [34921785242](https://github.com/sKeLe100/firstmate/actions/runs/34921785242), [34918872259](https://github.com/sKeLe100/firstmate/actions/runs/34918872259), [34910885603](https://github.com/sKeLe100/firstmate/actions/runs/34910885603), and [34898264601](https://github.com/sKeLe100/firstmate/actions/runs/34898264601), plus a same-day follow-up refresh of 6 scripts (`fm-busy-adapter-wiring`, `fm-codex-continuity-live-e2e`, `fm-pi-branch-extension`, `fm-secondmate-restart`, `fm-spawn-pool-base-freshen`, `fm-watch-arm`) whose hints the newly added `--check-hint-drift` immediately caught as stale against [34941467922](https://github.com/sKeLe100/firstmate/actions/runs/34941467922).
Those per-script maxima total 5484423 ms of conservative balance weight, and every current portable-serial script has a measured hint (`serial_unhinted=0`).
Taking the slowest of several runs rather than a single run keeps the balance honest on a slow runner: individual scripts varied noticeably between those four runs, most sharply `tests/fm-watch-triage.test.sh` (444-484 s) and `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` (roughly 170-312 s).
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default; the coverage guard's `--check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so hint drift fails the coverage guard instead of silently pushing one shard into its job cap.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured or understated scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
That is not hypothetical: by 2026-09-14 the previously recorded hints (last refreshed 2026-09-01, 139 of then-160 scripts hinted) had drifted so far that `fm-watch-triage` measured 444-484 s against a table entry of 262.6 s and `fm-teardown` measured 136-161 s against 97.6 s, and the lane's serial shard 1 ran 19.75 of its 30-minute cap on the 2026-09-14 red main (run history: 3 of the last 100 GHA runs failed on exactly this 600 s per-script tripwire, not a real hang).
`bin/fm-test-run.sh --check-coverage` also verifies the coverage of every currently unhinted or unmeasured script; see "Coverage guard" below for the additional drift check on measured-vs-hinted duration.
Refresh the hints whenever the serial lane gains scripts, or whenever the coverage guard's staleness check (below) reports drift, rather than waiting for the per-script or job tripwire to trip.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of5` | 35 | 1096877 ms (~18.28 min) |
| `portable-serial-2of5` | 36 | 1096892 ms (~18.28 min) |
| `portable-serial-3of5` | 38 | 1096897 ms (~18.28 min) |
| `portable-serial-4of5` | 38 | 1096889 ms (~18.28 min) |
| `portable-serial-5of5` | 37 | 1096868 ms (~18.28 min) |
| imbalance | | 29 ms |

The current table is generated from the runner's retained maxima; every current portable-serial script is hinted (`serial_unhinted=0`).
This fork's worst shard carries ~18.28 min of assignment weight, 61.0% of its 30-minute job cap.

The single longest script, `tests/fm-watch-triage.test.sh` at 480776 ms, is the floor for any shard count.

Refresh the hints by downloading the per-shard timing artifacts from several green CI runs, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`, and updating the table above:

Run this from the home's own clone so `gh` resolves the repository whose CI
produced the artifacts (this home's runs live in its own fork, not the upstream
template); pass `-R <owner>/<repo>` only to target a different repository.

```sh
for run in <run-id> <run-id> <run-id>; do
  gh run download "$run" --pattern 'fm-test-timing-portable-serial-*' -D "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard uploads no artifact, so pick runs where every serial shard is green or the lane's slowest scripts go unmeasured in exactly the shard that needs them most.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It reports the unmeasured serial share as `serial_unhinted=` and refuses when that share exceeds `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so the shards stay balanced on evidence rather than on the default weight.

`--check-coverage` only proves the shard partition is complete and disjoint; it says nothing about whether a *present* hint is still an honest number, so a hint could go stale for months without ever failing anything.
`bin/fm-test-run.sh --check-hint-drift <lane.json> [more lane.json...]` closes that gap: given a green run's per-lane timing artifacts, it takes the slowest measured `duration_ms` per script across every input and refuses when that measured duration exceeds the script's recorded hint by more than `PORTABLE_SERIAL_HINT_DRIFT_MULTIPLIER` (1.5x).
`.github/workflows/ci.yml`'s `Behavior timing aggregate` job runs this automatically against the just-completed portable-serial shard artifacts, after `tests-portable-serial`, so a hint drifting stale (as `fm-watch-triage`'s 262.6 s hint did against a real 444-484 s, and `fm-teardown`'s 97.6 s did against a real 136-161 s, both undetected until the 2026-09-14 red main) now fails CI instead of only costing shard balance.
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
| portable serial 1-5 | job `timeout-minutes: 30`; per-script bound derived by `bin/fm-test-run.sh` | This fork's balanced shards measure about 17.3 minutes of conservative assignment weight, leaving roughly 1.7x hang-tripwire margin for job setup and runner-speed spread. The cap deliberately diverges from the upstream template's 20 minutes, which would leave under 1.15x margin on this fork's lane. The per-script bound is a deliberate second tripwire, added after a single wedged script (a rare bash signal/trap race surfacing during `tests/fm-watch-triage.test.sh`, see run [33776418360](https://github.com/kunchenguid/firstmate/actions/runs/33776418360)) silently consumed the whole 30-minute job with no captured output before GitHub cancelled it. `bin/fm-test-run.sh` derives that bound itself for any `portable-serial` or `portable-serial-<k>of<n>` lane, at `PORTABLE_SERIAL_TIMEOUT_MULTIPLIER` (2x) the slowest hint in `portable_serial_weight_hints`, so `.github/workflows/ci.yml` no longer hard-codes a literal that a hint refresh can leave stale - today that derivation is 2 x 480776 ms rounded up, 962s, comfortably below the 30-minute job cap while still failing a wedged script with its output long before that cap. Pass `--per-script-timeout-secs` explicitly to override the derived bound for one invocation. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finished around 7 minutes before this lane gained `fm-backend-herdr-focus-flash-e2e`, which measures about 2 minutes against a real lab locally, so the step bound is still the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. Refresh this figure from the lane's uploaded timing artifact. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the job-level numbers; `bin/fm-test-run.sh` owns the portable-serial per-script bound, derived from the hint table so it cannot lose margin independently of a hint refresh.

The suspected mechanism behind the wedged script that motivated the per-script bound above is a rare bash async-signal/trap race in `bin/fm-wake-lib.sh`'s lock-wait/handoff path (`_fm_lock_acquire_wait_handoff`, `fm_lock_acquire_wait_bounded`) under external process-group kill; it has not been reproduced locally and `fm-wake-lib.sh` is safety-critical, so no fix has been attempted there pending real reproduction.
