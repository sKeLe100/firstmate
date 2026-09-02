---
name: questionnaire
description: >-
  Walk the captain through the pending decision bundle one interactive batch at a time, recording each ruling durably, and when nothing needs ruling offer a senior-tier project-review scout that refills the bundle with grounded candidate next steps.
  Use when the captain invokes /questionnaire or says he is ready for the decision batch, asks to rule on pending decisions, or asks to be walked through what is waiting on him.
  Never fire autonomously: decisions are filed into the durable bundle as they arise and drained only on the captain's invocation.
user-invocable: true
metadata:
  internal: true
---

# questionnaire

Drain the captain-held decision bundle interactively, or refill it when it is empty.
This skill owns only presentation, batching, and the chat-rulability filter; reading and closing decisions each keep their existing single owner.

## Gather

Run `bin/fm-bearings-snapshot.sh --json` once and read `decisions_open`; its header owns the fields.
Do not build a second decision reader, scrape reports or status tails, or pass `--all-decisions`: date-deferred holds sit in `gates` until due, and a prose-deferred hold disclosed in `omitted[]` stays silent until the captain raises it himself.

## Filter

Present only chat-rulable rows: questions the captain can settle with words now.
Skip silently any hold that merely records a standing order already in force (a stated ruling plus a trigger or cadence, asking nothing).
List separately, read-only and without questions, any hold waiting on a real-world act by the captain - an on-device check, a credential, a purchase - so it is visible but never nagged as a question.
When no chat-rulable rows remain, go to Refill.

## Present

Use the AskUserQuestion tool, at most 4 questions per call, ordered with `declared_priority` rows first (keep the snapshot's order) then oldest-first.
Split a multi-part hold across consecutive calls, keeping its parts contiguous, and never interleave two holds' parts.
Write each question in the captain's nouns per `AGENTS.md` section 9, name the project, put the recommended option first labeled "(Recommended)" when the source report made one, use `multiSelect` for non-exclusive parts, and always allow a deferral answer.

## Record and close

`captain-hold-lifecycle` owns closing; follow it exactly.
Record each ruling with `bin/fm-captain-hold.sh answer <task-id>` carrying the captain's actual words, with `--release` when the answer frees a gated work item rather than completing a question, run in the originating home's `FM_HOME`.
Record "later" as `tasks-axi hold <id> ... --until <date>`, defaulting to +7 days when the captain gives no specific date, and say so.
Close a multi-part hold only when every part is answered, folding all answers into one recorded ruling; otherwise re-hold with the answered parts recorded.
Finish with one plain-chat recap of rulings and deferrals, confirm answered items left `decisions_open` on a fresh snapshot read, and route freed work through the normal lifecycle.

## Refill (no pending decisions)

Say so first; the scout is an offer taken on the same invocation, not a silent substitute.
Run `bin/fm-questionnaire-refill-source.sh`: it finds the newest matching report over `data/*roundtable*/report.md` and `data/*roadmap*/report.md` and prints its path only when it is within the 14-day hard staleness ceiling it owns. It does not judge whether that report's candidates are still open and it dispatches nothing - candidates-first judgment and the sweep dispatch below are this skill's job.
When it prints a path, read that report; if it still names open, undispatched candidates, present those through the Present section above instead of dispatching a scout.
When it exits 1 (no report, its candidates are already spent, or the newest report exceeds the 14-day ceiling), dispatch one scout through the normal lifecycle - scout brief via `bin/fm-brief.sh`, `bin/fm-spawn.sh --purpose investigation`, senior-tier dispatch per `config/crew-dispatch.json` (model reasoning quality is the bottleneck; `quota-array-dispatch` arbitrates within the tier) - to review every registered project in `data/projects.md` except one the captain has explicitly parked (e.g. movie-aggregator): recent landings from git log, PRs, and backlog completions, then 2-4 concrete candidate next steps grounded in that project's own state, report-only, no implementation.
Exit 2 is a usage error, not a scout trigger: surface it to the captain and stop.
On the scout's completion wake, register each candidate needing the captain's pick as a captain-held task per `captain-hold-lifecycle` (one consolidated hold per project), so the next `/questionnaire` drains them through the sections above.
