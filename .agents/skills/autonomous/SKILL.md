---
name: autonomous
description: >-
  Run an autonomous dispatch pass: evaluate open decisions for bundling,
  check whether nudge thresholds are met, and execute a structured
  dispatch cycle that minimizes unnecessary captain contact.
  Use when the captain invokes /autonomous, mentions standing orders
  or autonomous dispatch, or when a silent-invocation point (12:30/17:30
  fleet-dispatch-points) fires.
user-invocable: true
metadata:
  internal: true
---

# autonomous

Autonomous dispatch pass.
When invoked, `/autonomous` evaluates open decisions for bundling,
checks whether nudge thresholds are met, and executes a structured
dispatch cycle that minimizes unnecessary captain contact.

## 2. Name and triggers

Name: `/autonomous` (not `/standing-orders`).

Triggers:

- Captain invokes `/autonomous`.
- Captain mentions standing orders or autonomous dispatch.
- A silent-invocation point fires (the 12:30 and 17:30 fleet-dispatch-points,
  folded into this skill per the captain's 2026-09-01 ruling).
- `/nightwatch` calls this pass procedure once it ships
  (see section 6 for the interim: while nightwatch is unarmed, the
  bare night-bucket wake runs the pass directly).

## 3. Decision minimization and bundling

The pass evaluates the open-decision bundle before contacting the captain.
The goal is to batch decisions into a single contact rather than nagging
one-by-one.

Nudge thresholds - contact the captain when either condition holds:

- Bundle size >= 5 chat-rulable decisions.
  A chat-rulable decision is any open captain hold: a decision is simply
  a task held for the captain, and no prose heuristic filters that set.
- Oldest pending decision >= 48 hours old.
  Measure from the decision's creation or last-update time in the
  decision record, not from the last time the captain was shown decisions.

Both thresholds are proposed per the captain's 2026-09-01 ruling
(question Q3) and belong here as this skill's own numbers.

To gather decisions, take step 1's single snapshot read (which sets
`FM_BEARINGS_GATES` so `gates` is not truncated) and read `decisions_open`.
Do not restate a bare snapshot command here: step 1 owns the read.
Do not build a second decision reader, scrape reports or status tails,
or pass `--all-decisions`: date-deferred holds sit in `gates` until
due, and a prose-deferred hold disclosed in `omitted[]` stays silent
until the captain raises it himself.

Read `decisions_open` as an array of rows, each carrying `id`, `key`,
`verb`, `summary`, `owner`, `declared_priority`, `since`, and
`created_at` (the last two per the captain's timestamp ruling: `since`
is the human-readable timestamp of when the captain call was raised, read
from the `held-since` mark in `data/task-marks.tsv` and falling back to the
row's own tasks-axi creation date on rows written before the sidecar
existed; `created_at` is the epoch seconds derived from it, absent when
neither is present).
Step 2's `fm-autonomous-thresholds.sh` call counts only chat-rulable
rows toward the bundle-size threshold and finds the oldest chat-rulable
row by `created_at` for the time-threshold check, counting every open
captain hold. Use
`declared_priority` rows first when ordering the presented bundle at
step 5, then oldest-first by `created_at`.

The captain's attention window is owned by `bin/fm-captain-window.sh`.
Check it before contacting the captain. Step 4 owns the full rule,
including its 48-hour override; follow step 4 rather than any summary
of it here.

The concurrent dispatch cap is owned by `config/dispatch-cap` (optional
and gitignored; the built-in default base is 3 when it is absent),
reduced by the quota ladder read from `quota-axi --json` at dispatch
intake, per `docs/configuration.md`. The effective cap is both together,
never the base alone. Step 3 owns the full rule; check lane occupancy
against it there. Do not hardcode a number here: read the live config
and the live quota.

The dispatch profile is owned by `config/crew-dispatch.json`.
Resolve it before spawning any crewmate.

## 4. The pass procedure

Run these steps in order.
Each step must complete successfully before proceeding to the next.

