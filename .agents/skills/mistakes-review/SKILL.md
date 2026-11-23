---
name: mistakes-review
description: >-
  Load for a mistakes review pass (at least every 2 days, or when the captain asks), when a ledger entry needs graduation into a rule, guard or tool fix, or when the captain calls out a mistake (log it the same turn).
user-invocable: false
metadata:
  internal: true
---

# mistakes-review

Turn `data/mistakes.md` from a log into a learning loop, without writing laws unasked.
This pass runs in the supervising home, not in a worker: the ledger, recall index, archive, and pass marker are private data only firstmate writes.
The reviewer never applies its own proposals: it returns them for the captain or firstmate to land.
The design and graduation rules are `data/mistakes-log-graduation-scout/report.md` sections 5-9.
That report is the single owner of the ledger schema and size caps, and this skill is the recurring procedure that enforces them.

## A captain call-out is logged the same turn

When the captain calls out a mistake, log it in `data/mistakes.md` in the same turn, before anything else, with `Priority: captain-callout` on its scope / family / state line, and confirm the entry id in the next captain-facing reply.
A call-out is reviewed on the next pass rather than after two recurrences, and it is always a priority item in that pass.
Not logging a mistake is itself a mistake: a task that shipped without a receipt is recorded here too.

## The pass

Run the steps in order and keep the output in the table described below.

1. Reconcile `data/mistakes-index.md` to every ledger entry added since the last pass: family, IDs, symptom aliases, and the live target a reader should consult.
   List every entry the index misses and fix the index rows, not the ledger.
2. Scan the primary and worker transcripts written since the last pass for error-shaped turns: failed commands, rejected edits, repeated retries, wrong assumptions, and tool misuse such as a plain `grep` where a purpose-built search tool or a project's code-graph index exists.
   Do the scan with plain `grep` or `rg` over the transcript files; the scan itself is a scripted search, not a model tool call.
   Log anything missing from the ledger as a new entry with `detected-by=transcript`.
3. Enforce the graduation caps: 32 KiB for the active ledger and 8 KiB / 40 rows for the recall index.
   Overflow moves the closed, eligible entries to `data/mistakes-archive/YYYY-MM-NN.md` and leaves a live pointer behind.
   Never silently delete history, and never claim cap compliance while over it: record a capacity exception and pause new admissions until triaged.
4. Classify each open family as mechanical, mixed, or prose-only, and draft its smallest concrete owner: a test, a `bin/` guard, or a skill.
   Prose is the last resort, and only for the judgment-only remainder.
5. Return the review table and stop.
   Do not edit `AGENTS.md`, a skill, a guard, a tool, or `data/captain.md`; do not merge anything.

## The review table

Return one Markdown table with these columns, plus a short paragraph for anything the table cannot carry:

| Entry / family | Recurrence | State | Class | Proposed owner | Verbatim proposed change |
| --- | --- | --- | --- | --- | --- |

Put the exact, ready-to-apply text in the last column for any `AGENTS.md` or skill change, and the exact command, test path, or code location for any guard or tool fix.
The captain or firstmate lands it; the reviewer only proposes.
An entry that needs no change stays marked `none` with the reason it is already prevented.

## Scheduling

The pass runs at least every 2 days; `bin/fm-timed-dispatch.sh` is the existing scheduler, not cron.
`bin/fm-mistakes-review.sh arm` arms the next pass 2 days out through that mechanism and wakes firstmate to run it; `arm --in 60` bootstraps the first pass.
After every pass, run `bin/fm-mistakes-review.sh mark` to record the completed pass, which is also the transcript-scan cursor, then `bin/fm-mistakes-review.sh arm` to arm the next one.
`bin/fm-mistakes-review.sh due` exits 0 when a pass is due, so a heartbeat or session start that finds it due re-arms a missed pass rather than waiting for a wake that never came.
The armed wake names `mistakes-review`; firstmate runs this pass itself when that wake fires, because a worker cannot write the private index, archive, or pass marker.
