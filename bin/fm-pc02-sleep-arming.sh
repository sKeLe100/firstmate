#!/usr/bin/env bash
# fm-pc02-sleep-arming.sh - single owner of PC02's idle-sleep posture: deploy
# the keep-awake watcher, arm the AC standby timer, and report or roll back the
# posture. PC02-specific mechanics (the keep-awake predicate, the Windows power
# request, and the wake bridge) stay with their own owners:
#   - bin/fm-pc02-sleep-guard.sh runs inside PC02's WSL and owns the predicate;
#   - bin/fm-pc02-sleep-watcher.ps1 holds the Windows system request while the
#     predicate is busy and resets the native idle timer when work ends;
#   - bin/fm-pc02-wake.sh sends the WoWLAN packet and waits for SSH.
# This script only installs those pieces and uses Windows' own sleep timer
# (STANDBYIDLE on AC) as the sleep authority, so real console and controller
# input keep PC02 awake without a second idle clock.
#
# Usage:
#   fm-pc02-sleep-arming.sh install [--host HOST] [--idle-minutes N]
#   fm-pc02-sleep-arming.sh status [--host HOST]
#   fm-pc02-sleep-arming.sh uninstall [--host HOST]
#   fm-pc02-sleep-arming.sh --help
#
# install is idempotent and must run while PC02 is reachable; it caches the
# wake config through bin/fm-pc02-wake.sh discover, deploys the guard to the
# WSL home, deploys the watcher to C:\ProgramData\Pc02Power, registers and
# starts the logon scheduled task, sets AC standby-idle to --idle-minutes
# (default 30), sets AC hibernate-idle to never, and adds a Parsec system
# request override so Parsec's blanket "system required" request cannot block
# the native timer. It never shuts down or reboots Windows.
#
# status is read-only and prints `asleep (wakeable)` when PC02 does not answer.
# uninstall stops and removes the task, removes the Parsec override, restores
# the observed AC standby timer of never, and removes the deployed files.
#
# Env overrides:
#   FM_PC02_WAKE_HOST     SSH target (default: pc02)
#   FM_PC02_WAKE_CONFIG   wake config path (see bin/fm-pc02-wake.sh)
set -u

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-pc02-sleep-arming.sh: %s\n' "$1" >&2
  exit 1
}

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARD_SRC="$SELF_DIR/fm-pc02-sleep-guard.sh"
WATCHER_SRC="$SELF_DIR/fm-pc02-sleep-watcher.ps1"
WAKE="$SELF_DIR/fm-pc02-wake.sh"

MODE=${1:-}
case "$MODE" in
  install | status | uninstall) shift ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "fm-pc02-sleep-arming.sh: usage: fm-pc02-sleep-arming.sh install|status|uninstall [options]" >&2
    exit 2
    ;;
esac

HOST=${FM_PC02_WAKE_HOST:-pc02}
IDLE_MINUTES=30
while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      [ "$#" -ge 2 ] || die "--host needs a value"
      HOST=$2
      shift 2
      ;;
    --host=*)
      HOST=${1#--host=}
      shift
      ;;
    --idle-minutes)
      [ "$#" -ge 2 ] || die "--idle-minutes needs a value"
      IDLE_MINUTES=$2
      shift 2
      ;;
    --idle-minutes=*)
      IDLE_MINUTES=${1#--idle-minutes=}
      shift
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

case "$HOST" in
  '' | -* | *[!A-Za-z0-9._@-]*) die "unsafe SSH host: $HOST" ;;
esac
case "$IDLE_MINUTES" in
  '' | *[!0-9]*) die "--idle-minutes must be a positive integer" ;;
esac
[ "$IDLE_MINUTES" -ge 1 ] || die "--idle-minutes must be at least 1"

[ -f "$GUARD_SRC" ] || die "missing $GUARD_SRC"
[ -f "$WATCHER_SRC" ] || die "missing $WATCHER_SRC"
[ -x "$WAKE" ] || die "missing executable $WAKE"

remote_bash() {  # run a bash script from stdin on PC02
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" bash -s
}

powershell_remote() {  # run one PowerShell command line on PC02
  local command=$1
  remote_bash <<REMOTE
/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command '$command' 2>&1 | tr -d '\r'
REMOTE
}

win_temp_wsl() {  # print PC02's Windows temp dir as a /mnt/c path
  local win
  win=$(powershell_remote '[Environment]::GetFolderPath("LocalApplicationData")' | tail -1) || return 1
  [ -n "$win" ] || return 1
  printf '%s' "$win" | sed 's|^C:|/mnt/c|; s|\\|/|g'
}

