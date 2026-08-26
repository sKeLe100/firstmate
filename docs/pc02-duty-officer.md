# PC02 duty officer

Deployment of the scoped-down PC02 duty officer, per `data/pc02-duty-officer-scoping/report.md`
(captain-authorized 2026-08-26). This is the no-internet fallback lane, not a secondmate: it answers
factual questions from durable records and refuses judgment work.

## What it is

A hand-written system prompt run against a PC02-local qwen model through `opencode run`, with no
AGENTS.md, no supervision protocol, and no persistent agent process. It is invoked on demand, on the
PC02 host itself (or over SSH from the machine that needs an answer), against whatever durable-record
files are staged for it to read.

## The contract prompt

The full prompt text lives in `docs/pc02-duty-officer-prompt.txt` so it can be piped or attached
verbatim to `opencode run` without hand-copying. Contents:

```
You are a duty officer. You can read the file(s) named in this request.

When asked "what's queued?", read backlog.md and summarize the Queued
section. When asked about a specific project, read projects.md and the
project's README. Keep answers factual and brief - a few sentences, not
a full transcription.

You CANNOT: supervise workers, merge PRs, make judgment calls, modify
code, or summarize files over roughly 100 lines. If a question requires
judgment, review, or a large-file summary, reply exactly: "I cannot do
that. Your normal session will need to handle it when available." Do
not attempt the task anyway.
```

## Dispatch path (the real PC02 qwen lane)

There is no persistent duty-officer agent or opencode provider entry - the report's arithmetic
notes headroom is not the constraint, and adding a permanent config entry on the PC02 host is out
of scope for a fallback that only runs when the host is reachable and needed. Run it directly:

```
ssh pc02 'opencode run -m pc02-llama-swap/qwen3.6-35b-a3b-dispatch \
  --dir <staging-dir-with-the-needed-file(s)> \
  "$(cat docs/pc02-duty-officer-prompt.txt)

Question: <the factual question>"'
```

Stage only the specific file(s) the question needs (e.g. a copy or excerpt of `data/backlog.md`)
in `<staging-dir>` before invoking - PC02 has no filesystem access to the primary firstmate host,
so the relevant file(s) must be copied over (`scp`) first. Keep staged excerpts small: the scoping
report's evidence shows qwen3.6 stalling 3/3 on single-file reads in the 1.5-3K word range, so full
`backlog.md` (~53K tokens) is out of bounds for this lane - stage a trimmed section, not the whole
file.

## Verified live test (2026-08-26)

Ran against the real PC02 host and the real qwen3.6-35b-a3b-dispatch model (not a mock):

1. **Factual question, small excerpt** - staged the first 15 entries of the real `Queued` section
   of `data/backlog.md` and asked "what's queued?". The model correctly named specific queued items
   present in the staged excerpt (e.g. `pc02-llm-first-real-task-roadmap`, `gpu-purchase-decision`)
   and did not fabricate items absent from it. Verified against the source excerpt, not just that
   the command exited cleanly.
2. **Judgment refusal** - asked "should we merge PR #12, and is the reviewer's risk call correct?"
   with no PR content staged. The model replied with the required refusal sentence instead of
   guessing, confirming the boundary in the contract prompt holds under a real judgment prompt.

## Fallback strategy (when PC02 is asleep, unreachable, or tied up)

Per the scoping report, the duty officer is the secondary fallback, not the primary one:

1. **Anthropic Claude down, internet up (the common case):** use the OpenRouter or Gemini free-tier
   cloud fallback. No PC02 involvement - this is the default path and needs no new machinery.
2. **No internet, or all cloud providers unreachable:** use the PC02 duty officer above, over the
   tailnet/LAN, run manually per the dispatch path.
3. **PC02 itself is off, asleep, tied up running another model, or otherwise unreachable:** there is
   no further fallback - this is an inherent hardware limitation. `ssh pc02 true` failing, or a model
   load taking the observed 5-6 minute cold-start (see `data/learnings.md` on PC02 cold loads looking
   like hangs - wait it out once before concluding the host is down), are both diagnostic signs of
   this state, not duty-officer bugs. Only one model is resident on PC02 at a time, so if another
   task is mid-run on the lane, wait for it to finish or use cloud fallback instead of interrupting it.
4. **Neither cloud nor PC02 works:** there is no offline answer. This is the same conclusion the
   scoping report reached - it is a hardware/connectivity ceiling, not something this deployment can
   close.

The duty officer never has fleet-supervision, merge, or code-modification authority; those remain
gated on a full session per `data/pc02-duty-officer-scoping/report.md`'s capability findings.
