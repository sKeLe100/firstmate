---
name: perspective-catalog
description: >-
  Agent-only catalog of opt-in worker perspectives and the intake procedure that selects one.
  Load at every scout or ship intake whose purpose class is review, investigation, or planning, before scaffolding the brief, and before adding, editing, or removing a catalog fragment.
  Owns the fixed seven-entry catalog, the selection precedence, the purpose-class defaults, and the may/may-not rule for fragment content; bin/fm-brief.sh --perspective owns the insertion mechanics.
user-invocable: false
metadata:
  internal: true
---

# perspective-catalog

A perspective is a short brief-template fragment that frames how a worker approaches its task: stance, what to read first, what to return, what to refuse, and output shape.
Firstmate chooses one at intake from this fixed catalog and `bin/fm-brief.sh --perspective <slug>` inserts it as a `# Perspective` section between `# Task` and `# Setup`.
The fragment never owns any contract: Setup, Rules, and Definition of done stay with the scaffold, so a perspective can never contradict what `bin/fm-spawn.sh` validates.
The review stances (`independent-reviewer`, `reaction-review`, `parallel-review-seat`) refuse editing and committing, so `bin/fm-brief.sh` accepts them on scout briefs only and refuses them on a ship brief.
The design and its evidence live in the private scout report that proposed it (2026-09-04); this skill is the only shared owner.

## Catalog

Each fragment is `references/<slug>.md`, inserted with its HTML maintainer comments removed and the rest of its prose untouched.

| slug | eligible purposes | stance |
|---|---|---|
| `explorer` | investigation | Read-only discovery for one precise question; file:line evidence; options, not rulings. |
| `architect` | planning | Blueprint only: boundaries, data flow, migration order, failure modes, test seams, reserved decisions. |
| `researcher` | investigation | Primary sources, versions, citations; sourced fact kept apart from inference. |
| `validator` | review | Run the gate, probe boundaries, reproduce; report severity and suspected location; never fix. |
| `independent-reviewer` | review | Read-only; cite file:line; recount every checkable claim with method; unprompted observations; zero findings is inconclusive; ends ship / ship-with-changes / rethink. |
| `reaction-review` | review | Five generic lenses, each naming and classifying a real downside; simulated reactions are disclaimed. |
| `parallel-review-seat` | review | Same stance and output shape as independent-reviewer, plus: one of two independent seats on the same subject and question, never sees the other's output, opens with its model family and model name. |

Keep the catalog at seven or fewer entries.
Every fragment opens with a dated HTML comment stating why it exists; that comment is maintainer bookkeeping and never reaches the worker's brief. When you change a fragment, update that line and re-read this table so the two do not drift.

## Selection precedence at intake

Resolve the perspective after the project, mode, yolo, purpose class, and dispatch profile are already resolved (AGENTS.md section 4 and 7); it never changes those.

1. An explicit per-task captain instruction naming a slug.
2. The matched `config/crew-dispatch.json` rule's optional `perspective` field (`docs/configuration.md` "Crewmate dispatch profiles").
3. The catalog default for the purpose class.
4. None.

Purpose-class defaults:

- Eligible purposes are `review`, `investigation`, and `planning` only.
- `code`, `mechanical`, and `summarize` always default to none; only a captain naming a slug overrides that.
- A scout with an eligible purpose defaults to `explorer`; a review scout defaults to `independent-reviewer`.
- A ship task defaults to none: on a no-mistakes ship the pipeline already supplies the reviewer stance, and the fragment costs the worker context for no changed outcome.
- A slug outside the catalog is a refusal from `fm-brief.sh`, never a silent fallback; report it and re-resolve.

Pass the resolved slug as `bin/fm-brief.sh <id> <repo> --scout --perspective <slug>` (or on a ship scaffold).
The scaffold records a fixed `Perspective: <slug>` line, and `fm-spawn.sh` echoes it into task meta as `perspective=` so the task record durably names the stance it was launched with; no telemetry consumer reads it yet.

## What a fragment may and may not contain

May: stance, what to read first, what to return, what to refuse, output shape (recounts, unprompted observations, a verdict word).

May not: status-protocol lines, worktree or branch instructions, delivery-mode rules, merge authority, gate commands, project-specific canon (UX rules, domain authorities, app probe lists), or harness-specific instructions.
Those are owned by the scaffold, the project's own committed docs, or `harness-adapters`; a fragment that restates one of them creates a second contract owner and must be cut.
Review of a fragment against this list is a human and reviewer check, not code.
