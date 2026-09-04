---
name: queue
description: Show the next queued work items at a glance, grouped by whether each is dispatchable, blocked, needs the captain, or deferred - project, kind, age, dispatch tier. Use when the captain invokes /queue (or `/queue lanes` for the full lane hierarchy, `/queue priority` for the old flat priority-sorted view) or asks "what's queued", "what's next", "show me the queue", or similar.
user-invocable: true
metadata:
  internal: true
---

# queue

Give the captain a concise, scannable list of the next queued work so they can see at a glance what is coming and decide what to dispatch.
This skill is read-only.
It never dispatches, steers, holds, blocks, reorders, or otherwise mutates the backlog or any task state.

## What it does

1. **Gather with one deterministic command.**
   Run `bin/fm-queue-snapshot.sh` (default 30 items) and read its output.
   It is the single bounded, deterministic source for this listing: it shells out to `tasks-axi list --state queued` for every queued item, sorts the full set by gate class then project then newest-first by default (or by descending `priority` when the captain invoked `/queue priority`, tiebreak: tasks-axi's own return order), takes the top N, and enriches each row with more deterministic facts tasks-axi does not itself carry: `rank` (the 1-based position after that sort), `posture` (that item's project delivery mode/yolo, from `bin/fm-project-mode.sh`, the single owner of `data/projects.md` parsing), a derived `autonomy` verdict, and a derived `gate` verdict.
   `kind` and `created` ride through from tasks-axi's own item record unmodified; do not derive or guess either.
   The snapshot's `gate` field is one of `dispatchable`, `blocked`, `captain`, or `deferred-until <date>`, already derived from that row's own `blocked`/`hold_until` fields and its `autonomy` verdict; never re-derive it from the title or your own read of the item.
   When the snapshot's `hidden[...]` rows are present (only when `--limit` truncated the full queued set), it is the per-repo breakdown of the items the limit cut, from the same full queued set `total_queued` counts, sorted by descending count.
   If the captain invoked `/queue lanes`, pass `--limit` unchanged but still read the full `hierarchy_lanes` block per step 2's lanes branch below; the item list and hidden summary render exactly as usual either way.
   If the captain invoked `/queue priority` (or otherwise explicitly asked for the old priority-sorted view), pass `--priority` to the script and render the item list as one flat priority-ranked list exactly as this skill did before gate-class grouping existed - do not split it into the four gate-class sections in that case. `lanes` and `priority` compose: pass both flags when the captain asked for both.
   Do not create or consult a second backlog reader, a second `data/projects.md` parser, a second priority sort, or a raw `tasks-axi list`/`data/backlog.md` read as a substitute.
   Its `items[...]` rows are RFC4180 CSV, one line per item, with any newline, carriage return, or tab inside a value written as the literal `\n`/`\r`/`\t` and any literal backslash doubled to `\\`; read them as CSV, not as TOON, and undo that escaping before showing a title or reason to the captain (`C:\\path` is really `C:\path`).
   The script's own header owns its exact fields, sort/tiebreak rule, and derivation rules; do not restate its logic here beyond what this skill needs to render.

