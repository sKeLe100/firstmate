---
name: repowise
description: >-
  Use only when explicitly asked to use RepoWise for repository context or CLI retrieval.
  Route project-backed commands to the assigned worker; do not enable indexing, MCP, plugins, or hooks.
user-invocable: true
disable-model-invocation: true
---

# RepoWise

Use the optional upstream CLI to retrieve context from an existing, explicitly approved index.
This skill adds no automatic setup or launch behavior.
Operator setup boundaries and upstream references live in [RepoWise integration](../../../docs/repowise.md).

## Scope and entry checks

Firstmate delegates project-backed commands to the assigned worker because even retrieval can write database/cache state.
A worker uses only its assigned checkout and the paths authorized by its brief.
An explicit skill invocation permits these checks; it does not authorize installation, indexing, provider spending, or access to other projects or homes.

1. Resolve the intended checkout with `pwd -P` and `git rev-parse --show-toplevel`, and record its current HEAD and working-tree status.
   Use the assigned worktree rather than the canonical clone, supervisor home, or an ancestor workspace.
2. Check whether `repowise` is already available with `command -v repowise`.
   If absent, report that fact and continue with ordinary repository tools.
   Do not install or upgrade it.
3. Require an existing `.repowise` index whose checkout identity and use were explicitly approved in the task or operator setup.
   Resolve its location before access; do not follow a cache symlink outside the authorized checkout.
   If the index is absent, stale, inherited from another checkout, or of unknown provenance, use live file reads and report the limitation.
   Never initialize, seed, rebuild, delete, or refresh it as a repair.
4. Before invoking the CLI, confirm the approved configuration is keyless, uses mock embeddings, disables model-backed decisions and session capture, and uses a checkout-local database.
   Check for inherited provider/remote-database overrides without printing secret values.
   A `.repowise/.env` file, an unverified global fallback, or an index built with a different embedder requires clarification from firstmate rather than a silent override.
   Inspect only authorized paths; do not scan global configuration or histories to satisfy this check.

Index creation and refresh remain disabled in this integration pending a separately recorded pilot decision and task scope.
Turning off session decision capture does not disable initialization's separate local transcript savings backfill.
Never read Claude/Codex transcripts to operate this skill.

## Direct CLI retrieval

For every permitted CLI invocation, set these variables only in that child process:

```text
DO_NOT_TRACK=1
REPOWISE_TELEMETRY_DISABLED=1
REPOWISE_SKIP_EDITOR_SETUP=1
```

These are telemetry/editor limits, not a guarantee of no network or home-directory writes.
Read `repowise --version` and the relevant command's installed `--help` under the same process-local environment before issuing a project query.
Verify its target-path options, workspace selection and output format.
The source baseline is RepoWise `v0.55.0`; another version needs a focused check of the relevant query and side effects, not an automatic upgrade.
Keep the working directory at the assigned checkout, pass its absolute path through the supported target option, and select single-repository mode where supported.
If a command cannot unambiguously target that checkout, do not run it.
An ancestor `.repowise-workspace.yaml` is not permission to query its other repositories.

Choose only the retrieval needed for the request:

| Need | Upstream CLI command |
| --- | --- |
| Locate likely code, symbols or paths | `search` |
| Summarize a known file or module | `context` |
| Retrieve a known symbol and its bounds | `symbol` |
| Inspect indexed health or change risk | `health` or `risk` |

Use a bounded query and inspect the returned paths, line bounds, freshness and completeness before relying on it.
Compare the indexed commit with live HEAD, and inspect working-tree changes separately: a matching commit does not prove an index includes uncommitted edits.
Confirm important relationships and source excerpts against live files.
Mock embeddings provide a keyless baseline, not meaningful semantic vectors.
An empty graph edge or low risk score does not prove an edit is safe, particularly for shell or dynamic dispatch.

Do not call `ask`, generation, decision capture, publishing, watch, initialization, update, or other mutating/provider-backed commands through this retrieval skill.
Do not start MCP or the dashboard, install the Claude plugin, register global settings, install Git/editor hooks, generate repository guidance, or share a base index.
Those are separate optional integrations, not fallback actions.

## Result and fallback

Report the checkout and index freshness, the useful code paths/lines, and any missing or degraded evidence.
Do not claim measured token savings or complete call/reference coverage without evidence.
On unavailable tooling, unsupported flags, ambiguous scope, privacy uncertainty or retrieval failure, report the specific limitation and continue with `rg`, file reads and existing task validation.
Preserve the index and user configuration; do not repair them outside the task's authority.
RepoWise does not replace Firstmate's project records, project instructions, tests, no-mistakes pipeline, or merge authority.
