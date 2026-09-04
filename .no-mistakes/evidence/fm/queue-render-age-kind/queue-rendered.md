# What the captain sees (`.agents/skills/queue` rendering of the snapshot above)

Rendered by hand from `queue-snapshot-with-lanes.txt` following SKILL.md steps 2, 3
and 7 verbatim. Today's date: 2026-09-04.

## `/queue --limit 3`

```
standard/fast available (senior, routine, default lanes all at 20% remaining); 0 slots live.

showing 3 of 9 queued
hidden: 3 firstmate, 2 no project, 1 pc02

1. qk-01: queue gate-class grouping
   project: firstmate - kind: ship - 5d - tier: claude/claude-opus-5/high - autonomous-eligible
2. qk-02: survey display-manager options
   project: pc02 - kind: scout - 15d - tier: claude/claude-opus-5/high - captain-gated
3. qk-03: ratify lane policy
   project: firstmate - kind: captain - 51d - tier: claude/claude-opus-5/high - captain-gated - gated: held (captain): awaiting captain ruling

Ask about any item by id or description for full detail (body, blockers, dependencies,
links) via `tasks-axi show <id> --full`; everything else is deliberately omitted above.
```

Note the one-line lane summary replacing the old ~6-line header, the
`hidden:` line derived from `hidden[3]{repo,count}` (3+2+1 = 6 = total_queued 9 - count 3),
and each detail line now carrying `kind:` and `<age>d` computed from the new
`created` field (2026-08-30 -> 5d, 2026-08-20 -> 15d, 2026-07-15 -> 51d).

## `/queue lanes` (full per-tier detail, moved here, not deleted)

```
Lane hierarchy (config/crew-dispatch.json):
  for "hard, ambiguous, or high-stakes work":
    claude / claude-opus-5 / high - available now (20% remaining (all_models))
  for "routine implementation":
    claude / claude-sonnet-5 / medium - available now (20% remaining (all_models))
  for default (no rule matched):
    claude / claude-haiku-4-5-20251001 / low - available now (20% remaining (all_models))
live slots: 0 (firstmate has no configured concurrency cap by default)
```
