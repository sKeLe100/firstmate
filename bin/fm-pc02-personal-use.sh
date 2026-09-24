#!/usr/bin/env bash
# fm-pc02-personal-use.sh - single owner of the captain's PC02 personal-use
# switch: a flag file in PC02's own WSL home directory that
# bin/fm-pc02-test-offload.sh checks fresh on every run (its "layer 1")
# before ever offloading a heavy test run there.
#
# The flag lives on PC02 itself, not on PC01, because the captain's own
# no-terminal Windows desktop toggle (installed by `install-toggle` below)
# must be able to flip it without any PC01/firstmate involvement.
# docs/pc02-outage-runbook.md documents both the desktop toggle and this
# script for the captain.
#
# Usage:
#   fm-pc02-personal-use.sh on              flip the switch on (PC01 only)
#   fm-pc02-personal-use.sh off             flip the switch off (PC02 may offload)
#   fm-pc02-personal-use.sh status          print "on" or "off"
#   fm-pc02-personal-use.sh install-toggle  (re)deploy the Windows desktop
#                                            toggle and resource-check script
#                                            onto PC02; safe to re-run
#
# Env overrides (match bin/fm-pc02-test-offload.sh's own):
#   FM_PC02_OFFLOAD_HOST                ssh target (default: pc02)
#   FM_PC02_OFFLOAD_PERSONAL_USE_FLAG   flag file path relative to PC02's
#                                      $HOME (default: .fm-pc02-personal-use)
#   FM_PC02_OFFLOAD_RESOURCE_CHECK_PS1  Windows-side resource-check script
#                                      path as WSL sees it (default:
#                                      /mnt/c/pc02-llm-server/bin/fm-pc02-resource-check.ps1)
#
# Exit status: 0 on success, 2 on a usage error, 1 if the ssh call itself
# fails (network/host problem, not a usage error).
set -u

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

ACTION=${1:-}
case "$ACTION" in
  on | off | status | install-toggle) ;;
  *)
    echo "fm-pc02-personal-use.sh: usage: fm-pc02-personal-use.sh on|off|status|install-toggle" >&2
    exit 2
    ;;
esac

HOST="${FM_PC02_OFFLOAD_HOST:-pc02}"
PERSONAL_USE_FLAG="${FM_PC02_OFFLOAD_PERSONAL_USE_FLAG:-.fm-pc02-personal-use}"
RESOURCE_CHECK_PS1="${FM_PC02_OFFLOAD_RESOURCE_CHECK_PS1:-/mnt/c/pc02-llm-server/bin/fm-pc02-resource-check.ps1}"
WIN_POWERSHELL='/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'

case "$ACTION" in
  on)
    cmd="touch \"\$HOME/$PERSONAL_USE_FLAG\" && echo on"
    # shellcheck disable=SC2029 # deliberate client-side expansion: cmd is already %q-quoted for the remote shell's re-parse.
    ssh "$HOST" "bash -lc $(printf '%q' "$cmd")" || exit 1
    ;;
  off)
    cmd="rm -f \"\$HOME/$PERSONAL_USE_FLAG\" && echo off"
    # shellcheck disable=SC2029 # deliberate client-side expansion: cmd is already %q-quoted for the remote shell's re-parse.
    ssh "$HOST" "bash -lc $(printf '%q' "$cmd")" || exit 1
    ;;
  status)
    cmd="[ -f \"\$HOME/$PERSONAL_USE_FLAG\" ] && echo on || echo off"
    # shellcheck disable=SC2029 # deliberate client-side expansion: cmd is already %q-quoted for the remote shell's re-parse.
    ssh "$HOST" "bash -lc $(printf '%q' "$cmd")" || exit 1
    ;;
  install-toggle)
    # The resource-check script: Windows-wide CPU% and summed GPU-engine
    # utilization%, the same two numbers bin/fm-pc02-test-offload.sh's
    # automatic layer-2 check reads. Colocated with the existing PC02
    # llama-swap tooling directory (docs/pc02-outage-runbook.md) rather than
    # inventing a second host-tooling location.
    resource_ps1=$(cat <<'PS1'
$cpu = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 2).CounterSamples[-1].CookedValue
$gpu = ((Get-Counter '\GPU Engine(*)\Utilization Percentage').CounterSamples | Measure-Object -Property CookedValue -Sum).Sum
Write-Output "cpu=$([math]::Round($cpu,1)) gpu=$([math]::Round($gpu,1))"
PS1
)
    # The no-terminal toggle: a double-clickable .vbs (wscript.exe runs it
    # with no visible window) that flips the same flag file over `wsl.exe`
    # and shows a brief confirmation popup. `wsl.exe` with no `-d` targets
    # PC02's only registered distro, the same one `ssh pc02` lands in.
    toggle_vbs=$(cat <<'VBS'
Set objShell = CreateObject("WScript.Shell")
toggleCmd = "if [ -f ~/.fm-pc02-personal-use ]; then rm -f ~/.fm-pc02-personal-use; echo OFF; else touch ~/.fm-pc02-personal-use; echo ON; fi"
Set objExec = objShell.Exec("wsl.exe bash -lc """ & toggleCmd & """")
Do While objExec.Status = 0
  WScript.Sleep 50
Loop
result = Trim(objExec.StdOut.ReadAll())
If InStr(result, "ON") > 0 Then
  objShell.Popup "PC02 personal use: ON - firstmate test runs will stay on PC01.", 4, "PC02 toggle"
Else
  objShell.Popup "PC02 personal use: OFF - firstmate may offload idle test runs here.", 4, "PC02 toggle"
End If
VBS
)
    remote_install=$(cat <<REMOTE
mkdir -p "\$(dirname $(printf '%q' "$RESOURCE_CHECK_PS1"))"
cat > $(printf '%q' "$RESOURCE_CHECK_PS1") <<'PS1EOF'
$resource_ps1
PS1EOF
mkdir -p /mnt/c/pc02-llm-server/bin
cat > /mnt/c/pc02-llm-server/bin/fm-pc02-personal-use-toggle.vbs <<'VBSEOF'
$toggle_vbs
VBSEOF
$WIN_POWERSHELL -NoProfile -Command '\$desktop = [Environment]::GetFolderPath("Desktop"); \$s = New-Object -ComObject WScript.Shell; \$lnk = \$s.CreateShortcut("\$desktop\PC02 Personal Use Toggle.lnk"); \$lnk.TargetPath = "C:\pc02-llm-server\bin\fm-pc02-personal-use-toggle.vbs"; \$lnk.IconLocation = "shell32.dll,44"; \$lnk.Description = "Toggle whether firstmate may offload idle test runs to PC02"; \$lnk.Save()'
REMOTE
)
    # shellcheck disable=SC2029 # deliberate client-side expansion: remote_install is already %q-quoted for the remote shell's re-parse.
    ssh "$HOST" "bash -lc $(printf '%q' "$remote_install")" || exit 1
    echo "fm-pc02-personal-use.sh: installed $RESOURCE_CHECK_PS1 and the Desktop toggle shortcut on $HOST" >&2
    ;;
esac
