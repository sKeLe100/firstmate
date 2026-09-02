# Windows post-update auto-recovery (PC01, PC02)

Captain-actioned setup (captain-authorized 2026-08-26) so a Windows 11 update reboot on PC01 or
PC02 does not strand the fleet at the login screen.
Both machines are tailnet-only and never exposed externally, so local Autologon credentials are an
accepted tradeoff here.
Every command below is paste-ready for the captain to run at the machine in an elevated PowerShell
window; no worker or automation runs these unattended.

## What this buys

- The machine signs in on its own after a Windows Update reboot, with no one at the keyboard.
- PC01: WSL, the firstmate host's tmux serving session, and its dashboard servers come back up
  at logon, via Task Scheduler.
- PC02: the WSL manual-start gap is closed and llama-swap serving comes back up at logon, via the
  same mechanism.
- Windows' own "restart apps after sign-in" and active-hours settings reduce how often this path is
  even needed.

## 1. Enable automatic sign-in (both machines)

Use Sysinternals Autologon rather than hand-editing the registry when possible - it stores the
password with `LSA` secrets instead of a plaintext registry value.

```powershell
# Elevated PowerShell. Downloads and runs Sysinternals Autologon interactively.
Invoke-WebRequest -Uri "https://download.sysinternals.com/files/AutoLogon.zip" -OutFile "$env:TEMP\AutoLogon.zip"
Expand-Archive -Path "$env:TEMP\AutoLogon.zip" -DestinationPath "$env:TEMP\AutoLogon" -Force
& "$env:TEMP\AutoLogon\Autologon64.exe"
```

Autologon opens a small dialog: fill in the local username, domain (use the machine name for a
local account), and password, then click Enable. It writes `AutoAdminLogon`, `DefaultUserName`,
and an obfuscated `DefaultPassword` under
`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`.

If Autologon cannot be fetched, the registry-only fallback (plaintext password at rest - only use
this if Autologon is genuinely unavailable) is:

```powershell
$key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $key -Name AutoAdminLogon -Value "1"
Set-ItemProperty -Path $key -Name DefaultUserName -Value "<local-username>"
Set-ItemProperty -Path $key -Name DefaultPassword -Value "<local-password>"
Set-ItemProperty -Path $key -Name DefaultDomainName -Value "$env:COMPUTERNAME"
```

Also stop the machine from sleeping and from demanding a password on wake, so neither a screen
timeout nor a lock re-strands the machine between the auto sign-in and the scheduled task firing.
The two `powercfg` calls only keep the machine awake (no standby on AC, no display blanking); they
do not touch the sign-in prompt. The `ConsoleLock` setting is the one behind "If you've been away,
when should Windows require you to sign in again" (Settings > Accounts > Sign-in options); setting
it to 0 on both power sources, and pinning it via the matching policy registry key so a Windows
Update does not reset it, is what stops a wake, hibernate resume, fast startup, or manual Win+L
from leaving a login screen waiting:

```powershell
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0

# Never require a sign-in on wake (ConsoleLock: 0 = never, 1 = when the PC wakes from sleep).
powercfg /setacvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0
powercfg /setdcvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0
powercfg /setactive SCHEME_CURRENT

# Pin the same ConsoleLock setting as policy so an update cannot restore the sign-in prompt.
$lock = 'HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\0e796bdb-100d-47d6-a2d5-f7d2daa51f51'
New-Item -Path $lock -Force | Out-Null
New-ItemProperty -Path $lock -Name 'ACSettingIndex' -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $lock -Name 'DCSettingIndex' -Value 0 -PropertyType DWord -Force | Out-Null
```

## 2. PC01: bring the firstmate stack back at logon

Create one scheduled task that fires at logon of the autologon account and drives WSL to bring up
tmux and the dashboard servers.
Adjust `<distro>`, `<wsl-user>`, and the startup command to match how the firstmate host and
dashboards are normally started on PC01.

