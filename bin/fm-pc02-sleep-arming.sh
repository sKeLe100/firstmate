#!/usr/bin/env bash
# fm-pc02-sleep-arming.sh - single owner of PC02's idle-sleep posture: deploy
# the keep-awake watcher, arm the AC standby timer, and report or roll back the
# posture. PC02-specific mechanics (the keep-awake predicate, the Windows power
# request, and the wake bridge) stay with their own owners:
#   - bin/fm-pc02-sleep-guard.sh runs inside PC02's WSL and owns the predicate;
#   - bin/fm-pc02-sleep-watcher.ps1 holds the Windows system request while the
#     predicate is busy and resets the native idle timer when work ends;
#   - bin/fm-pc02-wake.sh sends the WoWLAN packet and waits for SSH.
# This script only installs those pieces. Windows' own sleep timer (STANDBYIDLE
# on AC) is the primary authority, so real console and controller input keep
# PC02 awake without a second idle clock; the watcher's forced S3 path is a
# gated backstop that needs hibernation off and a verified RTC wake task.
#
# Usage:
#   fm-pc02-sleep-arming.sh install [--host HOST] [--idle-minutes N]
#   fm-pc02-sleep-arming.sh test-sleep [--host HOST] [--attended]
#                                      [--test-minutes N] [--sleep-timeout SECS]
#                                      [--wake-timeout SECS] [--backstop-wait SECS]
#   fm-pc02-sleep-arming.sh check-attendance [--attended]
#   fm-pc02-sleep-arming.sh status [--host HOST]
#   fm-pc02-sleep-arming.sh uninstall [--host HOST]
#   fm-pc02-sleep-arming.sh --help
#
# install is idempotent and must run while PC02 is reachable; it caches the
# wake config through bin/fm-pc02-wake.sh discover, deploys the guard to the
# WSL home, deploys the watcher to C:\ProgramData\Pc02Power, registers and
# starts the logon scheduled task, sets AC standby-idle to --idle-minutes
# (default 30), sets AC hibernate-idle to never, turns hibernation off so the
# only suspend state is S3, proves that a wake-enabled backstop task can be
# registered, and adds a Parsec system request override. It never shuts down
# or reboots Windows.
#
# test-sleep is the only remote sleep check. It refuses unless the captain is
# present: it fails when the home has state/.afk or when PC01's America/New_York
# local hour is 22:00-08:00, and both refusals need an explicit --attended.
# It keeps the OS standby timer at the production 30 minutes and arms only the
# watcher's in-memory test window, waits for the sleep, wakes PC02, and always
# reinstalls the 30-minute production window afterward. The watcher also
# restores 30 minutes itself after any test-window wake, even if this command
# is gone, and it refuses a forced sleep unless the RTC wake backstop task was
# registered and verified and hibernation is off.
#
# check-attendance runs only the presence gate, prints allowed or refused, and
# is safe to use in tests and by an operator before a test.
#
# status is read-only and prints `asleep (wakeable)` when PC02 does not answer.
# uninstall stops and removes the task, removes the Parsec override, restores
# the observed AC standby timer of never, and removes the deployed files. It
# leaves hibernation off because the rule is S3 only.
#
# Env overrides:
#   FM_PC02_WAKE_HOST     SSH target (default: pc02)
#   FM_PC02_WAKE_CONFIG   wake config path (see bin/fm-pc02-wake.sh)
#   FM_HOME, FM_STATE_OVERRIDE  home whose state/.afk gates test-sleep
set -u

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-pc02-sleep-arming.sh: %s\n' "$1" >&2
  exit 1
}

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=$(cd "$SELF_DIR/.." && pwd -P)
GUARD_SRC="$SELF_DIR/fm-pc02-sleep-guard.sh"
WATCHER_SRC="$SELF_DIR/fm-pc02-sleep-watcher.ps1"
WAKE="$SELF_DIR/fm-pc02-wake.sh"

