# fm-pc02-sleep-watcher.ps1 - PC02-side companion to bin/fm-pc02-sleep-guard.sh.
#
# One long-running Windows process owns the keep-awake bridge: while the guard
# says PC02 has work, this process holds a Windows system power request with
# SetThreadExecutionState, and when the work ends it clears the request and
# resets Windows' own idle timer so the native 30-minute standby countdown
# starts then. Windows' native timer remains the primary sleep trigger.
# A forced S3 suspend is only a backstop for a host whose native timer is held
# by a pre-existing kernel request. It refuses to run unless hibernation is off
# and a wake-enabled RTC backstop task was registered and verified, and after a
# short test-window wake it restores the production 30-minute window.
#
# The guard is the single owner of the predicate and runs inside the default
# WSL distribution. A guard failure fails awake: a broken probe must not let
# Windows sleep through work it can no longer observe.
#
# Deployed and started by bin/fm-pc02-sleep-arming.sh; do not install it by hand.
# Status and transitions are logged to the configured log path, and the latest
# verdict is atomically written to the configured status path for diagnosis.
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$Distro = 'Ubuntu',

    [ValidateNotNullOrEmpty()]
    [string]$GuardPath = '/home/sean_/.local/bin/fm-pc02-sleep-guard.sh',

    [ValidateRange(2, 300)]
    [int]$PollSeconds = 20,

    [ValidateRange(1, 1440)]
    [int]$IdleMinutes = 30,

    [ValidateRange(2, 60)]
    [int]$WakeBackstopMinutes = 10,

    [ValidateNotNullOrEmpty()]
    [string]$WakeTaskName = 'PC02-fm-sleep-wake-backstop',

    [ValidateNotNullOrEmpty()]
    [string]$LogPath = 'C:\ProgramData\Pc02Power\watcher.log',

    [ValidateNotNullOrEmpty()]
    [string]$StatusPath = 'C:\ProgramData\Pc02Power\status.txt',

    [switch]$Once,

    [switch]$DryRun,

    [switch]$NoSleep
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class Pc02SleepGuardState {
    [Flags]
    public enum ExecutionState : uint {
        Continuous = 0x80000000,
        SystemRequired = 0x00000001
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern ExecutionState SetThreadExecutionState(ExecutionState state);

    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    // The C API takes one-byte BOOLEANs, not four-byte BOOLs. Marshaling them
    // as U1 is what makes bHibernate=FALSE actually select S3 instead of
    // letting the default 4-byte marshaling scramble the arguments.
    [DllImport("powrprof.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.U1)]
    public static extern bool SetSuspendState(
        [MarshalAs(UnmanagedType.U1)] bool hibernate,
        [MarshalAs(UnmanagedType.U1)] bool forceCritical,
        [MarshalAs(UnmanagedType.U1)] bool disableWakeEvent);

    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }
}
'@

function Invoke-ExecutionState([Pc02SleepGuardState+ExecutionState]$State) {
    if ($DryRun) {
        return
    }
    $result = [Pc02SleepGuardState]::SetThreadExecutionState($State)
    if ([uint32]$result -eq 0) {
        throw "SetThreadExecutionState failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
    }
}

function Write-Log([string]$Line) {
    try {
        $dir = Split-Path -Parent $LogPath
        if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 1048576)) {
            Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force
        }
        Add-Content -LiteralPath $LogPath -Value ("{0} {1}" -f ([DateTimeOffset]::UtcNow.ToString('o')), $Line)
    }
    catch {
        # Logging must never take the keep-awake bridge down.
    }
}

function Get-LastInputIdleSeconds {
    # The watcher must run in the interactive console session for this to be
    # meaningful; the installer registers it as an interactive logon task.
    $sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    if ($sessionId -eq 0) {
        return $null
    }
    try {
        $info = New-Object 'Pc02SleepGuardState+LASTINPUTINFO'
        $info.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf([type]('Pc02SleepGuardState+LASTINPUTINFO'))
        if (-not [Pc02SleepGuardState]::GetLastInputInfo([ref]$info)) {
            return $null
        }
        $idleMs = [uint32]([Environment]::TickCount - $info.dwTime)
        return [int]([math]::Floor($idleMs / 1000))
    }
    catch {
        return $null
    }
}

function Invoke-Sleep {
    # Windows' native idle timer is armed, but a pre-existing kernel request on
    # this host can hold it indefinitely. A forced suspend is the durable
    # backstop; SetSuspendState(FALSE, ...) suspends to S3 rather than hibernating.
    if ($DryRun -or $NoSleep) {
        return
    }
    Invoke-ExecutionState ([Pc02SleepGuardState+ExecutionState]::Continuous)
    if (-not [Pc02SleepGuardState]::SetSuspendState($false, $false, $false)) {
        throw "SetSuspendState failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
    }
}

