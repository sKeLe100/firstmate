# Live validation — `bin/fm-pc02-test-offload.sh` wait-for-slot (fm/pc02-offload-wait-for-slot)

Baseline already run by the executor: `bin/fm-test-run.sh --changed --exclude-family real-herdr-gated --exclude-quarantined --pc02-if-idle`.

## What was driven

`bin/fm-pc02-test-offload.sh` (the real product) was driven end-to-end, both against a
fixture PC02 whose `ssh`/`rsync` fake only the network host (readiness probe, kernel slot
locks, mirror sync, remote suite all real) and against the real `pc02` host (16 threads,
idle). Driver: `scenario-driver.sh`; transcripts: `raw-*.log`; regression suite:
`focused-test-suite.log` (`bash tests/fm-pc02-test-offload.test.sh`, 61 cases, exit 0).

| # | Scenario (user action → observable result) | Result |
|---|---|---|
| a | Six slots configured, all six held → the run waits (`waiting up to 120s for a free slot`), takes the slot that frees (`claimed PC02 slot 3 of 6`) and runs the suite on PC02, never `running on PC01` | pass |
| b | Six slots configured → six concurrent offloads claim six distinct slots (`1 of 6` … `6 of 6`), a seventh sees `all 6 PC02 test slots are busy`, and each slot is capped at `auto_jobs=2` (16 threads / 6 slots) | pass |
| c | All slots held and the bound expires → `stayed busy through the 4s wait bound; running locally` after waiting ≥4s, the real local suite runs with the forwarded arguments | pass |
| d | Personal-use switch on, missing tool, missing resource-check script, unreachable host → each routes to PC01 at once under a 600s bound, naming its reason (including the resource-check path) | pass |
| e | The pinned entry `bin/fm-test-run.sh --pc02-if-idle --max-wall-ms …` with all slots busy → immediate `all 6 PC02 test slots are busy; running locally`, no wait spent from the caller's budget | pass |
| f | A live LLM lane holds PC02 → the run waits (`waiting up to 60s`), `PC02 is free again after 4s`, then claims a slot and runs remotely; nothing reached PC02 before the lane cleared | pass |
| g | A lane that never clears → falls back on time (`and still so after the 3s wait bound; running on PC01`), real local suite runs, PC02 never reached | pass |
| h | Malformed `FM_PC02_OFFLOAD_SLOT_WAIT_SECS` / `_INTERVAL_SECS` / `FM_PC02_OFFLOAD_GATE_RECHECK_SECS` → exit 2 naming knob and value, no suite runs; `--help` documents both new knobs and makes no `non-negative` claim the code rejects | pass |
| i | Real `pc02`: with a disposable slot file of 6 the run reports `claimed PC02 slot 1 of 6` and `running tests remotely on pc02`, suite `exit=0`; with this home's real config (no slot file) it reports `claimed PC02 slot 1 of 2` | pass |

## Note on “6 slots now”

The change makes the count configurable (`FM_PC02_OFFLOAD_SLOTS` → `${XDG_CONFIG_HOME:-$HOME/.config}/firstmate/pc02-offload-slots` → default 2) and re-reads it every run. On this home the
slot file does not exist yet, so a real run today reports `1 of 2`; the shipped operator step
(docs/configuration.md) is to write `6` to that file after merge. With the file present the
same real host reports `1 of 6`, and six concurrent offloads are admitted (scenario b/i).
