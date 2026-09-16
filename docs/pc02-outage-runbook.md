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
