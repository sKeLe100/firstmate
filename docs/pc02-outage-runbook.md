# PC02 local serving stack outage runbook

Recovery steps for when PC02's local model-serving stack (llama-swap) is
down and a human needs to bring it back up, with no resident agent walking
through the steps.

This is a recovery checklist, not an architecture doc.

## What the stack is

PC02 runs llama-swap inside WSL as a systemd service. llama-swap is a single
Go binary (`~/.local/bin/llama-swap`) that fronts two large local models
(`qwen3.8-27b-dispatch` and `qwen3.6-35b-a3b-dispatch`) with
hot-swap-on-request, so only one holds the GPU at a time.

It binds to the host's tailnet IP `100.67.55.77:8080` (not loopback). opencode
connects via `pc02-llamaswap/<model>`.

- **Binary**: `~/.local/bin/llama-swap` (installed from the llama-swap GitHub releases page)
- **Config**: `/home/sean_/fm-pc02-llm-lab/projects/pc02-llm-lab-tooling/llama-swap/config.yaml`
- **Service**: `llama-swap.service` (systemd user unit or system unit)
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

Check the llama-swap service status:

```bash
ssh pc02 "systemctl --user status llama-swap 2>&1"
# or, if deployed as a system service:
ssh pc02 "systemctl status llama-swap 2>&1"
```

If the service is not found, not enabled, or not active, the stack is down.

Check if llama-swap's port responds:

```bash
ssh pc02 "curl -s --connect-timeout 5 http://100.67.55.77:8080/health"
ssh pc02 "curl -s --connect-timeout 5 http://100.67.55.77:8080/v1/models"
```

If curl returns nothing or connection refused, llama-swap is not serving.

Check if the process is running:

```bash
ssh pc02 "ps aux | grep llama-swap | grep -v grep"
```

If no process matches, llama-swap is not running.

## How to restart

If the systemd service is not active, start it:

```bash
ssh pc02 "systemctl --user start llama-swap"
# or, if deployed as a system service:
ssh pc02 "sudo systemctl start llama-swap"
```

If the service unit file does not exist (the unit was never deployed or was
removed), start llama-swap manually:

```bash
ssh pc02 "bash -lc 'nohup setsid llama-swap --config /home/sean_/fm-pc02-llm-lab/projects/pc02-llm-lab-tooling/llama-swap/config.yaml --listen 100.67.55.77:8080 >/tmp/llama-swap.log 2>&1 &'"
```

Wait for the model to load. Cold starts take approximately 5-6 minutes.

Verify it's up:

```bash
ssh pc02 "curl -s --connect-timeout 10 http://100.67.55.77:8080/v1/models"
```

If the models endpoint lists `qwen3.8-27b-dispatch` and `qwen3.6-35b-a3b-dispatch`,
the stack is back.

## If the restart itself fails

**Service unit not found or config path missing:**
The service file at `llama-swap/llama-swap.service` (from the
`pc02-llm-lab-tooling` repo) points to
`/home/sean_/fm-pc02-llm-lab/projects/pc02-llm-lab-tooling/llama-swap/`.
If this directory does not exist on the host, the repo was not deployed to
its permanent location. Either deploy the unit file and config to the correct
paths per the `llama-swap/README.md` deploy steps, or start llama-swap
manually as shown above with the inline config path.

**llama-swap starts but crashes or fails to load a model:**
Check the service logs:

```bash
ssh pc02 "journalctl --user -u llama-swap --no-pager -n 50"
# or system service:
ssh pc02 "journalctl -u llama-swap --no-pager -n 50"
```

Look for GPU driver errors, out-of-memory, or model file corruption.
Check that the model files referenced in `config.yaml` exist at the paths
listed (under `fm-pc02-llm-lab/models/`).

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
then restart WSL and the llama-swap service. Memory pressure can cause
WSL to kill processes or prevent new ones from starting.

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
