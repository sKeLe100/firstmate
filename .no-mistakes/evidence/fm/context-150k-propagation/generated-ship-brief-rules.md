# Rules
1. Never push to the default branch. Never merge a PR.
 2. Stay inside this worktree; modify nothing outside it.
 3. The padded-countdown token counter (the <total_tokens> block) in claude's UI is unreliable and can stick at 0 for a whole session; use /context or /home/sean_/.no-mistakes/worktrees/4936102b4bcf/01M1076P44G0D2FVYW0HCFMVJE/bin/fm-context-usage.sh for actual context numbers.
 4. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
 5. Report status by appending one line:
    `echo "{state}: {one short line}" >> '/tmp/fmhome.Y44f/state/demo-ctx.status'`
    States: working, needs-decision, blocked, paused, done, failed.
    Each append wakes firstmate, so report sparingly: only phase changes a supervisor
    would act on (setup done, bug reproduced, fix implemented, validation passed) and the
    needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
    firstmate reads your pane for that.
    A mid-task `working:` line (including setup complete) is nonterminal: do not end the
    turn after it; continue the same stage until a defined `done:` gate under Definition of done.
    Use `paused: {why}` - distinct from `blocked:` - ONLY when you are deliberately idling on a
    known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
    a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
    cadence instead of treating it as a possible wedge. Use `blocked:` when you are stuck and need help.
    After every append, verify with `ls -la '/tmp/fmhome.Y44f/state/demo-ctx.status'` that the line landed at that exact
    path with recent content; do not trust the append, and do not report `done`, until that
    verification succeeds - a write tool can silently place the file somewhere else, and that
    failure is itself a `blocked:` condition to report.
 6. If you hit the same obstacle twice, append `blocked: {why}` and stop; firstmate will help.
 7. If a decision belongs above the implementation worker (product choices, destructive actions, ask-user findings),
   append `needs-decision: {summary of options}` and stop. Firstmate will apply the configured authority and reply with the decision.
   To let firstmate target its answer at this exact decision (`--resolve-key`), give it a stable key:
   put `[key=<slug>]` BETWEEN the verb and the colon, e.g. `needs-decision [key=<slug>]: {summary}`
   or `blocked [key=<slug>]: {why}` - a complete token at the head of the note is accepted as an equivalent position, but a token further inside the note is prose and folds under the default key instead.
   A decision or blocker you opened stays open until a `resolved` line carrying its exact key lands; a later `done:` or `working:` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append `resolved: {how it cleared}` yourself (same `[key=<slug>]` if you opened it with one) as you resume.
8. Never stop, restart, or update the shared `no-mistakes` daemon - it is one instance serving
