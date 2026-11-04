# PC02 local serving stack outage runbook

Recovery steps for when PC02's local model-serving stack (llama-swap) is
down and a human needs to bring it back up, with no resident agent walking
through the steps.

This is a recovery checklist, not an architecture doc.

## What the stack is

PC02 runs llama-swap as a native Windows application at
`C:\pc02-llm-server\bin\llama-swap.exe`. It is launched via a Windows
Scheduled Task and fronts two large local models
(`qwen3.8-27b-dispatch` and `qwen3.6-35b-a3b-dispatch`) with
hot-swap-on-request, so only one holds the GPU at a time.

It binds to the host's tailnet IP `100.67.55.77:8080` (not loopback). opencode
connects via `pc02-llamaswap/<model>`.

- **Binary**: `C:\pc02-llm-server\bin\llama-swap.exe` (native Windows)
- **Config**: `C:\pc02-llm-server\bin\native-config.yaml` (WSL path: `/mnt/c/pc02-llm-server/bin/native-config.yaml`)
- **Launch**: Windows Scheduled Task, driven by `C:\pc02-llm-server\bin\pc02-llama-swap-autostart.ps1`
- **Port**: `100.67.55.77:8080` (the tailnet address on `eth1`)
- **Model cold starts**: approximately 5-6 minutes

Note: `ssh pc02` lands inside WSL Linux (hostname SeansDesktop), not on
Windows. All commands below run directly over `ssh pc02`.

## Symptoms the stack is down

- opencode connects to a `pc02-llamaswap/*` model but returns provider errors,
  timeouts, or "connection refused"
- A crewmate or scout dispatched to a PC02 lane shows no output for longer than
  the raised stale-escalation threshold (default 600 seconds) and the opencode
  log has no `message=loop` lines for that task's session
- Firstmate reports an opencode+pc02-llamaswap crew as stale or dead, and no
  loop-step heartbeat has been seen

## How to check

Connect to PC02 (via tailnet/LAN):

```bash
ssh pc02 true
```

If this fails, the host itself is unreachable - see "Ceiling" below.

Check if llama-swap's port responds:

```bash
ssh pc02 "curl -s --connect-timeout 5 http://100.67.55.77:8080/health"
ssh pc02 "curl -s --connect-timeout 5 http://100.67.55.77:8080/v1/models"
```

If curl returns nothing or connection refused, llama-swap is not serving.

Check the Windows Scheduled Task status from WSL:

```bash
ssh pc02 "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -Command 'Get-ScheduledTask -TaskName *llama-swap* | Select-Object TaskName,State'"
```

If the task is not found or its State is not `Ready`/`Running`, the stack is
likely down.

## How to restart

Restart llama-swap via the autostart script:

```bash
ssh pc02 "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -Command '& \"C:\\pc02-llm-server\\bin\\pc02-llama-swap-autostart.ps1\"'"
```

Wait for the model to load. Cold starts take approximately 5-6 minutes.

Verify it's up:

```bash
ssh pc02 "curl -s --connect-timeout 10 http://100.67.55.77:8080/v1/models"
```

If the models endpoint lists `qwen3.8-27b-dispatch` and `qwen3.6-35b-a3b-dispatch`,
the stack is back.

## If the restart itself fails

**Autostart script missing or executable:** Confirm the script exists:

```bash
ssh pc02 "ls -la /mnt/c/pc02-llm-server/bin/pc02-llama-swap-autostart.ps1"
```