function Test-S3Only {
    # The standing rule is sleep to S3, never hibernate. The installer turns
    # hibernate off; if it is available anyway, refuse the forced sleep rather
    # than risk stranding the host in a state Wi-Fi wake cannot reach.
    $text = (& powercfg.exe /a) -join "`n"
    $available = ($text -split 'The following sleep states are not available')[0]
    if ($available -notmatch 'Standby \(S3\)') {
        throw 'S3 standby is not available on this system'
    }
    if ($available -match '(?m)^\s*Hibernate\s*$') {
        throw 'hibernation is available; refusing a forced sleep until it is off or S3 is confirmed'
    }
}

function Register-WakeBackstop {
    # -WakeToRun is the RTC wake. Without a verified backstop the host must not
    # sleep: a failed magic packet would otherwise require a physical button.
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $at = (Get-Date).AddMinutes($WakeBackstopMinutes)
    $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit 0'
    $trigger = New-ScheduledTaskTrigger -Once -At $at
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Unregister-ScheduledTask -TaskName $WakeTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $WakeTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    $task = Get-ScheduledTask -TaskName $WakeTaskName -ErrorAction Stop
    if (-not $task.Settings.WakeToRun) {
        throw 'wake backstop task was not registered wake-enabled'
    }
    Write-Log ("wake backstop registered for {0}" -f $at.ToString('o'))
}