MODE=${1:-}
case "$MODE" in
  install | test-sleep | check-attendance | status | uninstall) shift ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "fm-pc02-sleep-arming.sh: usage: fm-pc02-sleep-arming.sh install|test-sleep|check-attendance|status|uninstall [options]" >&2
    exit 2
    ;;
esac

HOST=${FM_PC02_WAKE_HOST:-pc02}
IDLE_MINUTES=30
WATCHER_IDLE_MINUTES=
ATTENDED=0
TEST_MINUTES=2
SLEEP_TIMEOUT=300
WAKE_TIMEOUT=120
BACKSTOP_WAIT=700
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
    --attended)
      ATTENDED=1
      shift
      ;;
    --test-minutes)
      [ "$#" -ge 2 ] || die "--test-minutes needs a value"
      TEST_MINUTES=$2
      shift 2
      ;;
    --test-minutes=*)
      TEST_MINUTES=${1#--test-minutes=}
      shift
      ;;
    --sleep-timeout)
      [ "$#" -ge 2 ] || die "--sleep-timeout needs a value"
      SLEEP_TIMEOUT=$2
      shift 2
      ;;
    --sleep-timeout=*)
      SLEEP_TIMEOUT=${1#--sleep-timeout=}
      shift
      ;;
    --wake-timeout)
      [ "$#" -ge 2 ] || die "--wake-timeout needs a value"
      WAKE_TIMEOUT=$2
      shift 2
      ;;
    --wake-timeout=*)
      WAKE_TIMEOUT=${1#--wake-timeout=}
      shift
      ;;
    --backstop-wait)
      [ "$#" -ge 2 ] || die "--backstop-wait needs a value"
      BACKSTOP_WAIT=$2
      shift 2
      ;;
    --backstop-wait=*)
      BACKSTOP_WAIT=${1#--backstop-wait=}
      shift
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

WATCHER_IDLE_MINUTES=${WATCHER_IDLE_MINUTES:-$IDLE_MINUTES}

case "$HOST" in
  '' | -* | *[!A-Za-z0-9._@-]*) die "unsafe SSH host: $HOST" ;;
esac
for pair in "idle-minutes:$IDLE_MINUTES" "watcher-idle-minutes:$WATCHER_IDLE_MINUTES" \
  "test-minutes:$TEST_MINUTES" "sleep-timeout:$SLEEP_TIMEOUT" \
  "wake-timeout:$WAKE_TIMEOUT" "backstop-wait:$BACKSTOP_WAIT"; do
  name=${pair%%:*}
  value=${pair#*:}
  case "$value" in
    '' | *[!0-9]*) die "--$name must be a positive integer" ;;
  esac
  [ "$value" -ge 1 ] || die "--$name must be at least 1"
done
if [ "$MODE" = install ] && [ "$IDLE_MINUTES" -lt 30 ]; then
  die "install keeps the production window at 30 minutes or more; use test-sleep for a shortened test window"
fi

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

state_dir() {
  printf '%s' "${FM_STATE_OVERRIDE:-${FM_HOME:-$FM_ROOT}/state}"
}

assert_attended() {
  # A remote sleep test is only safe while the captain is present. The two
  # observable proxies are the away record and PC01's America/New_York quiet
  # hours; either refusal can be overridden only by an explicit --attended.
  local state hour
  [ "$ATTENDED" -eq 1 ] && return 0
  state=$(state_dir)
  if [ -e "$state/.afk" ]; then
    printf 'fm-pc02-sleep-arming.sh: refusing a remote sleep test while state/.afk exists; pass --attended only when the captain is present\n' >&2
    return 3
  fi
  hour=$(TZ=America/New_York date +%H 2>/dev/null) || {
    printf 'fm-pc02-sleep-arming.sh: cannot determine PC01 America/New_York local hour; refusing\n' >&2
    return 3
  }
  case "$hour" in
    '' | *[!0-9]*)
      printf 'fm-pc02-sleep-arming.sh: PC01 America/New_York local hour is unreadable (%s); refusing\n' "$hour" >&2
      return 3
      ;;
  esac
  if [ "$hour" -ge 22 ] || [ "$hour" -lt 8 ]; then
    printf 'fm-pc02-sleep-arming.sh: refusing a remote sleep test during quiet hours (%s:00 ET, 22:00-08:00); pass --attended only when the captain is present\n' "$hour" >&2
    return 3
  fi
  return 0
}