2. **Open with a one-line availability summary, before the numbered list; show the full hierarchy only under `/queue lanes`.**
   Read the snapshot's `hierarchy_lanes` and `live_slots` fields.
   By default (no `lanes` argument), render one summary line above the numbered items, never after: for each `for` group that has at least one row with `available: no` or `available: unknown`, name it as constrained (e.g. "senior lanes at 20%" using that group's lowest numeric `<n>%` remaining reason when one is present, else "senior lanes unknown"); groups where every row is `available: yes` are named together as available (e.g. "standard/fast available"). Join the constrained and available clauses into one line, e.g. "senior lanes at 20%; standard/fast available." Append `live_slots` to the same line, e.g. "; 2 slots live." When `hierarchy_lanes` is unavailable for any reason (see below), the summary line states that reason plainly instead and still appends `live_slots`.
   When the captain invoked `/queue lanes`, instead render the full per-tier detail block this step used to always show: group `hierarchy_lanes[...]` rows by `for` (each rule's own `when` text, or `default (no rule matched)`) and list every row's `harness`/`model`/`effort` with its `available` verdict, rendering `yes` as "available now", `no` as "unavailable (<reason>)", and `unknown` as "unknown (<reason>)" - never upgrade an `unknown` to a guessed available or unavailable - followed by `live_slots` on its own line. Use each row's own `for` text as the task-class label verbatim; never substitute a fixed label (such as "senior"/"standard"/"fast") that is not what the configured rule actually says, since this header must stay driven by `config/crew-dispatch.json` and never hardcoded. A harness with no configured rule (for example a retired subscription with no matching entry in `config/crew-dispatch.json`) never appears here - the snapshot only ever reports lanes the config itself defines, so there is nothing to filter out on this side.
   In both forms, when `hierarchy_lanes: unavailable (dispatch_config: <status>)`, say once that no lane hierarchy can be shown for that reason (for `absent`/`invalid`/`unverified`, the same explanation used for per-item tiers below; `unreadable` means the config went away between the validity check and this read, so report it as a transient read failure and do not fall back to a remembered lane set); when it is instead `hierarchy_lanes: unavailable (config defines no dispatch profiles)`, say once that the dispatch config is readable but defines no lanes. Its `hierarchy_lanes[...]` rows are RFC4180 CSV with the same one-line-per-row escaping as `items[...]` below (`\n`/`\r`/`\t` for newline, carriage return, and tab; `\\` for a literal backslash); read them as CSV and undo that escaping before showing a `for` text or availability reason, so a rule whose `when` is `hard, ambiguous, or high-stakes work` stays one lane group rather than three.
   Render `live_slots` as the count of dispatched worker slots currently tracked (persistent secondmates are excluded, since they hold no dispatch slot); firstmate has no configured concurrency cap by default, so state that plainly rather than inventing or asking about a cap that may not exist.

3. **When the snapshot reports `total_queued`, say so up front so a capped list is never mistaken for the whole queue, and follow it with the hidden-by-project breakdown.**
   That field is present only when the requested limit truncated the full queued set; when present, open the list with a line such as "showing N of M queued" (N = `count`, M = `total_queued`) before the numbered items. When it is absent, nothing was truncated - render the list exactly as before, with no such line.
   When `total_queued` is present, the snapshot also reports `hidden[...]` rows (the per-repo counts of exactly the items the limit cut, from the same full queued set `total_queued` counts). Render one line summarizing it right after the "showing N of M" line, e.g. "hidden: 41 firstmate, 15 pc02, 9 no project" - use "no project" for the `repo` value `-`, sort as the snapshot already sorted (highest count first), and name every repo the snapshot lists rather than truncating the breakdown. When `hidden[...]` has no rows (`total_queued` absent), skip this line entirely.

4. **By default, render four gate-class sections in order; number each item from the snapshot's own `rank`, and never drop a gated item silently.**
   Unless `--priority` was passed (see step 1), group the returned items into four sections, in this fixed order, using each item's own `gate` field: **Dispatchable**, **Blocked**, **Needs the captain** (`gate: captain`), **Deferred** (`gate: deferred-until <date>` - subgroup or label by date when more than one distinct date appears). Skip a section entirely when it has no items; never print an empty section header.
   Within each section, group items by `project` as the secondary key (repo `-` renders as "no project", grouped last). When a project's items in that section number more than ~5, collapse that project's group to one count line (e.g. "firstmate: 12 more dispatchable items - ask by project for the list") instead of listing every item; otherwise list them individually. Order items within a group newest-first by `created` (an item with no `created` sorts last within its group); in the Deferred section the snapshot already orders each project's items by hold date ascending first, so its date subgroups appear in that order with contiguous ranks.
   Still render every item the snapshot returns somewhere in these sections (individually or folded into a collapsed count line) - the captain asked to see the true shape of the queue, and quietly dropping items would misrepresent it.
   Number each individually-rendered item by its snapshot `rank` - never renumber, re-sort within a group, or re-order by your own judgment, since the snapshot already produced this exact order.
   Mark a gated item's own reason inline on its detail line: blocked items name what they are blocked by, held items give the hold's reason (and its `hold_until` date when set); an item with neither `blocked: yes` nor `held: yes` needs no gate note beyond the section it is already sorted into.
   When `--priority` was passed instead, skip this grouping and render the flat priority-ranked list exactly as before (numbered by `rank`, gate notes still inline per item, no section headers).
   In that `--priority` view, read the snapshot's `priority_analysis` line to decide how to describe the sort. The line has the form `priority_analysis: priority_meaningful: <yes|no> (N/M items have priority, P%)`. When `priority_meaningful` is `no` (fewer than 20% of the full queued set carries a numeric priority value), do NOT describe the list as "sorted by priority" - with so few prioritized items that framing is misleading and the listing is mostly showing insertion order for the unprioritized bulk. Instead, state the sort honestly: "the N prioritized items first, then the rest in backlog order" (adjusting N to whatever the actual count is). When `priority_meaningful` is `yes`, describe the list as "sorted by priority" as usual. Either way, the snapshot's own `rank` field numbers the rows.

5. **Resolve each item's dispatch tier by the same judgment real dispatch uses - never by running quota.**
   If the snapshot reports `dispatch_config: absent`, no per-item tier can be resolved; say so once for the whole list rather than repeating a caveat on every bullet, and note that a spawn without configured profiles falls back to `config/crew-harness`.
   If it reports `dispatch_config: invalid`, say once that the dispatch profile file is present but invalid and tiers are unavailable until it is fixed, per `docs/configuration.md`'s `CREW_DISPATCH: invalid` diagnostic - the snapshot applies that same validity contract, so a file that merely parses as JSON but breaks a rule (missing `when`, empty `default`, unverified harness, unsupported effort) reports `invalid` here too. Do not match tiers against a config in that state; a tier real dispatch would refuse is worse than no tier.
   If it reports `dispatch_config: unverified`, `jq` is missing so the config's validity could not be checked; say that once and skip tier matching for the same reason, and note that `jq` is a bootstrap-required tool.
   If it reports `dispatch_config: present`, read `config/crew-dispatch.json` yourself and, for each item, match its title/kind against the rules' natural-language `when` conditions exactly as `AGENTS.md` section 4 has firstmate do at real dispatch time; use the first rule that fits, or `default` when none fits.
   Render the matched profile(s) as the tier: a single profile shows its harness, model (if given), and effort; a profile array shows every candidate separated by `|`, labelled as candidates, e.g. `senior tier: codex gpt-5.5 high | claude sonnet-5 high`.
   Do NOT call `quota-axi` to narrow an array down to one pick for this listing - that is a per-item live quota read the captain explicitly asked this listing to avoid, and thirty of them is not worth the cost for a view.
   State plainly, once, that concrete profile-array selection happens at dispatch time via `quota-array-dispatch`, not in this listing.

6. **Report autonomy exactly as the snapshot derived it, translated to plain language.**
   The snapshot's `autonomy` field is already derived, never guessed: `captain-gated` when the item's own kind is `captain` or it carries a captain-kind hold, or when its project's registry posture has yolo off; `autonomous-eligible` when none of those hold and yolo is on; `unclear` only when the item carries no captain-kind signal and no project to check (repo empty AND no id-prefix match), which this skill must render as an honest "unclear" rather than picking a side.
   Render `autonomous-eligible` as "clears itself", `captain-gated` as "needs you", and `unclear` as "unclear - ask me about it".
   When `autonomy_reason` is exactly `project inferred from id prefix`, append " (inferred)" to that rendered label - e.g. "clears itself (inferred)" or "needs you (inferred)" - so the captain can tell a resolved-by-repo verdict from one resolved by matching the id's prefix against a registered project.
   Never override or re-derive this verdict from the title or your own read of the situation; a wrong "clears itself" is worse than an honest "unclear".

7. **Render one numbered, two-line entry per item - a title line and a detail line.**
   Title line: `<rank>. <id>: <short title>`.
   Detail line, indented under it: `project: <project> - kind: <kind> - <age>d - tier: <candidates or the once-stated absent/invalid note> - <autonomy>[ - gated: <reason>]`.
   Compute `<age>d` from the item's `created` field as whole days elapsed since that date (today's date is available to you); when `created` is empty for an item, render `age: unknown` in its place instead of a day count rather than guessing.
   Render `kind` verbatim as tasks-axi reports it (scout/ship/task/captain/etc).
   Truncate a long title to stay scannable; the id is always exact so the captain can ask about it by name.
   Put no other field on either line - no dates, no hold details beyond the one-line gate note, no body text, no links.
   End the list with one short line making clear that any item can be asked about by id or description for full detail (body, blockers, dependencies, links) via `tasks-axi show <id> --full`, and that the list above is deliberately everything-else-omitted.

8. **Answer follow-up questions about one item read-only.**
   When the captain asks about a specific item, run `tasks-axi show <id> --full` (or `tasks-axi list --repo <name>` for "what else is queued for X") and answer from that, still without mutating anything.

## Not covered

- Per-host local lane detail (the PC02 local dispatch tier) is deliberately out of scope for this header: the `pc02-local-dispatch-tier-rule` it would depend on is not verified in `config/crew-dispatch.json`, so the lane hierarchy reports only the account-wide lanes the config actually defines. Do not synthesize a local PC02 lane from host knowledge.

## Empty and degraded cases

- Zero queued items: say plainly that nothing is queued right now.
- `tasks-axi` missing or erroring: the snapshot script fails loudly; relay that the backlog could not be read rather than showing an empty list.
- No project recorded on an item: its posture is `n/a`, and its autonomy is `unclear` unless the item is captain-kind (stays `captain-gated`) or the snapshot inferred a project from its id prefix (see step 6), which resolves posture/autonomy from that inferred project instead; say so rather than assuming either way.

## Tone

Follow `AGENTS.md` section 9: plain outcomes, the captain's own nouns, full `https://...` PR links if any item's note references one, and the mandatory direct address to the captain.
Task ids, project names, and dispatch tier details are the literal content the captain asked this listing for, not internal jargon to translate away.
