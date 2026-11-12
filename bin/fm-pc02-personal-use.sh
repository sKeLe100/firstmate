#!/usr/bin/env bash
# fm-pc02-personal-use.sh - single owner of the captain's PC02 personal-use
# switch: a flag file in PC02's own WSL home directory that
# bin/fm-pc02-test-offload.sh checks fresh on every run before ever
# offloading a heavy test or lint run there. This switch is the only thing
# that stops PC02 testing.
#
# The same flag gates PC02's self-hosted GitHub Actions runners:
# `install-toggle` deploys bin/fm-pc02-personal-use-runners.sh, a user path
# unit that triggers it, and a drop-in per discovered `actions.runner.*` unit,
# so the runners stop when the flag appears and start when it disappears - from
# either the PC01 command below or the Windows desktop toggle.
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
#                                            toggle and the runner gate onto
#                                            PC02; safe to re-run
#
# Env overrides (match bin/fm-pc02-test-offload.sh's own):
#   FM_PC02_OFFLOAD_HOST                ssh target (default: pc02)
#   FM_PC02_OFFLOAD_PERSONAL_USE_FLAG   flag file path relative to PC02's
#                                      $HOME (default: .fm-pc02-personal-use)
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
    # The no-terminal toggle: a double-clickable .vbs (wscript.exe runs it
    # with no visible window) that flips the same flag file over `wsl.exe`
    # and shows a brief confirmation popup. `wsl.exe` with no `-d` targets
    # PC02's only registered distro, the same one `ssh pc02` lands in.
    flag_q=$(printf '%q' "$PERSONAL_USE_FLAG")
    toggle_vbs=$(cat <<VBS
Set objShell = CreateObject("WScript.Shell")
toggleCmd = "if [ -f ~/$flag_q ]; then rm -f ~/$flag_q; echo OFF; else touch ~/$flag_q; echo ON; fi"
Set objExec = objShell.Exec("wsl.exe bash -lc """ & toggleCmd & """")
Do While objExec.Status = 0
  WScript.Sleep 50
Loop
result = Trim(objExec.StdOut.ReadAll())
If InStr(result, "ON") > 0 Then
  objShell.Popup "PC02 personal use: ON - test runs stay on PC01 and PC02 runners stop.", 4, "PC02 toggle"
Else
  objShell.Popup "PC02 personal use: OFF - test runs may offload here and PC02 runners start.", 4, "PC02 toggle"
End If
VBS
)
    remote_install=$(cat <<REMOTE
mkdir -p /mnt/c/pc02-llm-server/bin
cat > /mnt/c/pc02-llm-server/bin/fm-pc02-personal-use-toggle.vbs <<'VBSEOF'
$toggle_vbs
VBSEOF
$WIN_POWERSHELL -NoProfile -Command '\$desktop = [Environment]::GetFolderPath("Desktop"); \$s = New-Object -ComObject WScript.Shell; \$lnk = \$s.CreateShortcut("\$desktop\PC02 Personal Use Toggle.lnk"); \$lnk.TargetPath = "C:\pc02-llm-server\bin\fm-pc02-personal-use-toggle.vbs"; \$lnk.IconLocation = "shell32.dll,44"; \$lnk.Description = "Toggle whether firstmate may offload idle test runs to PC02"; \$lnk.Save()'
REMOTE
)
    # 1. Install the Windows desktop toggle.
    # shellcheck disable=SC2029 # deliberate client-side expansion: remote_install is already %q-quoted for the remote shell's re-parse.
    ssh "$HOST" "bash -lc $(printf '%q' "$remote_install")" || exit 1

    # 2. Stream the runner-gate helper over stdin, so the remote shell never
    # re-parses its contents.
    self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
    runner_helper="$self_dir/fm-pc02-personal-use-runners.sh"
    if [ ! -r "$runner_helper" ]; then
      echo "fm-pc02-personal-use.sh: missing $runner_helper" >&2
      exit 1
    fi
    # shellcheck disable=SC2016 # $HOME must reach the remote shell, not expand here.
    helper_install='mkdir -p "$HOME/.local/bin" && cat > "$HOME/.local/bin/fm-pc02-personal-use-runners.sh" && chmod 755 "$HOME/.local/bin/fm-pc02-personal-use-runners.sh"'
    # shellcheck disable=SC2029 # deliberate client-side expansion: helper_install is already %q-quoted for the remote shell's re-parse.
    ssh "$HOST" "bash -lc $(printf '%q' "$helper_install")" < "$runner_helper" || exit 1

    # 3. Deploy the path unit, its service, and one drop-in per discovered
    # actions.runner.* unit; then converge the runners to the current flag.
    # Discovery is by pattern so a newly registered runner is gated too.
    remote_units=$(cat <<REMOTE
set -eu
flag=$flag_q
case "\$flag" in
  /*) watch_path=\$flag ;;
  *) watch_path="%h/\$flag" ;;
esac
unit_dir="\$HOME/.config/systemd/user"
mkdir -p "\$unit_dir"
cat > "\$unit_dir/fm-pc02-personal-use-runners.service" <<'UNITEOF'
[Unit]
Description=Gate PC02 self-hosted GitHub Actions runners on the personal-use flag

[Service]
Type=oneshot
ExecStart=%h/.local/bin/fm-pc02-personal-use-runners.sh
TimeoutStartSec=15min
UNITEOF
printf 'Environment="FM_PC02_OFFLOAD_PERSONAL_USE_FLAG=%s"\n' "$PERSONAL_USE_FLAG" >> "\$unit_dir/fm-pc02-personal-use-runners.service"
{
  echo '[Unit]'
  echo "Description=Watch PC02's personal-use flag and gate the self-hosted runners"
  echo
  echo '[Path]'
  echo "PathChanged=\$watch_path"
  echo
  echo '[Install]'
  echo 'WantedBy=default.target'
} > "\$unit_dir/fm-pc02-personal-use-runners.path"
for unit in \$(systemctl --user list-unit-files 'actions.runner.*.service' --no-legend --no-pager | awk 'NF { print \$1 }'); do
  case "\$unit" in
    actions.runner.*.service) ;;
    *) continue ;;
  esac
  mkdir -p "\$unit_dir/\$unit.d"
  printf '[Unit]\nConditionPathExists=!%s\n' "\$watch_path" > "\$unit_dir/\$unit.d/10-fm-pc02-personal-use.conf"
done
systemctl --user daemon-reload
systemctl --user enable fm-pc02-personal-use-runners.path
systemctl --user restart fm-pc02-personal-use-runners.path
"\$HOME/.local/bin/fm-pc02-personal-use-runners.sh"
REMOTE
)
    # shellcheck disable=SC2029 # deliberate client-side expansion: remote_units is already %q-quoted for the remote shell's re-parse.
    ssh "$HOST" "bash -lc $(printf '%q' "$remote_units")" || exit 1
    echo "fm-pc02-personal-use.sh: installed the Desktop toggle and runner gate on $HOST" >&2
    ;;
esac
