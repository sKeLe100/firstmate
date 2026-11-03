#!/usr/bin/env bash
# Read-only cross-host survey of the surfaces bin/fm-pc02-test-offload.sh compares.
set -u
ver() { local t=$1 a=--version; [ "$t" != tmux ] || a=-V; local p; p=$(type -P "$t" 2>/dev/null) || { echo "$t=absent"; return; }; local v; v=$(timeout 5 "$p" "$a" 2>&1 </dev/null); v=$(printf '%s\n' "$v" | awk 'NR==1{f=$0} /[0-9]/{print; found=1; exit} END{if(!found)print f}'); printf '%s=%s\n' "$t" "$v"; }
echo "host=$(hostname)"
for t in git bash python3 jq node shellcheck actionlint ruby chromium herdr pi tmux; do ver "$t"; done
echo "nofile=$(ulimit -n)"
echo "LC_ALL=${LC_ALL-}|LANG=${LANG-}|TZ=${TZ-}"
echo "cpus=$(nproc) mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)"
