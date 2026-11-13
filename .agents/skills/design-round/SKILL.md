---
name: design-round
description: >-
  Run a multi-skill design round only when the captain invokes /design-round, says "design round", or asks for mockups from several design skills.
  At redesign or new-page intake, offer a round in one line; never start one unasked.
user-invocable: true
metadata:
  internal: true
---

# design-round

A design round asks several design skills for mockups of one page, scores them with one neutral reviewer, and lets the captain pick.
It is a supervisor recipe built only from existing tools: scouts, a ship, the questionnaire, a private claude.ai Artifact, and the Lavish board.
Invocation: `/design-round <project> <page> [redesign|audit|new]`, defaulting to `redesign`.

## Home preferences

Read the `[design-rounds]` and `[hallmark]` entries in the home's captain preferences before intake.
They own the generator slots and their order, the scorer, local skill paths, and any private rules such as telemetry settings.
If they are absent, ask the captain for the slots instead of guessing; this skill names no default skill path.

## Round flow (redesign)

1. **Intake.** Resolve the project and page, file one backlog item for the round, and write one shared design brief under the round's `data/<round>/` directory.
   The brief covers the goal, layout constraints, a real data snapshot, and the output contract: static `mockups/<slot>-<a|b>/index.html`, phone and desktop screenshots, and a short rationale per mockup.
   Give each worker its own port range so local preview servers never collide.
2. **Baseline.** Reuse an existing critique and audit of the current page when one exists; otherwise the scorer runs them first and the findings join the brief as the shared problem list.
3. **Fan-out.** Dispatch one generator scout per slot in parallel, 2 mockups each (default 3 slots).
   Each worker loads only its own skill and runs only that skill's own checks.
   Tell a generator that is designed for interactive use which steps it must skip unattended, so known gaps are expected rather than rediscovered.
4. **Score.** One fresh scorer scout reviews every mockup plus the baseline, preferably on a different model family from the generators.
   Its deterministic detector is a pass/fail floor; ranking comes from its critique score.
   It recaptures every screenshot with one tool at fixed viewports and writes `scoreboard.md` and `shots/`.
   Skip a scorer candidate that cannot read images.
5. **Review surfaces.** Build one `review/index.html` holding the scoreboard, phone and desktop shots, and each rationale, with shots referenced relatively.
   Publish it as a private claude.ai Artifact with the shots in its `files` map, and open the same file as a Lavish board for annotations.
   If the private page cannot be published, use the Lavish board only and ask the captain before any other route.
6. **Pick.** Hold one captain decision for the round and offer the scorer's top 3 through the questionnaire; the captain may name any other mockup in chat.
   Board annotations become tweak requests for the landing.
7. **Landing.** Dispatch one ship that builds the chosen mockup into the real page under the project's delivery mode.
   Its merge waits for the captain's word even on a project whose standing posture is `yolo`.
   The same ship writes the project's `DESIGN.md` from the chosen direction.
   Generator scaffolding never lands.
8. **Keep the mockups.** Preserve the round's mockups, shots, scoreboard, and review page under `data/<round>/` for later reference; never clean them up with the scouts.

## Variants

- **Audit only:** steps 1, 2, 4, and 5 with one reviewer scout running critique, audit, and detector; the review page is a findings page with no mockups and no pick.
- **New page:** skip step 2; the brief comes from the captain's answers, or from the project's `DESIGN.md` when it has one.

## Safety rules

- Never install or link a broad-trigger design skill globally; load it by path inside the worker.
  A global link is allowed only where the captain's preferences already approve it.
- Every Impeccable call sets `IMPECCABLE_NO_TELEMETRY=1`, and its concept-seed step never runs.
- Mockups are offline: no external requests, fonts self-hosted.
- Workers install helper tools only in their own copy and use only their assigned ports.
- Generator and scorer scouts never push or open a PR.
- Nothing is merged, and nothing is shared to a third-party host, without the captain's word.

## Cost

A round occupies about four lanes at once: the generators run under the `design` purpose and the scorer under `review`, each through normal dispatch.
Read quota before and after the first round in a home and record the measured cost of one round in `data/learnings.md`.
If the generators' account is over pace, queue the round and tell the captain rather than downgrading the generators.
