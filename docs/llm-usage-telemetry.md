# LLM usage telemetry archive

This is the durable, append-only record of local and remote LLM usage that
both firstmate's own dispatch machinery and PC02's llama-swap front door
write into. Nothing in this document renders anything; the `fleet-dashboards`
project owns every rendering surface, including the LLM lab shell, and reads
this archive without either collector knowing it exists.

## Ownership split

- **Firstmate side** (this document's authority, implemented in
  `bin/fm-llm-usage-lib.sh`): purpose tagging, delegation-chain recording,
  and outcome correlation for every crew dispatch, local or remote.
- **PC02 serving side** (the `pc02-llm-lab` secondmate's own work): models
  configured vs resident, per-model call counts, speed, errors, launch
  parameters, and model-swap frequency, emitted from the llama-swap front
  door itself.
- Neither side reads the other's file. A later renderer reads both.

## Format contract (binding on both sides)

- One JSON object per line (JSONL), UTF-8, no trailing comma, newline-terminated.
- **Append-only.** A record, once written, is never edited or rewritten in
  place. A correction is a new record, not a patched old one.
- Each source writes its own file; there is no shared file lock between
  processes on different machines. A record's `source` field, not its file
  path, is the authoritative origin.
- Firstmate's own file: `<data-dir>/llm-usage/firstmate.jsonl`, written by
  `fm_llm_usage_emit` in `bin/fm-llm-usage-lib.sh`, where `<data-dir>` is the
  home's resolved data directory (`<FM_HOME>/data`, or `FM_DATA_OVERRIDE` when
  a caller redirects it). Every persistent firstmate home (the primary and
  each secondmate) writes its own copy under its own data directory; a
  renderer that wants a fleet-wide view merges them by `ts`.
- PC02's file is PC02's own choice of path; document it in `pc02-llm-lab`'s
  own project material so the renderer can find it. This document only binds
  the record shape below, not PC02's file location.
- A missing, unwritable, or partially-written archive is never a dispatch,
  relaunch, or teardown failure on the firstmate side: every write goes
  through `fm_llm_usage_emit`, which is silent on success and logs to
  the home's `llm-usage-write-errors.log` under its resolved state directory
  on failure, without propagating an error.
- No field is ever required to be present with an empty-string value; an
  unknown or not-applicable field is simply absent from that record, and a
  reader must treat a missing key as "unknown", never as false, zero, or
  empty.

## Envelope (every record, both sources)

| field | type | meaning |
|---|---|---|
| `schema_version` | integer | `1` for this contract |
| `ts` | string | UTC timestamp, `YYYY-MM-DDTHH:MM:SSZ` |
| `source` | string | `"firstmate"` or `"pc02-serving"` |
| `event_type` | string | see per-source tables below |

Every other field is event-type-specific and optional per the "absent means
unknown" rule above.

## Firstmate-side event types

### `dispatch` — emitted on every crew dispatch, local or remote

Recorded once per task, at the point `bin/fm-spawn.sh` publishes that task's
`state/<id>.meta`. Covers all dispatches, not only local-model ones, so
local and remote performance sit on the same axis. The captain's own Open
WebUI chats are out of scope here; the serving side classifies those
`interactive` on its own.

| field | meaning |
|---|---|
| `task_id` | the dispatched task's id |
| `kind` | `ship` \| `scout` \| `secondmate` |
| `purpose` | `code` \| `planning` \| `review` \| `summarize` \| `mechanical` \| `investigation` \| `unspecified` |
| `harness` | resolved harness adapter name |
| `model` | resolved model name, when the harness/profile carries one |
| `effort` | resolved effort level, when the harness carries one |
| `backend` | runtime session-provider backend |
| `mode` | delivery mode, ship tasks only |
| `project` | project directory (or secondmate home path for `kind=secondmate`) |

`purpose` is resolved by firstmate at intake, the same way `mode` and `yolo`
are (`AGENTS.md` section 7), and passed to `fm-spawn.sh --purpose`. An
omitted `--purpose` records `unspecified` rather than blocking the spawn.

### `delegation` — emitted on a re-delegation

The highest-value signal per the captain: whether a task changed hands
between models, what went wrong, and where it landed. Covers at minimum:

- **`bin/fm-control.sh relaunch`** (harness/model switch on the same task):
  emitted once the replacement worker is confirmed alive, reusing the
  relaunch's own required `--note`/`--note-file` text as `reason` — no new
  flag needed, since that note already exists to tell the replacement worker
  what happened.
- **A fresh spawn after a failed attempt on the same backlog item**: emitted
  by `bin/fm-spawn.sh` when called with `--redelegated-from <prior-task-id>
  --redelegation-reason <text>`; both are optional and only apply to
  `kind=ship`/`kind=scout` spawns, so an ordinary fresh dispatch is
  unaffected.

| field | meaning |
|---|---|
| `task_id` | the task id this delegation record is filed under (the *new* task for a redispatch, the relaunched task for a relaunch) |
| `from_task_id` | the prior task id, redispatch path only |
| `from_harness` / `from_model` | the model the work started on |
| `to_harness` / `to_model` | the model the work ended up on |
| `had_issue` | `"true"` unless the switch was a deliberate non-failure choice |
| `reason` | free text: what the issue was, or why the switch happened |
| `trigger` | `relaunch` \| `redispatch` |

### `outcome` — emitted at teardown

Wires the honest completion signal back to the model that did the work.
Never synthesizes a quality score from latency or call counts; if the only
available signal is speed, this event says nothing about quality at all.
Emitted once, at the point `bin/fm-teardown.sh` completes for `kind=ship` or
`kind=scout` (secondmates are persistent infrastructure, not backlog work,
and have no outcome to record).

| field | meaning |
|---|---|
| `task_id` | the torn-down task's id |
| `kind` | `ship` \| `scout` |
| `purpose` | copied from the task's `dispatch` record via its meta |
| `harness` / `model` | the model that did the final work on this task |
| `mode` | delivery mode |
| `result` | `landed` \| `abandoned` |
| `pr_url` | the task's PR, when one existed |
| `retried` | `"true"` when a `bin/fm-control.sh relaunch` completed on this task before teardown (a refused or rolled-back attempt does not count), else absent |

`result=landed` means teardown's own landed-work proof passed (the same
proof `fm-teardown.sh` already requires before an ordinary, non-`--force`
teardown). `result=abandoned` means the task was torn down with `--force`
(explicit captain-authorized discard of unlanded work). Neither value says
anything about code quality beyond "did it ship" — CI/check color, when
available, lives in the task's PR itself, not duplicated into this record.

## PC02 serving-side event types (reference only, PC02's own contract)

PC02 implements against the envelope above. The following event types are
suggested, not mandated: `call` (per-completion request, with tokens/sec,
time-to-first-token, wall time, error/failure mode) and `model_swap`
(llama-swap resident-model change). `pc02-llm-lab` may extend or rename
these freely as long as it keeps the shared envelope fields; the join key
between the two archives is `model` (and `task_id` when PC02 can thread a
per-request identifier back from the caller, which is out of scope for this
document to mandate).
