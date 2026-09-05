# Codex

Verified on 2026-09-05 with codex-cli 0.153.4 unless a fact gives a newer version.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Unknown until a semantic source is live-verified: the app-server turn lifecycle is unreachable for a pane worker, and project lifecycle hooks did not fire for a Firstmate-launched worker. |
| Exit command | `/quit`; its slash popup needs about one second between text and Enter, which the shared submit path used by the control plane handles. |
| Interrupt | Single Escape. |
| Skill invocation | `$<skill>`, for example `$no-mistakes`; `/<skill>` is Claude-only and Codex rejects it as "Unrecognized command". |
| Resume | `codex resume <session-id>`, using the id printed on quit. |
| Model flag | `--model <model>`. |
| Effort flag | `-c 'model_reasoning_effort="<effort>"'`; see the catalog support below. |
| Model discovery | Read `~/.codex/models_cache.json` for current model slugs and per-model effort support, or open the interactive session's `/model` picker. |

The codex-cli 0.153.4 catalog lists low, medium, high, and xhigh for every model.
It additionally lists `max` on gpt-5.6-luna, gpt-5.6-sol, gpt-5.6-terra, gpt-6-astra, and gpt-reserve, and `ultra` on gpt-6-astra, gpt-5.6-sol, and gpt-5.6-terra.
`bin/fm-spawn.sh` owns launch-time validation against that catalog and the diagnostic for unsupported efforts.

## Lane rule

The Codex lane is per Firstmate home, matching the PC02 lane guard.
`bin/fm-spawn.sh` scans only this home's task metas and refuses a Codex launch while another local Codex task, worker or secondmate, is alive or still unconfirmed; a positively dead local endpoint releases the lane.
Remote-routed metas are outside the guard's scope, so a Codex secondmate published on another host never blocks a local Codex launch, and the refusal names the home it applies to.
Batched Codex spawns are refused separately and unconditionally.

## Executable rediscovery

`bin/fm-spawn.sh` rediscovers the codex executable from PATH on every spawn and relaunch, resolves it with `readlink -f`, probes `--version`, and never reads it from a prior meta.
A raw custom launch command whose first word is a codex binary is refused unless that binary resolves to the same path; the refusal names both resolved paths.
The task meta records `codex_exe` and `codex_version` as audit evidence only; nothing consumes them.

A directory trust dialog appears on the first run for a repository root: "Do you trust the contents of this directory?"
Accept it with Enter and verify the instructions begin processing.
The decision persists for the repository, so later worktrees of the same project skip it.

## Skill popup

A `$<skill>` invocation opens a `$` autocomplete popup.
Submitting too fast lets the popup swallow Enter, so the invocation never lands.
`../../../bin/fm-send.sh` gives a leading `$` a 1.2-second settle before the first Enter only when the exact task metadata records `harness=codex`, with the target backend's submit retry as the safety net.
That scope is load-bearing because a leading `$` commonly starts ordinary text such as `$5/month` or `$HOME`.
An explicit `session:window` target has no metadata, so its harness is unknown and uses the non-Codex fast path.
This is why `$no-mistakes` reaches a Codex worker instead of being consumed by the popup.

## Primary integration

The primary integration was verified on 2026-07-08 with codex-cli 0.142.1.
The firstmate primary's `.codex/hooks.json` registers a Stop hook that pipes Codex's payload to `../../../bin/fm-turnend-guard.sh`.
Codex Stop hooks preserve exit status 2 and stderr to block, and expose `stop_hook_active` for the same one-block loop safety used by the guard's default mode.

The Stop payload includes `cwd`, but the tracked hook does not use it to choose the guard executable.
Codex runs the Stop command with process PWD set to the hook-loaded project root, while no `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, or `CODEX_CWD` root variable is set.
The tracked hook anchors to `pwd -P`, verifies that root is Firstmate-shaped and hook-bearing, and then invokes the guard with the original payload.

Codex's primary watcher protocol is `../../../bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`, not `../../../bin/fm-watch-arm.sh`.
Codex cannot reason while a foreground tool call is running, so the checkpoint is deliberately foreground and bounded to return control regularly for user messages and queued notifications.
Codex's PreToolUse watcher-arm seatbelt blocks directly through its project hook.
