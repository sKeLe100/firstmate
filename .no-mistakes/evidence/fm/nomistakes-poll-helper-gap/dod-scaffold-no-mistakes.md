# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append `done: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass `--intent` as only this brief's `## Captain's intent` subsection plus any later words the captain actually said.
For a legacy brief with no such subsection, include only words explicitly labeled `Captain:`, `Captain's words:`, `Captain's ask:`, or `Captain's intent:`; never copy its mixed `# Task` wholesale. If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include `## Firstmate spec`, later Firstmate build constraints, or your own decisions and tradeoffs.
The `--intent` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into `--intent` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich `--intent` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.
Poll long-running pipeline steps (no-mistakes runs, test loops) with synchronous foreground checks on an explicit sleep/retry cadence; do not park a background Task/Monitor call on a step that can run for many minutes.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call (e.g. `no-mistakes axi run --intent "..." >run.log 2>&1 &`) and poll with `/home/sean_/.no-mistakes/worktrees/4936102b4bcf/01M2GK1SD0BXCEA26T7P27VC9A/bin/fm-nomistakes-poll-lib.sh wait --dir <worktree>` from a separate call instead of sitting in one blocking hold your harness will kill.
Do not hand-roll your own `axi status` exit condition: top-level `status: running` stays exactly that while a step is actively running AND while a step is gated awaiting your response, so checking it alone either spins forever on a parked gate or exits before responding to one - three independent crewmates hit this on 2026-09-08. `/home/sean_/.no-mistakes/worktrees/4936102b4bcf/01M2GK1SD0BXCEA26T7P27VC9A/bin/fm-nomistakes-poll-lib.sh wait` reads the real per-step/gate detail and returns only on a genuine gate, outcome, or its own bounded timeout (exit 2, meaning: call it again).
If the branch already has a prior finished no-mistakes run, do not rely on `/home/sean_/.no-mistakes/worktrees/4936102b4bcf/01M2GK1SD0BXCEA26T7P27VC9A/bin/fm-nomistakes-poll-lib.sh wait` until the NEW run's own status/outcome appears in `no-mistakes axi status`: without `--run`, `axi status` reports the branch's active-or-most-recent run, so a first poll before the daemon registers the new drive call returns the OLD run's terminal outcome as if it were yours.
Where a harness's own command limit is not established, assume it bounds commands and use that same background-and-poll shape.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies `ask-user-authority` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass `--yes` (or `-y`) to `no-mistakes axi run` or `no-mistakes axi respond`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

After any custody recovery on a rebased branch, run `bin/fm-nomistakes-gate-check.sh` before pushing; treat a `diverged` result as an immediate `blocked:` report rather than pushing anyway.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), run `/home/sean_/.no-mistakes/worktrees/4936102b4bcf/01M2GK1SD0BXCEA26T7P27VC9A/bin/fm-claim-check.sh main` piping in your intended `done:` summary; if it reports unverified paths, fix the summary before reporting (do not silence the gate, and do not hand-edit or recommit once the run is closed out).
Append `done: PR {url} checks green` and stop. You are finished.
