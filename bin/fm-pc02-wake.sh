#!/usr/bin/env bash
# fm-pc02-wake.sh - the ONE owner of waking PC02 over Wi-Fi and of reporting
# whether it is awake or asleep. Firstmate calls it before sending PC02 work
# (the PC02 test offload, a pc02-llamaswap/* lane dispatch, a send or relaunch
# to the remote pc02-mate, and a CI job routed to the fm-pc02 runner label).
#
# Standing ruling (2026-08-24): PC02 wakes over Wi-Fi only, never cable; it
# stays asleep rather than shutting down; and wake is verified by SSH/TCP, never
# by ping. This script therefore sends a WoWLAN magic packet for PC02's Wi-Fi
# MAC on PC01's LAN broadcast (the method PC01 used for the passing 2026-08-26
# wake test) plus the last-known LAN address, then waits for SSH to answer.
#
# Usage:
#   fm-pc02-wake.sh ensure [--host HOST] [--if-managed] [--timeout SECS] [--quiet]
#   fm-pc02-wake.sh status [--host HOST] [--if-managed] [--quiet]
#   fm-pc02-wake.sh wake   [--host HOST] [--if-managed] [--quiet]
#   fm-pc02-wake.sh discover [--host HOST]
#   fm-pc02-wake.sh --help
#
# `ensure` returns 0 as soon as SSH answers; if it had to wake PC02 it waits up
# to --timeout seconds (default 120) and returns 4 when SSH never answers.
# `status` never sends a packet and always prints one word, even with --quiet
# (which only silences ensure/wake/discover output): awake, asleep, or unmanaged.
# A host with no SSH answer prints `asleep`; the standing posture keeps PC02
# asleep rather than powered off, so this is the "asleep, wakeable" reading
# fleet checks must use, never dead or offline.
# `discover` must run while PC02 is reachable; it caches PC02's Wi-Fi MAC, LAN
# address, and tailnet address in the wake config, and derives the LAN broadcast
# from PC01's route to that LAN address.
#
# Config: $FM_PC02_WAKE_CONFIG, default ~/.config/firstmate/pc02-wake.conf,
# one key=value per line: host, mac, broadcast, lan_ip, tailnet_ip.
# bin/fm-pc02-sleep-arming.sh install writes it. Values are read, never sourced.
#
# Env overrides:
#   FM_PC02_WAKE_HOST       default SSH target and config host (default: pc02)
#   FM_PC02_WAKE_CONFIG     config path (default above)
#   FM_PC02_WAKE_HOSTS      extra managed SSH aliases, space separated
#   FM_PC02_WAKE_TIMEOUT    default ensure wait seconds (default: 120)
#   FM_PC02_WAKE_PROBE_TIMEOUT  SSH connect timeout seconds (default: 3)
#   FM_PC02_WAKE_PORT       magic-packet UDP port (default: 9)
#   FM_PC02_WAKE_PACKETS    packet count (default: 3)
#   FM_PC02_WAKE_DRY_RUN    1 prints the packet destinations and sends nothing
#   FM_PC02_WAKE=0          ensure and wake send no packet: they probe, print
#                           awake/asleep, and return 4 when not awake (status and
#                           discover are unaffected). Per-path switches also exist:
#                           FM_PC02_WAKE_OFFLOAD (test offload), FM_PC02_WAKE_CI (CI
#                           routing), and FM_PC02_WAKE (fm-spawn lane dispatch).
#
# Exit status: 0 success/awake/status answered; 4 not awake after `ensure`
# or `wake`; 2 usage; 1 a missing config, missing python3, or failed discovery.
set -u

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-pc02-wake.sh: %s\n' "$1" >&2
  exit 1
}

MODE=${1:-}
case "$MODE" in
  ensure | status | wake | discover) shift ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "fm-pc02-wake.sh: usage: fm-pc02-wake.sh ensure|status|wake|discover [options]" >&2
    exit 2
    ;;
esac

