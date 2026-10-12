---
name: repowise
description: >-
  Use for history, co-change, blast-radius, hotspot, or concept-search questions in a project the captain has opted in to RepoWise, and when the captain explicitly asks for RepoWise retrieval.
  Use plain rg and file reads for literal identifiers and for projects without RepoWise.
  Route project-backed commands to the assigned worker; do not add automatic indexing, MCP registration, plugins, hooks, or spawn and brief behavior.
user-invocable: true
disable-model-invocation: true
metadata:
  internal: true
---

# RepoWise

Use the optional upstream CLI to retrieve context from a repository index in the assigned checkout.
Structural retrieval (symbols, graph, git signals) is the default; semantic search applies only when the approved local embedding endpoint is reachable.
This skill adds no automatic setup, launch, spawn, brief, or hook behavior.
Operator setup boundaries and upstream references live in [RepoWise integration](../../../docs/repowise.md).

## Scope and entry checks

Firstmate delegates project-backed commands to the assigned worker because retrieval can write database and cache state.
A worker uses only its assigned checkout, the paths authorized by its brief, and the local embedding endpoint named below.

1. Resolve the intended checkout with `pwd -P` and `git rev-parse --show-toplevel`, and record its current HEAD and working-tree status.
   Use the assigned worktree rather than the canonical clone, supervisor home, or an ancestor workspace.
2. Check whether `repowise` is available with `command -v repowise`.
   If absent, report that fact and continue with `rg` and file reads.
   Do not install or upgrade it.
3. Check the checkout's `.repowise/` index for provenance:
   - `.repowise/mcp.json` names this checkout's absolute path.
   - The indexed commit is an ancestor of HEAD.
   - `.repowise/config.yaml` names the embedder this policy expects (`mock`, or the local endpoint below).
   - No `.repowise/.env` is present.
   If every check passes and the indexed commit differs from HEAD, refresh with `repowise update <abs path> --index-only --no-workspace`.
   If any check fails, or the index is absent and the task is a retrieval question, remove this checkout's `.repowise/` and cold-build it under step 4.
   Remove-and-rebuild applies only to the worker's own assigned checkout; never copy an index between checkouts, pool slots, or homes, and never touch another checkout's `.repowise/`.
4. Before invoking the CLI, set the process-local environment and confirm the embedder:
   - Semantic: `--embedder openai` with `OPENAI_BASE_URL` set in the same child process to the captain-approved local tailnet embedding endpoint (nomic-embed-text, OpenAI-compatible).
     Refuse if `OPENAI_BASE_URL` is unset rather than letting a default apply, and never point it at a hosted URL.
     Check the endpoint is reachable first; if it is not, use the structural mode below.
   - Structural (default, or endpoint down): `--embedder mock`.
     Report "semantic leg off" in the result.
   Check for inherited provider or remote-database overrides without printing secret values.
   Inspect only authorized paths; do not scan global configuration or histories to satisfy this check.

Cold build, for the assigned checkout only: run `repowise init <abs path> --yes --no-prose --provider mock --embedder <openai|mock> --no-workspace --no-seed --no-save-key --no-editor-setup --no-hook --no-distill-hook --no-claude-md --no-agents --no-codex --no-cost-tracking`, with the environment from the first section of step 4.
Confirm each opt-out against `repowise init --help` before running it, because a flag the installed version lacks is a refusal, not a silent default.
Keep `XDG_*` config, data, cache and state directories inside the checkout.
Transcript savings backfill is not part of this skill; do not enable it.

## Direct CLI retrieval

For every CLI invocation, set these variables only in that child process:

```text
DO_NOT_TRACK=1
REPOWISE_TELEMETRY_DISABLED=1
REPOWISE_SKIP_EDITOR_SETUP=1
```

These are telemetry and editor limits, not a guarantee of no network or home-directory writes.
Read `repowise --version` and the relevant command's installed `--help` under the same environment before a project query.
The version baseline is 0.55.0; another version needs a focused check of the query and its side effects, not an automatic upgrade.
Keep the working directory at the assigned checkout, pass its absolute path through the supported target option, and select single-repository mode where supported.
If a command cannot unambiguously target that checkout, do not run it.
An ancestor `.repowise-workspace.yaml` is not permission to query its other repositories.

Choose the retrieval the question needs:

| Need | Upstream CLI command |
| --- | --- |
| Find code by concept or natural-language description | `search` |
| Summarize a known file or module | `context` |
| Retrieve a known symbol and its bounds | `symbol` |
| Co-change partners, blast radius (importers), churn | `risk --target <file>` (not positional; a bare path is read as a git revision and exits 2) |
| Complexity hotspots | `health` |
| Why a file or symbol is connected | `why` |

Use `rg` and file reads, not RepoWise, for literal identifiers, exact string matches, and "where is X handled" questions with a known name.
RepoWise helped most on history, co-change, blast-radius, and hotspot questions, where it returns git-derived counts in one call.
Batch related questions into one CLI call where possible, because `search` and `health` can take tens of seconds per invocation.
Use a bounded query and inspect the returned paths, line bounds, freshness and completeness before relying on it.
Compare the indexed commit with live HEAD, and inspect working-tree changes separately: a matching commit does not prove an index includes uncommitted edits.
Confirm important relationships and source excerpts against live files.
Weights from `risk` co-change output are not verified counts; confirm a partner list against `git log` before stating it as fact.
An empty caller list is "unknown", never "none", for shell or dynamic dispatch: RepoWise's reference graph does not cover shell.
An empty graph edge or low risk score does not prove an edit is safe.

Do not call `ask`, generation, decision capture, publishing, watch, update outside step 3, or other mutating or provider-backed commands through this retrieval skill.
This skill does not register or automatically start MCP, the dashboard, plugins, global settings, Git or editor hooks, generated repository guidance, or shared base indexes.

## Result and fallback

Report the checkout, index freshness, whether the semantic leg was on, the useful code paths and lines, and any missing or degraded evidence.
Do not claim measured token savings or complete call or reference coverage without evidence.
On unavailable tooling, unsupported flags, ambiguous scope, failed provenance, an unreachable endpoint for a semantic-only question, or retrieval failure, report the specific limitation and continue with `rg`, file reads and existing task validation.
Preserve the index and user configuration; do not repair them outside the task's authority.
RepoWise does not replace Firstmate's project records, project instructions, tests, no-mistakes pipeline, or merge authority.
