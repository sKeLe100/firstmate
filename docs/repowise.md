# Optional RepoWise integration

Firstmate includes a [RepoWise skill](../.agents/skills/repowise/SKILL.md) for CLI retrieval from a repository index in the assigned worker's checkout.
RepoWise is available on opted-in projects: CLI retrieval, structural by default, and semantic search when the local embedding endpoint is up.
When the harness discovers Firstmate's skill directory, use `/repowise` in Claude Code or `$repowise` where that syntax is supported.
Otherwise name RepoWise in the task and have the worker's brief reference the skill's path in the Firstmate code root.
Firstmate routes project-backed execution to the assigned worker because retrieval can write cache/database state.
There is no automatic installation, indexing, MCP registration, plugin, or hook integration, and no spawn or brief integration yet.
If RepoWise is absent, stale, or unused, normal Firstmate workflows remain available on `rg` and file reads.

## Deployment status

RepoWise 0.55.0 is installed durably at `~/.local/bin/repowise`.
The captain's decisions are to offer the CLI only on opted-in projects, with no MCP or hooks by default, and to pilot on `pt-tracker` first.
Semantic search uses the captain's local PC02 embedding service on the tailnet, with nomic-embed-text and no hosted provider.
The per-project opt-in list and the spawn and brief integration are later slices; until they land, opt-in is the captain's explicit word for the task.

The captain ruled on 2026-10-12 that the privacy concern about RepoWise reading local agent transcripts at init is lifted for the pilot.
The verified init backfilled local savings by opening 505 Codex session paths under `~/.codex/sessions` and zero Claude transcript paths; transcript contents were not manually inspected and no history was sent to a provider.
This scoped permission is not a general history review or provider-transmission authorization.

## Operator prerequisites

