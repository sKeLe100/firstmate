# Optional RepoWise integration

Firstmate includes an explicitly invoked [RepoWise skill](../.agents/skills/repowise/SKILL.md) for direct CLI retrieval from an existing, approved repository index.
When the harness discovers Firstmate's skill directory, use `/repowise` in Claude Code or `$repowise` where that syntax is supported.
Otherwise explicitly request RepoWise in the task and have the worker's brief reference the skill's path in the Firstmate code root.
Firstmate routes project-backed execution to the assigned worker because retrieval can write cache/database state.
There is no automatic installation, indexing, MCP registration, plugin, hook, or spawn integration.
If RepoWise is absent or unused, normal Firstmate workflows remain available.

## Deployment status

The initial integration provides the retrieval procedure and its boundaries; it does not enable live project indexing.
A real-project pilot requires a recorded decision about initialization's local conversation-history access, a named checkout, and permission for the tool/cache paths it can write.
Keep that decision in the owning home's ordinary task records rather than a global enable flag or committed project instructions.

In the reviewed [RepoWise v0.55.0 initialization code](https://github.com/repowise-dev/repowise/blob/v0.55.0/packages/cli/src/repowise/cli/commands/init_cmd/command.py#L109-L124), initialization recovers savings from local agent transcripts separately from decision capture.
Session decision capture defaults off, but disabling it does not disable this separate read.
No supported initialization opt-out for that read was established by the integration review.
Prefer a verified no-history path or explicitly authorize the limited local read for a pilot; do not treat a keyless run as history-free.

## Operator prerequisites

The operator owns any installation and machine configuration changes.
RepoWise requires Python 3.11 or newer; use an isolated, pinned installation rather than modifying Firstmate's dependencies.
The source baseline is [`v0.55.0`](https://github.com/repowise-dev/repowise/releases/tag/v0.55.0), not a floating checkout of upstream main.
This baseline records the reviewed interface and does not claim a completed live compatibility test.
Consult the [official project](https://github.com/repowise-dev/repowise) and the installed command's help before an approved setup.
Do not apply the official unattended initialization recipe or plugin install commands as part of an ordinary Firstmate task.

The skill owns execution checks, permitted query commands, process-local environment limits and fallback behavior.
It does not authorize installation or refresh an index that is missing or stale.
Approval to query an existing index must also cover its cache writes and effective configuration; no command is assumed filesystem read-only solely because it retrieves information.

## Pilot configuration boundaries

An approved pilot should start with a cold, independent index in one assigned checkout, with automatic worktree seeding and ancestor workspace selection disabled.
Upstream [worktree seeding](https://github.com/repowise-dev/repowise/blob/v0.55.0/packages/cli/src/repowise/cli/worktree.py#L185-L236) copies the whole `.repowise` directory, including any saved credentials or inherited policy it contains.
Do not share a writable cache with the canonical clone, another worker, or another home.
An existing directory or reused worktree path does not prove index identity or freshness.

Use a keyless provider/embedder configuration and explicitly disable model-backed decisions, session capture and session discovery.
Mock embeddings support the restricted baseline but do not provide meaningful semantic search.
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
A separately authorized live pilot must verify filesystem/network side effects, transcript scope, persistent editor opt-outs, keyless provider behavior, isolated checkout identity, stale/uncommitted-file handling, and useful retrieval against live files.
Record the installed version, exact commands and measured results in the task's private evidence.
No live pilot is implied by the presence of this skill.
