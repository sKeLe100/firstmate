# /queue as the captain sees it (rendered from queue-snapshot-limit3.txt, today = 2026-09-04)

Fixture: 68 queued items across firstmate / pc02 / no-project, `--limit 3`.

## `/queue`

    "hard, ambiguous, or high-stakes work" lanes available; routine work and default lanes unknown (no live quota data for codex); 0 slots live.

    showing 3 of 68 queued
    hidden: 41 firstmate, 15 pc02, 9 no project

    1. q1: expose created/kind on /queue
       project: firstmate - kind: ship - 7d - tier: claude/opus/high - autonomous-eligible
    2. q2: survey pc02 disk layout
       project: pc02 - kind: scout - 46d - tier: codex/gpt-5/medium - captain-gated
    3. q3: untriaged inbox item
       project: (none) - kind: task - 1d - tier: codex/gpt-5/low - unclear

    Ask about any item by id or description for full detail (`tasks-axi show <id> --full`); everything else is deliberately omitted.

The old header was the ~6-line per-tier block; it is now the single summary line above.

## `/queue lanes`

    Lane hierarchy (config/crew-dispatch.json):
      for "hard, ambiguous, or high-stakes work":
        claude/opus/high - available now (20% remaining (all_models))
      for "routine work":
        codex/gpt-5/medium - unknown (no live quota data for codex)
      for default (no rule matched):
        codex/gpt-5/low - unknown (no live quota data for codex)
    live_slots: 0 (no configured concurrency cap)

    showing 3 of 68 queued
    hidden: 41 firstmate, 15 pc02, 9 no project
    ...same 3 items as above...

## Empty `created` (queue-snapshot-empty-created.txt)

Item q9 comes back with `created` empty, so its detail line renders
`project: firstmate - kind: ship - age: unknown - ...` rather than a guessed day count.