```powershell
$action = New-ScheduledTaskAction -Execute "wsl.exe" `
  -Argument "-d <distro> -u <wsl-user> -- bash -lc '~/firstmate/bin/fm-startup-network.sh >/tmp/fm-boot.log 2>&1 & tmux new-session -d -s firstmate; ~/dashboards/start.sh >/tmp/dash-boot.log 2>&1 &'"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\<local-username>"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName "PC01-FirstmateAutoStart" -Action $action -Trigger $trigger `
  -Settings $settings -RunLevel Highest -Force
```

Replace the inner `bash -lc '...'` command with whatever this machine's actual tmux/dashboard
launch script is - the placeholder above only names the shape (start tmux detached, then the
dashboard servers detached) so the task does not block the logon trigger waiting on a foreground
process.

## 3. PC02: close the WSL gap and bring llama-swap back at logon

Same scheduled-task shape as PC01, with the addition that PC02's WSL has been manual-start only
until now; the `-AtLogOn` trigger below is what closes that gap, since Windows does not auto-launch
a WSL distro on its own.

```powershell
$action = New-ScheduledTaskAction -Execute "wsl.exe" `
  -Argument "-d <distro> -u <wsl-user> -- bash -lc '~/llama-swap/start.sh >/tmp/llama-swap-boot.log 2>&1 &'"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\<local-username>"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName "PC02-LlamaSwapAutoStart" -Action $action -Trigger $trigger `
  -Settings $settings -RunLevel Highest -Force
```

If llama-swap is normally launched from inside a persistent WSL systemd service instead of an
ad hoc script, replace the inner command with the matching `sudo systemctl start <unit>` (or
`service <name> start`) call instead of a raw script path.

## 4. Complementary Windows settings

- **Restart apps after sign-in**: Settings > Accounts > Sign-in options > toggle on "Automatically
  save my restartable apps and restart them after I sign in." This only covers apps Windows itself
  tracked as open at shutdown (mostly Store/UWP apps and a subset of well-behaved Win32 apps) - it
  is a helpful bonus, not a substitute for the Task Scheduler entries above, which are the only
  reliable path for WSL and tmux-hosted processes.
- **Active hours**: Settings > Windows Update > Advanced options > Active hours. Set active hours to
  bracket the periods this machine must not be mid-reboot (e.g. working hours), so update-driven
  restarts land in a predictable low-traffic window instead of colliding with active use.

## 5. Verification checklist (simulated reboot)

Run this on each machine after completing steps 1-3, to prove the stack self-restores with no
manual intervention:

1. Confirm the scheduled task exists and is enabled: `Get-ScheduledTask -TaskName "PC01-FirstmateAutoStart"` (or the PC02 task name) shows `State: Ready`.
2. Confirm autologon values are set: `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' | Select AutoAdminLogon,DefaultUserName`.
3. Trigger a real restart: `Restart-Computer -Force`.
4. Do not touch the keyboard or mouse during boot.
5. After the machine finishes rebooting, confirm on-screen that it reached the desktop (or is
   headless-idle at desktop) without a login prompt waiting.
6. From another tailnet machine, confirm the expected services answer:
   - PC01: the firstmate host and dashboard ports respond (e.g. `curl` the dashboard URL).
   - PC02: llama-swap's port responds (e.g. `curl` its health/models endpoint).
7. Check the boot logs left by the scheduled task (`/tmp/fm-boot.log`, `/tmp/dash-boot.log`,
   `/tmp/llama-swap-boot.log` inside WSL) for errors, even if step 6 passed, since a service can
   crash-loop and still leave a stale port bound.
8. If any check fails, inspect Task Scheduler's history for the task (right-click the task > View
   History) for the exact failure, then re-register the task by re-running the `Register-ScheduledTask`
   block from section 2 (PC01) or section 3 (PC02) with the correction, and repeat this checklist
   from item 1.

A pass on all eight items is the proof bar: the machine reached a working desktop and every tracked
service answered, with nobody at the keyboard past step 3.

## Maintaining this file

Keep this page limited to current setup steps and the verification checklist for these two
machines.
Route anything that stops being current (a changed startup command, a retired task name) back
through the captain rather than leaving stale paste-ready commands in place.