### Step 0 - Re-read the captain's standing orders

Read `data/captain.md`'s captain preferences and working style before
evaluating anything else.
That file is the captain's durable standing orders for this home, and they
bind this pass exactly as the configured owners below do: a standing order
recorded there needs no restatement in chat to take effect.
When `data/captain.md` is absent, use the firstmate repo's built-in defaults
per `AGENTS.md` and continue the pass - the absent file is not an error, this
step counts as completed successfully, and the pass must not abort, since a
home with no recorded instruction is exactly the one that needs the refill and
stuck-work surfacing below.
The session-start digest prints that file once per session, which is not the
same as this pass reading it: a pass that runs many hours or one context reset
later must read it again rather than relying on what a session happened to
retain.
Where a standing order and this skill's own text disagree, the standing order
wins and the disagreement is a defect in this skill to report, not a conflict
to arbitrate per pass.
Record which standing orders applied; step 10 names them in the pass log.

### Step 1 - Gather decision state

Run `FM_BEARINGS_GATES=500 bin/fm-bearings-snapshot.sh --json`.
Read `decisions_open` from the output. The `FM_BEARINGS_GATES` override
keeps the `gates` projection from being truncated to its default of 20,
so the deferred-ready check later in the pass sees every queued item.
This is the authoritative decision source: do not scrape status lines,
backlog prose, or agent chat for decision state.

### Step 2 - Evaluate nudge thresholds

Pipe the `decisions_open` array into `bin/fm-autonomous-thresholds.sh`,
which is the single owner of the chat-rulable filter, the bundle-size
count, and the 48h-age check. Do not reimplement its counting or
filtering logic inline. It prints `nudge: bundle-size`, `nudge: time`,
`nudge: both`, or `none`, exiting 0 when a nudge is due and 1 otherwise.

This step only decides whether a questionnaire-ready nudge is owed; it
never ends the pass. Record the result (nudge needed or not, and which
threshold) and proceed to step 3 either way, since dispatch work is
independent of whether a decision nudge is due.

### Step 3 - Check dispatch availability

Read the base concurrent dispatch cap from `config/dispatch-cap`.
The effective cap is that base reduced by the quota ladder read from
`quota-axi --json` (schemaVersion 5) at dispatch intake, checked
alongside the base cap rather than replacing it. `docs/configuration.md`
owns the full ladder, including its percent-remaining floor and its
elapsed-time-in-window dimension; read the current numbers there rather
than from any restatement, since a restated threshold here can drift.
Check how many autonomous Claude lanes are currently active against both
the base cap and the ladder before treating a lane as available.
If the cap is at or exceeded, record that new dispatch is deferred due to
dispatch-cap occupancy and skip only steps 7-8 (the dispatch actions) later
in the pass. The cap never suppresses captain contact: steps 4-6 still run,
so an owed nudge still reaches the captain.

Do not hardcode the cap value here: read the live config and the live
quota, and use the built-in default base of 3 when `config/dispatch-cap`
is absent.