If the file does not exist, the `C:\pc02-llm-server\` directory may have been
removed or relocated. Contact the captain.

**Scheduled Task missing or disabled:** Check task availability:

```bash
ssh pc02 "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -Command 'Get-ScheduledTask -TaskName *llama-swap*'"
```

If the task does not exist, the initial setup of the autostart Scheduled Task
needs to be recreated. Contact the captain.

**llama-swap starts but crashes or fails to load a model:** Check the Windows
application event log or any logs written by the autostart script. The script
may write logs to `C:\pc02-llm-server\logs\` or WSL-side paths like
`/tmp/llama-swap.log`. Check those for GPU driver errors, out-of-memory, or
model file corruption. Verify that the model files referenced in
`native-config.yaml` exist at the paths listed (under `C:\pc02-llm-server\models\`).

**Model fails to load (llama-swap is running but the port responds with an error
about the model):**
Check that the expected model file exists and is intact on disk. A cold start
failure on a previously working model usually means the model file was corrupted
or removed.

**WSL is not running:**
From the Windows host (via RDP, physical access, or Windows Terminal/PowerShell),
start WSL:

```powershell
wsl --shutdown
wsl
```

Or from another machine that can reach PC02's Windows host via the tailnet.

**Windows host memory pressure:**
If the Windows host reports "Memory needs to be freed on this machine"
(the captain observed this on PC02), free memory by closing applications,
then restart WSL and llama-swap. Memory pressure can cause WSL to kill
processes or prevent new ones from starting.

### Historical: WSL systemd (obsolete)

The following commands no longer apply to PC02's production setup, which uses
native Windows Scheduled Tasks (documented above). They are retained for
reference only — if you encounter a WSL systemd unit, it is a leftover from a
prior architecture and should not be used.

```bash
ssh pc02 "systemctl --user status llama-swap 2>&1"
ssh pc02 "systemctl status llama-swap 2>&1"
ssh pc02 "systemctl --user start llama-swap"
ssh pc02 "journalctl --user -u llama-swap --no-pager -n 50"
```

## PC02 as a test and lint host

Besides serving models, PC02's stronger hardware can run this repo's own
heavy `bin/fm-test-run.sh` suites and canonical `bin/fm-lint.sh` lint
(including the no-mistakes test and lint steps) when PC02 is not needed for
anything else. `bin/fm-test-run.sh --pc02-if-idle` (see its own header) hands
test runs to `bin/fm-test-compute.sh`, which tries hosted compute first and
then the existing PC02/PC01 admission path in
`bin/fm-pc02-test-offload.sh`; set `FM_TEST_COMPUTE_DISABLE=1` when a
PC02-only/offline route is intended. The no-mistakes lint command reaches the
same PC02/PC01 admission through `bin/fm-test-compute.sh lint`; PC02 runs the
canonical partitions, and PC01's last-resort lint runs the changed-file subset.
`bin/fm-pc02-test-offload.sh` owns every readiness check and the
sync/execution mechanics for both; read its header and `--help` for the exact
contract rather than duplicating it here.

**The captain's personal-use switch**: a Desktop shortcut on PC02 named
"PC02 Personal Use Toggle" flips a flag with no terminal - one double-click
turns it on (offloading stays on PC01 only) or off (PC02 may pick up
idle offloaded runs again), with a brief popup confirming the new state. The
same switch is reachable from PC01 with `bin/fm-pc02-personal-use.sh
on|off|status`. Besides that manual switch, every offload attempt also
checks automatically whether PC02's llama-swap has any model loaded for a
live session (its `/running` endpoint; a healthy llama-swap with nothing
loaded does not block offloading), and whether Windows-wide CPU or GPU utilization looks busy (a game
or other heavy foreground use); a busy PC02 from any of those checks is waited
on up to the offload's wait bound before the run routes to PC01, an unclear
check is waited on the same way rather than guessing PC02 is free, and an
unreachable PC02 routes the run to PC01 at once. Re-run `bin/fm-pc02-personal-use.sh install-toggle` if the shortcut
or its resource-check script ever need to be redeployed (safe to re-run).

### Reclaiming leaked test roots

When `bin/fm-pc02-hygiene.sh` reports stale test roots, reclaim them on PC02 itself (for example inside `ssh pc02`); the report is strictly read-only and the offload reaps only its own mirror, so this manual sequence is what clears a leaked root.
`bin/fm-pc02-hygiene-lib.sh`'s header owns the exact definition of a counted root; the report prints the paths it counted as `stale_test_root=` lines (at most 50, then a `stale_test_roots_omitted=` count), so use those paths as the authoritative list when it has them.

The report counts exactly three classes of test root, and only these may be removed:

- offload mirrors `$HOME/<FM_PC02_OFFLOAD_REMOTE_BASE>/run-*` left behind by a wrapper whose exit trap never ran;
- `$TMP_ROOT`/`fm-test-run.*` roots left by a direct test run;
- `$TMP_ROOT`/`fm-*` directories that carry a `.fm-test-fixture` marker (written by `tests/lib.sh`).

Never widen the match to a bare `fm-*`: real task temp roots live there too, so only a directory carrying that marker may be removed.
For every class, remove only a root that is older than the report's stale bound (`FM_PC02_HYGIENE_STALE_AGE_SECS`, default 21600 seconds / six hours), that no live process references, and always `chmod -R u+w` before `rm -rf` because test fixtures can leave read-only `*.git-hooks` directories that make `rm -rf` fail.

Use the paths the report printed when it had room for them, re-checking liveness just before removal:

```bash
bin/fm-pc02-hygiene.sh | sed -n 's/^stale_test_root=//p' | while IFS= read -r dir; do
  base=${dir##*/}
  pgrep -f -- "$base" >/dev/null && continue
  chmod -R u+w -- "$dir" 2>/dev/null || true
  rm -rf -- "$dir"
done
```

When the report printed `stale_test_roots_omitted=`, cover the rest by class, applying the same age, liveness and `chmod` rules:

```bash
age=${FM_PC02_HYGIENE_STALE_AGE_SECS:-21600}
age_min=$((age / 60))
remote_base=${FM_PC02_OFFLOAD_REMOTE_BASE:-.fm-pc02-test-offload}
tmp_root=${FM_PC02_OFFLOAD_TMP_ROOT:-/tmp}
before=$(df -Pk "$tmp_root" | awk 'NR == 2 { print $3 }')
removed=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    */.fm-test-fixture) dir=${path%/.fm-test-fixture} ;;
    *) dir=$path ;;
  esac
  [ -d "$dir" ] && [ ! -L "$dir" ] || continue
  base=${dir##*/}
  pgrep -f -- "$base" >/dev/null && continue
  chmod -R u+w -- "$dir" 2>/dev/null || true
  rm -rf -- "$dir" && removed=$((removed + 1))
done < <(
  find "$HOME/$remote_base" -mindepth 1 -maxdepth 1 -type d -name 'run-*' -mmin +"$age_min" 2>/dev/null
  find "$tmp_root" -mindepth 1 -maxdepth 1 -type d -name 'fm-test-run.*' -mmin +"$age_min" 2>/dev/null
  find "$tmp_root" -mindepth 2 -maxdepth 2 -type f -name '.fm-test-fixture' \
    -path "$tmp_root/fm-*/.fm-test-fixture" -mmin +"$age_min" 2>/dev/null
)
after=$(df -Pk "$tmp_root" | awk 'NR == 2 { print $3 }')
printf 'removed=%s tmp_used_kb=%s->%s\n' "$removed" "$before" "$after"
```

Re-run `bin/fm-pc02-hygiene.sh` afterwards: `stale_test_roots` should drop to 0, and its `tmp_used_mib`/`disk_used_mib` lines show the reclaimed space.

**Warning**: `wsl --shutdown` (see "WSL is not running" above) drops all
remote access to PC02, including this offload path, until someone reaches
the Windows desktop directly and runs `wsl` again - an SSH session cannot
trigger that restart itself, because `sshd` runs inside WSL. Only apply a
`.wslconfig` change or other edit needing a WSL restart when physical/RDP
access to the Windows desktop is available to bring it back up.

## Ceiling

This runbook covers recovery of llama-swap when the host is reachable.
It does not cover:

- **PC02 host unreachable** (no SSH): this is the fallback strategy boundary
  from `docs/pc02-duty-officer.md` section 3. There is no further recovery
  path - this is a hardware limitation.
- **PC02 is asleep, powered off, or tied up running another model:** only one
  model is resident on PC02 at a time. Wait for the current model to finish
  or use cloud fallback.
- **Neither cloud nor PC02 works:** there is no offline answer. Same conclusion
  as the duty officer scoping report.

When PC02 is unreachable or the host has no further recovery path, the fallback
is the cloud fallback lane (OpenRouter or Gemini free-tier) per the duty officer
fallback strategy.