restore_production_window() {
  # Called from the test-sleep EXIT trap. The OS standby timer is never set
  # below 30 minutes, and this re-arms the watcher's production window too.
  # bin/fm-pc02-sleep-watcher.ps1 also restores 30 minutes itself after its
  # first wake from a test window, so this is a second, independent layer.
  if remote_bash <<<'true' >/dev/null 2>&1; then
    ( IDLE_MINUTES=30 WATCHER_IDLE_MINUTES=30; install_pieces >/dev/null 2>&1 ) \
      && printf 'restored production 30-minute window\n' \
      || printf 'warning: could not restore the production window; rerun install once PC02 answers\n' >&2
  else
    printf 'warning: PC02 is not reachable; the watcher restores the 30-minute window itself after its next wake\n' >&2
  fi
}

test_sleep_pieces() {
  local deadline started=0
  assert_attended || exit 3
  require_awake
  IDLE_MINUTES=30
  WATCHER_IDLE_MINUTES=$TEST_MINUTES
  trap 'restore_production_window' EXIT
  printf 'test: arming the watcher window at %s minute(s); the OS standby timer stays at 30 minutes\n' "$TEST_MINUTES"
  install_pieces

  deadline=$(( $(date +%s) + SLEEP_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! remote_bash <<<'true' >/dev/null 2>&1; then
      started=1
      break
    fi
    sleep 5
  done
  if [ "$started" -ne 1 ]; then
    printf 'test: PC02 did not sleep within %s seconds\n' "$SLEEP_TIMEOUT" >&2
    return 4
  fi
  printf 'test: PC02 is asleep; waking it with the Wi-Fi magic packet\n'
  if ! "$WAKE" ensure --host "$HOST" --timeout "$WAKE_TIMEOUT"; then
    printf 'test: the magic packet did not wake PC02; waiting up to %s seconds for the RTC wake backstop\n' "$BACKSTOP_WAIT" >&2
    deadline=$(( $(date +%s) + BACKSTOP_WAIT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if remote_bash <<<'true' >/dev/null 2>&1; then
        printf 'test: PC02 woke from the RTC backstop\n'
        break
      fi
      sleep 10
    done
    if ! remote_bash <<<'true' >/dev/null 2>&1; then
      printf 'test: PC02 is still unreachable after %s seconds; see data/pc02-sleep-arming/wake-failure.md\n' "$BACKSTOP_WAIT" >&2
      return 5
    fi
  fi
  printf 'test: PC02 answered; checking WSL and the runners\n'
  remote_bash <<'REMOTE'
printf 'wsl=%s\n' "$(uname -s)"
systemctl --user is-system-running 2>/dev/null || true
for unit in $(systemctl --user list-unit-files 'actions.runner.*.service' --no-legend 2>/dev/null | awk '{print $1}'); do
  printf 'runner %s %s\n' "$unit" "$(systemctl --user is-active "$unit" 2>/dev/null || true)"
done
REMOTE
  printf 'test: passed\n'
  return 0
}

check_attendance_pieces() {
  if assert_attended; then
    printf 'attended: allowed\n'
    return 0
  fi
  printf 'attended: refused\n' >&2
  exit 3
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
\$action = New-ScheduledTaskAction -Execute \$ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \`"\$InstallDir\\fm-pc02-sleep-watcher.ps1\`" -IdleMinutes $WATCHER_IDLE_MINUTES"
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
# The standing rule is S3 only. Turning hibernation off makes the forced
# SetSuspendState path incapable of selecting S4 and leaves Fast Startup off.
powercfg.exe /h off
if (\$LASTEXITCODE -ne 0) { throw "powercfg /h off failed: \$LASTEXITCODE" }
if (Get-Process -Name parsecd -ErrorAction SilentlyContinue) {
  powercfg.exe /requestsoverride PROCESS parsecd.exe System
  if (\$LASTEXITCODE -ne 0) { throw "powercfg requestsoverride failed: \$LASTEXITCODE" }
}
# Prove a wake-enabled backstop task can be registered before any test relies
# on one. The watcher registers the real task immediately before a sleep.
\$BackstopName = 'PC02-fm-sleep-wake-backstop-probe'
\$backstopAction = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit 0'
\$backstopTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(30)
\$backstopPrincipal = New-ScheduledTaskPrincipal -UserId \$user -LogonType Interactive -RunLevel Highest
\$backstopSettings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Unregister-ScheduledTask -TaskName \$BackstopName -Confirm:\$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName \$BackstopName -Action \$backstopAction -Trigger \$backstopTrigger -Principal \$backstopPrincipal -Settings \$backstopSettings -Force | Out-Null
\$probe = Get-ScheduledTask -TaskName \$BackstopName -ErrorAction Stop
if (-not \$probe.Settings.WakeToRun) { throw 'wake backstop task was not registered wake-enabled' }
Unregister-ScheduledTask -TaskName \$BackstopName -Confirm:\$false
Start-Sleep -Seconds 3
\$task = Get-ScheduledTask -TaskName \$TaskName
Write-Output "installed task=\$TaskName user=\$user idleMinutes=$IDLE_MINUTES watcherIdleMinutes=$WATCHER_IDLE_MINUTES hibernate=off wake-backstop=verified taskState=\$(\$task.State)"
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
  INSTALL_OUT=$out

  # Clean the staging files; the installed copies are the durable ones.
  rm -f "$setup_local"
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" "rm -rf '$temp_wsl'" >/dev/null 2>&1 || true

  verify_installed
}

verify_installed() {
  local guard standby hibernate task watcher sleep_states available watcher_action
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
  watcher_action=$(powershell_remote '(Get-ScheduledTask -TaskName "PC02-fm-sleep-watcher").Actions[0].Arguments' | tail -1)
  watcher=$(powershell_remote 'Get-Content -LiteralPath "C:\ProgramData\Pc02Power\status.txt" -ErrorAction SilentlyContinue' | tail -1)
  sleep_states=$(powershell_remote 'powercfg /a')
  available=$(printf '%s\n' "$sleep_states" | sed -n '1,/The following sleep states are not available/p')
  printf '%s\n' "$available" | grep -q 'Standby (S3)' \
    || die "PC02 does not report S3 standby as available; refusing to arm sleep"
  if printf '%s\n' "$available" | grep -Eq '^[[:space:]]+Hibernate[[:space:]]*$'; then
    die "PC02 still reports hibernation as available; refusing to arm a forced S3 sleep"
  fi
  case "${INSTALL_OUT:-}" in
    *'wake-backstop=verified'*) ;;
    *) die "the install did not verify a wake-enabled backstop task" ;;
  esac
  case "${INSTALL_OUT:-}" in
    *'hibernate=off'*) ;;
    *) die "the install did not turn hibernation off" ;;
  esac
  case "$watcher_action" in
    *"-IdleMinutes $WATCHER_IDLE_MINUTES"*) ;;
    *) die "the watcher task does not carry -IdleMinutes $WATCHER_IDLE_MINUTES: $watcher_action" ;;
  esac
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
  printf 'guard=%s standby_ac=%ss hibernate_ac=0 s3_only=yes wake_backstop=verified task=%s\n' "$guard" "$((16#$standby))" "$task"
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
  test-sleep) test_sleep_pieces ;;
  check-attendance) check_attendance_pieces ;;
  status) status_pieces ;;
  uninstall) uninstall_pieces ;;
esac