The operator owns any installation and machine configuration changes.
RepoWise requires Python 3.11 or newer; use an isolated, pinned installation rather than modifying Firstmate's dependencies.
The source baseline is [`v0.55.0`](https://github.com/repowise-dev/repowise/releases/tag/v0.55.0), not a floating checkout of upstream main.
The pilot verified the pinned install, init, offline refresh and MCP stdio handshake; see the task pilot report for full command transcripts and measurements.
Consult the [official project](https://github.com/repowise-dev/repowise) and the installed command's help before an approved setup.
Do not apply the official unattended initialization recipe or plugin install commands as part of an ordinary Firstmate task.

The skill owns execution checks, permitted query commands, process-local environment limits and fallback behavior.
On an opted-in project it authorizes a worker to cold-build (`repowise init`) and refresh (`repowise update`) the index in its own assigned checkout, but not installation or upgrade of the CLI.
Those commands write cache and database state and read effective configuration; no command is assumed filesystem read-only solely because it retrieves information.

## Pilot configuration boundaries

An opted-in project's index starts cold and independent in one assigned checkout, with automatic worktree seeding and ancestor workspace selection disabled.
Upstream [worktree seeding](https://github.com/repowise-dev/repowise/blob/v0.55.0/packages/cli/src/repowise/cli/worktree.py#L185-L236) copies the whole `.repowise` directory, including any saved credentials or inherited policy it contains.
Do not share a writable cache with the canonical clone, another worker, or another home.
An existing directory or reused worktree path does not prove index identity or freshness.

Use a keyless provider and explicitly disable model-backed decisions, session capture and session discovery.
The embedder is either the local PC02 endpoint, set explicitly in the child process, or `mock` when that endpoint is down.
Mock embeddings give structural and full-text retrieval only, not semantic search.
`--no-prose` alone is insufficient: initialization can still resolve a decision provider from an explicit provider or ambient API keys.
The [upstream init interface](https://github.com/repowise-dev/repowise/blob/v0.55.0/packages/cli/src/repowise/cli/commands/init_cmd/command.py) and effective child-process configuration must agree with the approved policy.
Do not persist API keys, silently adopt remote database overrides, or print credential values while checking configuration.

Keep editor setup, generated project guidance, Git hooks and distillation hooks disabled, including persistent project-file opt-outs for later refreshes.
Do not change global Claude settings or account pins, or add project `AGENTS.md`/`CLAUDE.md` content.
Each project's maintainers own any committed ignore or guidance change.
Generated cache data must stay outside tracked changes without discarding existing work.

Use explicit index exclusions for private content rather than relying only on Git ignores.
In a Firstmate checkout this includes private operational state, project clones, credentials and task scratch material.
For other projects, choose exclusions according to their actual source layout.
RepoWise's inspected local-exclude reader uses a literal `.git/info/exclude`, which is not the linked-worktree layout; Git cleanliness alone is not proof that private files were excluded from indexing.

## Verified pilot results and remaining seams

The pinned install used `uv tool install --python 3.13 repowise==0.55.0` with task-local uv tool/bin directories; the durable operator executable is `~/.local/bin/repowise`.
The pilot init used `DO_NOT_TRACK=1`, `REPOWISE_TELEMETRY_DISABLED=1`, mock provider/embedder (structural only; the semantic path adds `--embedder openai` against the local endpoint), no prose, no workspace or seed, no editor setup or hooks, and explicit exclusions.
The contained offline init succeeded in 10.82 seconds and produced a 4.0 MB index; its only network attempt was the optional GitHub tree-sitter language-pack manifest fetch for COBOL, and indexing continued without that parser.
For clone-only write boundaries, keep every `XDG_*` config, data, cache and state directory under the approved checkout; the contained pilot placed RepoWise index and cache files under `.repowise/`.
The offline index-only incremental refresh succeeded after a committed fixture change, updating one changed file in 2.50 seconds with no degraded stages.
The MCP stdio JSON-RPC handshake completed `initialize` and `tools/list`, exposing ten tools; Claude Code's local health check connected successfully.
When the CLI is absent, the skill's fallback was verified: report the missing executable and continue with ordinary repository tools such as `rg`.

Worktree identity across tasks, regression against Firstmate hooks, cleanup and landing authority remain unproven.
Pilot measurements on `pt-tracker` decide whether the opt-in stays; broad rollout waits until those seams are validated.

## Privacy, cost and compatibility limits

Telemetry is enabled by default in the reviewed release.
The skill supplies process-local opt-outs; these do not disable every possible network path, including update checks and configured providers.
Provider-backed synthesis or embeddings can send selected code/context to the configured provider and incur its normal charges.
Claude's ordinary token/context costs also remain; this integration makes no measured savings claim.
Treat local indexes as sensitive derived data and do not publish or upload them through this integration.

RepoWise is licensed `AGPL-3.0-or-later`; Firstmate treats it as an optional external executable and does not vendor or redistribute it.
The [upstream licensing guidance](https://github.com/repowise-dev/repowise/blob/v0.55.0/docs/business/COMMERCIAL.md) describes free internal use and commercial options.
Redistribution, modification or hosted deployment needs assessment for that actual arrangement.

The official Claude plugin, Lens UI, automatic hooks, MCP and fleet-wide workspaces are outside this phase.
Any later integration must prove it preserves Firstmate's primary supervision hooks, worker lifecycle hooks, account configuration and worktree isolation on the affected harness/backend surfaces.
Graph/risk output remains advisory; ordinary source inspection, tests and the selected delivery path retain authority.

## Verification

Structural changes to the skill and this page use `bin/fm-doc-audience-check.sh` and the normal Firstmate delivery checks.
Any further live check, including the unproven seams above, must verify filesystem/network side effects, transcript scope, persistent editor opt-outs, keyless provider behavior, isolated checkout identity, stale/uncommitted-file handling, and useful retrieval against live files.
Record the installed version, exact commands and measured results in the task's private evidence.
Indexing is authorized only on opted-in projects, in the worker's own checkout; see Deployment status.