HOST=${FM_PC02_WAKE_HOST:-pc02}
CONFIG=${FM_PC02_WAKE_CONFIG:-$HOME/.config/firstmate/pc02-wake.conf}
IF_MANAGED=0
QUIET=0
TIMEOUT=${FM_PC02_WAKE_TIMEOUT:-120}
PROBE_TIMEOUT=${FM_PC02_WAKE_PROBE_TIMEOUT:-3}
PORT=${FM_PC02_WAKE_PORT:-9}
PACKETS=${FM_PC02_WAKE_PACKETS:-3}
DRY_RUN=${FM_PC02_WAKE_DRY_RUN:-0}

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
    --if-managed)
      IF_MANAGED=1
      shift
      ;;
    --timeout)
      [ "$#" -ge 2 ] || die "--timeout needs a value"
      TIMEOUT=$2
      shift 2
      ;;
    --timeout=*)
      TIMEOUT=${1#--timeout=}
      shift
      ;;
    --quiet)
      QUIET=1
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
case "$TIMEOUT" in
  '' | *[!0-9]*) die "--timeout must be a non-negative integer" ;;
esac
case "$PROBE_TIMEOUT" in
  '' | *[!0-9]*) die "FM_PC02_WAKE_PROBE_TIMEOUT must be a positive integer" ;;
esac
case "$PORT" in
  '' | *[!0-9]*) die "FM_PC02_WAKE_PORT must be a positive integer" ;;
esac
case "$PACKETS" in
  '' | *[!0-9]*) die "FM_PC02_WAKE_PACKETS must be a positive integer" ;;
esac

config_get() {  # <key>: last value wins, matching the fleet's flat config style.
  [ -f "$CONFIG" ] || return 0
  sed -n "s/^$1=//p" "$CONFIG" 2>/dev/null | tail -1
}

config_host=$(config_get host)
config_mac=$(config_get mac)
config_broadcast=$(config_get broadcast)
config_lan=$(config_get lan_ip)
config_tailnet=$(config_get tailnet_ip)

is_managed() {
  local candidate
  for candidate in "$config_host" "$config_lan" "$config_tailnet" ${FM_PC02_WAKE_HOSTS:-}; do
    [ -n "$candidate" ] || continue
    [ "$candidate" = "$HOST" ] && return 0
  done
  return 1
}

if [ "$IF_MANAGED" -eq 1 ] && ! is_managed; then
  { [ "$QUIET" -eq 1 ] && [ "$MODE" != status ]; } || printf 'unmanaged\n'
  exit 0
fi

probe() {
  ssh -o BatchMode=yes -o ConnectTimeout="$PROBE_TIMEOUT" "$HOST" true </dev/null >/dev/null 2>&1
}

send_packets() {
  local destinations=() dest
  [ -n "$config_mac" ] || die "no PC02 Wi-Fi MAC in $CONFIG; run fm-pc02-sleep-arming.sh install while PC02 is awake"
  for dest in "$config_broadcast" "$config_lan"; do
    [ -n "$dest" ] || continue
    destinations+=("$dest")
  done
  [ "${#destinations[@]}" -gt 0 ] || die "no broadcast or LAN address in $CONFIG"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'dry-run: would send %s magic packet(s) for %s to %s:%s\n' \
      "$PACKETS" "$config_mac" "${destinations[*]}" "$PORT"
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || die "python3 is required to build the magic packet"
  python3 - "$config_mac" "$PORT" "$PACKETS" "${destinations[@]}" <<'PY'
import socket
import sys
import time

mac = sys.argv[1]
port = int(sys.argv[2])
count = int(sys.argv[3])
destinations = sys.argv[4:]
octets = mac.replace('-', ':').split(':')
if len(octets) != 6 or any(len(o) != 2 for o in octets):
    raise SystemExit(f"invalid MAC address: {mac}")
try:
    mac_bytes = bytes(int(o, 16) for o in octets)
except ValueError:
    raise SystemExit(f"invalid MAC address: {mac}")
packet = b'\xff' * 6 + mac_bytes * 16
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
try:
    for index in range(count):
        for destination in destinations:
            sock.sendto(packet, (destination, port))
        if index + 1 < count:
            time.sleep(0.1)
finally:
    sock.close()
PY
}