function Remove-WakeBackstop {
    Unregister-ScheduledTask -TaskName $WakeTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Read-KernelPowerEvents {
    # Post-wake evidence for the S3 guarantee. This never blocks the loop; the
    # pre-sleep Test-S3Only gate is the enforcement.
    foreach ($id in @(42, 107)) {
        try {
            $events = Get-WinEvent -FilterHashtable @{LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = $id} -MaxEvents 2 -ErrorAction Stop
            foreach ($event in $events) {
                $message = ($event.Message -replace '\s+', ' ').Trim()
                if ($message.Length -gt 400) { $message = $message.Substring(0, 400) }
                Write-Log ("kernel-power id=$id {0} {1}" -f $event.TimeCreated.ToString('o'), $message)
            }
        }
        catch {
            Write-Log "kernel-power id=$id read failed: $($_.Exception.Message)"
        }
    }
}

function Restore-ProductionWindow {
    # A test window is short only in the watcher's memory. After the first wake
    # it returns to 30 minutes and rewrites its own task argument so a restart
    # cannot silently re-arm a short window.
    if ($IdleMinutes -lt 30) {
        & powercfg.exe /change standby-timeout-ac 30 | Out-Null
        $script:IdleMinutes = 30
        $script:idleSeconds = 1800
        try {
            $task = Get-ScheduledTask -TaskName 'PC02-fm-sleep-watcher' -ErrorAction Stop
            $arguments = $task.Actions[0].Arguments -replace '-IdleMinutes\s+\d+', '-IdleMinutes 30'
            if ($task.Actions[0].Arguments -ne $arguments) {
                $action = New-ScheduledTaskAction -Execute $task.Actions[0].Execute -Argument $arguments
                Set-ScheduledTask -TaskName 'PC02-fm-sleep-watcher' -Action $action | Out-Null
            }
        }
        catch {
            Write-Log "could not rewrite the watcher task to 30 minutes: $($_.Exception.Message)"
        }
        Write-Log 'restored production idle window to 30 minutes after the test sleep'
    }
}

function Write-Status([bool]$Inhibited, [string]$Reasons, [string]$ErrorText) {
    try {
        $dir = Split-Path -Parent $StatusPath
        if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $state = if ($Inhibited) { 'inhibited' } else { 'eligible' }
        $line = "ts=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) state=$state reasons=$Reasons idle_seconds=$idleSeconds input_idle=$lastInputIdle"
        if ($ErrorText) { $line = "$line error=$($ErrorText -replace '\s+', ' ')" }
        Set-Content -LiteralPath $StatusPath -Value $line -Encoding ascii
    }
    catch {
        # Status is diagnostic only, but record why it failed once it is the
        # only remaining clue (for example a Windows ACL denial).
        try { Write-Log "status write failed: $($_.Exception.Message)" } catch {}
    }
}

function Invoke-Guard {
    # A busy PC02 can make WSL slow to start a command. Bound the probe so a
    # hung distro fails awake instead of wedging the watcher with a stale
    # verdict. The files live beside the status file and are reused one poll at
    # a time by the single watcher instance.
    $dir = Split-Path -Parent $StatusPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $outFile = Join-Path $dir 'guard.out'
    $errFile = Join-Path $dir 'guard.err'
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath 'wsl.exe' `
        -ArgumentList @('-d', $Distro, '--', 'bash', $GuardPath, 'status') `
        -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    if (-not $process.WaitForExit(15000)) {
        & taskkill.exe /T /F /PID $process.Id 2>&1 | Out-Null
        throw "guard probe timed out"
    }
    $output = @()
    if (Test-Path -LiteralPath $outFile) { $output += Get-Content -LiteralPath $outFile }
    if (Test-Path -LiteralPath $errFile) { $output += Get-Content -LiteralPath $errFile }
    if ($null -ne $process.ExitCode -and $process.ExitCode -ne 0) {
        throw "guard exited $($process.ExitCode)`: $($output -join ' ')"
    }
    $verdict = $null
    foreach ($line in $output) {
        if ($line -match '^(busy|free)(\s|$)') {
            $verdict = $line.Trim()
            break
        }
    }
    if (-not $verdict) {
        throw "guard returned no verdict: $($output -join ' ')"
    }
    return $verdict
}

$lastReasons = ''
$inhibited = $false
$lastReasonsLogged = $null
$lastBusyAt = [DateTimeOffset]::UtcNow
$idleSeconds = $IdleMinutes * 60
$lastInputIdle = 'unknown'
# The host is awake when this process starts, so any backstop left by a prior
# incarnation is stale.
Remove-WakeBackstop
try {
    while ($true) {
        $shouldInhibit = $true
        $reasons = 'guard-error'
        $errorText = ''
        try {
            $verdict = Invoke-Guard
            if ($verdict -match '^free$') {
                $shouldInhibit = $false
                $reasons = 'free'
            }
            elseif ($verdict -match '^busy\s*(.*)$') {
                $shouldInhibit = $true
                $reasons = $Matches[1]
                if (-not $reasons) { $reasons = 'busy' }
            }
            else {
                throw "unrecognized guard verdict: $verdict"
            }
        }
        catch {
            # Fail awake: never sleep through work the probe cannot see.
            $shouldInhibit = $true
            $reasons = 'guard-error'
            $errorText = $_.Exception.Message
            Write-Log "guard error: $errorText"
        }

        $inputIdle = Get-LastInputIdleSeconds
        if ($null -eq $inputIdle) { $lastInputIdle = 'unknown' } else { $lastInputIdle = $inputIdle }
        $now = [DateTimeOffset]::UtcNow
        if ($shouldInhibit -or ($null -ne $inputIdle -and $inputIdle -lt $idleSeconds)) {
            $lastBusyAt = $now
        }

        # The forced-suspend backstop: only after the guard has been free and
        # the console quiet for the whole window, and only with a verified RTC
        # wake backstop and a host that can enter S3 without hibernating.
        if (-not $NoSleep -and -not $shouldInhibit -and $null -ne $inputIdle -and $inputIdle -ge $idleSeconds -and ($now - $lastBusyAt).TotalSeconds -ge $idleSeconds) {
            $sleepAllowed = $true
            try {
                Test-S3Only
                Register-WakeBackstop
            }
            catch {
                $sleepAllowed = $false
                Write-Log "refusing forced sleep: $($_.Exception.Message)"
                $lastBusyAt = [DateTimeOffset]::UtcNow
            }
            if ($sleepAllowed) {
                Write-Log "idle for $idleSeconds s; suspending PC02"
                try {
                    Invoke-Sleep
                    $lastBusyAt = [DateTimeOffset]::UtcNow
                }
                catch {
                    Write-Log "forced suspend failed: $($_.Exception.Message)"
                    $lastBusyAt = [DateTimeOffset]::UtcNow
                }
                finally {
                    Remove-WakeBackstop
                }
                Read-KernelPowerEvents
                Restore-ProductionWindow
            }
        }

        $changed = ($shouldInhibit -ne $inhibited) -or ($reasons -ne $lastReasonsLogged)
        if ($shouldInhibit -ne $inhibited) {
            if ($shouldInhibit) {
                Invoke-ExecutionState (
                    [Pc02SleepGuardState+ExecutionState]::Continuous -bor
                    [Pc02SleepGuardState+ExecutionState]::SystemRequired
                )
            }
            else {
                Invoke-ExecutionState ([Pc02SleepGuardState+ExecutionState]::Continuous)
                # A non-continuous request resets Windows' system idle timer, so
                # the native standby countdown starts when the work ends.
                Invoke-ExecutionState ([Pc02SleepGuardState+ExecutionState]::SystemRequired)
            }
            $inhibited = $shouldInhibit
        }
        if ($changed) {
            $stateLabel = if ($shouldInhibit) { 'inhibited' } else { 'eligible' }
            Write-Log "state=$stateLabel reasons=$reasons"
            $lastReasonsLogged = $reasons
        }
        $lastReasons = $reasons
        Write-Status $shouldInhibit $lastReasons $errorText
        if ($Once) { break }
        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    if ($inhibited) {
        try { Invoke-ExecutionState ([Pc02SleepGuardState+ExecutionState]::Continuous) } catch {}
    }
}
