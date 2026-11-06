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
offloaded runs again), with a brief popup confirming the new state. The
same switch is reachable from PC01 with `bin/fm-pc02-personal-use.sh
on|off|status`. This manual switch is the only thing that stops PC02 testing:
a live PC02 model worker, a loaded llama-swap, and ordinary host CPU/GPU load
do not block an offload, because PC02 runs the test slots alongside a model.
The per-slot locks still bound how many suites run at once, and a run waits for
a free slot up to the offload's wait bound; an unreachable PC02 routes the run
to PC01 at once. Re-run `bin/fm-pc02-personal-use.sh install-toggle` if the
shortcut ever needs to be redeployed (safe to re-run).

### Reclaiming leaked test roots

`bin/fm-pc02-hygiene.sh` is an ssh wrapper, so run it where the checkout lives
(normally PC01). It is strictly read-only and prints the PC02 paths it counted,
one per `stale_test_root=` line - at most 50 per run, then a
`stale_test_roots_omitted=` count - so the printed list is the whole set a
manual pass may consider. Every removal command runs on PC02 itself, for
example inside `ssh pc02`: those are PC02 paths, and running `rm` with them from
PC01 would delete same-named PC01 directories instead.

`bin/fm-pc02-hygiene-lib.sh`'s header owns the exact definition of a counted
root. It counts exactly three classes, and only these may be removed:

- offload mirrors `$HOME/<FM_PC02_OFFLOAD_REMOTE_BASE>/run-*` left behind by a
  wrapper whose exit trap never ran;
- `$TMP_ROOT`/`fm-test-run.*` roots left by a direct test run;
- `$TMP_ROOT`/`fm-*` directories carrying a `.fm-test-fixture` marker
  (`tests/lib.sh` writes it). Never widen the match to a bare `fm-*`: real task
  temp roots live there too.

Every path the report printed already passed its stale-age bound and its live
reference scan (cwd, environment value, `--flag=value`, open file descriptor)
plus the owner-marker rules, so never add a root the report did not print: a
root it excluded is still owned, sometimes only through an environment value or
an open fd that a name search cannot see. The loop below re-checks on PC02 that
a path is one of the three counted classes, its stale-age bound, and its owner
markers (`run-*/pgid`, plus the fixture marker's recorded pid/start-time/cmdline
identity), then restores owner write with `chmod -R u+w` (test fixtures leave
read-only `*.git-hooks` directories that block `rm -rf`) and removes the root.

On PC01, hand the report's counted paths to PC02:

```bash
bin/fm-pc02-hygiene.sh | sed -n 's/^stale_test_root=//p' | ssh pc02 'cat > "$HOME/.pc02-stale-paths"'
```

On PC02 (inside `ssh pc02`), re-check and remove only those paths:

```bash
age=${FM_PC02_HYGIENE_STALE_AGE_SECS:-21600}
tmp_root=${FM_PC02_OFFLOAD_TMP_ROOT:-/tmp}
remote_base=${FM_PC02_OFFLOAD_REMOTE_BASE:-.fm-pc02-test-offload}
now=$(date +%s)
group_alive() {  # <root>: the mirrored run's pgid still names a live group
  local pg
  [ -r "$1/pgid" ] || return 1
  read -r pg < "$1/pgid" || return 1
  case "$pg" in "" | *[!0-9]*) return 1 ;; esac
  kill -0 -- "-$pg" 2>/dev/null
}
marker_owner_alive() {  # <root>: the marker's recorded owner is still that process
  local pid id start hex
  [ -r "$1/.fm-test-fixture" ] || return 1
  { read -r pid; read -r id; } < "$1/.fm-test-fixture" || return 1
  case "$pid" in "" | *[!0-9]*) return 1 ;; esac
  [ -n "$id" ] && [ -r "/proc/$pid/stat" ] || return 1
  start=$(awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$pid/stat" 2>/dev/null)
  set -- ${id#*=}
  [ "$1" = "$start" ] || return 1
  hex=$(od -An -v -tx1 "/proc/$pid/cmdline" 2>/dev/null | tr -d '[:space:]')
  [ "${id##*cmdline-hex=}" = "$hex" ]
}
removed=0
while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  case "$dir" in
    "$HOME/$remote_base"/run-*) ;;
    "$tmp_root"/fm-test-run.*) ;;
    "$tmp_root"/fm-*) [ -f "$dir/.fm-test-fixture" ] || continue ;;
    *) continue ;;
  esac
  [ -d "$dir" ] && [ ! -L "$dir" ] || continue
  group_alive "$dir" && continue
  marker_owner_alive "$dir" && continue
  if [ -f "$dir/.fm-test-fixture" ]; then
    mtime=$(stat -c %Y -- "$dir/.fm-test-fixture" 2>/dev/null) || continue
  else
    mtime=$(stat -c %Y -- "$dir" 2>/dev/null) || continue
  fi
  case "$mtime" in "" | *[!0-9]*) continue ;; esac
  [ $((now - mtime)) -ge "$age" ] || continue
  chmod -R u+w -- "$dir" 2>/dev/null || true
  rm -rf -- "$dir" && removed=$((removed + 1))
done < "$HOME/.pc02-stale-paths"
printf 'removed=%s\n' "$removed"
```

Then re-run `bin/fm-pc02-hygiene.sh` on PC01 and repeat while it still prints
`stale_test_root=` lines; `stale_test_roots` should reach 0, and its
`tmp_used_mib`/`disk_used_mib` lines show the reclaimed space. If a path the
loop just removed reappears in the next report, stop: something still owns it
and the report is the authority on that.

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
