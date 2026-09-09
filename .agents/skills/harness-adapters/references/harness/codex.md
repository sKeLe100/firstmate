# Codex

Verified on 2026-06-11 with codex-cli 0.139.0 unless a fact gives a newer version.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Unknown until a semantic source is live-verified: the app-server turn lifecycle is unreachable for a pane worker, and project lifecycle hooks did not fire for a Firstmate-launched worker. |
| Exit command | `/quit`; its slash popup needs about one second between text and Enter, which the shared submit path used by the control plane handles. |
| Interrupt | Single Escape. |
| Skill invocation | `$<skill>`, for example `$no-mistakes`; `/<skill>` is Claude-only and Codex rejects it as "Unrecognized command". |
| Resume | `codex resume <session-id>`, using the id printed on quit. |
| Model flag | `--model <model>`. |
| Effort flag | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh>"'`, verified on codex-cli 0.142.1 whose installed schema contains `model_reasoning_effort`, active config uses it, and bundled catalog advertises only these four values while omitting `max`. |
| Model discovery | Open the current interactive session's `/model` picker. |
| Approval bypass | `--dangerously-bypass-approvals-and-sandbox` is **required** on every launch (enforced in `bin/fm-spawn.sh`). Removing or softening this flag re-enables the `codex-auto-review` feature, which bills a second hidden model call against the weekly allocation on every approval request. |
| Required axes | Both. Codex CLI launches on its own bundled default model and reasoning effort when a flag is absent, so `../../../bin/fm-spawn.sh` refuses a codex spawn or relaunch that names no model or an effort outside the four above, instead of the record-and-omit contract every other harness follows. A raw launch command is exempt. |

## Lane rule

The Codex lane is per Firstmate home, matching the PC02 lane guard.
`bin/fm-spawn.sh` scans only this home's task metas and refuses a Codex launch while another local Codex task, worker or secondmate, is alive or still unconfirmed; a positively dead local endpoint releases the lane.
Remote-routed metas are outside the guard's scope, so a Codex secondmate published on another host never blocks a local Codex launch, and the refusal names the home it applies to.
A MULTI-pair batch resolving to Codex is refused separately, whatever the lane holds, because pairs spawn one at a time and a refusal partway through would leave a half-spawned batch; a single `id=repo` pair is one spawn and goes through under the lane rule above.

## Executable rediscovery

`bin/fm-spawn.sh` rediscovers the codex executable from PATH on every LOCAL spawn and relaunch, resolves it with `readlink -f`, probes `--version`, and never reads it from a prior meta.
A secondmate routed to a remote host is published by that host and returns before this block, so it takes no rediscovery, probe or pin and records no `codex_exe`/`codex_version`; that host's own `fm-spawn.sh` applies these rules.
A raw custom launch command whose first word is a codex binary is refused unless that binary resolves to the same path; the refusal names both resolved paths.
The raw line is read once with the shell's own lexical rules (`bin/fm-raw-launch-lib.sh`, pinned against bash itself by `tests/fm-raw-launch-lib.test.sh`), so word boundaries and values come from one pass: `"codex"`, `'codex'`, `\codex` and `co"dex"` all classify as Codex, and quoted or backslash-escaped whitespace in a leading `NAME=value` assignment cannot move the command word.
A raw launch firstmate cannot read conclusively is refused outright rather than classified as another harness: an unterminated quote, a newline, a command word that is a shell expansion, tilde, glob or brace pattern, a command substitution anywhere, an unquoted control operator or redirection, or no command word at all.
A raw Codex launch is also refused when any word after the executable would expand in the pane, so the `--fast` refusal is conclusive; a wrapper such as `env codex ...` still classifies as that wrapper.
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