require_awake() {
  if remote_bash <<<'true' >/dev/null 2>&1; then
    return 0
  fi
  echo "fm-pc02-sleep-arming.sh: PC02 is not reachable; waking it through bin/fm-pc02-wake.sh" >&2
  "$WAKE" ensure --host "$HOST" --timeout 120 >/dev/null || die "PC02 did not answer after a wake attempt"
}

install_pieces() {
  local remote_home temp_wsl temp_win watcher_name setup_name setup_local setup_win out
  require_awake
  remote_home=$(remote_bash <<'REMOTE' | tail -1
printf %s "$HOME"
REMOTE
  ) || die "could not read PC02's WSL home"
  [ -n "$remote_home" ] || die "PC02 returned an empty WSL home"

  # Cache the Wi-Fi MAC, LAN address, tailnet address, and LAN broadcast now,
  # while PC02 can be queried.
  "$WAKE" discover --host "$HOST" >/dev/null || die "could not discover PC02's wake addresses"

  # Deploy the predicate to the WSL home; the watcher invokes it there.
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" \
    'mkdir -p "$HOME/.local/bin" && cat > "$HOME/.local/bin/fm-pc02-sleep-guard.sh" && chmod 0755 "$HOME/.local/bin/fm-pc02-sleep-guard.sh"' \
    <"$GUARD_SRC" || die "could not copy the sleep guard to PC02"

  temp_wsl=$(win_temp_wsl) || die "could not read PC02's Windows temp directory"
  temp_win=$(printf '%s' "$temp_wsl" | sed 's|^/mnt/c|C:|; s|/|\\\\|g')
  watcher_name="fm-pc02-sleep-watcher.ps1"
  setup_name="fm-pc02-sleep-arming-install.ps1"

  ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" \
    "mkdir -p '$temp_wsl' && cat > '$temp_wsl/$watcher_name'" <"$WATCHER_SRC" \
    || die "could not copy the watcher to PC02"

  setup_local=$(mktemp "${TMPDIR:-/tmp}/fm-pc02-arming.XXXXXX") || die "could not create a temporary setup file"
  trap 'rm -f "${setup_local:-}"' EXIT
  cat >"$setup_local" <<EOF
\$ErrorActionPreference = 'Stop'
\$InstallDir = 'C:\\ProgramData\\Pc02Power'
\$TaskName = 'PC02-fm-sleep-watcher'
\$SourceWatcher = '$temp_win\\$watcher_name'
New-Item -ItemType Directory -Force -Path \$InstallDir | Out-Null
\$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
icacls.exe \$InstallDir /grant "*\${sid}:(OI)(CI)M" | Out-Null
Copy-Item -LiteralPath \$SourceWatcher -Destination "\$InstallDir\\fm-pc02-sleep-watcher.ps1" -Force
\$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
\$ps = "\$env:SystemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
\$action = New-ScheduledTaskAction -Execute \$ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \`"\$InstallDir\\fm-pc02-sleep-watcher.ps1\`" -IdleMinutes $IDLE_MINUTES"
\$trigger = New-ScheduledTaskTrigger -AtLogOn -User \$user
\$principal = New-ScheduledTaskPrincipal -UserId \$user -LogonType Interactive -RunLevel Highest
\$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Stop-ScheduledTask -TaskName \$TaskName -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName \$TaskName -Action \$action -Trigger \$trigger -Principal \$principal -Settings \$settings -Force | Out-Null
Start-ScheduledTask -TaskName \$TaskName
powercfg.exe /change standby-timeout-ac $IDLE_MINUTES
if (\$LASTEXITCODE -ne 0) { throw "powercfg standby-timeout-ac failed: \$LASTEXITCODE" }
powercfg.exe /change hibernate-timeout-ac 0
powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_SLEEP HYBRIDSLEEP 0
powercfg.exe /setactive SCHEME_CURRENT
if (Get-Process -Name parsecd -ErrorAction SilentlyContinue) {
  powercfg.exe /requestsoverride PROCESS parsecd.exe System
  if (\$LASTEXITCODE -ne 0) { throw "powercfg requestsoverride failed: \$LASTEXITCODE" }
}
Start-Sleep -Seconds 3
\$task = Get-ScheduledTask -TaskName \$TaskName
Write-Output "installed task=\$TaskName user=\$user idleMinutes=$IDLE_MINUTES taskState=\$(\$task.State)"
if (Test-Path -LiteralPath "\$InstallDir\\status.txt") { Write-Output ("watcher=" + (Get-Content -LiteralPath "\$InstallDir\\status.txt" -Raw).Trim()) }
EOF
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" \
    "cat > '$temp_wsl/$setup_name'" <"$setup_local" \
    || die "could not copy the install script to PC02"

  setup_win="$temp_win\\$setup_name"
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
    "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$setup_win' 2>&1" | tr -d '\r') \
    || die "the PC02 install script failed: $(printf '%s\n' "$out" | tail -3 | tr '\n' ' ')"
  printf '%s\n' "$out"

  # Clean the staging files; the installed copies are the durable ones.
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" "rm -rf '$temp_wsl'" >/dev/null 2>&1 || true

  verify_installed
}

verify_installed() {
  local guard standby hibernate task watcher
  guard=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" \
    'bash "$HOME/.local/bin/fm-pc02-sleep-guard.sh" status 2>&1' | tr -d '\r' | tail -1) \
    || die "the deployed sleep guard did not answer"
  case "$guard" in
    free | busy*) ;;
    *) die "the deployed sleep guard returned an unexpected verdict: $guard" ;;
  esac
  standby=$(powershell_remote 'powercfg /q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE' \
    | sed -n 's/.*Current AC Power Setting Index: 0x//p' | tail -1)
  hibernate=$(powershell_remote 'powercfg /q SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE' \
    | sed -n 's/.*Current AC Power Setting Index: 0x//p' | tail -1)
  task=$(powershell_remote '(Get-ScheduledTask -TaskName "PC02-fm-sleep-watcher").State' | tail -1)
  watcher=$(powershell_remote 'Get-Content -LiteralPath "C:\ProgramData\Pc02Power\status.txt" -ErrorAction SilentlyContinue' | tail -1)
  case "$standby" in
    '' | *[!0-9A-Fa-f]*) die "could not read PC02's AC standby timer" ;;
  esac
  [ "$((16#$standby))" -eq "$((IDLE_MINUTES * 60))" ] \
    || die "PC02 AC standby timer is $((16#$standby))s, expected $((IDLE_MINUTES * 60))s"
  case "$hibernate" in
    '' | *[!0-9A-Fa-f]*) die "could not read PC02's AC hibernate timer" ;;
  esac
  [ "$((16#$hibernate))" -eq 0 ] || die "PC02 AC hibernate timer is $((16#$hibernate))s, expected 0 (never)"
  case "$task" in
    Ready | Running) ;;
    *) die "PC02 sleep watcher task state is '$task'" ;;
  esac
  printf 'guard=%s standby_ac=%ss hibernate_ac=0 task=%s\n' "$guard" "$((16#$standby))" "$task"
  [ -z "$watcher" ] || printf 'watcher=%s\n' "$watcher"
}

status_pieces() {
  local probe
  probe=$("$WAKE" status --host "$HOST" 2>/dev/null) || probe=unknown
  case "$probe" in
    asleep)
      printf 'power=asleep (wakeable)\n'
      return 0
      ;;
    awake) ;;
    *)
      printf 'power=unreachable\n'
      return 0
      ;;
  esac
  remote_bash <<'REMOTE'
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
echo "guard=$(bash "$HOME/.local/bin/fm-pc02-sleep-guard.sh" status 2>&1 </dev/null | tail -1)"
echo "watcher=$(cat /mnt/c/ProgramData/Pc02Power/status.txt 2>/dev/null | tail -1)"
echo "task=$("$PS" -NoProfile -Command '(Get-ScheduledTask -TaskName "PC02-fm-sleep-watcher" -ErrorAction SilentlyContinue).State' 2>/dev/null </dev/null | tr -d '\r' | tail -1)"
echo "standby_ac=$("$PS" -NoProfile -Command 'powercfg /q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE' 2>/dev/null </dev/null | grep 'Current AC Power Setting Index' | awk '{print $NF}')"
echo "hibernate_ac=$("$PS" -NoProfile -Command 'powercfg /q SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE' 2>/dev/null </dev/null | grep 'Current AC Power Setting Index' | awk '{print $NF}')"
echo '--- requests ---'
"$PS" -NoProfile -Command 'powercfg /requests' 2>/dev/null </dev/null | tr -d '\r'
echo '--- overrides ---'
"$PS" -NoProfile -Command 'powercfg /requestsoverride' 2>/dev/null </dev/null | tr -d '\r'
REMOTE
}

uninstall_pieces() {
  require_awake
  remote_bash <<'REMOTE'
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
"$PS" -NoProfile -Command '
  Stop-ScheduledTask -TaskName "PC02-fm-sleep-watcher" -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName "PC02-fm-sleep-watcher" -Confirm:$false -ErrorAction SilentlyContinue
  powercfg.exe /requestsoverride PROCESS parsecd.exe
  powercfg.exe /change standby-timeout-ac 0
  powercfg.exe /change hibernate-timeout-ac 0
' </dev/null 2>&1 | tr -d '\r'
rm -rf /mnt/c/ProgramData/Pc02Power
rm -f "$HOME/.local/bin/fm-pc02-sleep-guard.sh"
REMOTE
  printf 'uninstalled; AC standby restored to never\n'
}

case "$MODE" in
  install) install_pieces ;;
  status) status_pieces ;;
  uninstall) uninstall_pieces ;;
esac