The dispatch-cap check above answers only "is there Claude-lane headroom".
It says nothing about PC02: only one PC02 lane may run at a time
(the same rule `bin/fm-spawn.sh`'s `pc02_lane_guard` enforces at spawn
time), so a PC02-routed candidate can read as dispatchable under the
Claude cap while PC02 itself is already held by another task. Before
treating any PC02-routed candidate as dispatchable, separately run
`bin/fm-autonomous-pc02-lane.sh`, which mirrors `pc02_lane_guard`'s
scan-and-liveness read (state/*.meta for a live task on a
pc02-llamaswap/* model, whatever its harness). It prints `free`
(exit 0) or `occupied: <task-id>` (exit 1); if it cannot read the state
directory it prints an error on stderr and exits 2, which is fail-closed -
treat exit 2 exactly like occupied, never as free. When it reports occupied,
defer that candidate specifically - do not fall back to counting it
against, or clearing it via, the generic dispatch-cap headroom - and
continue evaluating any non-PC02 candidates normally.

Neither the cap nor the PC02 lane guard answers whether this HOST can carry
another agent: both are quota and lane accounting, and an agent starved of
memory wedges its pipeline rather than failing to launch.
Before treating any candidate as dispatchable, run
`bin/fm-host-memory.sh`, which reads `MemAvailable` from `/proc/meminfo`
against the floor in `config/host-memory-floor` (absent means the built-in
default). It prints `free` (exit 0) or `low: <available>MiB < <floor>MiB`
(exit 1); an unreadable `/proc/meminfo` or a malformed floor prints an error
on stderr and exits 2, which means the host reading is unavailable: record the
reason and continue evaluating candidates normally rather than deferring
dispatch. Only a `low` reading defers.
When it reports `low`, defer every new dispatch this pass and record the
host-memory reason; `bin/fm-spawn.sh` enforces the same floor at spawn time,
so a candidate dispatched past this check is refused there anyway, except for a `--relaunch`, which is exempt because a same-task replacement is net-neutral and would be measured while the agent it replaces still holds its memory.

### Step 4 - Check the captain's attention window

Run `bin/fm-captain-window.sh` with no flags (`--now` and `--weekday`
are test-only flags). It prints `band=<band> offer=yes|no`.
For the question this step owns - whether to contact the captain with a
nudge - the `offer` field is the single canonical predicate: `offer=yes`
means in-window, `offer=no` means outside. Do not branch on `band` for
that nudge decision.
This step owns the quiet-hours rule for the whole skill:
On `offer=yes`, proceed to step 5.
On `offer=no`, queue the nudge silently for the next window
entry: skip only steps 5-6 and continue at step 7, since the window
gates captain contact, not dispatch.
Two exceptions override the quiet hours. First, when step 2 reported the
time threshold and the oldest pending decision exceeds 48 hours, contact
the captain anyway - run steps 5-6 despite `offer=no`. Second, on a fleet
stall - every lane blocked or held while at least one row is still
`gate: dispatchable` in `bin/fm-queue-snapshot.sh` - contact the captain
despite `offer=no`, likewise running steps 5-6; `docs/configuration.md`
"Fleet-stall breakout" owns the stall definition and the once-per-episode
reporting rule. Piercing the band permits contact; it does not compel it.
Those are the only quiet-hours overrides.
The attention window schedule is owned by `bin/fm-captain-window.sh`.

### Step 5 - Prepare the nudge message

Run this step and step 6 only when step 2 recorded a nudge as needed.
Otherwise skip directly to step 7.

Compose a single-line batched summary of the decisions in bundle,
ordered with `declared_priority` rows first (keep the snapshot's order)
then oldest-first.
Use the captain's nouns per `AGENTS.md` section 9.
Name the project where relevant.
Put the recommended option first labeled "(Recommended)" when the
source report made one.

The message must be concise: one paragraph, not a multi-line dump.
If the bundle has >= 10 decisions, summarize by project rather than
listing each one individually.

### Step 6 - Present decisions to the captain

Send the batched summary to the captain.
Ask for rulings on each decision, or offer a deferral.
Use `bin/fm-captain-hold.sh` to record rulings durably.
For "later" deferrals, record as `tasks-axi hold <id> ... --until <date>`,
defaulting to +7 days when the captain gives no specific date.

Wait for the captain's response.
If the captain declines to rule on any decision, defer it to the
next pass cycle.

### Step 7 - Execute dispatched work

Skip this step and step 8 when step 3 found the dispatch cap at or exceeded.

For decisions that resolve to dispatching new work, spawn crewmates
through the normal lifecycle per `bin/fm-spawn.sh`.
Resolve dispatch profiles from `config/crew-dispatch.json` before spawning.
Pass the purpose class explicitly to `fm-spawn.sh --purpose`.

For decisions that resolve to reviewing existing work, surface the
review-ready item to the captain.
Do not review work autonomously without captain approval.

### Step 8 - Resolve the senior tier for planning-heavy work

If any dispatched work would normally route to the PC02 lane,
evaluate the 3-part trigger test from section 5.
When the test passes, the work needs the senior tier's plan-then-execute
shape rather than the PC02 lane: resolve it through
`config/crew-dispatch.json`'s senior rule per `quota-array-dispatch`.
That rule's own text carries the captain's 2026-09-07 order, and this step
never overrides it: Fable is never auto-selected here, Opus 5 is the
autonomous senior default, and routing to Fable requires the captain's
explicit per-dispatch approval for that task.
When the test fails, use the PC02 lane directly.

### Step 9 - Refill idle lanes from the queue

Read the queue with `bin/fm-queue-snapshot.sh`, which is the single owner of
the per-item eligibility verdict this step needs.
Step 1's bearings snapshot answers what the captain owes a decision on; it is
not a dispatch source, because its `gates[]` projection carries no item kind,
hold date, or autonomy verdict and so cannot tell a cleared time gate from a
live one. Keep step 1 where it is and read this snapshot here.

Each row carries a `gate` of `dispatchable`, `blocked`, `captain`, or
`deferred-until <date>`, and an `autonomy` of `autonomous-eligible`,
`captain-gated`, or `unclear`, both derived from that row's own fields.
Dispatch rows where `gate` is `dispatchable`, in the order the snapshot
returns them, up to the headroom step 3 found, following the normal dispatch
lifecycle.
That single condition is sufficient because the snapshot already folds
autonomy into the gate: a row is only `dispatchable` when its `autonomy` is
neither `captain-gated` nor `unclear`, so this step cannot dispatch work that
requires a captain decision.
Never re-derive either verdict from a row's title or your own reading of it,
and never widen the filter.
When step 3 found no headroom - the cap, the PC02 lane, or the host-memory
floor - leave the eligible rows queued and record them below instead.

An idle lane with an eligible row is the pass failing, not the queue being
empty: a pass that ends with headroom and an unclaimed `dispatchable` row must
say in the step 10 log line which row it declined and why.

### Step 10 - Record the pass outcome

Log the pass outcome durably.
Record the number of decisions evaluated, the number ruled on, the
number deferred, and the number dispatched.
Append to the pass log: the epoch timestamp, the threshold that fired,
and a one-line summary of outcomes.
Name in that summary the standing orders step 0 applied, and any eligible row
step 9 declined with its reason, so a later pass can see what this one chose
rather than only what it did.
Write that line once, as this step's single append; never go back and amend a
line already appended.

The pass log path is `state/.autonomous-pass-log`.
Each entry is a single line: `<epoch>\t<threshold>\t<summary>`.

### Deferred-ready visibility (end-of-pass reporting)

After step 9, add a deferred-ready line to the pass summary.
Name each item step 9 read as `gate: dispatchable` from
`bin/fm-queue-snapshot.sh`, which is the single owner of that derivation, and
that passed the stale-work check but was not dispatched, once it qualifies as
deferred-ready.

An item becomes deferred-ready when either condition holds:

- Eligible and undispatched across >= 2 consecutive passes.
- Eligible for > 24 hours (measured from when it first read
  `gate: dispatchable` and passed the stale-work check).

Each deferred-ready item carries its plain-language deferral reason
(dispatch-cap occupancy, PC02 lane occupied, host memory below the floor,
outside attention window, or senior-tier daytime restriction). Below threshold, stay silent - no
separate ping, no notification. Rides the existing summary ping and its band gating.

Mechanics: at step 10 bookkeeping, when an eligible item goes undispatched,
run `bin/fm-captain-hold.sh mark set <task-id> deferred-since <UTC-ISO8601-timestamp>`,
and `bin/fm-captain-hold.sh mark clear <task-id> deferred-since` when the item
is eventually dispatched. That subcommand is the only writer of firstmate's
own sidecar `data/task-marks.tsv` (`<task-id>\t<key>\t<value>`, the same shape
as `data/roundtable-marks.tsv`); never hand-edit the file, since the writer
rewrites it whole under a lock and a concurrent edit would be lost.
Sidecar tracking covers primary-home tasks only. `gates[]` also carries
secondmate-owned queued items, whose marks live in that secondmate's own home;
the `mark` writer only reaches the primary home, so those items are excluded
from deferred-ready naming until secondmate-side sidecar tracking exists. That
is a known limitation, not a bug - do not stamp a secondmate item's id here,
since the primary home's pruning would drop the stray mark anyway.
The mark does NOT go into the backlog row's trailing metadata
block: tasks-axi owns that block and its parser rejects any word it does not
know, so an unrecognized word swallows the row's title, repo, and kind in
tasks-axi's own surfaces.
The full timestamp (not a bare date) is what makes the > 24 hour
condition above measurable.
The next pass reads the mark back as `gates[].deferred_since` from the
step 1 snapshot it already takes - `bin/fm-fleet-snapshot.sh` joins the
sidecar onto each backlog record - so consecutive-pass eligibility needs
no second read.

## 5. PC02-to-senior-tier plan-then-execute split

When the pass would dispatch a task through the PC02 lane, apply the
3-part trigger test to decide whether the work needs the senior tier's
plan-then-execute path instead: it plans first, then executes with the plan
as a guard.
Which model serves that path is not this skill's call.
`config/crew-dispatch.json`'s senior rule owns the candidates and
`quota-array-dispatch` owns the choice among them, under the captain's
2026-09-07 order that Fable is never auto-selected and Opus 5 is the
autonomous default.

The trigger test (all three parts must pass to route to the senior tier):

1. **Budget gate**: the task's estimated token cost exceeds the PC02
   lane's per-turn budget threshold.
   This threshold is defined by the PC02 lane's configuration.
   Read it from the lane's own config, do not hardcode it here.
   If the task's budget cannot be estimated, treat this gate as passed.

2. **Classification gate**: the task is a planning-heavy type
   (architecture review, multi-step migration design, cross-project
   dependency analysis, or other work requiring structured planning
   before execution) OR a deeply exploratory type
   (investigation of unknowns, cross-system debugging, or work where
   the solution path is not yet clear).
   Code review, small fixes, and straightforward feature additions
   do not pass this gate.

3. **Operational impact gate**: the task's surface has high operational
   impact when planned poorly.
   Work that affects multiple systems, touches shared infrastructure,
   or has a high cost of incorrect execution passes this gate.
   Isolated, low-risk changes do not.

When all three gates pass, route to the senior tier for plan-then-execute.
When any gate fails, use the PC02 lane directly.

### Daytime-only restriction (Q4)

Senior-tier planning scouts run daytime only for now.
A planning scout is a task dispatched through the senior tier that
requires the captain to review and approve the plan before execution.
Check `bin/fm-captain-window.sh` before dispatching a planning scout:
if outside the captain's attention window, queue the scout for the
next morning pass.

Overnight, ambiguous items wait for the morning pass.
A morning pass is the first `/autonomous` invocation after the
captain's attention window opens (per `bin/fm-captain-window.sh`).
Ambiguous items are tasks where the 3-part test is uncertain or
where classification gate requires captain judgment.

The daytime-only restriction applies to planning scouts only.
Non-planning dispatches (execution-only senior-tier work, PC02 lane
work) follow the normal dispatch rules without a daytime restriction.

## 6. Gaps, never-do list, and restart contract

### Gaps

- Fable is available; what constrains it is authority, not availability.
  The captain's 2026-09-07 order makes Fable a per-dispatch captain
  approval and Opus 5 the autonomous senior default, so this pass
  never selects Fable on its own. Section 5's split therefore routes to
  the senior tier as `config/crew-dispatch.json` defines it, and
  `quota-array-dispatch` chooses among that rule's candidates.
  An earlier version of this skill described Fable as unbuilt and
  routed to it directly; both were wrong and are corrected here.

- `/nightwatch` is not yet shipped.
  While nightwatch is unarmed, the bare night-bucket wake runs the
  pass procedure directly.
  Once `/nightwatch` ships, its dispatch loop will call this skill's
  pass procedure as one shared implementation.
  The pass procedure is written as a clean, callable unit so
  `/nightwatch` can invoke it later without duplicating logic.
  See the `fleet-dispatch-points` backlog task: its body should
  reflect the fold-in (Q2) as silent invocations of the `/autonomous`
  pass rather than a separate mechanism, with its existing
  monitor-and-report-at-debriefs trial clause preserved.

- The nudge thresholds (>= 5 decisions, >= 48h oldest) are this
  skill's own numbers and belong here.
  They are not duplicated from any other config owner.

### NEVER-do list

- Do NOT bypass the nudge thresholds to contact the captain for
  fewer than 5 decisions when they are under 48 hours old.
  Decision minimization is the skill's core purpose.

- Do NOT auto-merge any PR during the pass.
  Merge authority remains per `AGENTS.md` section 7: `yolo` is the
  only standing routine merge authority.

- Do NOT dispatch work on a `no-mistakes-prod-only` project without
  resolving the delivery mode explicitly.

- Do NOT handle security-sensitive, destructive, or irreversible
  actions autonomously during the pass.
  These always require explicit captain confirmation.

- Do NOT read the agent's chat to evaluate decisions.
  Use only the durable decision record from `fm-bearings-snapshot.sh`.

- Do NOT dispatch on an unverified harness adapter.
  Load `harness-adapters` before any spawn.

- Do NOT bypass `ask-user-authority` for any ask-user finding.
  When a decision has an ask-user finding, load the skill and
  follow its escalation policy.

- Do NOT contact the captain during their quiet hours,
  except under step 4's 48-hour override (step 4 owns this rule;
  it is stated there once and not restated here).
  The pass itself still runs: dispatch, logging, and queue
  re-evaluation are never quiet-hours gated.

- Do NOT confuse the refill sweep with idle-fleet autonomy.
  Refill's sweep (new candidates, report-only, filed as captain
  holds) and idle-fleet autonomy (self-assigned work at
  the cloud cap) are different: idle-fleet autonomy never files its
  self-assigned items as captain holds, and refill never dispatches.

- When idle-fleet autonomy produces roadmap/scope deliverables,
  name them `data/<project>-roadmap-.../report.md` so they
  feed `/questionnaire`'s refill source glob for free.

### Idempotent restart contract

The pass is idempotent by construction.
Running `/autonomous` multiple times without the captain having
ruled on any decision between runs must produce the same result.
The pass does not modify decision records until the captain
explicitly rules, so re-evaluation of the same state always
yields the same evaluation.

If the captain rules on some but not all decisions between runs,
the second pass only re-evaluates the unresolved decisions.
Resolved decisions are already closed and do not re-enter the bundle.

If the pass is interrupted mid-cycle (step N incomplete),
the next invocation is a fresh pass, not a resumption.
It re-reads the decision state from the authoritative source
(`fm-bearings-snapshot.sh`) and re-evaluates from step 1.
No partial state is carried forward.

### References to live owners

This skill cites these live owners rather than restating their values:

- `quota-axi` - quota and model selection
- `bin/fm-captain-window.sh` - captain attention window
- `config/dispatch-cap` - concurrent autonomous dispatch cap
- `bin/fm-autonomous-pc02-lane.sh` - whether the single PC02 lane is free
- `config/crew-dispatch.json` - dispatch profiles
- `captain-hold-lifecycle` - closing captain-held decisions
- `ask-user-authority` - deciding ask-user findings

Do not hardcap numbers from these owners in this skill.
The nudge thresholds (5 / 48h) are this skill's own numbers
and are the only hard numbers here.
