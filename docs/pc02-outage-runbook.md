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
- **Watchdog**: Scheduled Task `PC02-llama-swap-watchdog` checks port 8080
  every minute and relaunches llama-swap if it stops answering (see
  "Automatic recovery watchdog" below)

Note: `ssh pc02` lands inside WSL Linux (hostname SeansDesktop), not on
Windows. All commands below run directly over `ssh pc02`.

## Current known-good config (qwen3.6-35b-a3b-dispatch)

`qwen3.6-35b-a3b-dispatch` runs with the asymmetric KV cache

    --cache-type-k q8_0 --cache-type-v q4_0

alongside `--flash-attn on`, `--no-kv-offload`, `-c 262144`, and `--no-mmap`.
This was validated on 2026-09-18 by cold-starting the model and confirming
real generation against the endpoint.

A full `q4_0` K + `q4_0` V change was trialled on 2026-09-18 and hung
llama-server during cold start (no OS reboot, no crash/WER record), so it was
abandoned and must not be retried. The suspected cause is combining quantized
K+V with `--no-kv-offload` and flash-attention at a 262144 context, a known
llama.cpp footgun. The config backed up immediately before the failed q4_0
trial is `C:\pc02-llm-server\bin\native-config.yaml.bak-2026-09-18-kvq4`; the
backup taken before the q8_0 K / q4_0 V trial is
`native-config.yaml.bak-2026-09-18-q8k-q4v`. If q8_0 K / q4_0 V ever
misbehaves, the documented fallback is the original symmetric
`--cache-type-k q8_0 --cache-type-v q8_0`.

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

Check if llama-swap's port responds. From WSL use `127.0.0.1`: connecting
from WSL to the host's own tailnet IP is intermittently unreliable under WSL
mirrored networking and can give a false negative.

```bash
ssh pc02 "curl -s --connect-timeout 5 http://127.0.0.1:8080/v1/models"
ssh pc02 "curl -s --connect-timeout 5 http://100.67.55.77:8080/v1/models"
```

If curl returns nothing or connection refused, llama-swap is not serving. When
in doubt, confirm from a real tailnet client rather than from PC02 itself.

Check the Windows Scheduled Task status from WSL:

```bash
ssh pc02 "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -Command 'Get-ScheduledTask -TaskName *llama-swap* | Select-Object TaskName,State'"
```

If the task is not found or its State is not `Ready`/`Running`, the stack is
likely down.

## Automatic recovery watchdog

`PC02-llama-swap-watchdog` is a Windows Scheduled Task that runs every minute
while `sean_` is logged on (matching the serving stack's own lifetime, since
llama-swap is a user-session process). It requests
`http://127.0.0.1:8080/v1/models`; if the port answers, it exits without
doing anything, so a healthy service is never double-launched. If the port
stops answering it:

1. copies `swap-stderr.log`/`swap-stdout.log` to timestamped
   `swap-*-hang-<timestamp>.log` files (keeping the newest 20 pairs),
2. stops any stuck `llama-swap`/`llama-server` process, and
3. relaunches via the same pattern as the logon autostart task.

Check it and read its action log:

```bash
ssh pc02 "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -Command 'Get-ScheduledTask -TaskName PC02-llama-swap-watchdog | Select-Object TaskName,State'"
ssh pc02 "cat /mnt/c/pc02-llm-server/bin/watchdog.log"
```

Run it on demand (for example after confirming the stack is down):

```bash
ssh pc02 "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -Command 'Start-ScheduledTask -TaskName PC02-llama-swap-watchdog'"
```

Disable or re-enable it:

```bash
ssh pc02 "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -Command 'Disable-ScheduledTask -TaskName PC02-llama-swap-watchdog'"
ssh pc02 "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -Command 'Enable-ScheduledTask -TaskName PC02-llama-swap-watchdog'"
```

It complements, and does not replace, the logon-only
`PC02-llama-swap-autostart` task. Because it runs only while `sean_` is logged
on, it does not help if the desktop session is fully logged off; the watchdog
and the serving stack share that user-session lifetime.

## How to restart

**Preserve the logs first.** The autostart launch redirects llama-swap's
output into `swap-stderr.log`/`swap-stdout.log`, overwriting whatever was
there. Before any recovery restart, copy those files aside so the failing
run's diagnostics are not lost (this is exactly the evidence that was lost in
the 2026-09-18 q4_0 K+V incident):

```bash
ssh pc02 "cd /mnt/c/pc02-llm-server/bin && ts=\$(date +%Y%m%d-%H%M%S) && cp -a swap-stderr.log swap-stderr.hang-\$ts.log && cp -a swap-stdout.log swap-stdout.hang-\$ts.log"
```

Stop any running llama-swap first - the autostart script only launches, so
starting a second copy while the first still owns port 8080 does nothing
useful:

```bash
ssh pc02 "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -Command 'Get-Process llama-swap,llama-server -ErrorAction SilentlyContinue | Stop-Process -Force'"
```

Then restart llama-swap via the autostart script:

```bash
ssh pc02 "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -Command '& \"C:\\pc02-llm-server\\bin\\pc02-llama-swap-autostart.ps1\"'"
```

Wait for the model to load. The `qwen3.6-35b-a3b-dispatch` model cold-starts
from the C: SSD in roughly 20-30 seconds; other entries (notably the
`--no-mmap` MTP variants) can take several minutes.

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
application event log, `C:\pc02-llm-server\bin\swap-stderr.log`, and
`C:\pc02-llm-server\bin\swap-stdout.log` (plus any `swap-*-hang-*.log` copies
the watchdog preserved) for GPU driver errors, out-of-memory, or model
loading errors. Verify that the model files referenced in `native-config.yaml`
exist at the paths listed.

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

## PC02 as a test host

Besides serving models, PC02's stronger hardware can run this repo's own
heavy `bin/fm-test-run.sh` suites (including the no-mistakes test step) when
PC02 is not needed for anything else. `bin/fm-test-run.sh --pc02-if-idle`
(see its own header) execs into `bin/fm-pc02-test-offload.sh`, which is the
single owner of every readiness check and the sync/execution mechanics; read
its header and `--help` for the exact contract rather than duplicating it
here.

**The captain's personal-use switch**: a Desktop shortcut on PC02 named
"PC02 Personal Use Toggle" flips a flag with no terminal - one double-click
turns it on (test offloading stays on PC01 only) or off (PC02 may pick up
idle test runs again), with a brief popup confirming the new state. The same
switch is reachable from PC01 with `bin/fm-pc02-personal-use.sh
on|off|status`. Besides that manual switch, every offload attempt also
checks automatically whether PC02's llama-swap has any model loaded for a
live session (its `/running` endpoint; a healthy llama-swap with nothing
loaded does not block offloading), and whether Windows-wide CPU or GPU utilization looks busy (a game
or other heavy foreground use); any of those routes the run to PC01 instead,
and an unreachable or unclear check does the same rather than guessing PC02
is free. Re-run `bin/fm-pc02-personal-use.sh install-toggle` if the shortcut
or its resource-check script ever need to be redeployed (safe to re-run).

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
