---
name: autonomous
description: >-
  Run an autonomous dispatch pass: evaluate open decisions for bundling,
  check whether nudge thresholds are met, and execute a structured
  10-step dispatch cycle that minimizes unnecessary captain contact.
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
10-step dispatch cycle that minimizes unnecessary captain contact.

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

To gather decisions, run `bin/fm-bearings-snapshot.sh --json` once
and read `decisions_open`.
Do not build a second decision reader, scrape reports or status tails,
or pass `--all-decisions`: date-deferred holds sit in `gates` until
due, and a prose-deferred hold disclosed in `omitted[]` stays silent
until the captain raises it himself.

Read `decisions_open` as an array of rows, each carrying `id`, `key`,
`verb`, `summary`, `owner`, `declared_priority`, `since`, and
`created_at` (the last two per the captain's timestamp ruling: `since`
is the human-readable date, `created_at` the epoch seconds derived from
it, absent on rows that predate the field).
Step 2's `fm-autonomous-thresholds.sh` call counts only chat-rulable
rows toward the bundle-size threshold and finds the oldest chat-rulable
row by `created_at` for the time-threshold check, counting every open
captain hold. Use
`declared_priority` rows first when ordering the presented bundle at
step 5, then oldest-first by `created_at`.

The captain's attention window is owned by `bin/fm-captain-window.sh`.
Check it before contacting the captain: if outside the window, queue
silently for the next window entry rather than interrupting.

The concurrent dispatch cap is owned by `config/dispatch-cap`.
Check current lane occupancy against this cap before dispatching new work.
The file is optional and gitignored; when it is absent the built-in
default cap is 3.
Do not hardcode a number here: read the config file, falling back to 3.

The dispatch profile is owned by `config/crew-dispatch.json`.
Resolve it before spawning any crewmate.

## 4. The 10-step pass procedure

Run these steps in order.
Each step must complete successfully before proceeding to the next.

### Step 1 - Gather decision state

Run `bin/fm-bearings-snapshot.sh --json`.
Read `decisions_open` from the output.
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
`quota-axi --json` (schemaVersion 5) at dispatch intake, per
`docs/configuration.md`: the ladder is checked alongside the base cap
rather than replacing it, so `five_hour.percentRemaining < 10` means an
effective cap of 1 no matter what the base says.
Check how many autonomous Claude lanes are currently active against both
the base cap and the ladder before treating a lane as available.
If the cap is at or exceeded, record that new dispatch is deferred due to
dispatch-cap occupancy and skip only steps 7-8 (the dispatch actions) later
in the pass. The cap never suppresses captain contact: steps 4-6 still run,
so an owed nudge still reaches the captain.

Do not hardcode the cap value here: read the live config and the live
quota, and use the built-in default base of 3 when `config/dispatch-cap`
is absent.

### Step 4 - Check the captain's attention window

Run `bin/fm-captain-window.sh` with no flags (`--now` and `--weekday`
are test-only flags). It prints `band=<band> offer=yes|no`.
The `offer` field is the single canonical predicate: `offer=yes` means
in-window, `offer=no` means outside. Do not branch on `band`.
This step owns the quiet-hours rule for the whole skill:
On `offer=yes`, proceed to step 5.
On `offer=no`, queue the nudge silently for the next window
entry: skip only steps 5-6 and continue at step 7, since the window
gates captain contact, not dispatch.
The single exception: when step 2 reported the time threshold and the
oldest pending decision exceeds 48 hours, contact the captain anyway -
run steps 5-6 despite `offer=no`. That is the only quiet-hours override.
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

### Step 8 - Run the PC02-to-Fable split (section 5)

If any dispatched work would normally route to the PC02 lane,
evaluate the 3-part trigger test from section 5.
When the test passes, route through Fable for plan-then-execute
instead.
Respect the daytime-only restriction from the captain's Q4 ruling.

### Step 9 - Record the pass outcome

Log the pass outcome durably.
Record the number of decisions evaluated, the number ruled on, the
number deferred, and the number dispatched.
Append to the pass log: the epoch timestamp, the threshold that fired,
and a one-line summary of outcomes.

The pass log path is `state/.autonomous-pass-log`.
Each entry is a single line: `<epoch>\t<threshold>\t<summary>`.

### Step 10 - Re-evaluate the queue

After the pass completes, re-evaluate queued work items whose blockers
have cleared or whose time gates have passed.
Dispatch any that are now eligible, following the normal dispatch
lifecycle - but only when step 3's cap check still found headroom.
When step 3 found the cap at or exceeded, queue them instead of
dispatching.

Do not auto-dispatch work that requires a captain decision.
Auto-dispatch only work whose authority is already established
(yolo on, delivery-mode resolved, no ask-user findings pending).

### Deferred-ready visibility (end-of-pass reporting)

After step 10, add a deferred-ready line to the pass summary.
Name each item that passed step 10's eligibility filter (blockers
cleared, time gates passed, authority already established) and stale-work
check but was not dispatched, once it qualifies as deferred-ready.

An item becomes deferred-ready when either condition holds:

- Eligible and undispatched across >= 2 consecutive passes.
- Eligible for > 24 hours (measured from when it first passed
  the eligibility filter and stale-work check).

Each deferred-ready item carries its plain-language deferral reason
(dispatch-cap occupancy, outside attention window, or Fable daytime
restriction). Below threshold, stay silent - no separate ping, no
notification. Rides the existing summary ping and its band gating.

Mechanics: write a `deferred-since <date>` metadata word into the item's
trailing backlog metadata block at step 9 bookkeeping when an eligible item
goes undispatched - the same space-separated metadata-word syntax as `since`,
read back through the same `metadata_word()` path as `hold`/`hold-kind`/
`since`, so it is visible in the plain `--json` snapshot with no second read.
Remove the `deferred-since` word when the item is eventually dispatched.
The next pass reads it as `gates[].deferred_since` from the snapshot it
already takes to determine consecutive-pass eligibility.

## 5. PC02-to-Fable plan-then-execute split

When the pass would dispatch a task through the PC02 lane, apply the
3-part trigger test to decide whether to route through Fable instead.
Fable is the plan-then-execute path: it plans first, then executes
with the plan as a guard.

The trigger test (all three parts must pass to route to Fable):

1. **Budget gate**: the task's estimated token cost exceeds the PC02
   lane's per-turn budget threshold.
   This threshold is defined by the PC02 lane's configuration.
   Read it from the lane's own config, do not hardcode it here.
   If the task's budget cannot be estimated, route to Fable.

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

When all three gates pass, route through Fable for plan-then-execute.
When any gate fails, use the PC02 lane directly.

### Daytime-only restriction (Q4)

Fable planning scouts run daytime only for now.
A planning scout is a task dispatched through the Fable path that
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
Non-planning dispatches (execution-only Fable, PC02 lane work)
follow the normal dispatch rules without a daytime restriction.

## 6. Gaps, never-do list, and restart contract

### Gaps

- Fable integration is planned but not yet built.
  Until Fable ships, the PC02-to-Fable split (section 5) can be
  evaluated but the actual Fable dispatch path is unavailable.
  Route through PC02 as a fallback when Fable is not available.
  When Fable ships, the split gates will automatically enable the
  Fable path without changing this skill's contract.

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
- `config/crew-dispatch.json` - dispatch profiles
- `captain-hold-lifecycle` - closing captain-held decisions
- `ask-user-authority` - deciding ask-user findings

Do not hardcap numbers from these owners in this skill.
The nudge thresholds (5 / 48h) are this skill's own numbers
and are the only hard numbers here.
