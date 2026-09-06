# /queue rendering, base commit rules vs. this change's rules

Same real `bin/fm-queue-snapshot.sh` output (see `queue-snapshot-fixture.txt`,
produced from a real tasks-axi backlog + data/projects.md registry with
firstmate at yolo=on and legacy-app at yolo=off). Both renderings below follow
`.agents/skills/queue/SKILL.md` steps 4/6/7 literally - the "before" per the
base commit's wording, the "after" per this change's wording. dispatch_config
is absent in the fixture, so the tier note is stated once as the skill requires.

Tier: dispatch config absent - no tier candidates available (stated once, applies to all items below).

## BEFORE (base commit 84f4d53) - one undifferentiated "Needs the captain" bucket

### Dispatchable
**firstmate**
1. fm-1: ship the queue skill update
   project: firstmate - kind: ship - 0d - tier: config absent - clears itself

### Needs the captain
**firstmate**
2. fm-2: decide delivery mode for release
   project: firstmate - kind: captain - 0d - tier: config absent - needs you
3. fm-6: scope unclear: dashboard refresh
   project: firstmate - kind: ship - 0d - tier: config absent - clears itself - gated: ambiguous scope
4. fm-8: held with no reason
   project: firstmate - kind: ship - 0d - tier: config absent - clears itself - gated: held
**legacy-app**
5. fm-3: captain call on pricing copy
   project: legacy-app - kind: captain - 0d - tier: config absent - needs you
6. fm-4: upgrade auth library
   project: legacy-app - kind: ship - 0d - tier: config absent - needs you
7. fm-5: rewrite onboarding docs
   project: legacy-app - kind: docs - 0d - tier: config absent - needs you
**no project**
8. fm-7: orphan chore
   project: no project - kind: chore - 0d - tier: config absent - unclear - ask me about it

The captain cannot tell from this why any of ranks 2-8 need them: a captain-kind
decision, a yolo-off registry posture, and an ambiguous-scope hold all read the
same, and every "needs you" is bare.

## AFTER (this change, 941983a) - split by cause, autonomy_reason always shown

### Dispatchable
**firstmate**
1. fm-1: ship the queue skill update
   project: firstmate - kind: ship - 0d - tier: config absent - clears itself (project registry posture has yolo on)

### Needs the captain

#### captain kind or captain-kind hold
**firstmate**
2. fm-2: decide delivery mode for release
   project: firstmate - kind: captain - 0d - tier: config absent - needs you (captain kind or captain-kind hold)
**legacy-app**
5. fm-3: captain call on pricing copy
   project: legacy-app - kind: captain - 0d - tier: config absent - needs you (captain kind or captain-kind hold)

#### project registry posture has yolo off
**legacy-app**
6. fm-4: upgrade auth library
   project: legacy-app - kind: ship - 0d - tier: config absent - needs you (project registry posture has yolo off)
7. fm-5: rewrite onboarding docs
   project: legacy-app - kind: docs - 0d - tier: config absent - needs you (project registry posture has yolo off)

#### ambiguous scope
**firstmate**
3. fm-6: scope unclear: dashboard refresh
   project: firstmate - kind: ship - 0d - tier: config absent - clears itself (project registry posture has yolo on) - gated: ambiguous scope

#### no project recorded on this item
**no project**
8. fm-7: orphan chore
   project: no project - kind: chore - 0d - tier: config absent - unclear - ask me about it (no project recorded on this item)

#### project registry posture has yolo on
**firstmate**
4. fm-8: held with no reason
   project: firstmate - kind: ship - 0d - tier: config absent - clears itself (project registry posture has yolo on) - gated: held

Ask about any item by id or description for full detail (body, blockers, dependencies, links) via `tasks-axi show <id> --full`; everything else is deliberately omitted above.

## What this demonstrates

- Every item now carries its `autonomy_reason` in parentheses after the verdict (step 6).
- "Needs the captain" is split into five distinct cause sub-headings, sorted by
  descending item count then alphabetically for the ties (2,2,1,1,1).
- Ranks are still the snapshot's own `rank` values, unrenumbered, and all 8
  snapshot rows still appear exactly once.
- firstmate's items are now split across three cause sub-headings - the
  expected consequence of grouping by why before by project.
- fm-8 is the review-1 case: `held: yes` with `hold_reason` = the absent-field
  placeholder `-`. Under the fixed rule it falls through to its
  `autonomy_reason` instead of landing under a sub-heading literally titled "-".