discover() {
  local info mac lan tailnet dev cidr
  probe || die "PC02 is not reachable at $HOST; discover needs it awake"
  info=$(ssh -o BatchMode=yes -o ConnectTimeout="$PROBE_TIMEOUT" "$HOST" bash -s 2>/dev/null <<'REMOTE' | tr -d '\r' | tail -1
/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command '
  $w = Get-NetAdapter -Name Wi-Fi
  $ip = (Get-NetIPAddress -InterfaceAlias Wi-Fi -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1).IPAddress
  $t = (Get-NetIPAddress -InterfaceAlias Tailscale -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
  Write-Output ("{0}|{1}|{2}" -f $w.MacAddress, $ip, $t)
'
REMOTE
  ) || die "could not read PC02 adapter addresses"
  mac=${info%%|*}
  info=${info#*|}
  lan=${info%%|*}
  tailnet=${info#*|}
  [ -n "$mac" ] && [ -n "$lan" ] || die "PC02 returned no Wi-Fi MAC or LAN address"
  dev=$(ip -4 route get "$lan" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
  cidr=
  [ -n "$dev" ] && cidr=$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | head -1)
  broadcast=
  if [ -n "$cidr" ]; then
    broadcast=$(python3 - "$cidr" <<'PY' 2>/dev/null || true
import ipaddress, sys
net = ipaddress.ip_interface(sys.argv[1]).network
print(net.broadcast_address)
PY
)
  fi
  [ -n "$broadcast" ] || broadcast=255.255.255.255
  mkdir -p "$(dirname "$CONFIG")" || die "could not create $(dirname "$CONFIG")"
  tmp=$(mktemp "${CONFIG}.XXXXXX") || die "could not create a temporary config"
  {
    printf 'host=%s\n' "${config_host:-$HOST}"
    printf 'mac=%s\n' "$mac"
    printf 'broadcast=%s\n' "$broadcast"
    printf 'lan_ip=%s\n' "$lan"
    printf 'tailnet_ip=%s\n' "$tailnet"
  } >"$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$CONFIG" || die "could not replace $CONFIG"
  [ "$QUIET" -eq 1 ] || printf 'discovered %s mac=%s broadcast=%s lan_ip=%s tailnet_ip=%s\n' \
    "${config_host:-$HOST}" "$mac" "$broadcast" "$lan" "$tailnet"
}

case "$MODE" in
  discover)
    discover
    exit 0
    ;;
  status)
    if probe; then
      printf 'awake\n'
    else
      printf 'asleep\n'
    fi
    exit 0
    ;;
  wake)
    if probe; then
      [ "$QUIET" -eq 1 ] || printf 'awake\n'
      exit 0
    fi
    if [ "${FM_PC02_WAKE:-1}" = 0 ]; then
      [ "$QUIET" -eq 1 ] || printf 'asleep\n'
      exit 4
    fi
    send_packets
    [ "$QUIET" -eq 1 ] || printf 'waking\n'
    exit 0
    ;;
  ensure)
    if probe; then
      [ "$QUIET" -eq 1 ] || printf 'awake\n'
      exit 0
    fi
    if [ "${FM_PC02_WAKE:-1}" = 0 ]; then
      [ "$QUIET" -eq 1 ] || printf 'asleep\n'
      exit 4
    fi
    send_packets
    deadline=$(( $(date +%s) + TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if probe; then
        [ "$QUIET" -eq 1 ] || printf 'awake\n'
        exit 0
      fi
      sleep 2
    done
    [ "$QUIET" -eq 1 ] || printf 'asleep\n'
    exit 4
    ;;
esac
